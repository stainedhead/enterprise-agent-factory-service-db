package migrate_test

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stainedhead/enterprise-agent-factory-service-db/bootstrap"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

func TestLoadEmbedded(t *testing.T) {
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if len(migs) < 2 {
		t.Fatalf("want at least 2 migrations, got %d", len(migs))
	}
	for _, m := range migs {
		if m.Down == "" {
			t.Errorf("%06d_%s has no down script", m.Version, m.Name)
		}
	}
}

func TestLoadRejectsGaps(t *testing.T) {
	fsys := fstest.MapFS{
		"000001_a.up.sql": {Data: []byte("select 1")},
		"000003_c.up.sql": {Data: []byte("select 1")},
	}
	if _, err := migrate.Load(fsys); err == nil {
		t.Fatal("expected an error for a version gap")
	}
}

// connect opens a fresh database for one test. Skips when AFS_TEST_DATABASE_URL is unset.
func connect(t *testing.T) *pgx.Conn {
	t.Helper()
	url := os.Getenv("AFS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("AFS_TEST_DATABASE_URL not set")
	}
	ctx := t.Context()
	admin, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	name := "afs_test_" + strings.ToLower(strings.NewReplacer("/", "_", " ", "_").Replace(t.Name()))
	_, _ = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{name}.Sanitize())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	cfg, err := pgx.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Database = name
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx := context.Background()
		_ = conn.Close(ctx)
		_, _ = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{name}.Sanitize())
		_ = admin.Close(ctx)
	})
	if _, err := conn.Exec(ctx, bootstrap.RolesSQL); err != nil {
		t.Fatal(err)
	}
	return conn
}

func migrated(t *testing.T) *pgx.Conn {
	t.Helper()
	conn := connect(t)
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := migrate.Up(t.Context(), conn, migs); err != nil {
		t.Fatal(err)
	}
	return conn
}

func TestUpDownUp(t *testing.T) {
	conn := connect(t)
	ctx := t.Context()
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := migrate.Up(ctx, conn, migs); err != nil || n != len(migs) {
		t.Fatalf("up: n=%d err=%v", n, err)
	}
	if n, err := migrate.Up(ctx, conn, migs); err != nil || n != 0 {
		t.Fatalf("second up should be a no-op: n=%d err=%v", n, err)
	}
	if n, err := migrate.Down(ctx, conn, migs, len(migs)); err != nil || n != len(migs) {
		t.Fatalf("down: n=%d err=%v", n, err)
	}
	if v, _ := migrate.Version(ctx, conn); v != 0 {
		t.Fatalf("version after full down = %d", v)
	}
	if _, err := migrate.Up(ctx, conn, migs); err != nil {
		t.Fatalf("up after down: %v", err)
	}
}

func TestChecksumMismatchIsRefused(t *testing.T) {
	conn := migrated(t)
	migs, _ := migrate.Load(migrations.FS)
	migs[0].Up += "\n-- edited"
	if _, err := migrate.Up(t.Context(), conn, migs); !errors.Is(err, migrate.ErrChecksumMismatch) {
		t.Fatalf("want ErrChecksumMismatch, got %v", err)
	}
}

const (
	teamA = "team_01JD3Z5Y8K2M4N6P8Q0R2S4T6V"
	teamB = "team_01JD3Z5Y8K2M4N6P8Q0R2S4T6W"
)

func seedTeams(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	_, err := conn.Exec(t.Context(), `
		INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd)
		VALUES ($1, 'payments', 'Payments', 'CC100', 'a@example.com', 5000),
		       ($2, 'search', 'Search', 'CC200', 'b@example.com', 1000)`, teamA, teamB)
	if err != nil {
		t.Fatal(err)
	}
}

func sqlState(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

func TestConstraints(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)

	t.Run("ephemeral team requires expiry", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email)
			VALUES ('team_01JD3Z5Y8K2M4N6P8Q0R2S4T6X', 'swarm-x', 'Swarm', 'ephemeral', 'CC1', 'c@example.com')`)
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("bad id prefix rejected", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email)
			VALUES ('agt_01JD3Z5Y8K2M4N6P8Q0R2S4T6X', 'bad', 'Bad', 'CC1', 'c@example.com')`)
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("namespace derived from slug", func(t *testing.T) {
		var ns string
		if err := conn.QueryRow(ctx, `SELECT namespace FROM afs.teams WHERE id = $1`, teamA).Scan(&ns); err != nil || ns != "afs-t-payments" {
			t.Fatalf("namespace = %q, err %v", ns, err)
		}
	})
	t.Run("budget above ceiling rejected", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.budgets (id, team_id, period, amount_usd)
			VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, 'monthly', 1500)`, teamB)
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("version bumps on update", func(t *testing.T) {
		var v int64
		err := conn.QueryRow(ctx, `UPDATE afs.teams SET description = 'x' WHERE id = $1 AND version = 1 RETURNING version`, teamA).Scan(&v)
		if err != nil || v != 2 {
			t.Fatalf("version = %d, err %v", v, err)
		}
	})
	t.Run("revisions recorded", func(t *testing.T) {
		var n int
		_ = conn.QueryRow(ctx, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'teams' AND resource_id = $1`, teamA).Scan(&n)
		if n < 2 {
			t.Fatalf("revisions = %d, want >= 2", n)
		}
	})
	t.Run("audit log is append-only", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome) VALUES ('system','t','Test','allowed')`); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec(ctx, `DELETE FROM afs.audit_log`); err == nil {
			t.Fatal("delete from audit_log succeeded")
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.audit_log SET action = 'x'`); err == nil {
			t.Fatal("update of audit_log succeeded")
		}
	})
	t.Run("no secret value column exists", func(t *testing.T) {
		var n int
		_ = conn.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns
			WHERE table_schema = 'afs' AND column_name ~ '(value|password|plaintext|secret_string)'
			  AND table_name NOT IN ('service_settings')`).Scan(&n)
		if n != 0 {
			t.Fatalf("%d columns look like they hold secret values", n)
		}
	})
}

func TestSpendReservation(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	_, err := conn.Exec(ctx, `
		INSERT INTO afs.budgets (id, team_id, period, amount_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, 'monthly', 100);
		`, teamA)
	if err != nil {
		t.Fatal(err)
	}
	_, err = conn.Exec(ctx, `INSERT INTO afs.spend_counters (budget_id, period_start, limit_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', '2026-11-01', 100)`)
	if err != nil {
		t.Fatal(err)
	}
	reserve := func(amount string) bool {
		var ok bool
		if err := conn.QueryRow(ctx, `SELECT afs.reserve_spend('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', '2026-11-01', $1::numeric)`, amount).Scan(&ok); err != nil {
			t.Fatal(err)
		}
		return ok
	}
	if !reserve("60") {
		t.Fatal("first reservation should fit")
	}
	if reserve("50") {
		t.Fatal("second reservation would exceed the cap and must fail")
	}
	if _, err := conn.Exec(ctx, `SELECT afs.settle_spend('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', '2026-11-01', 60, 12.5)`); err != nil {
		t.Fatal(err)
	}
	if !reserve("50") {
		t.Fatal("after settling to actual cost, the reservation should fit")
	}
}

func TestRowLevelSecurityIsolatesTeams(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	_, err := conn.Exec(ctx, `
		INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin) VALUES
		 ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, 'gh-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:/afs/t/a/gh-token-AbCdEf', 'managed'),
		 ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T6W', $2, 'gh-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:/afs/t/b/gh-token-AbCdEf', 'managed')`,
		teamA, teamB)
	if err != nil {
		t.Fatal(err)
	}

	count := func(setup string) (teams, secrets int) {
		t.Helper()
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, "SET LOCAL ROLE afs_app; "+setup); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM afs.teams`).Scan(&teams); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.secrets`).Scan(&secrets)
		})
		if err != nil {
			t.Fatal(err)
		}
		return
	}

	if tm, s := count(`SET LOCAL afs.team_ids = '` + teamA + `'`); tm != 1 || s != 1 {
		t.Fatalf("team A caller sees teams=%d secrets=%d, want 1/1", tm, s)
	}
	if tm, s := count(``); tm != 0 || s != 0 {
		t.Fatalf("unbound caller sees teams=%d secrets=%d, want 0/0", tm, s)
	}
	if tm, s := count(`SET LOCAL afs.service_admin = 'on'`); tm != 2 || s != 2 {
		t.Fatalf("service admin sees teams=%d secrets=%d, want 2/2", tm, s)
	}

	// A team-A caller cannot write a row into team B.
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamA+`'`)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO afs.team_egress_rules (id, team_id, host, purpose)
			VALUES ('egr_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, 'github.com', 'git')`, teamB)
		return err
	})
	if sqlState(err) != "42501" {
		t.Fatalf("cross-team insert: want insufficient_privilege (RLS), got %v", err)
	}
}
