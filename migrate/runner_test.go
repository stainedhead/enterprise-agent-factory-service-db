package migrate_test

// Runner behaviour: lock timeout, error paths of Load, Up, Down and Version (PRD §6 Observability and
// Quality: migrate sets a lock_timeout; migrate keeps ≥ 90% coverage).

import (
	"errors"
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

// failFS fails ReadDir, or ReadFile for one name.
type failFS struct {
	fstest.MapFS
	failDir  bool
	failFile string
}

func (f failFS) ReadDir(name string) ([]fs.DirEntry, error) {
	if f.failDir {
		return nil, errors.New("boom")
	}
	return f.MapFS.ReadDir(name)
}

func (f failFS) ReadFile(name string) ([]byte, error) {
	if name == f.failFile {
		return nil, errors.New("boom")
	}
	return f.MapFS.ReadFile(name)
}

func TestLoadErrors(t *testing.T) {
	ok := []byte("select 1")
	cases := []struct {
		name string
		fsys fs.FS
		want string
	}{
		{"unreadable directory", failFS{MapFS: fstest.MapFS{}, failDir: true}, "read migrations"},
		{"unreadable file", failFS{MapFS: fstest.MapFS{"000001_a.up.sql": {Data: ok}}, failFile: "000001_a.up.sql"}, "read 000001_a.up.sql"},
		{"two names for one version", fstest.MapFS{"000001_a.up.sql": {Data: ok}, "000001_b.down.sql": {Data: ok}}, "two names"},
		{"down without up", fstest.MapFS{"000001_a.down.sql": {Data: ok}}, "no up script"},
		{"does not start at 1", fstest.MapFS{"000002_a.up.sql": {Data: ok}}, "contiguous"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := migrate.Load(c.fsys)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want error containing %q, got %v", c.want, err)
			}
		})
	}
	t.Run("other files are ignored", func(t *testing.T) {
		migs, err := migrate.Load(fstest.MapFS{"000001_a.up.sql": {Data: ok}, "README.md": {Data: ok}, "embed.go": {Data: ok}})
		if err != nil || len(migs) != 1 || migs[0].Down != "" {
			t.Fatalf("migs=%v err=%v", migs, err)
		}
	})
}

func TestUpAndDownErrors(t *testing.T) {
	ctx := t.Context()

	t.Run("a failing up stops the run and keeps earlier migrations", func(t *testing.T) {
		conn := connect(t)
		migs := []migrate.Migration{
			{Version: 1, Name: "ok", Up: "CREATE TABLE public.t1 (id int)", Down: "DROP TABLE public.t1"},
			{Version: 2, Name: "bad", Up: "CREATE TABLE public.t1 (id int)"},
		}
		n, err := migrate.Up(ctx, conn, migs)
		if n != 1 || err == nil || !strings.Contains(err.Error(), "apply 000002_bad") {
			t.Fatalf("n=%d err=%v", n, err)
		}
		if v, _ := migrate.Version(ctx, conn); v != 1 {
			t.Fatalf("version = %d, want 1", v)
		}
	})
	t.Run("down needs a down script", func(t *testing.T) {
		conn := connect(t)
		migs := []migrate.Migration{{Version: 1, Name: "nodown", Up: "SELECT 1"}}
		if _, err := migrate.Up(ctx, conn, migs); err != nil {
			t.Fatal(err)
		}
		if _, err := migrate.Down(ctx, conn, migs, 1); err == nil || !strings.Contains(err.Error(), "no down script") {
			t.Fatalf("want no down script, got %v", err)
		}
	})
	t.Run("a failing down is reported and leaves the version", func(t *testing.T) {
		conn := connect(t)
		migs := []migrate.Migration{{Version: 1, Name: "baddown", Up: "SELECT 1", Down: "DROP TABLE public.missing"}}
		if _, err := migrate.Up(ctx, conn, migs); err != nil {
			t.Fatal(err)
		}
		if _, err := migrate.Down(ctx, conn, migs, 1); err == nil || !strings.Contains(err.Error(), "revert 000001_baddown") {
			t.Fatalf("want revert error, got %v", err)
		}
		if v, _ := migrate.Version(ctx, conn); v != 1 {
			t.Fatalf("version = %d, want 1", v)
		}
	})
	t.Run("down skips migrations that were never applied", func(t *testing.T) {
		conn := connect(t)
		migs := []migrate.Migration{{Version: 1, Name: "a", Up: "SELECT 1", Down: "SELECT 1"}, {Version: 2, Name: "b", Up: "SELECT 1", Down: "SELECT 1"}}
		if _, err := migrate.Up(ctx, conn, migs[:1]); err != nil {
			t.Fatal(err)
		}
		if n, err := migrate.Down(ctx, conn, migs, 2); err != nil || n != 1 {
			t.Fatalf("n=%d err=%v", n, err)
		}
	})
	t.Run("a closed connection fails cleanly", func(t *testing.T) {
		conn := connect(t)
		_ = conn.Close(ctx)
		migs := []migrate.Migration{{Version: 1, Name: "a", Up: "SELECT 1", Down: "SELECT 1"}}
		if _, err := migrate.Up(ctx, conn, migs); err == nil || !strings.Contains(err.Error(), "acquire migration lock") {
			t.Fatalf("up: %v", err)
		}
		if _, err := migrate.Down(ctx, conn, migs, 1); err == nil {
			t.Fatal("down on a closed connection succeeded")
		}
		if _, err := migrate.Version(ctx, conn); err == nil || !strings.Contains(err.Error(), "ensure tracking table") {
			t.Fatalf("version: %v", err)
		}
	})
	t.Run("an unreadable tracking table fails up and down", func(t *testing.T) {
		conn := connect(t)
		if _, err := conn.Exec(ctx, `CREATE TABLE public.afs_schema_migrations (version text PRIMARY KEY, name text NOT NULL, checksum text NOT NULL);
			INSERT INTO public.afs_schema_migrations VALUES ('x', 'x', 'x')`); err != nil {
			t.Fatal(err)
		}
		migs := []migrate.Migration{{Version: 1, Name: "a", Up: "SELECT 1", Down: "SELECT 1"}}
		if _, err := migrate.Up(ctx, conn, migs); err == nil {
			t.Fatal("up over a malformed tracking table succeeded")
		}
		if _, err := migrate.Down(ctx, conn, migs, 1); err == nil {
			t.Fatal("down over a malformed tracking table succeeded")
		}
	})
}

// A migration waiting on a lock held by live traffic must fail after the lock timeout instead of
// queueing every later query on that table behind it.
func TestLockTimeoutStopsBlockedMigration(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	other, err := pgx.ConnectConfig(ctx, conn.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = other.Close(ctx) }()
	tx, err := other.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `LOCK TABLE afs.teams IN ACCESS SHARE MODE`); err != nil {
		t.Fatal(err)
	}

	migs, _ := migrate.Load(migrations.FS)
	blocked := append(migs, migrate.Migration{Version: len(migs) + 1, Name: "blocked",
		Up: "ALTER TABLE afs.teams ADD COLUMN lock_probe integer"})

	t.Run("a blocked DDL fails with lock_not_available", func(t *testing.T) {
		start := time.Now()
		n, err := migrate.Up(ctx, conn, blocked, migrate.WithLockTimeout(200*time.Millisecond))
		if n != 0 || sqlState(err) != "55P03" {
			t.Fatalf("n=%d err=%v, want 55P03", n, err)
		}
		if time.Since(start) > 5*time.Second {
			t.Fatalf("took %v", time.Since(start))
		}
	})
	t.Run("the lock timeout is local to the migration transaction", func(t *testing.T) {
		var v string
		if err := conn.QueryRow(ctx, `SHOW lock_timeout`).Scan(&v); err != nil || v != "0" {
			t.Fatalf("lock_timeout after Up = %q, %v", v, err)
		}
	})
	t.Run("down applies the timeout too", func(t *testing.T) {
		if err := tx.Rollback(ctx); err != nil {
			t.Fatal(err)
		}
		if _, err := migrate.Up(ctx, conn, blocked); err != nil {
			t.Fatal(err)
		}
		blocked[len(blocked)-1].Down = "ALTER TABLE afs.teams DROP COLUMN lock_probe"
		tx2, err := other.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx2.Rollback(ctx) }()
		if _, err := tx2.Exec(ctx, `LOCK TABLE afs.teams IN ACCESS SHARE MODE`); err != nil {
			t.Fatal(err)
		}
		if _, err := migrate.Down(ctx, conn, blocked, 1, migrate.WithLockTimeout(200*time.Millisecond)); sqlState(err) != "55P03" {
			t.Fatalf("down: want 55P03, got %v", err)
		}
	})
}

// The lock timeout is set inside each migration's transaction: the default, an override, or none.
func TestLockTimeoutIsSetPerMigration(t *testing.T) {
	ctx := t.Context()
	probe := func(want string) []migrate.Migration {
		return []migrate.Migration{{Version: 1, Name: "probe", Up: `DO $$ BEGIN
			IF current_setting('lock_timeout') <> '` + want + `' THEN
				RAISE EXCEPTION 'lock_timeout is %', current_setting('lock_timeout');
			END IF; END $$`, Down: `DO $$ BEGIN
			IF current_setting('lock_timeout') <> '` + want + `' THEN
				RAISE EXCEPTION 'lock_timeout is %', current_setting('lock_timeout');
			END IF; END $$`}}
	}
	cases := []struct {
		name string
		opts []migrate.Option
		want string
	}{
		{"default", nil, "10s"},
		{"override", []migrate.Option{migrate.WithLockTimeout(1500 * time.Millisecond)}, "1500ms"},
		{"zero disables it", []migrate.Option{migrate.WithLockTimeout(0)}, "0"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			conn := connect(t)
			migs := probe(c.want)
			if _, err := migrate.Up(ctx, conn, migs, c.opts...); err != nil {
				t.Fatalf("up: %v", err)
			}
			if _, err := migrate.Down(ctx, conn, migs, 1, c.opts...); err != nil {
				t.Fatalf("down: %v", err)
			}
		})
	}
	if migrate.DefaultLockTimeout != 10*time.Second {
		t.Fatalf("DefaultLockTimeout = %v", migrate.DefaultLockTimeout)
	}
}

// R-1: a negative lock timeout is refused before any SQL runs; a sub-millisecond one is not "none".
func TestLockTimeoutBounds(t *testing.T) {
	ctx := t.Context()
	t.Run("negative is refused before the lock", func(t *testing.T) {
		conn := connect(t)
		migs := []migrate.Migration{{Version: 1, Name: "a", Up: "CREATE TABLE public.t_neg (id int)", Down: "DROP TABLE public.t_neg"}}
		if n, err := migrate.Up(ctx, conn, migs, migrate.WithLockTimeout(-time.Second)); n != 0 || !errors.Is(err, migrate.ErrNegativeLockTimeout) {
			t.Fatalf("up: n=%d err=%v", n, err)
		}
		if n, err := migrate.Down(ctx, conn, migs, 1, migrate.WithLockTimeout(-time.Second)); n != 0 || !errors.Is(err, migrate.ErrNegativeLockTimeout) {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		var tracked bool
		if err := conn.QueryRow(ctx, `SELECT to_regclass('public.afs_schema_migrations') IS NOT NULL`).Scan(&tracked); err != nil || tracked {
			t.Fatalf("SQL ran before the option was checked (tracking table exists=%v, %v)", tracked, err)
		}
	})
	t.Run("sub-millisecond rounds up to 1ms", func(t *testing.T) {
		conn := connect(t)
		probe := []migrate.Migration{{Version: 1, Name: "probe", Up: `DO $$ BEGIN
			IF current_setting('lock_timeout') <> '1ms' THEN
				RAISE EXCEPTION 'lock_timeout is %', current_setting('lock_timeout');
			END IF; END $$`}}
		if _, err := migrate.Up(ctx, conn, probe, migrate.WithLockTimeout(300*time.Microsecond)); err != nil {
			t.Fatal(err)
		}
	})
}
