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
		 ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, 'gh-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-payments/_shared/gh-token-AbCdEf', 'managed'),
		 ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T6W', $2, 'gh-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-search/_shared/gh-token-AbCdEf', 'managed')`,
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

const (
	agentA1 = "agt_01JD3Z5Y8K2M4N6P8Q0R2S4T6V"
	agentA2 = "agt_01JD3Z5Y8K2M4N6P8Q0R2S4T6W"
	arnBase = "arn:aws:secretsmanager:us-east-1:111122223333:secret:"
)

func seedAgents(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	_, err := conn.Exec(t.Context(), `
		INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
		INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+teamA+`', 'claude-sonnet');
		INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES
		 ('`+agentA1+`', '`+teamA+`', 'reviewer-bot', 'omp-review', 'ghcr.io/x/omp@sha256:abc', 'claude-sonnet'),
		 ('`+agentA2+`', '`+teamA+`', 'incident-scribe', 'hermes-ops', 'ghcr.io/x/hermes@sha256:def', 'claude-sonnet')`)
	if err != nil {
		t.Fatal(err)
	}
}

func TestAgentsHaveNoReplicaCount(t *testing.T) {
	conn := migrated(t)
	var n int
	if err := conn.QueryRow(t.Context(), `SELECT count(*) FROM information_schema.columns
		WHERE table_schema = 'afs' AND table_name = 'agents' AND column_name = 'replicas'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("agents.replicas still present (n=%d, err=%v): one agent is one pod", n, err)
	}
}

func TestSecretPathsAreManaged(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)

	insert := func(id, agentID, name, arnPath, suppliedPath string) error {
		var agent any
		if agentID != "" {
			agent = agentID
		}
		_, err := conn.Exec(ctx, `INSERT INTO afs.secrets (id, team_id, agent_id, name, secrets_manager_arn, origin, path)
			VALUES ($1, $2, $3, $4, $5, 'managed', $6)`, id, teamA, agent, name, arnBase+arnPath+"-AbCdEf", suppliedPath)
		return err
	}
	pathOf := func(id string) string {
		var p string
		if err := conn.QueryRow(ctx, `SELECT path FROM afs.secrets WHERE id = $1`, id).Scan(&p); err != nil {
			t.Fatal(err)
		}
		return p
	}

	t.Run("secret_path computes the hierarchy", func(t *testing.T) {
		var shared, agent string
		if err := conn.QueryRow(ctx, `SELECT afs.secret_path($1, NULL, 'gh'), afs.secret_path($1, $2, 'gh')`, teamA, agentA1).Scan(&shared, &agent); err != nil {
			t.Fatal(err)
		}
		if shared != "afs/afs-t-payments/_shared/gh" || agent != "afs/afs-t-payments/reviewer-bot/gh" {
			t.Fatalf("paths = %q, %q", shared, agent)
		}
	})
	t.Run("team-shared secret gets the managed path, ignoring a supplied one", func(t *testing.T) {
		if err := insert("sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60", "", "github-bot-key", "afs/afs-t-payments/_shared/github-bot-key", "user/chosen/path"); err != nil {
			t.Fatal(err)
		}
		if p := pathOf("sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60"); p != "afs/afs-t-payments/_shared/github-bot-key" {
			t.Fatalf("path = %q", p)
		}
	})
	t.Run("agent secret gets the agent path", func(t *testing.T) {
		if err := insert("sec_01JD3Z5Y8K2M4N6P8Q0R2S4T61", agentA2, "pagerduty-token", "afs/afs-t-payments/incident-scribe/pagerduty-token", ""); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("same name allowed in another scope", func(t *testing.T) {
		if err := insert("sec_01JD3Z5Y8K2M4N6P8Q0R2S4T62", agentA1, "pagerduty-token", "afs/afs-t-payments/reviewer-bot/pagerduty-token", ""); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("ARN outside the managed path rejected", func(t *testing.T) {
		err := insert("sec_01JD3Z5Y8K2M4N6P8Q0R2S4T63", "", "snyk-token", "somewhere/else/snyk-token", "")
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("agent from another team rejected", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.secrets (id, team_id, agent_id, name, secrets_manager_arn, origin)
			VALUES ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T64', $1, $2, 'x', $3, 'managed')`, teamB, agentA1, arnBase+"afs/afs-t-search/reviewer-bot/x-AbCdEf")
		if sqlState(err) != "23503" {
			t.Fatalf("want foreign_key_violation, got %v", err)
		}
	})
	t.Run("registered origin no longer allowed", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin)
			VALUES ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T65', $1, 'legacy', $2, 'registered')`, teamA, arnBase+"afs/afs-t-payments/_shared/legacy-AbCdEf")
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("path inputs are immutable", func(t *testing.T) {
		for _, stmt := range []string{
			`UPDATE afs.secrets SET name = 'renamed' WHERE id = 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60'`,
			`UPDATE afs.secrets SET path = 'x/y/z' WHERE id = 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60'`,
			`UPDATE afs.secrets SET agent_id = '` + agentA1 + `' WHERE id = 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60'`,
			`UPDATE afs.agents SET name = 'renamed' WHERE id = '` + agentA1 + `'`,
			`UPDATE afs.teams SET slug = 'renamed' WHERE id = '` + teamA + `'`,
		} {
			if _, err := conn.Exec(ctx, stmt); sqlState(err) != "55000" {
				t.Errorf("%s: want object_not_in_prerequisite_state, got %v", stmt, err)
			}
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.secrets SET description = 'ok' WHERE id = 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60'`); err != nil {
			t.Fatalf("metadata update should succeed: %v", err)
		}
	})
	t.Run("agent secret binds only to its own agent", func(t *testing.T) {
		bind := func(agentID, secretID, target string) error {
			_, err := conn.Exec(ctx, `INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target)
				VALUES ($1, $2, $3, 'env', $4)`, teamA, agentID, secretID, target)
			return err
		}
		if err := bind(agentA2, "sec_01JD3Z5Y8K2M4N6P8Q0R2S4T61", "PAGERDUTY_TOKEN"); err != nil {
			t.Fatalf("own agent: %v", err)
		}
		if err := bind(agentA1, "sec_01JD3Z5Y8K2M4N6P8Q0R2S4T61", "PAGERDUTY_TOKEN"); sqlState(err) != "23514" {
			t.Fatalf("other agent: want check_violation, got %v", err)
		}
		if err := bind(agentA1, "sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60", "GITHUB_APP_KEY"); err != nil {
			t.Fatalf("team-shared secret to any agent: %v", err)
		}
	})
	t.Run("path prefix setting is validated and used", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '"Bad/Prefix"' WHERE key = 'secrets.path_prefix'`); sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '"afs-dev"' WHERE key = 'secrets.path_prefix'`); err != nil {
			t.Fatal(err)
		}
		var p string
		if err := conn.QueryRow(ctx, `SELECT afs.secret_path($1, NULL, 'gh')`, teamA).Scan(&p); err != nil || p != "afs-dev/afs-t-payments/_shared/gh" {
			t.Fatalf("path = %q, err %v", p, err)
		}
	})
}
