// Package migrate applies the embedded Agent Factory migrations to PostgreSQL. afs-api and the
// afs-migrate command both use it, so there is one migration path everywhere.
package migrate

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"slices"
	"strconv"

	"github.com/jackc/pgx/v5"
)

// Migration is one numbered migration with its up and (optional) down SQL.
type Migration struct {
	Version int
	Name    string
	Up      string
	Down    string
}

// Checksum identifies the up script; applied migrations must not change after they merge.
func (m Migration) Checksum() string {
	sum := sha256.Sum256([]byte(m.Up))
	return hex.EncodeToString(sum[:])
}

var fileRe = regexp.MustCompile(`^(\d{6})_([a-z0-9_]+)\.(up|down)\.sql$`)

// Load reads migrations from fsys, sorted by version.
func Load(fsys fs.FS) ([]Migration, error) {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return nil, fmt.Errorf("read migrations: %w", err)
	}
	byVersion := map[int]*Migration{}
	for _, e := range entries {
		m := fileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		v, _ := strconv.Atoi(m[1])
		body, err := fs.ReadFile(fsys, e.Name())
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", e.Name(), err)
		}
		mig := byVersion[v]
		if mig == nil {
			mig = &Migration{Version: v, Name: m[2]}
			byVersion[v] = mig
		}
		if mig.Name != m[2] {
			return nil, fmt.Errorf("migration %06d has two names: %s and %s", v, mig.Name, m[2])
		}
		if m[3] == "up" {
			mig.Up = string(body)
		} else {
			mig.Down = string(body)
		}
	}
	out := make([]Migration, 0, len(byVersion))
	for _, m := range byVersion {
		if m.Up == "" {
			return nil, fmt.Errorf("migration %06d_%s has no up script", m.Version, m.Name)
		}
		out = append(out, *m)
	}
	slices.SortFunc(out, func(a, b Migration) int { return a.Version - b.Version })
	for i, m := range out {
		if m.Version != i+1 {
			return nil, fmt.Errorf("migration versions must be contiguous from 1; found %06d at position %d", m.Version, i+1)
		}
	}
	return out, nil
}

const trackingDDL = `CREATE TABLE IF NOT EXISTS public.afs_schema_migrations (
  version    integer PRIMARY KEY,
  name       text NOT NULL,
  checksum   text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
)`

// lockKey is the advisory lock that serializes concurrent migrators (e.g. several afs-api pods).
const lockKey = 7_302_026_1120

// ErrChecksumMismatch means an applied migration's file was edited after it was applied.
var ErrChecksumMismatch = errors.New("applied migration changed")

// Up applies every pending migration, each in its own transaction, and returns how many ran.
func Up(ctx context.Context, conn *pgx.Conn, migs []Migration) (int, error) {
	return withLock(ctx, conn, func() (int, error) {
		applied, err := appliedChecksums(ctx, conn)
		if err != nil {
			return 0, err
		}
		n := 0
		for _, m := range migs {
			if sum, ok := applied[m.Version]; ok {
				if sum != m.Checksum() {
					return n, fmt.Errorf("%06d_%s: %w", m.Version, m.Name, ErrChecksumMismatch)
				}
				continue
			}
			err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, m.Up); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `INSERT INTO public.afs_schema_migrations (version, name, checksum) VALUES ($1, $2, $3)`,
					m.Version, m.Name, m.Checksum())
				return err
			})
			if err != nil {
				return n, fmt.Errorf("apply %06d_%s: %w", m.Version, m.Name, err)
			}
			n++
		}
		return n, nil
	})
}

// Down reverts the most recent `steps` applied migrations. For local development and tests.
func Down(ctx context.Context, conn *pgx.Conn, migs []Migration, steps int) (int, error) {
	return withLock(ctx, conn, func() (int, error) {
		applied, err := appliedChecksums(ctx, conn)
		if err != nil {
			return 0, err
		}
		n := 0
		for i := len(migs) - 1; i >= 0 && n < steps; i-- {
			m := migs[i]
			if _, ok := applied[m.Version]; !ok {
				continue
			}
			if m.Down == "" {
				return n, fmt.Errorf("%06d_%s has no down script", m.Version, m.Name)
			}
			err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, m.Down); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `DELETE FROM public.afs_schema_migrations WHERE version = $1`, m.Version)
				return err
			})
			if err != nil {
				return n, fmt.Errorf("revert %06d_%s: %w", m.Version, m.Name, err)
			}
			n++
		}
		return n, nil
	})
}

// Version returns the highest applied migration version, or 0.
func Version(ctx context.Context, conn *pgx.Conn) (int, error) {
	if _, err := conn.Exec(ctx, trackingDDL); err != nil {
		return 0, fmt.Errorf("ensure tracking table: %w", err)
	}
	var v int
	err := conn.QueryRow(ctx, `SELECT coalesce(max(version), 0) FROM public.afs_schema_migrations`).Scan(&v)
	return v, err
}

func appliedChecksums(ctx context.Context, conn *pgx.Conn) (map[int]string, error) {
	if _, err := conn.Exec(ctx, trackingDDL); err != nil {
		return nil, fmt.Errorf("ensure tracking table: %w", err)
	}
	rows, err := conn.Query(ctx, `SELECT version, checksum FROM public.afs_schema_migrations`)
	if err != nil {
		return nil, err
	}
	out := map[int]string{}
	for rows.Next() {
		var v int
		var s string
		if err := rows.Scan(&v, &s); err != nil {
			return nil, err
		}
		out[v] = s
	}
	return out, rows.Err()
}

func withLock(ctx context.Context, conn *pgx.Conn, fn func() (int, error)) (n int, err error) {
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, int64(lockKey)); err != nil {
		return 0, fmt.Errorf("acquire migration lock: %w", err)
	}
	defer func() {
		if _, uerr := conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, int64(lockKey)); uerr != nil && err == nil {
			err = fmt.Errorf("release migration lock: %w", uerr)
		}
	}()
	return fn()
}
