package migrate_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"testing/fstest"
	"time"

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
	// Configuration values and cost-allocation tags are non-secret by design (000005 and 000010 reject
	// credential-like names), so their tables and views are exempt from the column-name check.
	t.Run("no secret value column exists", func(t *testing.T) {
		var n int
		_ = conn.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns
			WHERE table_schema = 'afs' AND column_name ~ '(value|password|plaintext|secret_string)'
			  AND table_name NOT IN ('service_settings', 'namespace_config_values', 'agent_config_values', 'agent_config_resolved',
			                         'service_tags', 'team_tags', 'team_effective_tags', 'agent_effective_tags',
			                         'cost_daily_by_tag', 'agent_activity_daily_by_tag', 'external_traffic_daily_by_tag')`).Scan(&n)
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
		_, err = tx.Exec(ctx, `INSERT INTO afs.namespace_config_values (id, team_id, name, config_value)
			VALUES ('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, 'LOG_LEVEL', 'debug')`, teamB)
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

func TestAgentPersistentStorage(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)

	t.Run("agents get a default volume", func(t *testing.T) {
		var size, keep int
		var class, onDelete, sched string
		err := conn.QueryRow(ctx, `SELECT storage_size_gib, storage_class, storage_on_delete, snapshot_schedule, snapshot_retain_count
			FROM afs.agents WHERE id = $1`, agentA1).Scan(&size, &class, &onDelete, &sched, &keep)
		if err != nil || size != 20 || class != "gp3" || onDelete != "snapshot_then_delete" || sched != "daily" || keep != 7 {
			t.Fatalf("defaults = %d %s %s %s %d, err %v", size, class, onDelete, sched, keep, err)
		}
	})
	t.Run("volume can grow", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET storage_size_gib = 50 WHERE id = $1`, agentA1); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("volume cannot shrink", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET storage_size_gib = 10 WHERE id = $1`, agentA1)
		if sqlState(err) != "55000" {
			t.Fatalf("want object_not_in_prerequisite_state, got %v", err)
		}
	})
	t.Run("storage class is immutable", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `INSERT INTO afs.storage_classes (id, volume_type) VALUES ('io2-fast', 'io2')`); err != nil {
			t.Fatal(err)
		}
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET storage_class = 'io2-fast' WHERE id = $1`, agentA1)
		if sqlState(err) != "55000" {
			t.Fatalf("want object_not_in_prerequisite_state, got %v", err)
		}
	})
	t.Run("disabled storage class rejected for new agents", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.storage_classes SET enabled = false WHERE id = 'io2-fast'`); err != nil {
			t.Fatal(err)
		}
		_, err := conn.Exec(ctx, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, storage_class)
			VALUES ('agt_01JD3Z5Y8K2M4N6P8Q0R2S4T6X', $1, 'new-agent', 't', 'x@sha256:a', 'claude-sonnet', 'io2-fast')`, teamA)
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("bad settings rejected", func(t *testing.T) {
		for _, set := range []string{"storage_size_gib = 2000", "storage_on_delete = 'keep'", "snapshot_schedule = 'hourly'", "snapshot_retain_count = 0"} {
			if _, err := conn.Exec(ctx, `UPDATE afs.agents SET `+set+` WHERE id = $1`, agentA2); sqlState(err) != "23514" {
				t.Errorf("%s: want check_violation, got %v", set, err)
			}
		}
	})
	t.Run("completed snapshot needs an EBS id", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.agent_volume_snapshots (id, team_id, agent_id, reason, state)
			VALUES ('vsnap_01JD3Z5Y8K2M4N6P8Q0R2S4T6V', $1, $2, 'scheduled', 'completed')`, teamA, agentA1)
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("app requests manual snapshots for its own team only", func(t *testing.T) {
		as := func(teams, reason, id, team string) error {
			return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teams+`'`); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `INSERT INTO afs.agent_volume_snapshots (id, team_id, agent_id, reason) VALUES ($1, $2, $3, $4)`,
					id, team, agentA1, reason)
				return err
			})
		}
		if err := as(teamA, "manual", "vsnap_01JD3Z5Y8K2M4N6P8Q0R2S4T60", teamA); err != nil {
			t.Fatalf("own team manual snapshot: %v", err)
		}
		if err := as(teamA, "scheduled", "vsnap_01JD3Z5Y8K2M4N6P8Q0R2S4T61", teamA); sqlState(err) != "42501" {
			t.Fatalf("app writing a scheduled snapshot: want 42501, got %v", err)
		}
		if err := as(teamB, "manual", "vsnap_01JD3Z5Y8K2M4N6P8Q0R2S4T62", teamA); sqlState(err) != "42501" {
			t.Fatalf("other team: want 42501, got %v", err)
		}
		var n int
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_volume_snapshots`).Scan(&n)
		})
		if err != nil || n != 0 {
			t.Fatalf("team B sees %d team A snapshots (err %v)", n, err)
		}
	})
}

func TestConfigurationValues(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)

	exec := func(sql string, args ...any) error {
		_, err := conn.Exec(ctx, sql, args...)
		return err
	}
	if err := exec(`INSERT INTO afs.namespace_config_values (id, team_id, name, config_value) VALUES
		('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4T60', $1, 'LOG_LEVEL', 'info'),
		('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4T61', $1, 'GITHUB_ORG', 'acme-payments')`, teamA); err != nil {
		t.Fatal(err)
	}

	t.Run("literal and namespace values resolve", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source, config_value) VALUES
			('acv_01JD3Z5Y8K2M4N6P8Q0R2S4T60', $1, $2, 'LOG_LEVEL', 'literal', 'debug'),
			('acv_01JD3Z5Y8K2M4N6P8Q0R2S4T61', $1, $2, 'GITHUB_ORG', 'namespace', NULL)`, teamA, agentA1); err != nil {
			t.Fatal(err)
		}
		rows, err := conn.Query(ctx, `SELECT name, source, resolved_value FROM afs.agent_config_resolved WHERE agent_id = $1 ORDER BY name`, agentA1)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]string{}
		for rows.Next() {
			var n, src, v string
			if err := rows.Scan(&n, &src, &v); err != nil {
				t.Fatal(err)
			}
			got[n] = src + "=" + v
		}
		if got["LOG_LEVEL"] != "literal=debug" || got["GITHUB_ORG"] != "namespace=acme-payments" {
			t.Fatalf("resolved = %v", got)
		}
	})
	t.Run("namespace link needs a namespace value of that name", func(t *testing.T) {
		err := exec(`INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source) VALUES
			('acv_01JD3Z5Y8K2M4N6P8Q0R2S4T62', $1, $2, 'MISSING', 'namespace')`, teamA, agentA1)
		if sqlState(err) != "23503" {
			t.Fatalf("want foreign_key_violation, got %v", err)
		}
	})
	t.Run("namespace link ignores another team's values", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.namespace_config_values (id, team_id, name, config_value) VALUES
			('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4T62', $1, 'REGION_HINT', 'us-east-1')`, teamB); err != nil {
			t.Fatal(err)
		}
		err := exec(`INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source) VALUES
			('acv_01JD3Z5Y8K2M4N6P8Q0R2S4T63', $1, $2, 'REGION_HINT', 'namespace')`, teamA, agentA1)
		if sqlState(err) != "23503" {
			t.Fatalf("want foreign_key_violation, got %v", err)
		}
	})
	t.Run("literal needs a value and namespace link must not carry one", func(t *testing.T) {
		for _, src := range []string{`'literal', NULL`, `'namespace', 'x'`} {
			err := exec(`INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source, config_value) VALUES
				('acv_01JD3Z5Y8K2M4N6P8Q0R2S4T64', $1, $2, 'LOG_LEVEL', `+src+`)`, teamA, agentA2)
			if sqlState(err) != "23514" {
				t.Errorf("%s: want check_violation, got %v", src, err)
			}
		}
	})
	t.Run("credential-like and malformed names rejected", func(t *testing.T) {
		for _, name := range []string{"DB_PASSWORD", "GITHUB_TOKEN", "STRIPE_API_KEY", "lower_case", "1STARTS_WITH_DIGIT"} {
			err := exec(`INSERT INTO afs.namespace_config_values (id, team_id, name, config_value) VALUES
				('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4T63', $1, $2, 'v')`, teamA, name)
			if sqlState(err) != "23514" {
				t.Errorf("%s: want check_violation, got %v", name, err)
			}
		}
	})
	t.Run("config name cannot shadow a secret env var and vice versa", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin)
			VALUES ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60', $1, 'gh', $2, 'managed')`, teamA, arnBase+"afs/afs-t-payments/_shared/gh-AbCdEf"); err != nil {
			t.Fatal(err)
		}
		if err := exec(`INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target)
			VALUES ($1, $2, 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60', 'env', 'GH_APP_PEM')`, teamA, agentA2); err != nil {
			t.Fatal(err)
		}
		err := exec(`INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source, config_value) VALUES
			('acv_01JD3Z5Y8K2M4N6P8Q0R2S4T65', $1, $2, 'GH_APP_PEM', 'literal', 'x')`, teamA, agentA2)
		if sqlState(err) != "23505" {
			t.Fatalf("config over secret: want unique_violation, got %v", err)
		}
		err = exec(`INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target)
			VALUES ($1, $2, 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4T60', 'env', 'LOG_LEVEL')`, teamA, agentA1)
		if sqlState(err) != "23505" {
			t.Fatalf("secret over config: want unique_violation, got %v", err)
		}
	})
	t.Run("linked namespace value cannot be deleted or renamed", func(t *testing.T) {
		if err := exec(`DELETE FROM afs.namespace_config_values WHERE name = 'GITHUB_ORG'`); sqlState(err) != "23503" {
			t.Fatalf("delete: want foreign_key_violation, got %v", err)
		}
		if err := exec(`UPDATE afs.namespace_config_values SET name = 'GH_ORG' WHERE name = 'GITHUB_ORG'`); sqlState(err) != "23503" {
			t.Fatalf("rename: want foreign_key_violation, got %v", err)
		}
		if err := exec(`UPDATE afs.namespace_config_values SET config_value = 'acme-pay' WHERE name = 'GITHUB_ORG'`); err != nil {
			t.Fatalf("value change should succeed: %v", err)
		}
	})
	t.Run("agents.env is gone", func(t *testing.T) {
		var n int
		_ = conn.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns
			WHERE table_schema = 'afs' AND table_name = 'agents' AND column_name = 'env'`).Scan(&n)
		if n != 0 {
			t.Fatal("agents.env still exists; configuration lives in agent_config_values")
		}
	})
	t.Run("other team cannot see config", func(t *testing.T) {
		var ns, ag int
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM afs.namespace_config_values WHERE team_id = $1`, teamA).Scan(&ns); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_config_resolved`).Scan(&ag)
		})
		if err != nil || ns != 0 || ag != 0 {
			t.Fatalf("team B sees ns=%d agent=%d (err %v)", ns, ag, err)
		}
	})
	t.Run("deleting the team removes its configuration", func(t *testing.T) {
		if err := exec(`DELETE FROM afs.agent_secret_bindings WHERE team_id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		if err := exec(`DELETE FROM afs.agents WHERE team_id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		if err := exec(`DELETE FROM afs.namespace_config_values WHERE team_id = $1`, teamA); err != nil {
			t.Fatalf("namespace values unlinked once agents are gone: %v", err)
		}
	})
}

func TestAgentEnvBackfill(t *testing.T) {
	conn := connect(t)
	ctx := t.Context()
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := migrate.Up(ctx, conn, migs[:4]); err != nil {
		t.Fatal(err)
	}
	seedTeams(t, conn)
	seedAgents(t, conn)
	if _, err := conn.Exec(ctx, `UPDATE afs.agents SET env = '{"LOG_LEVEL":"warn","FEATURE_X":"on"}' WHERE id = $1`, agentA1); err != nil {
		t.Fatal(err)
	}
	if _, err := migrate.Up(ctx, conn, migs); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM afs.agent_config_resolved
		WHERE agent_id = $1 AND source = 'literal' AND ((name = 'LOG_LEVEL' AND resolved_value = 'warn') OR (name = 'FEATURE_X' AND resolved_value = 'on'))`, agentA1).Scan(&n); err != nil || n != 2 {
		t.Fatalf("backfilled %d of 2 env entries (err %v)", n, err)
	}
}

func TestCrossAccountRoleLinks(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	exec := func(sql string, args ...any) error {
		_, err := conn.Exec(ctx, sql, args...)
		return err
	}
	if err := exec(`INSERT INTO afs.org_aws_accounts (id, name, status) VALUES
		('222233334444', 'payments-prod', 'active'),
		('555566667777', 'shared-tools', 'active'),
		('888899990000', 'payments-legacy', 'suspended'),
		('123412341234', 'search-prod', 'active')`); err != nil {
		t.Fatal(err)
	}
	// Team A: everything named payments-* plus one account by id. Team B: nothing.
	if err := exec(`UPDATE afs.teams SET allowed_aws_accounts = '{payments-*,555566667777}' WHERE id = $1`, teamA); err != nil {
		t.Fatal(err)
	}
	link := func(id, agentID, account, role, profile, ext string) error {
		return exec(`INSERT INTO afs.agent_role_links (id, team_id, agent_id, account_id, role_arn, profile_name, external_id)
			VALUES ($1, $2, $3, $4, $5, $6, $7)`, id, teamA, agentID, account, role, profile, ext)
	}
	const ext = "afs-AbCdEfGhIjKlMnOpQrSt"

	t.Run("agent on the shared team role cannot link", func(t *testing.T) {
		err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T60", agentA1, "222233334444", "arn:aws:iam::222233334444:role/deployer", "prod", ext+"0")
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	if err := exec(`UPDATE afs.agents SET iam_identity = 'dedicated' WHERE id = $1`, agentA1); err != nil {
		t.Fatal(err)
	}
	t.Run("dedicated agent links to an account its team may use", func(t *testing.T) {
		if err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T61", agentA1, "222233334444", "arn:aws:iam::222233334444:role/afs/deployer", "prod-deployer", ext+"1"); err != nil {
			t.Fatal(err)
		}
		if err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T62", agentA1, "555566667777", "arn:aws:iam::555566667777:role/reader", "tools", ext+"2"); err != nil {
			t.Fatalf("all_teams account: %v", err)
		}
		var st string
		if err := conn.QueryRow(ctx, `SELECT status FROM afs.agent_role_links WHERE id = 'arl_01JD3Z5Y8K2M4N6P8Q0R2S4T61'`).Scan(&st); err != nil || st != "pending_trust" {
			t.Fatalf("status = %q, err %v", st, err)
		}
	})
	t.Run("accounts outside the filter, suspended or unknown are rejected", func(t *testing.T) {
		if err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T63", agentA1, "123412341234", "arn:aws:iam::123412341234:role/x", "x", ext+"3"); sqlState(err) != "23514" {
			t.Errorf("outside filter: want check_violation, got %v", err)
		}
		if err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T64", agentA1, "888899990000", "arn:aws:iam::888899990000:role/x", "y", ext+"4"); sqlState(err) != "23514" {
			t.Errorf("suspended: want check_violation, got %v", err)
		}
		if err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T65", agentA1, "111111111111", "arn:aws:iam::111111111111:role/x", "z", ext+"5"); sqlState(err) != "23514" {
			t.Errorf("unknown: want check_violation, got %v", err)
		}
	})
	t.Run("star allows every active account", func(t *testing.T) {
		var a, b, c bool
		if err := exec(`UPDATE afs.teams SET allowed_aws_accounts = '{*}' WHERE id = $1`, teamB); err != nil {
			t.Fatal(err)
		}
		if err := conn.QueryRow(ctx, `SELECT afs.account_allowed($1, '123412341234'), afs.account_allowed($1, '888899990000'), afs.account_allowed($2, '123412341234')`,
			teamB, teamA).Scan(&a, &b, &c); err != nil {
			t.Fatal(err)
		}
		if !a || b || c {
			t.Fatalf("allowed = %v (B, active), %v (B, suspended), %v (A, outside filter)", a, b, c)
		}
	})
	t.Run("glob characters are not SQL wildcards", func(t *testing.T) {
		var ok bool
		if err := exec(`UPDATE afs.teams SET allowed_aws_accounts = '{payments_prod}' WHERE id = $1`, teamB); err != nil {
			t.Fatal(err)
		}
		if err := conn.QueryRow(ctx, `SELECT afs.account_allowed($1, '222233334444')`, teamB).Scan(&ok); err != nil || ok {
			t.Fatalf("'_' matched '-' (ok=%v, err %v)", ok, err)
		}
	})
	t.Run("role ARN must be in the linked account", func(t *testing.T) {
		err := link("arl_01JD3Z5Y8K2M4N6P8Q0R2S4T66", agentA1, "222233334444", "arn:aws:iam::555566667777:role/x", "mismatch", ext+"6")
		if sqlState(err) != "23514" {
			t.Fatalf("want check_violation, got %v", err)
		}
	})
	t.Run("role and external ID are immutable; status is not", func(t *testing.T) {
		if err := exec(`UPDATE afs.agent_role_links SET role_arn = 'arn:aws:iam::222233334444:role/other' WHERE id = 'arl_01JD3Z5Y8K2M4N6P8Q0R2S4T61'`); sqlState(err) != "55000" {
			t.Errorf("role change: want 55000, got %v", err)
		}
		if err := exec(`UPDATE afs.agent_role_links SET status = 'verified', last_verified_at = now() WHERE id = 'arl_01JD3Z5Y8K2M4N6P8Q0R2S4T61'`); err != nil {
			t.Errorf("status update: %v", err)
		}
	})
	t.Run("agent with links cannot return to the team role", func(t *testing.T) {
		if err := exec(`UPDATE afs.agents SET iam_identity = 'team_shared' WHERE id = $1`, agentA1); sqlState(err) != "55000" {
			t.Fatalf("want 55000, got %v", err)
		}
	})
	t.Run("other team cannot see links", func(t *testing.T) {
		var n int
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_role_links WHERE team_id = $1`, teamA).Scan(&n)
		})
		if err != nil || n != 0 {
			t.Fatalf("team B sees %d team A links (err %v)", n, err)
		}
	})
}

func TestExternalSystems(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	exec := func(sql string, args ...any) error {
		_, err := conn.Exec(ctx, sql, args...)
		return err
	}
	// asApp runs fn as afs_app bound to one team (or as a service admin when team is "").
	asApp := func(team string, fn func(tx pgx.Tx) error) error {
		return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			setup := `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '` + team + `'`
			if team == "" {
				setup = `SET LOCAL ROLE afs_app; SET LOCAL afs.service_admin = 'on'`
			}
			if _, err := tx.Exec(ctx, setup); err != nil {
				return err
			}
			return fn(tx)
		})
	}
	const github = "ext_01JDX0000000000000000000A2"
	const slack = "ext_01JDX0000000000000000000A7"
	const openai = "ext_01JDX0000000000000000000A9"
	access := func(agent string) map[string]string {
		t.Helper()
		rows, err := conn.Query(ctx, `SELECT slug, coalesce(disabled_at, 'on') FROM afs.agent_external_access WHERE agent_id = $1`, agent)
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]string{}
		for rows.Next() {
			var k, v string
			if err := rows.Scan(&k, &v); err != nil {
				t.Fatal(err)
			}
			m[k] = v
		}
		return m
	}

	t.Run("built-in catalog is on by default except non-Bedrock model providers", func(t *testing.T) {
		got := access(agentA1)
		if len(got) != 10 {
			t.Fatalf("agent sees %d systems, want 10: %v", len(got), got)
		}
		if got["github"] != "on" || got["atlassian"] != "on" || got["openai"] != "service" || got["openrouter"] != "service" {
			t.Fatalf("defaults = %v", got)
		}
	})
	t.Run("each level only narrows the one above", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.external_system_optouts (id, team_id, agent_id, system_id) VALUES
			('xso_01JD3Z5Y8K2M4N6P8Q0R2S4T60', $1, NULL, $2),
			('xso_01JD3Z5Y8K2M4N6P8Q0R2S4T61', $1, $3, $4)`, teamA, slack, agentA1, github); err != nil {
			t.Fatal(err)
		}
		a1, a2 := access(agentA1), access(agentA2)
		if a1["slack"] != "team" || a2["slack"] != "team" {
			t.Errorf("team opt-out: a1=%s a2=%s", a1["slack"], a2["slack"])
		}
		if a1["github"] != "agent" || a2["github"] != "on" {
			t.Errorf("agent opt-out: a1=%s a2=%s", a1["github"], a2["github"])
		}
		if err := exec(`UPDATE afs.external_systems SET enabled = false WHERE id = $1`, github); err != nil {
			t.Fatal(err)
		}
		if got := access(agentA2)["github"]; got != "service" {
			t.Errorf("service switch-off: a2=%s", got)
		}
		if err := exec(`INSERT INTO afs.external_system_optouts (id, team_id, agent_id, system_id) VALUES
			('xso_01JD3Z5Y8K2M4N6P8Q0R2S4T62', $1, NULL, $2)`, teamA, slack); sqlState(err) != "23505" {
			t.Errorf("duplicate team opt-out: want unique_violation, got %v", err)
		}
	})
	t.Run("team-admins cannot change the service catalog", func(t *testing.T) {
		err := asApp(teamA, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, `UPDATE afs.external_systems SET enabled = true WHERE id = $1`, openai)
			if err == nil && tag.RowsAffected() == 0 {
				return fmt.Errorf("no rows")
			}
			return err
		})
		if err == nil || err.Error() != "no rows" {
			t.Errorf("team caller update of a service entry: %v", err)
		}
		err = asApp(teamA, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, `DELETE FROM afs.external_systems WHERE id = $1`, openai)
			if err == nil && tag.RowsAffected() != 0 {
				return fmt.Errorf("deleted")
			}
			return err
		})
		if err != nil {
			t.Errorf("team caller delete of a service entry: %v", err)
		}
		if err := asApp("", func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE afs.external_systems SET enabled = true WHERE id = $1`, openai)
			return err
		}); err != nil {
			t.Errorf("service admin enabling openai: %v", err)
		}
	})
	t.Run("built-in entries cannot be deleted", func(t *testing.T) {
		if err := exec(`DELETE FROM afs.external_systems WHERE id = $1`, slack); sqlState(err) != "55000" {
			t.Fatalf("want 55000, got %v", err)
		}
	})
	declare := func(id, team, slug string) error {
		return asApp(team, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO afs.external_systems (id, team_id, slug, name, category, owner, purpose, endpoints)
				VALUES ($1, $2, $3, 'PagerDuty', 'other', 'payments-sre', 'Incident paging', '{api.pagerduty.com,events.pagerduty.com:443}')`, id, team, slug)
			return err
		})
	}
	t.Run("teams declare their own systems only when allowed", func(t *testing.T) {
		if err := declare("ext_01JD3Z5Y8K2M4N6P8Q0R2S4T60", teamA, "pagerduty"); sqlState(err) != "42501" {
			t.Fatalf("not allowed: want 42501, got %v", err)
		}
		err := asApp(teamA, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE afs.teams SET may_add_external_systems = true WHERE id = $1`, teamA)
			return err
		})
		if sqlState(err) != "42501" {
			t.Fatalf("team-admin granting itself the right: want 42501, got %v", err)
		}
		if err := asApp("", func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE afs.teams SET may_add_external_systems = true WHERE id = $1`, teamA)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if err := declare("ext_01JD3Z5Y8K2M4N6P8Q0R2S4T60", teamA, "pagerduty"); err != nil {
			t.Fatalf("allowed: %v", err)
		}
		if err := declare("ext_01JD3Z5Y8K2M4N6P8Q0R2S4T61", teamA, "github"); sqlState(err) != "23505" {
			t.Errorf("shadowing a catalog slug: want 23505, got %v", err)
		}
		if got := access(agentA1)["pagerduty"]; got != "on" {
			t.Errorf("team-declared system for agent: %s", got)
		}
		if err := exec(`INSERT INTO afs.external_systems (id, team_id, slug, name, category, endpoints)
			VALUES ('ext_01JD3Z5Y8K2M4N6P8Q0R2S4T62', $1, 'datadog', 'Datadog', 'other', '{api.datadoghq.com}')`, teamA); sqlState(err) != "23514" {
			t.Errorf("team entry without owner and purpose: want 23514, got %v", err)
		}
	})
	t.Run("endpoints are validated", func(t *testing.T) {
		for _, ep := range []string{`{}`, `{https://x.example.com}`, `{Example.com}`, `{x.example.com:70000}`, `{localhost}`, `{*.}`} {
			err := exec(`INSERT INTO afs.external_systems (id, slug, name, category, endpoints)
				VALUES ('ext_01JD3Z5Y8K2M4N6P8Q0R2S4T63', 'bad', 'Bad', 'other', $1)`, ep)
			if sqlState(err) != "23514" {
				t.Errorf("%s: want check_violation, got %v", ep, err)
			}
		}
		if err := exec(`INSERT INTO afs.external_systems (id, slug, name, category, endpoints)
			VALUES ('ext_01JD3Z5Y8K2M4N6P8Q0R2S4T63', 'internal-wiki', 'Wiki', 'other', '{wiki.corp.example:8443,*.corp.example}')`); err != nil {
			t.Errorf("valid endpoints: %v", err)
		}
	})
	t.Run("another team's systems are invisible and cannot be referenced", func(t *testing.T) {
		var n int
		if err := asApp(teamB, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.external_systems WHERE slug = 'pagerduty'`).Scan(&n)
		}); err != nil || n != 0 {
			t.Fatalf("team B sees %d team A systems (err %v)", n, err)
		}
		if err := exec(`INSERT INTO afs.external_system_optouts (id, team_id, system_id) VALUES
			('xso_01JD3Z5Y8K2M4N6P8Q0R2S4T63', $1, 'ext_01JD3Z5Y8K2M4N6P8Q0R2S4T60')`, teamB); sqlState(err) != "23503" {
			t.Errorf("opt-out of another team's system: want 23503, got %v", err)
		}
		if err := exec(`INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, external_system_id) VALUES
			('sec_01JD3Z5Y8K2M4N6P8Q0R2S4T6Z', $1, 'pd-key', $2, 'managed', 'ext_01JD3Z5Y8K2M4N6P8Q0R2S4T60')`,
			teamB, arnBase+"afs/afs-t-search/_shared/pd-key-AbCdEf"); sqlState(err) != "23503" {
			t.Errorf("secret for another team's system: want 23503, got %v", err)
		}
	})
}

func TestEgressRulesBecomeTeamSystems(t *testing.T) {
	conn := connect(t)
	ctx := t.Context()
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := migrate.Up(ctx, conn, migs[:6]); err != nil {
		t.Fatal(err)
	}
	seedTeams(t, conn)
	if _, err := conn.Exec(ctx, `INSERT INTO afs.team_egress_rules (id, team_id, host, port, purpose) VALUES
		('egr_01JD3Z5Y8K2M4N6P8Q0R2S4T60', $1, 'api.pagerduty.com', 443, 'paging'),
		('egr_01JD3Z5Y8K2M4N6P8Q0R2S4T61', $1, 'nexus.corp.example', 8443, 'artifacts')`, teamA); err != nil {
		t.Fatal(err)
	}
	if _, err := migrate.Up(ctx, conn, migs[:7]); err != nil {
		t.Fatal(err)
	}
	var eps []string
	var may bool
	if err := conn.QueryRow(ctx, `SELECT s.endpoints, t.may_add_external_systems FROM afs.external_systems s
		JOIN afs.teams t ON t.id = s.team_id WHERE s.team_id = $1 AND s.slug = 'egress-allow-list'`, teamA).Scan(&eps, &may); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(eps) != "[api.pagerduty.com nexus.corp.example:8443]" || !may {
		t.Fatalf("endpoints = %v, may add = %v", eps, may)
	}
	if _, err := migrate.Down(ctx, conn, migs, 1); err != nil {
		t.Fatalf("down: %v", err)
	}
	var n int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM afs.team_egress_rules WHERE team_id = $1`, teamA).Scan(&n); err != nil || n != 2 {
		t.Fatalf("rules after down = %d (err %v)", n, err)
	}
}

func TestAgentActivityReporting(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	exec := func(sql string, args ...any) error {
		_, err := conn.Exec(ctx, sql, args...)
		return err
	}
	sample := func(at, agent, state string, active, calls int) error {
		return exec(`INSERT INTO afs.agent_activity (bucket_start, team_id, agent_id, state, active_seconds, model_calls, input_tokens, cost_usd)
			VALUES ($1, $2, $3, $4, $5, $6, $6 * 1000, $6 * 0.01)`, at, teamA, agent, state, active, calls)
	}
	if _, err := conn.Exec(ctx, `SELECT afs.ensure_activity_partition('2026-11-01')`); err != nil {
		t.Fatal(err)
	}

	t.Run("samples are five-minute windows with consistent states", func(t *testing.T) {
		if err := sample("2026-11-20 10:02:00+00", agentA1, "working", 120, 1); sqlState(err) != "23514" {
			t.Errorf("unaligned window: want check_violation, got %v", err)
		}
		if err := sample("2026-11-20 10:00:00+00", agentA1, "idle", 60, 0); sqlState(err) != "23514" {
			t.Errorf("idle with active seconds: want check_violation, got %v", err)
		}
		if err := sample("2026-11-20 10:00:00+00", agentA1, "paused", 0, 3); sqlState(err) != "23514" {
			t.Errorf("paused with calls: want check_violation, got %v", err)
		}
		if err := sample("2026-11-20 10:00:00+00", agentA1, "sleeping", 0, 0); sqlState(err) != "23514" {
			t.Errorf("unknown state: want check_violation, got %v", err)
		}
		if err := sample("2026-11-20 10:00:00+00", agentA1, "working", 301, 1); sqlState(err) != "23514" {
			t.Errorf("active > window: want check_violation, got %v", err)
		}
	})

	// agentA1: 3 working, 1 idle, 1 paused, then idle again. agentA2: idle throughout.
	for _, s := range []struct {
		at, agent, state string
		active, calls    int
	}{
		{"2026-11-20 10:00:00+00", agentA1, "working", 240, 4},
		{"2026-11-20 10:05:00+00", agentA1, "working", 300, 6},
		{"2026-11-20 10:10:00+00", agentA1, "working", 60, 1},
		{"2026-11-20 10:15:00+00", agentA1, "idle", 0, 0},
		{"2026-11-20 10:20:00+00", agentA1, "paused", 0, 0},
		{"2026-11-20 10:25:00+00", agentA1, "idle", 0, 0},
		{"2026-11-20 10:00:00+00", agentA2, "idle", 0, 0},
		{"2026-11-20 10:05:00+00", agentA2, "idle", 0, 0},
	} {
		if err := sample(s.at, s.agent, s.state, s.active, s.calls); err != nil {
			t.Fatal(err)
		}
	}
	if err := sample("2026-11-20 10:00:00+00", agentA1, "idle", 0, 0); sqlState(err) != "23505" {
		t.Errorf("second sample for a window: want unique_violation, got %v", err)
	}

	t.Run("daily rollup gives time in state and utilization", func(t *testing.T) {
		var working, idle, off, active, calls int64
		var util float64
		if err := conn.QueryRow(ctx, `SELECT working_seconds, idle_seconds, off_seconds, active_seconds, model_calls, utilization_pct
			FROM afs.agent_activity_daily WHERE agent_id = $1 AND day = '2026-11-20'`, agentA1).
			Scan(&working, &idle, &off, &active, &calls, &util); err != nil {
			t.Fatal(err)
		}
		if working != 900 || idle != 600 || off != 300 || active != 600 || calls != 11 || util != 60.0 {
			t.Fatalf("working=%d idle=%d off=%d active=%d calls=%d util=%v", working, idle, off, active, calls, util)
		}
		var util2 float64
		if err := conn.QueryRow(ctx, `SELECT utilization_pct FROM afs.agent_activity_daily WHERE agent_id = $1`, agentA2).Scan(&util2); err != nil || util2 != 0 {
			t.Fatalf("idle agent utilization = %v (err %v)", util2, err)
		}
	})
	t.Run("current state shows how long an idle agent has been idle", func(t *testing.T) {
		var state string
		var idleSince time.Time
		if err := conn.QueryRow(ctx, `SELECT state, idle_since FROM afs.agent_activity_current WHERE agent_id = $1`, agentA1).
			Scan(&state, &idleSince); err != nil {
			t.Fatal(err)
		}
		if want := time.Date(2026, 11, 20, 10, 15, 0, 0, time.UTC); state != "idle" || !idleSince.Equal(want) {
			t.Fatalf("state=%s idle_since=%v, want idle since %v", state, idleSince, want)
		}
	})
	t.Run("daily cost rollup carries call counts", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.cost_daily (team_id, day, source, agent_id, model_id, input_tokens, output_tokens, cost_usd, calls)
			VALUES ($1, '2026-11-20', 'gateway', $2, 'claude-sonnet', 11000, 2000, 0.11, 11)`, teamA, agentA1); err != nil {
			t.Fatal(err)
		}
		if err := exec(`UPDATE afs.cost_daily SET calls = -1 WHERE team_id = $1`, teamA); sqlState(err) != "23514" {
			t.Fatalf("negative calls: want check_violation, got %v", err)
		}
	})
	t.Run("budget position reports the current period", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.budgets (id, team_id, period, amount_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T60', $1, 'monthly', 1000)`, teamA); err != nil {
			t.Fatal(err)
		}
		if err := exec(`INSERT INTO afs.spend_counters (budget_id, period_start, limit_usd, spent_usd, reserved_usd) VALUES
			  ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T60', '2026-10-01', 1000, 990, 0),
			  ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4T60', '2026-11-01', 1000, 412.5, 3)`); err != nil {
			t.Fatal(err)
		}
		var pct float64
		if err := conn.QueryRow(ctx, `SELECT used_pct FROM afs.team_budget_position WHERE team_id = $1`, teamA).Scan(&pct); err != nil || pct != 41.3 {
			t.Fatalf("used_pct = %v (err %v)", pct, err)
		}
	})
	t.Run("another team cannot see activity or write it", func(t *testing.T) {
		var n int
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_activity_daily WHERE team_id = $1`, teamA).Scan(&n)
		})
		if err != nil || n != 0 {
			t.Fatalf("team B sees %d team A activity rows (err %v)", n, err)
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamA+`'`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO afs.agent_activity (bucket_start, team_id, agent_id, state) VALUES ('2026-11-20 11:00:00+00', $1, $2, 'idle')`, teamA, agentA1)
			return err
		})
		if sqlState(err) != "42501" {
			t.Fatalf("API writing activity: want insufficient_privilege, got %v", err)
		}
	})
}

func TestExternalTrafficReporting(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	const github = "ext_01JDX0000000000000000000A2"
	const openai = "ext_01JDX0000000000000000000A9"
	flow := func(at, system, host, verdict, reason string, conns, reqs, errs int) error {
		var sys, rsn, rq any
		if system != "" {
			sys = system
		}
		if reason != "" {
			rsn = reason
		}
		if reqs >= 0 {
			rq = reqs
		}
		_, err := conn.Exec(ctx, `INSERT INTO afs.external_traffic (bucket_start, team_id, agent_id, system_id, host, port, verdict, denied_reason,
			connections, requests, errors, bytes_out, bytes_in)
			VALUES ($1, $2, $3, $4, $5, 443, $6, $7, $8, $9, $10, $8 * 1000, $8 * 5000)`,
			at, teamA, agentA1, sys, host, verdict, rsn, conns, rq, errs)
		return err
	}
	t.Run("flows are validated", func(t *testing.T) {
		if err := flow("2026-11-20 10:01:00+00", github, "api.github.com", "allowed", "", 1, 1, 0); sqlState(err) != "23514" {
			t.Errorf("unaligned window: want 23514, got %v", err)
		}
		if err := flow("2026-11-20 10:00:00+00", github, "api.github.com", "allowed", "system_off_team", 1, 1, 0); sqlState(err) != "23514" {
			t.Errorf("allowed with a denial reason: want 23514, got %v", err)
		}
		if err := flow("2026-11-20 10:00:00+00", "", "pastebin.example", "denied", "", 1, -1, 0); sqlState(err) != "23514" {
			t.Errorf("denied without a reason: want 23514, got %v", err)
		}
		if err := flow("2026-11-20 10:00:00+00", "", "Bad Host", "denied", "not_in_catalog", 1, -1, 0); sqlState(err) != "23514" {
			t.Errorf("bad host: want 23514, got %v", err)
		}
	})
	for _, f := range []struct {
		at, sys, host, verdict, reason string
		conns, reqs, errs              int
	}{
		{"2026-11-20 10:00:00+00", github, "api.github.com", "allowed", "", 12, 40, 1},
		{"2026-11-20 10:05:00+00", github, "api.github.com", "allowed", "", 8, 25, 0},
		{"2026-11-20 10:05:00+00", openai, "api.openai.com", "denied", "system_off_service", 3, -1, 0},
		{"2026-11-20 10:10:00+00", "", "pastebin.example", "denied", "not_in_catalog", 2, -1, 0},
	} {
		if err := flow(f.at, f.sys, f.host, f.verdict, f.reason, f.conns, f.reqs, f.errs); err != nil {
			t.Fatal(err)
		}
	}
	t.Run("daily rollup by system with denied attempts", func(t *testing.T) {
		var conns, reqs, errs, denied int64
		if err := conn.QueryRow(ctx, `SELECT connections, requests, errors, denied_connections FROM afs.external_traffic_daily
			WHERE agent_id = $1 AND system_id = $2`, agentA1, github).Scan(&conns, &reqs, &errs, &denied); err != nil {
			t.Fatal(err)
		}
		if conns != 20 || reqs != 65 || errs != 1 || denied != 0 {
			t.Fatalf("github: conns=%d reqs=%d errs=%d denied=%d", conns, reqs, errs, denied)
		}
		var n int
		if err := conn.QueryRow(ctx, `SELECT count(*) FROM afs.external_traffic_daily
			WHERE team_id = $1 AND denied_connections > 0`, teamA).Scan(&n); err != nil || n != 2 {
			t.Fatalf("denied rows = %d (err %v)", n, err)
		}
	})
	t.Run("another team cannot see traffic", func(t *testing.T) {
		var n int
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.external_traffic`).Scan(&n)
		})
		if err != nil || n != 0 {
			t.Fatalf("team B sees %d rows (err %v)", n, err)
		}
	})
}

func TestIdentityProvidersAndTeamGuardrails(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	asApp := func(team string, sql string, args ...any) error {
		return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			setup := `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '` + team + `'`
			if team == "" {
				setup = `SET LOCAL ROLE afs_app; SET LOCAL afs.service_admin = 'on'`
			}
			if _, err := tx.Exec(ctx, setup); err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, sql, args...)
			if err == nil && tag.RowsAffected() == 0 {
				return fmt.Errorf("no rows")
			}
			return err
		})
	}
	const okta = "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T60"
	const entraA = "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T61"
	addIdP := func(caller, id, kind, issuer string, def bool) error {
		return asApp(caller, `INSERT INTO afs.identity_providers (id, kind, name, issuer_url, client_id, is_default)
			VALUES ($1, $2, $2, $3, 'afs-console', $4)`, id, kind, issuer, def)
	}

	t.Run("service admins add providers; one default", func(t *testing.T) {
		if err := addIdP("", okta, "okta", "https://corp.okta.example", true); err != nil {
			t.Fatal(err)
		}
		if err := addIdP("", entraA, "entra_id", "https://login.microsoftonline.example/tenant/v2.0", false); err != nil {
			t.Fatal(err)
		}
		if err := addIdP("", "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T62", "entra_id", "https://login.microsoftonline.example/other/v2.0", true); sqlState(err) != "23505" {
			t.Errorf("second default: want 23505, got %v", err)
		}
		if err := addIdP("", "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T63", "okta", "https://corp.okta.example", false); sqlState(err) != "23505" {
			t.Errorf("same issuer twice: want 23505, got %v", err)
		}
		if err := addIdP("", "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T64", "google", "https://accounts.google.example", false); sqlState(err) != "23514" {
			t.Errorf("unsupported kind: want 23514, got %v", err)
		}
		if err := addIdP("", "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T65", "okta", "http://insecure.okta.example", false); sqlState(err) != "23514" {
			t.Errorf("http issuer: want 23514, got %v", err)
		}
		if err := asApp("", `UPDATE afs.identity_providers SET enabled = false WHERE id = $1`, okta); sqlState(err) != "23514" {
			t.Errorf("disable the default: want 23514, got %v", err)
		}
	})
	t.Run("team callers see every provider but cannot add or change one", func(t *testing.T) {
		if err := addIdP(teamA, "idp_01JD3Z5Y8K2M4N6P8Q0R2S4T66", "okta", "https://rogue.okta.example", false); sqlState(err) != "42501" {
			t.Errorf("team insert: want 42501, got %v", err)
		}
		if err := asApp(teamA, `UPDATE afs.identity_providers SET client_id = 'x' WHERE id = $1`, entraA); err == nil || err.Error() != "no rows" {
			t.Errorf("team update: want no rows, got %v", err)
		}
		var n int
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.identity_providers`).Scan(&n)
		}); err != nil || n != 2 {
			t.Errorf("team B sees %d providers, want 2; err %v", n, err)
		}
	})
	t.Run("a team chooses one of the service's enabled providers", func(t *testing.T) {
		if err := asApp(teamA, `UPDATE afs.teams SET identity_provider_id = $2 WHERE id = $1`, teamA, entraA); err != nil {
			t.Fatalf("team admin chooses Entra ID: %v", err)
		}
		if err := asApp("", `UPDATE afs.identity_providers SET enabled = false WHERE id = $1`, entraA); sqlState(err) != "55000" {
			t.Errorf("disable a provider in use: want 55000, got %v", err)
		}
		if err := asApp(teamA, `UPDATE afs.teams SET identity_provider_id = NULL WHERE id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		if err := asApp("", `UPDATE afs.identity_providers SET enabled = false WHERE id = $1`, entraA); err != nil {
			t.Fatalf("disable once unused: %v", err)
		}
		if err := asApp(teamA, `UPDATE afs.teams SET identity_provider_id = $2 WHERE id = $1`, teamA, entraA); sqlState(err) != "23514" {
			t.Errorf("choose a disabled provider: want 23514, got %v", err)
		}
		if err := asApp(teamA, `UPDATE afs.teams SET identity_provider_id = 'idp_01JD3Z5Y8K2M4N6P8Q0R2S4T6Z' WHERE id = $1`, teamA); sqlState(err) != "23503" {
			t.Errorf("unknown provider: want 23503, got %v", err)
		}
	})
	t.Run("group bindings: service level names a provider, team bindings use the team's", func(t *testing.T) {
		bind := func(id, role string, team any, idp any) error {
			_, err := conn.Exec(ctx, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name, identity_provider_id)
				VALUES ($1, $2, $3, 'group', 'grp-eng', $4)`, id, role, team, idp)
			return err
		}
		if err := bind("rb_01JD3Z5Y8K2M4N6P8Q0R2S4T60", "service_admin", nil, okta); err != nil {
			t.Fatalf("service-level binding naming a provider: %v", err)
		}
		if err := bind("rb_01JD3Z5Y8K2M4N6P8Q0R2S4T61", "team_viewer", teamA, okta); sqlState(err) != "23514" {
			t.Errorf("team binding naming a provider: want 23514, got %v", err)
		}
		if err := bind("rb_01JD3Z5Y8K2M4N6P8Q0R2S4T62", "team_viewer", teamA, nil); err != nil {
			t.Errorf("team binding: %v", err)
		}
	})
	t.Run("team admins set the account filter only when allowed", func(t *testing.T) {
		set := `UPDATE afs.teams SET allowed_aws_accounts = '{payments-*}' WHERE id = $1`
		if err := asApp(teamA, set, teamA); sqlState(err) != "42501" {
			t.Fatalf("not allowed: want 42501, got %v", err)
		}
		if err := asApp(teamA, `UPDATE afs.teams SET may_manage_aws_accounts = true WHERE id = $1`, teamA); sqlState(err) != "42501" {
			t.Fatalf("self-grant: want 42501, got %v", err)
		}
		if err := asApp("", `UPDATE afs.teams SET may_manage_aws_accounts = true WHERE id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		if err := asApp(teamA, set, teamA); err != nil {
			t.Fatalf("allowed: %v", err)
		}
		if err := asApp(teamA, `UPDATE afs.teams SET may_add_external_systems = true WHERE id = $1`, teamA); sqlState(err) != "42501" {
			t.Fatalf("external systems right is still service-admin only: got %v", err)
		}
	})
}

func TestCostAllocationTags(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	as := func(team string, sql string, args ...any) error {
		return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			setup := `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '` + team + `'`
			if team == "" {
				setup = `SET LOCAL ROLE afs_app; SET LOCAL afs.service_admin = 'on'`
			}
			if _, err := tx.Exec(ctx, setup); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, sql, args...)
			return err
		})
	}
	setTag := func(team, key, value string) error {
		return as(team, `INSERT INTO afs.team_tags (team_id, key, value) VALUES ($1, $2, $3)
			ON CONFLICT (team_id, key) DO UPDATE SET value = EXCLUDED.value`, team, key, value)
	}

	t.Run("service admins define fixed and required keys", func(t *testing.T) {
		if err := as("", `INSERT INTO afs.service_tags (key, mode, value) VALUES ('environment', 'fixed', 'prod')`); err != nil {
			t.Fatal(err)
		}
		if err := as("", `INSERT INTO afs.service_tags (key, mode, allowed_values, default_value)
			VALUES ('business-unit', 'required', '{payments,platform,unassigned}', 'unassigned')`); err != nil {
			t.Fatal(err)
		}
		if err := as(teamA, `INSERT INTO afs.service_tags (key, mode, value) VALUES ('owner', 'fixed', 'me')`); sqlState(err) != "42501" {
			t.Errorf("team caller defining a service tag: want 42501, got %v", err)
		}
		for _, bad := range []string{
			`INSERT INTO afs.service_tags (key, mode) VALUES ('afs-team-id', 'required')`,      // reserved prefix
			`INSERT INTO afs.service_tags (key, mode) VALUES ('aws:createdBy', 'required')`,    // reserved prefix
			`INSERT INTO afs.service_tags (key, mode) VALUES ('db-password', 'required')`,      // looks like a credential
			`INSERT INTO afs.service_tags (key, mode) VALUES ('region', 'fixed')`,              // fixed needs a value
			`INSERT INTO afs.service_tags (key, mode, value) VALUES ('tier', 'required', 'x')`, // required takes no value
			`INSERT INTO afs.service_tags (key, mode, allowed_values, default_value) VALUES ('tier', 'required', '{a,b}', 'c')`,
			`INSERT INTO afs.service_tags (key, mode, allowed_values) VALUES ('tier', 'required', '{"bad<value"}')`,
		} {
			if err := as("", bad); sqlState(err) != "23514" {
				t.Errorf("%s: want 23514, got %v", bad, err)
			}
		}
		if err := as("", `INSERT INTO afs.service_tags (key, mode, value) VALUES ('Environment', 'fixed', 'dev')`); sqlState(err) != "23505" {
			t.Errorf("case-insensitive duplicate: want 23505, got %v", err)
		}
	})
	t.Run("teams set required values and their own tags, never fixed ones", func(t *testing.T) {
		if err := setTag(teamA, "business-unit", "payments"); err != nil {
			t.Fatal(err)
		}
		if err := setTag(teamA, "business-unit", "marketing"); sqlState(err) != "23514" {
			t.Errorf("value outside the allowed list: want 23514, got %v", err)
		}
		if err := setTag(teamA, "environment", "dev"); sqlState(err) != "42501" {
			t.Errorf("override a fixed tag: want 42501, got %v", err)
		}
		if err := setTag(teamA, "Business-Unit", "payments"); sqlState(err) != "23514" {
			t.Errorf("respelled service key: want 23514, got %v", err)
		}
		if err := setTag(teamA, "project", "checkout-v2"); err != nil {
			t.Fatal(err)
		}
		if err := setTag(teamB, "project", "x"); err != nil {
			t.Fatal(err)
		}
		if err := as(teamB, `UPDATE afs.team_tags SET value = 'stolen' WHERE team_id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		var v string
		if err := conn.QueryRow(ctx, `SELECT value FROM afs.team_tags WHERE team_id = $1 AND key = 'project'`, teamA).Scan(&v); err != nil || v != "checkout-v2" {
			t.Errorf("team B changed team A's tag: %q %v", v, err)
		}
		if err := as("", `UPDATE afs.service_tags SET mode = 'fixed', value = 'p', allowed_values = NULL, default_value = NULL WHERE key = 'business-unit'`); sqlState(err) != "55000" {
			t.Errorf("make a key teams already set fixed: want 55000, got %v", err)
		}
	})
	t.Run("system tags team and agent id are always there", func(t *testing.T) {
		rows, err := conn.Query(ctx, `SELECT key, value, source FROM afs.agent_effective_tags WHERE agent_id = $1 ORDER BY key`, agentA1)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]string{}
		for rows.Next() {
			var k, v, s string
			if err := rows.Scan(&k, &v, &s); err != nil {
				t.Fatal(err)
			}
			got[k] = v + "/" + s
		}
		want := map[string]string{
			"afs-team-id": teamA + "/system", "afs-agent-id": agentA1 + "/system",
			"environment": "prod/service", "business-unit": "payments/team", "project": "checkout-v2/team",
		}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("agent tags\n got %v\nwant %v", got, want)
		}
		var src string
		if err := conn.QueryRow(ctx, `SELECT source FROM afs.team_effective_tags WHERE team_id = $1 AND key = 'business-unit'`, teamB).Scan(&src); err != nil || src != "service_default" {
			t.Errorf("team B business-unit source = %q, want service_default (%v)", src, err)
		}
	})
	t.Run("new teams must give required tags without a default", func(t *testing.T) {
		if err := as("", `INSERT INTO afs.service_tags (key, mode) VALUES ('cost-owner', 'required')`); err != nil {
			t.Fatal(err)
		}
		var src string
		if err := conn.QueryRow(ctx, `SELECT source FROM afs.team_effective_tags WHERE team_id = $1 AND key = 'cost-owner'`, teamB).Scan(&src); err != nil || src != "missing" {
			t.Errorf("existing team: source = %q, want missing (%v)", src, err)
		}
		newTeam := `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email)
			VALUES ('team_01JD3Z5Y8K2M4N6P8Q0R2S4T7A', 'fraud', 'Fraud', 'CC300', 'f@example.com')`
		if err := as("", newTeam); sqlState(err) != "23514" {
			t.Errorf("team without required tag: want 23514, got %v", err)
		}
		if err := as("", newTeam+`; INSERT INTO afs.team_tags (team_id, key, value)
			VALUES ('team_01JD3Z5Y8K2M4N6P8Q0R2S4T7A', 'cost-owner', 'risk')`); err != nil {
			t.Errorf("team with required tag in the same transaction: %v", err)
		}
		if err := as("", `DELETE FROM afs.team_tags WHERE team_id = 'team_01JD3Z5Y8K2M4N6P8Q0R2S4T7A' AND key = 'cost-owner'`); sqlState(err) != "23514" {
			t.Errorf("remove a required tag: want 23514, got %v", err)
		}
	})
	t.Run("cost, activity and traffic roll up by tag", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `
			INSERT INTO afs.cost_daily (team_id, day, source, agent_id, model_id, input_tokens, output_tokens, cost_usd, calls) VALUES
			 ('`+teamA+`', '2026-11-20', 'gateway', '`+agentA1+`', 'claude-sonnet', 1000, 100, 1.50, 3),
			 ('`+teamB+`', '2026-11-20', 'gateway', NULL, 'claude-sonnet', 500, 50, 0.50, 1)`); err != nil {
			t.Fatal(err)
		}
		var cost float64
		var teams int
		if err := conn.QueryRow(ctx, `SELECT sum(cost_usd)::float8, sum(teams)::int FROM afs.cost_daily_by_tag
			WHERE tag_key = 'environment' AND tag_value = 'prod'`).Scan(&cost, &teams); err != nil || cost != 2.0 || teams != 2 {
			t.Errorf("environment=prod: cost %v teams %d, want 2.0 and 2 (%v)", cost, teams, err)
		}
		if err := conn.QueryRow(ctx, `SELECT sum(cost_usd)::float8 FROM afs.cost_daily_by_tag
			WHERE tag_key = 'cost-owner' AND tag_value IS NULL`).Scan(&cost); err != nil || cost != 2.0 {
			t.Errorf("untagged cost-owner: %v, want 2.0 (%v)", cost, err)
		}
		var n int
		if err := conn.QueryRow(ctx, `SELECT count(*) FROM afs.cost_daily_by_tag WHERE tag_key LIKE 'afs-%'`).Scan(&n); err != nil || n != 0 {
			t.Errorf("system keys in rollup: %d (%v)", n, err)
		}
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.team_ids = '`+teamB+`'`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT sum(cost_usd)::float8 FROM afs.cost_daily_by_tag WHERE tag_key = 'environment'`).Scan(&cost)
		}); err != nil || cost != 0.5 {
			t.Errorf("team B sees %v in its rollup, want only its own 0.5 (%v)", cost, err)
		}
		for _, v := range []string{"afs.agent_activity_daily_by_tag", "afs.external_traffic_daily_by_tag"} {
			if _, err := conn.Exec(ctx, `SELECT * FROM `+v+` LIMIT 1`); err != nil {
				t.Errorf("%s: %v", v, err)
			}
		}
	})
	t.Run("the gateway reads an agent's tags", func(t *testing.T) {
		var n int
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_gateway`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_effective_tags WHERE agent_id = $1`, agentA1).Scan(&n)
		}); err != nil || n != 5 {
			t.Errorf("gateway sees %d tags, want 5 (cost-owner has no value yet) (%v)", n, err)
		}
	})
}

func TestModelPriceProposals(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	as := func(role, admin, sql string, args ...any) error {
		return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE `+role+`; SET LOCAL afs.actor = 'usr_admin'; SET LOCAL afs.service_admin = '`+admin+`'`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, sql, args...)
			return err
		})
	}
	const p1 = "mpp_01JD3Z5Y8K2M4N6P8Q0R2S4T60"
	const p2 = "mpp_01JD3Z5Y8K2M4N6P8Q0R2S4T61"
	propose := func(id, from string, in float64) error {
		return as("afs_billing", "off", `INSERT INTO afs.model_price_proposals (id, model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok)
			VALUES ($1, 'claude-sonnet', $2, $3, 15)`, id, from, in)
	}

	t.Run("billing proposes one price per model at a time", func(t *testing.T) {
		if err := propose(p1, "2026-12-01 00:00:00+00", 3); err != nil {
			t.Fatal(err)
		}
		if err := propose(p2, "2026-12-15 00:00:00+00", 2.5); sqlState(err) != "23505" {
			t.Errorf("second pending: want 23505, got %v", err)
		}
		if err := as("afs_app", "on", `INSERT INTO afs.model_price_proposals (id, model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok)
			VALUES ($1, 'claude-sonnet', now(), 1, 1)`, p2); sqlState(err) != "42501" {
			t.Errorf("api proposing: want 42501, got %v", err)
		}
	})
	t.Run("only service admins decide", func(t *testing.T) {
		if err := as("afs_app", "off", `UPDATE afs.model_price_proposals SET status = 'approved' WHERE id = $1`, p1); sqlState(err) != "42501" {
			t.Errorf("team caller approving: want 42501, got %v", err)
		}
		if err := as("afs_billing", "off", `UPDATE afs.model_price_proposals SET status = 'approved' WHERE id = $1`, p1); sqlState(err) != "42501" {
			t.Errorf("billing approving: want 42501, got %v", err)
		}
		if err := as("afs_app", "on", `UPDATE afs.model_price_proposals SET status = 'superseded' WHERE id = $1`, p1); sqlState(err) != "42501" {
			t.Errorf("api superseding: want 42501, got %v", err)
		}
		if err := as("afs_app", "on", `UPDATE afs.model_price_proposals SET status = 'approved' WHERE id = $1`, p1); err != nil {
			t.Fatal(err)
		}
		var by string
		var in float64
		var src string
		if err := conn.QueryRow(ctx, `SELECT p.decided_by, m.input_usd_per_mtok::float8, m.source
			FROM afs.model_price_proposals p JOIN afs.model_prices m ON m.model_id = p.model_id AND m.effective_from = p.effective_from
			WHERE p.id = $1`, p1).Scan(&by, &in, &src); err != nil || by != "usr_admin" || in != 3 || src != "aws_price_list" {
			t.Errorf("approval wrote price %v from %q by %q (%v)", in, src, by, err)
		}
		if err := as("afs_app", "on", `UPDATE afs.model_price_proposals SET status = 'rejected' WHERE id = $1`, p1); sqlState(err) != "55000" {
			t.Errorf("decide twice: want 55000, got %v", err)
		}
	})
	t.Run("a late approval takes effect from now, not the past", func(t *testing.T) {
		if err := propose(p2, "2020-01-01 00:00:00+00", 2); err != nil {
			t.Fatal(err)
		}
		if err := as("afs_app", "on", `UPDATE afs.model_price_proposals SET status = 'approved' WHERE id = $1`, p2); err != nil {
			t.Fatal(err)
		}
		var n int
		if err := conn.QueryRow(ctx, `SELECT count(*) FROM afs.model_prices WHERE model_id = 'claude-sonnet' AND effective_from < '2026-01-01'`).Scan(&n); err != nil || n != 0 {
			t.Errorf("backdated prices: %d (%v)", n, err)
		}
	})
	t.Run("pricing settings are typed", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '"often"' WHERE key = 'pricing.price_list_sync'`); sqlState(err) != "23514" {
			t.Errorf("non-boolean sync: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '250' WHERE key = 'billing.variance_alert_pct'`); sqlState(err) != "23514" {
			t.Errorf("variance over 100: want 23514, got %v", err)
		}
	})
}
