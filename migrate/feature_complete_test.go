package migrate_test

// Proofs for acceptance criteria that were pending at 000014 (spec 261121-db-feature-complete).

import (
	"context"
	"fmt"
	"io/fs"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

// swarmB is an ephemeral team that, with teamB, owns at least one row in every team-owned table
// after seedOtherTeams.
const swarmB = "team_01JD3Z5Y8K2M4N6P8Q0R2S4TB0"

// seedOtherTeams gives teams B and swarm B rows in every team-owned table, so isolation tests can
// prove that a team-A caller sees and changes none of them.
func seedOtherTeams(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	seedTeams(t, conn)
	_, err := conn.Exec(t.Context(), `
INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule)
VALUES ('`+swarmB+`', 'swarm-b', 'Swarm B', 'ephemeral', 'CC300', 's@example.com', 500, now() + interval '7 days', 'at_work_complete');
INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TB1', '`+swarmB+`', 'lifetime', 300, 'block');
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+teamB+`', 'claude-sonnet'), ('`+swarmB+`', 'claude-sonnet');
INSERT INTO afs.budgets (id, team_id, period, amount_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TB2', '`+teamB+`', 'monthly', 100);
INSERT INTO afs.spend_counters (budget_id, period_start, limit_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TB2', '2026-11-01', 100);
INSERT INTO afs.budget_threshold_events (budget_id, period_start, threshold) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TB2', '2026-11-01', 50);
INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES
 ('agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', '`+teamB+`', 'indexer', 'omp', 'ghcr.io/x/omp@sha256:abc', 'claude-sonnet');
INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin) VALUES
 ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4TB4', '`+teamB+`', 'log-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-search/_shared/log-token-AbCdEf', 'managed');
INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target) VALUES ('`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4TB4', 'env', 'LOG_TOKEN');
INSERT INTO afs.namespace_config_values (id, team_id, name, config_value) VALUES ('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4TB5', '`+teamB+`', 'LOG_LEVEL', 'info');
INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source, config_value) VALUES ('acv_01JD3Z5Y8K2M4N6P8Q0R2S4TB6', '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'MODE', 'literal', 'fast');
INSERT INTO afs.log_destinations (id, team_id, name, kind, config, secret_id) VALUES ('log_01JD3Z5Y8K2M4N6P8Q0R2S4TB7', '`+teamB+`', 'splunk', 'splunk_hec', '{"endpoint":"https://splunk.example.com"}', 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4TB4');
INSERT INTO afs.notification_channels (id, team_id, name, kind, config, secret_id) VALUES ('nch_01JD3Z5Y8K2M4N6P8Q0R2S4TB8', '`+teamB+`', 'ops', 'slack', '{"channel":"#ops"}', 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4TB4');
INSERT INTO afs.report_schedules (id, team_id, name, report, cadence, channel_id, next_run_at) VALUES ('rsc_01JD3Z5Y8K2M4N6P8Q0R2S4TB9', '`+teamB+`', 'weekly-cost', 'costs', 'weekly', 'nch_01JD3Z5Y8K2M4N6P8Q0R2S4TB8', now() + interval '1 day');
INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at) VALUES ('key_01JD3Z5Y8K2M4N6P8Q0R2S4TBA', '`+teamB+`', 'ci', 'team_viewer', 'afs_k_ab', decode(repeat('00',32),'hex'), now() + interval '30 days');
INSERT INTO afs.agent_volume_snapshots (id, team_id, agent_id, reason) VALUES ('vsnap_01JD3Z5Y8K2M4N6P8Q0R2S4TBB', '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'manual');
INSERT INTO afs.agent_identities (id, team_id, agent_id, kind) VALUES ('aid_01JD3Z5Y8K2M4N6P8Q0R2S4TBC', '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'aws_iam_role');
INSERT INTO afs.org_aws_accounts (id, name, status) VALUES ('123412341234', 'search-prod', 'active');
UPDATE afs.teams SET allowed_aws_accounts = '{search-*}' WHERE id IN ('`+teamB+`', '`+swarmB+`');
UPDATE afs.agents SET iam_identity = 'dedicated' WHERE id = 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3';
INSERT INTO afs.agent_role_links (id, team_id, agent_id, account_id, role_arn, profile_name, external_id)
 VALUES ('arl_01JD3Z5Y8K2M4N6P8Q0R2S4TBD', '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', '123412341234', 'arn:aws:iam::123412341234:role/reader', 'search-prod', 'afs-AbCdEfGhIjKlMnOpQrStB');
UPDATE afs.teams SET may_add_external_systems = true WHERE id = '`+teamB+`';
INSERT INTO afs.external_systems (id, team_id, slug, name, category, owner, purpose, endpoints)
 VALUES ('ext_01JD3Z5Y8K2M4N6P8Q0R2S4TBE', '`+teamB+`', 'pagerduty', 'PagerDuty', 'other', 'search-sre', 'Paging', '{api.pagerduty.com}');
INSERT INTO afs.external_system_optouts (id, team_id, system_id) VALUES ('xso_01JD3Z5Y8K2M4N6P8Q0R2S4TBF', '`+teamB+`', 'ext_01JD3Z5Y8K2M4N6P8Q0R2S4TBE');
INSERT INTO afs.team_tags (team_id, key, value) VALUES ('`+teamB+`', 'env', 'prod');
SELECT afs.current_team_tag_set('`+teamB+`');
INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ('rb_01JD3Z5Y8K2M4N6P8Q0R2S4TBP', 'team_admin', '`+teamB+`', 'group', 'grp-search');
INSERT INTO afs.work_orders (id, kind, title, team_id) VALUES ('wo_01JD3Z5Y8K2M4N6P8Q0R2S4TBQ', 'general', 'Reindex', '`+teamB+`');
INSERT INTO afs.usage_events (occurred_at, team_id, agent_id, model_id, request_id, outcome) VALUES (now(), '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'claude-sonnet', 'req-b1', 'ok');
INSERT INTO afs.agent_activity (bucket_start, team_id, agent_id, state) VALUES (date_trunc('hour', now()), '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'idle');
INSERT INTO afs.external_traffic (bucket_start, team_id, agent_id, host, verdict) VALUES (date_trunc('hour', now()), '`+teamB+`', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', 'api.example.com', 'allowed');
INSERT INTO afs.cost_daily (team_id, day, source, cost_usd) VALUES ('`+teamB+`', current_date, 'gateway', 1);
INSERT INTO afs.cost_reconciliations (team_id, day, gateway_usd, billed_usd, status) VALUES ('`+teamB+`', current_date, 1, 1, 'ok');
INSERT INTO afs.resource_status (resource_kind, resource_id, team_id) VALUES ('agents', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', '`+teamB+`');
INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES ('agent.created', 'agents', 'agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3', '`+teamB+`', '{}');
INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, team_id) VALUES ('user', 'usr_b', 'CreateAgent', 'allowed', '`+teamB+`');
INSERT INTO afs.swarm_stages (id, team_id, name, position) VALUES ('stg_01JD3Z5Y8K2M4N6P8Q0R2S4TBG', '`+swarmB+`', 'scan', 1);
INSERT INTO afs.agent_pools (id, team_id, name, template, image, model_id, workers) VALUES
 ('pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBH', '`+swarmB+`', 'scanner', 'omp', 'ghcr.io/x/omp@sha256:abc', 'claude-sonnet', 2),
 ('pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ', '`+swarmB+`', 'fixer', 'omp', 'ghcr.io/x/omp@sha256:abc', 'claude-sonnet', 2);
INSERT INTO afs.pool_handoffs (team_id, from_pool_id, to_pool_id) VALUES ('`+swarmB+`', 'pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBH', 'pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ');
INSERT INTO afs.secrets (id, team_id, pool_id, name, secrets_manager_arn, origin) VALUES ('sec_01JD3Z5Y8K2M4N6P8Q0R2S4TBK', '`+swarmB+`', 'pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ', 'gh-token',
 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-swarm-b/fixer/gh-token-AbCdEf', 'managed');
INSERT INTO afs.pool_secret_bindings (team_id, pool_id, secret_id, delivery, target) VALUES ('`+swarmB+`', 'pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ', 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4TBK', 'env', 'GH_TOKEN');
INSERT INTO afs.pool_config_values (id, team_id, pool_id, name, source, config_value) VALUES ('pcv_01JD3Z5Y8K2M4N6P8Q0R2S4TBN', '`+swarmB+`', 'pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ', 'MODE', 'literal', 'x');
INSERT INTO afs.pool_role_links (id, team_id, pool_id, account_id, role_name, profile_name, external_id)
 VALUES ('prl_01JD3Z5Y8K2M4N6P8Q0R2S4TBM', '`+swarmB+`', 'pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ', '123412341234', 'afs-fix', 'search-prod', 'afs-'||md5('x'));
`)
	if err != nil {
		t.Fatal(err)
	}
}

// asTeamA runs fn as afs_app bound to team A only (not a service admin), and rolls back.
func asTeamA(t *testing.T, conn *pgx.Conn, fn func(tx pgx.Tx) error) error {
	t.Helper()
	ctx := t.Context()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_a'; SET LOCAL afs.team_ids = '`+teamA+`'`); err != nil {
		t.Fatal(err)
	}
	return fn(tx)
}

// DB-US-1: for every table under row-level security that has a team column, a team-A caller's
// UPDATE and DELETE of other teams' rows (and of service-level rows) change zero rows, and where
// the table is team-scoped only, it sees none of them.
func TestCrossTeamWritesChangeNothing(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)

	// Keyed by something other than the team: proven in their own tests.
	exempt := map[string]string{
		"idempotency_keys": "scoped by principal (TestReportSchedulesIsolationTierAndIdempotencyKeys)",
	}
	rows, err := conn.Query(ctx, `
		SELECT c.relname,
		       CASE WHEN c.relname = 'teams' THEN 'id' ELSE 'team_id' END,
		       NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'afs' AND p.tablename = c.relname
		                     AND 'afs_app' = ANY (p.roles) AND p.policyname <> 'app_team_scope')
		  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE n.nspname = 'afs' AND c.relkind IN ('r', 'p') AND c.relrowsecurity AND NOT c.relispartition
		   AND (c.relname = 'teams' OR EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid
		                                         AND a.attname = 'team_id' AND NOT a.attisdropped))
		 ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	type table struct {
		name, col  string
		scopedOnly bool
	}
	var tables []table
	for rows.Next() {
		var tb table
		if err := rows.Scan(&tb.name, &tb.col, &tb.scopedOnly); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, tb)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(tables) < 30 {
		t.Fatalf("found %d team tables, expected at least 30", len(tables))
	}
	denied := func(err error) bool { return sqlState(err) == "42501" }
	for _, tb := range tables {
		t.Run(tb.name, func(t *testing.T) {
			if why, ok := exempt[tb.name]; ok {
				t.Skip(why)
			}
			others := "SELECT count(*) FROM afs." + pgx.Identifier{tb.name}.Sanitize() + " WHERE " + tb.col + " IS DISTINCT FROM '" + teamA + "'"
			var before int
			if err := conn.QueryRow(ctx, others).Scan(&before); err != nil {
				t.Fatal(err)
			}
			if before == 0 {
				t.Fatalf("seedOtherTeams has no row of another team in %s: extend the fixture", tb.name)
			}
			where := " WHERE " + tb.col + " IS DISTINCT FROM '" + teamA + "'"
			ident := "afs." + pgx.Identifier{tb.name}.Sanitize()
			for _, stmt := range []string{
				"UPDATE " + ident + " SET " + tb.col + " = " + tb.col + where,
				"DELETE FROM " + ident + where,
			} {
				err := asTeamA(t, conn, func(tx pgx.Tx) error {
					tag, err := tx.Exec(ctx, stmt)
					if err == nil && tag.RowsAffected() != 0 {
						t.Errorf("%s changed %d rows", strings.Fields(stmt)[0], tag.RowsAffected())
					}
					return err
				})
				if err != nil && !denied(err) {
					t.Errorf("%s: %v", strings.Fields(stmt)[0], err)
				}
			}
			if tb.scopedOnly {
				err := asTeamA(t, conn, func(tx pgx.Tx) error {
					var n int
					if err := tx.QueryRow(ctx, strings.Replace(others, "count(*)", "count(*)", 1)).Scan(&n); err != nil {
						return err
					}
					if n != 0 {
						t.Errorf("team A sees %d rows of other teams", n)
					}
					return nil
				})
				if err != nil && !denied(err) {
					t.Errorf("select: %v", err)
				}
			}
			var after int
			if err := conn.QueryRow(ctx, others).Scan(&after); err != nil || after != before {
				t.Fatalf("other teams' rows %d -> %d (%v)", before, after, err)
			}
		})
	}
}

// Fixture ids from seedOtherTeams.
const (
	secIDB    = "sec_01JD3Z5Y8K2M4N6P8Q0R2S4TB4"
	logDestB  = "log_01JD3Z5Y8K2M4N6P8Q0R2S4TB7"
	channelB  = "nch_01JD3Z5Y8K2M4N6P8Q0R2S4TB8"
	agentB    = "agt_01JD3Z5Y8K2M4N6P8Q0R2S4TB3"
	poolScanB = "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBH"
	poolFixB  = "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TBJ"
	workOrdB  = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TBQ"
)

// asApp runs sql as afs_app with the given session settings, in a transaction that commits.
func asApp(t *testing.T, conn *pgx.Conn, settings, sql string, args ...any) (int64, error) {
	t.Helper()
	var n int64
	err := pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_a'; "+settings); err != nil {
			return err
		}
		tag, err := tx.Exec(t.Context(), sql, args...)
		n = tag.RowsAffected()
		return err
	})
	return n, err
}

func scalar[T any](t *testing.T, conn *pgx.Conn, settings, sql string, args ...any) T {
	t.Helper()
	var v T
	err := pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if settings != "" {
			if _, err := tx.Exec(t.Context(), settings); err != nil {
				return err
			}
		}
		return tx.QueryRow(t.Context(), sql, args...).Scan(&v)
	})
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return v
}

const (
	appTeamA  = "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_a'; SET LOCAL afs.team_ids = '" + teamA + "'"
	appAdmin  = "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_admin'; SET LOCAL afs.service_admin = 'on'"
	onlyTeamA = "SET LOCAL afs.team_ids = '" + teamA + "'"
)

// DB-US-34.
func TestLogDestinationsAndNotificationChannels(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	const secIDA = "sec_01JD3Z5Y8K2M4N6P8Q0R2S4TC0"
	if _, err := conn.Exec(ctx, `
		INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin) VALUES
		 ('`+secIDA+`', '`+teamA+`', 'log-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-payments/_shared/log-token-AbCdEf', 'managed');
		INSERT INTO afs.log_destinations (id, team_id, name, kind, config, secret_id) VALUES
		 ('log_01JD3Z5Y8K2M4N6P8Q0R2S4TC1', '`+teamA+`', 'cw', 'cloudwatch', '{"logGroup":"/afs/payments"}', NULL);
		INSERT INTO afs.notification_channels (id, team_id, name, kind, config) VALUES
		 ('nch_01JD3Z5Y8K2M4N6P8Q0R2S4TC2', '`+teamA+`', 'ops', 'email', '{"to":["ops@example.com"]}'),
		 ('nch_01JD3Z5Y8K2M4N6P8Q0R2S4TC3', NULL, 'security', 'email', '{"to":["sec@example.com"]}')`); err != nil {
		t.Fatal(err)
	}

	t.Run("team callers see only their own", func(t *testing.T) {
		for _, tbl := range []string{"log_destinations", "notification_channels"} {
			if n := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.`+tbl); n != 1 {
				t.Errorf("%s: team A sees %d rows, want 1", tbl, n)
			}
		}
	})
	t.Run("a row for another team or the service is refused", func(t *testing.T) {
		for name, sql := range map[string]string{
			"destination for team B": `INSERT INTO afs.log_destinations (id, team_id, name, kind, config) VALUES ('log_01JD3Z5Y8K2M4N6P8Q0R2S4TC4', '` + teamB + `', 'x', 's3', '{}')`,
			"channel for team B":     `INSERT INTO afs.notification_channels (id, team_id, name, kind, config) VALUES ('nch_01JD3Z5Y8K2M4N6P8Q0R2S4TC5', '` + teamB + `', 'x', 'slack', '{}')`,
			"service-level channel":  `INSERT INTO afs.notification_channels (id, team_id, name, kind, config) VALUES ('nch_01JD3Z5Y8K2M4N6P8Q0R2S4TC6', NULL, 'x', 'slack', '{}')`,
		} {
			if _, err := asApp(t, conn, onlyTeamA, sql); sqlState(err) != "42501" {
				t.Errorf("%s: want 42501, got %v", name, err)
			}
		}
	})
	t.Run("another team's rows cannot be changed or removed", func(t *testing.T) {
		for _, sql := range []string{
			`UPDATE afs.log_destinations SET enabled = false WHERE id = '` + logDestB + `'`,
			`DELETE FROM afs.log_destinations WHERE id = '` + logDestB + `'`,
			`UPDATE afs.notification_channels SET enabled = false WHERE id = '` + channelB + `'`,
			`DELETE FROM afs.notification_channels WHERE id = '` + channelB + `'`,
			`UPDATE afs.notification_channels SET enabled = false WHERE team_id IS NULL`,
		} {
			if n, err := asApp(t, conn, onlyTeamA, sql); err != nil || n != 0 {
				t.Errorf("%s: %d rows, %v", sql, n, err)
			}
		}
	})
	t.Run("credentials are a reference to the team's own secret", func(t *testing.T) {
		for name, sql := range map[string]string{
			"destination naming team B's secret": `INSERT INTO afs.log_destinations (id, team_id, name, kind, config, secret_id) VALUES ('log_01JD3Z5Y8K2M4N6P8Q0R2S4TC7', '` + teamA + `', 'splunk', 'splunk_hec', '{}', '` + secIDB + `')`,
			"channel naming team B's secret":     `INSERT INTO afs.notification_channels (id, team_id, name, kind, config, secret_id) VALUES ('nch_01JD3Z5Y8K2M4N6P8Q0R2S4TC8', '` + teamA + `', 'hook', 'webhook', '{}', '` + secIDB + `')`,
			"destination naming no secret":       `INSERT INTO afs.log_destinations (id, team_id, name, kind, config, secret_id) VALUES ('log_01JD3Z5Y8K2M4N6P8Q0R2S4TC9', '` + teamA + `', 'dd', 'datadog', '{}', 'sec_01JD3Z5Y8K2M4N6P8Q0R2S4TCA')`,
			"moving a destination to B's secret": `UPDATE afs.log_destinations SET secret_id = '` + secIDB + `' WHERE id = 'log_01JD3Z5Y8K2M4N6P8Q0R2S4TC1'`,
		} {
			if _, err := conn.Exec(ctx, sql); sqlState(err) != "23503" {
				t.Errorf("%s: want 23503, got %v", name, err)
			}
		}
		if _, err := asApp(t, conn, onlyTeamA, `UPDATE afs.log_destinations SET secret_id = $1 WHERE id = 'log_01JD3Z5Y8K2M4N6P8Q0R2S4TC1'`, secIDA); err != nil {
			t.Errorf("own secret: %v", err)
		}
	})
	t.Run("a secret in use cannot be deleted", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `DELETE FROM afs.secrets WHERE id = $1`, secIDA); sqlState(err) != "23503" {
			t.Errorf("secret used by a destination: want 23503, got %v", err)
		}
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			for _, sql := range []string{
				`DELETE FROM afs.log_destinations WHERE secret_id = $1`,
				`DELETE FROM afs.agent_secret_bindings WHERE secret_id = $1`,
				`DELETE FROM afs.secrets WHERE id = $1`,
			} {
				if _, err := tx.Exec(ctx, sql, secIDB); err != nil {
					return err
				}
			}
			return nil
		})
		if sqlState(err) != "23503" {
			t.Errorf("secret used by a channel: want 23503, got %v", err)
		}
	})
	t.Run("a service-level channel holds no secret reference", func(t *testing.T) {
		// (team_id, secret_id) is a MATCH SIMPLE foreign key: with team_id NULL it is not checked, so
		// without a CHECK a service channel could name any team's secret, or none that exists.
		for i, sec := range []string{secIDB, "sec_01JD3Z5Y8K2M4N6P8Q0R2S4TCB"} {
			if _, err := conn.Exec(ctx, `INSERT INTO afs.notification_channels (id, team_id, name, kind, config, secret_id)
				VALUES ($1, NULL, $1, 'webhook', '{}', $2)`, fmt.Sprintf("nch_01JD3Z5Y8K2M4N6P8Q0R2S4TD%d", i), sec); sqlState(err) != "23514" {
				t.Errorf("service channel naming %s: want 23514, got %v", sec, err)
			}
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.notification_channels SET secret_id = $1 WHERE id = 'nch_01JD3Z5Y8K2M4N6P8Q0R2S4TC3'`, secIDB); sqlState(err) != "23514" {
			t.Errorf("adding a secret to a service channel: want 23514, got %v", err)
		}
	})
	t.Run("a channel used by a report schedule cannot be deleted", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `DELETE FROM afs.notification_channels WHERE id = $1`, channelB); sqlState(err) != "23503" {
			t.Errorf("want 23503, got %v", err)
		}
	})
}

// DB-US-35.
func TestSwarmTemplatesCatalog(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	const swt = "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TC0"
	insert := `INSERT INTO afs.swarm_templates (id, name, kind, spec, budget_usd, ttl_hours) VALUES ($1, $2, 'cve_remediation', '{"pools":[]}', 300, 72)`

	t.Run("service admins create templates", func(t *testing.T) {
		if _, err := asApp(t, conn, "SET LOCAL afs.service_admin = 'on'", insert, swt, "cve-fix"); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("a team caller cannot create, change or delete one", func(t *testing.T) {
		if _, err := asApp(t, conn, onlyTeamA, insert, "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TC1", "team-made"); sqlState(err) != "42501" {
			t.Errorf("insert: want 42501, got %v", err)
		}
		for _, sql := range []string{
			`UPDATE afs.swarm_templates SET budget_usd = 1 WHERE id = '` + swt + `'`,
			`DELETE FROM afs.swarm_templates WHERE id = '` + swt + `'`,
		} {
			if n, err := asApp(t, conn, onlyTeamA, sql); err != nil || n != 0 {
				t.Errorf("%s: %d rows, %v", sql, n, err)
			}
		}
	})
	t.Run("every signed-in caller reads every template", func(t *testing.T) {
		for name, settings := range map[string]string{
			"team caller":       appTeamA,
			"security operator": "SET LOCAL ROLE afs_app; SET LOCAL afs.security_operator = 'on'",
			"no team":           "SET LOCAL ROLE afs_app",
		} {
			if n := scalar[int](t, conn, settings, `SELECT count(*) FROM afs.swarm_templates`); n != 1 {
				t.Errorf("%s sees %d templates, want 1", name, n)
			}
		}
	})
	t.Run("disabling keeps the row and its revisions", func(t *testing.T) {
		if _, err := asApp(t, conn, "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.swarm_templates SET enabled = false WHERE id = $1`, swt); err != nil {
			t.Fatal(err)
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'swarm_templates' AND resource_id = $1`, swt); n < 2 {
			t.Errorf("revisions = %d, want >= 2", n)
		}
		if on := scalar[bool](t, conn, appTeamA, `SELECT enabled FROM afs.swarm_templates WHERE id = $1`, swt); on {
			t.Error("template still enabled")
		}
	})
	_ = ctx
}

// DB-US-4: the reconciler purges idempotency keys but cannot read stored responses.
func TestReconcilerCannotReadIdempotentResponses(t *testing.T) {
	conn := migrated(t)
	seedTeams(t, conn)
	if _, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.idempotency_keys (principal, key, team_id, operation, request_sha256, expires_at)
		VALUES ('usr_a', 'k1', $1, 'CreateAgent', sha256('b'), now() + interval '1 hour')`, teamA); err != nil {
		t.Fatal(err)
	}
	run := func(sql string) error {
		return pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(t.Context(), `SET LOCAL ROLE afs_reconciler`); err != nil {
				return err
			}
			_, err := tx.Exec(t.Context(), sql)
			return err
		})
	}
	if err := run(`SELECT response_body FROM afs.idempotency_keys`); sqlState(err) != "42501" {
		t.Errorf("response_body: want 42501, got %v", err)
	}
	if err := run(`SELECT operation, request_sha256 FROM afs.idempotency_keys`); sqlState(err) != "42501" {
		t.Errorf("request columns: want 42501, got %v", err)
	}
	if err := run(`SELECT principal, key, expires_at FROM afs.idempotency_keys`); err != nil {
		t.Errorf("principal, key, expires_at: %v", err)
	}
}

// Guards and constraints that were pending at 000014: DB-US-5, 13, 14, 15, 22, 26, 27, 28.
func TestPendingGuards(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	exec := func(sql string, args ...any) error { _, err := conn.Exec(ctx, sql, args...); return err }

	t.Run("a missing required tag is named in the error", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.service_tags (key, mode) VALUES ('cost-owner', 'required')`); err != nil {
			t.Fatal(err)
		}
		err := exec(`INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email) VALUES ('team_01JD3Z5Y8K2M4N6P8Q0R2S4TD0', 'untagged', 'U', 'CC1', 'u@example.com')`)
		if sqlState(err) != "23514" || !strings.Contains(err.Error(), "cost-owner") {
			t.Errorf("want 23514 naming cost-owner, got %v", err)
		}
		if err := exec(`DELETE FROM afs.service_tags WHERE key = 'cost-owner'`); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("teams due for teardown: expired, cap reached, and nothing else", func(t *testing.T) {
		due := func() map[string]string {
			rows, err := conn.Query(ctx, `SELECT team_id, coalesce(reason, '<null>') FROM afs.teams_due_for_teardown`)
			if err != nil {
				t.Fatal(err)
			}
			out := map[string]string{}
			for rows.Next() {
				var id, r string
				if err := rows.Scan(&id, &r); err != nil {
					t.Fatal(err)
				}
				out[id] = r
			}
			return out
		}
		// Swarm B is active, unexpired, its budget unspent and its work not complete: not due.
		if r, ok := due()[swarmB]; ok {
			t.Errorf("swarm B listed with reason %s before any rule fires", r)
		}
		if err := exec(`UPDATE afs.teams SET teardown_rule = 'at_cap_or_expiry' WHERE id = $1;`, swarmB); err != nil {
			t.Fatal(err)
		}
		if err := exec(`INSERT INTO afs.spend_counters (budget_id, period_start, limit_usd, spent_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TB1', '2026-11-01', 300, 300)`); err != nil {
			t.Fatal(err)
		}
		if r := due()[swarmB]; r != "cap_reached" {
			t.Errorf("spent the lifetime cap: reason %q, want cap_reached", r)
		}
		if err := exec(`UPDATE afs.teams SET expires_at = now() - interval '1 minute' WHERE id = $1`, swarmB); err != nil {
			t.Fatal(err)
		}
		if r := due()[swarmB]; r != "expired" {
			t.Errorf("past expiry: reason %q, want expired", r)
		}
		if _, ok := due()[teamB]; ok {
			t.Error("a persistent team is listed")
		}
	})

	t.Run("handoffs only join pools of the same team", func(t *testing.T) {
		const swarmC = "team_01JD3Z5Y8K2M4N6P8Q0R2S4TD1"
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `
				INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule)
				VALUES ('`+swarmC+`', 'swarm-c', 'Swarm C', 'ephemeral', 'CC4', 'c@example.com', 100, now() + interval '1 day', 'at_expiry');
				INSERT INTO afs.budgets (id, team_id, period, amount_usd) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TD2', '`+swarmC+`', 'lifetime', 50);
				INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+swarmC+`', 'claude-sonnet');
				INSERT INTO afs.agent_pools (id, team_id, name, template, image, model_id, workers)
				VALUES ('pool_01JD3Z5Y8K2M4N6P8Q0R2S4TD3', '`+swarmC+`', 'other', 'omp', 'ghcr.io/x/omp@sha256:abc', 'claude-sonnet', 1)`)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		for name, args := range map[string][]any{
			"from another team's pool": {swarmB, "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TD3", poolFixB},
			"to another team's pool":   {swarmB, poolScanB, "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TD3"},
		} {
			if err := exec(`INSERT INTO afs.pool_handoffs (team_id, from_pool_id, to_pool_id) VALUES ($1, $2, $3)`, args...); sqlState(err) != "23503" {
				t.Errorf("%s: want 23503, got %v", name, err)
			}
		}
	})

	t.Run("daily activity and traffic group by pool", func(t *testing.T) {
		day := "2026-11-20 10:00:00+00"
		for _, r := range [][]string{{poolScanB, "scanner-0"}, {poolScanB, "scanner-1"}, {poolFixB, "fixer-0"}} {
			if err := exec(`INSERT INTO afs.agent_activity (bucket_start, team_id, pool_id, worker_pod, state) VALUES ($1, $2, $3, $4, 'idle')`, day, swarmB, r[0], r[1]); err != nil {
				t.Fatal(err)
			}
			if err := exec(`INSERT INTO afs.external_traffic (bucket_start, team_id, pool_id, worker_pod, host, verdict, connections) VALUES ($1, $2, $3, $4, 'api.github.com', 'allowed', 2)`, day, swarmB, r[0], r[1]); err != nil {
				t.Fatal(err)
			}
		}
		if n := scalar[int](t, conn, "", `SELECT workers FROM afs.agent_activity_daily WHERE team_id = $1 AND pool_id = $2 AND day = '2026-11-20'`, swarmB, poolScanB); n != 2 {
			t.Errorf("scanner workers = %d, want 2", n)
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.agent_activity_daily WHERE team_id = $1 AND day = '2026-11-20'`, swarmB); n != 2 {
			t.Errorf("activity rows = %d, want one per pool (2)", n)
		}
		if n := scalar[int64](t, conn, "", `SELECT sum(connections) FROM afs.external_traffic_daily WHERE team_id = $1 AND pool_id = $2 AND day = '2026-11-20'`, swarmB, poolFixB); n != 2 {
			t.Errorf("fixer connections = %d, want 2", n)
		}
		if n := scalar[int](t, conn, "", `SELECT count(DISTINCT pool_id) FROM afs.external_traffic_daily WHERE team_id = $1 AND day = '2026-11-20'`, swarmB); n != 2 {
			t.Errorf("traffic pools = %d, want 2", n)
		}
	})

	t.Run("a merged repository needs a PR link", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.work_order_repos (work_order_id, repo, owning_team_id, status, merged_at) VALUES ($1, 'acme/search', $2, 'merged', now())`, workOrdB, teamB); sqlState(err) != "23514" {
			t.Errorf("merged without pr_url: want 23514, got %v", err)
		}
		if err := exec(`INSERT INTO afs.work_order_repos (work_order_id, repo, owning_team_id, status, merged_at, pr_url) VALUES ($1, 'acme/search', $2, 'merged', now(), 'https://github.com/acme/search/pull/1')`, workOrdB, teamB); err != nil {
			t.Errorf("merged with a link: %v", err)
		}
	})

	t.Run("the SLA warning window follows its setting", func(t *testing.T) {
		if err := exec(`UPDATE afs.work_orders SET sla_due_at = now() + interval '30 hours' WHERE id = $1`, workOrdB); err != nil {
			t.Fatal(err)
		}
		state := func() string {
			return scalar[string](t, conn, "", `SELECT sla_state FROM afs.work_order_progress WHERE work_order_id = $1`, workOrdB)
		}
		if s := state(); s != "due_soon" {
			t.Errorf("30 h before due with the default 48 h window: %s, want due_soon", s)
		}
		if err := exec(`UPDATE afs.service_settings SET value = '24' WHERE key = 'work_orders.sla_warning_hours'`); err != nil {
			t.Fatal(err)
		}
		if s := state(); s != "on_track" {
			t.Errorf("30 h before due with a 24 h window: %s, want on_track", s)
		}
	})

	t.Run("an unpinned image is refused", func(t *testing.T) {
		for _, img := range []string{"ghcr.io/x/omp:latest", "ghcr.io/x/omp"} {
			if err := exec(`INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES ('agt_01JD3Z5Y8K2M4N6P8Q0R2S4TD4', $1, 'loose', 'omp', $2, 'claude-sonnet')`, teamB, img); sqlState(err) != "23514" {
				t.Errorf("%s: want 23514, got %v", img, err)
			}
			if err := exec(`UPDATE afs.agents SET image = $1 WHERE id = $2`, img, agentB); sqlState(err) != "23514" {
				t.Errorf("update to %s: want 23514, got %v", img, err)
			}
		}
	})

	t.Run("billed cost beyond the variance setting is over threshold", func(t *testing.T) {
		recon := func(day string, gateway, billed float64, given string) string {
			t.Helper()
			var status string
			err := conn.QueryRow(ctx, `INSERT INTO afs.cost_reconciliations (team_id, day, gateway_usd, billed_usd, status)
				VALUES ($1, $2, $3, $4, $5)
				ON CONFLICT (team_id, day) DO UPDATE SET gateway_usd = EXCLUDED.gateway_usd, billed_usd = EXCLUDED.billed_usd, status = EXCLUDED.status
				RETURNING status`, teamB, day, gateway, billed, given).Scan(&status)
			if err != nil {
				t.Fatal(err)
			}
			return status
		}
		if s := recon("2026-11-01", 106, 100, "ok"); s != "over_threshold" {
			t.Errorf("6%% over with the default 5%%: %s, want over_threshold", s)
		}
		if s := recon("2026-11-02", 94, 100, "ok"); s != "over_threshold" {
			t.Errorf("6%% under: %s, want over_threshold", s)
		}
		if s := recon("2026-11-03", 104, 100, "over_threshold"); s != "ok" {
			t.Errorf("4%% over: %s, want ok", s)
		}
		if s := recon("2026-11-04", 5, 0, "ok"); s != "missing_billing" {
			t.Errorf("nothing billed: %s, want missing_billing", s)
		}
		if err := exec(`UPDATE afs.service_settings SET value = '10' WHERE key = 'billing.variance_alert_pct'`); err != nil {
			t.Fatal(err)
		}
		if s := recon("2026-11-01", 106, 100, "over_threshold"); s != "ok" {
			t.Errorf("6%% over with a 10%% setting: %s, want ok", s)
		}
	})

	t.Run("API keys expire within 90 days of their real creation", func(t *testing.T) {
		key := func(id, extra, expires string) error {
			_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at`+extra+`)
				VALUES ($1::text, '`+teamA+`', $1::text, 'team_viewer', 'afs_k_cd', sha256(convert_to($1::text, 'UTF8')), `+expires+`)`, id)
			return err
		}
		if err := key("key_01JD3Z5Y8K2M4N6P8Q0R2S4TD5", "", "now() + interval '91 days'"); sqlState(err) != "23514" {
			t.Errorf("91 days: want 23514, got %v", err)
		}
		if err := key("key_01JD3Z5Y8K2M4N6P8Q0R2S4TD6", ", created_at", "now() + interval '400 days', now() + interval '365 days'"); sqlState(err) != "23514" {
			t.Errorf("a back-dated creation time stretching expiry: want 23514, got %v", err)
		}
		if err := key("key_01JD3Z5Y8K2M4N6P8Q0R2S4TD7", "", "now() + interval '90 days'"); err != nil {
			t.Errorf("90 days: %v", err)
		}
		if n, err := asApp(t, conn, onlyTeamA, `UPDATE afs.api_keys SET created_at = now() + interval '1 year', expires_at = now() + interval '1 year 30 days' WHERE id = 'key_01JD3Z5Y8K2M4N6P8Q0R2S4TD7'`); sqlState(err) != "55000" {
			t.Errorf("moving creation forward to stretch expiry: want 55000, got %d rows, %v", n, err)
		}
	})

	t.Run("audit rows are permanent and can name a pool and worker pod", func(t *testing.T) {
		if err := exec(`INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, team_id, pool_id, worker_pod)
			VALUES ('agent', 'scanner-0', 'CallModel', 'allowed', $1, $2, 'scanner-0')`, swarmB, poolScanB); err != nil {
			t.Fatal(err)
		}
		if n := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.audit_log WHERE pool_id IS NOT NULL`); n != 0 {
			t.Errorf("team A sees %d pool audit rows of swarm B", n)
		}
		if pod := scalar[string](t, conn, "SET LOCAL ROLE afs_readonly", `SELECT worker_pod FROM afs.audit_log WHERE pool_id = $1`, poolScanB); pod != "scanner-0" {
			t.Errorf("worker pod %q", pod)
		}
		if err := exec(`TRUNCATE afs.audit_log`); err == nil {
			t.Error("TRUNCATE of audit_log succeeded")
		}
	})
}

// DB-US-19: every table with a revision trigger announces its changes, with ids only.
func TestEveryRevisionTableAnnouncesChanges(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	if _, err := conn.Exec(ctx, `
		INSERT INTO afs.service_tags (key, mode, value) VALUES ('environment', 'fixed', 'prod');
		INSERT INTO afs.swarm_templates (id, name, kind, spec, budget_usd, ttl_hours)
		  VALUES ('swt_01JD3Z5Y8K2M4N6P8Q0R2S4TE0', 'cve-fix', 'cve_remediation', '{"pools":[]}', 300, 72);
		INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest)
		  VALUES ('tpl_01JD3Z5Y8K2M4N6P8Q0R2S4TE1', 'omp-review', 'omp', ARRAY['sha256:'||repeat('a', 64)], 'sha256:'||repeat('a', 64));
		INSERT INTO afs.identity_providers (id, name, kind, issuer_url, client_id)
		  VALUES ('idp_01JD3Z5Y8K2M4N6P8Q0R2S4TE2', 'Okta', 'okta', 'https://idp.example.com', 'afs')`); err != nil {
		t.Fatal(err)
	}

	rows, err := conn.Query(ctx, `
		SELECT c.relname,
		       EXISTS (SELECT 1 FROM pg_trigger n JOIN pg_proc np ON np.oid = n.tgfoid
		                WHERE n.tgrelid = c.oid AND np.proname = 'notify_desired_state'
		                  AND n.tgtype & 1 = 1          -- FOR EACH ROW
		                  AND n.tgtype & 28 = 28)       -- INSERT, DELETE and UPDATE
		  FROM pg_trigger r JOIN pg_proc rp ON rp.oid = r.tgfoid JOIN pg_class c ON c.oid = r.tgrelid
		 WHERE rp.proname = 'record_revision' ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	type tbl struct {
		Name   string
		Notify bool
	}
	tables, err := pgx.CollectRows(rows, pgx.RowToStructByPos[tbl])
	if err != nil {
		t.Fatal(err)
	}
	if len(tables) < 25 {
		t.Fatalf("%d tables with a revision trigger, expected at least 25", len(tables))
	}
	if _, err := conn.Exec(ctx, `LISTEN afs_desired_state`); err != nil {
		t.Fatal(err)
	}
	for _, tb := range tables {
		t.Run(tb.Name, func(t *testing.T) {
			if !tb.Notify {
				t.Fatalf("%s has a revision trigger but no row-level notify trigger for insert, update and delete", tb.Name)
			}
			ident := "afs." + pgx.Identifier{tb.Name}.Sanitize()
			col := pgx.Identifier{scalar[string](t, conn, "", `SELECT attname FROM pg_attribute WHERE attrelid = $1::regclass AND attnum = 1`, ident)}.Sanitize()
			teamCol := "team_id"
			if tb.Name == "teams" {
				teamCol = "id"
			}
			// A no-op update of one row: the trigger fires on every updated row.
			var want string
			err := conn.QueryRow(ctx, `UPDATE `+ident+` x SET `+col+` = `+col+` WHERE ctid = (SELECT ctid FROM `+ident+` LIMIT 1)
				RETURNING $1::text || ':' || coalesce(to_jsonb(x)->>'`+teamCol+`', '') || ':' || coalesce(to_jsonb(x)->>'id', '')`, tb.Name).Scan(&want)
			if err != nil {
				t.Fatalf("update one row (extend the fixture if there is none): %v", err)
			}
			wctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			n, err := conn.WaitForNotification(wctx)
			if err != nil {
				t.Fatal(err)
			}
			if n.Payload != want {
				t.Errorf("payload %q, want %q", n.Payload, want)
			}
		})
	}
}

// DB-US-20: retention drops old activity and traffic partitions too, and keeps 13 whole months.
func TestRetentionDropsEveryFactTable(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	now := time.Now().UTC()
	thisMonth := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	kept := thisMonth.AddDate(0, -13, 0)
	dropped := thisMonth.AddDate(0, -14, 0)
	var names []string
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_reconciler`); err != nil {
			return err
		}
		for _, fn := range []string{"ensure_usage_partition", "ensure_activity_partition", "ensure_traffic_partition"} {
			for _, m := range []time.Time{dropped, kept, thisMonth} {
				if _, err := tx.Exec(ctx, `SELECT afs.`+fn+`($1)`, m.Format("2006-01-02")); err != nil {
					return fmt.Errorf("%s(%s): %w", fn, m.Format("2006-01"), err)
				}
			}
		}
		rows, err := tx.Query(ctx, `SELECT afs.drop_partitions_older_than(13)`)
		if err != nil {
			return err
		}
		names, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	suffix := dropped.Format("200601")
	want := map[string]bool{"usage_events_" + suffix: true, "agent_activity_" + suffix: true, "external_traffic_" + suffix: true}
	if len(names) != len(want) {
		t.Errorf("dropped %v, want %v", names, want)
	}
	for _, n := range names {
		if !want[n] {
			t.Errorf("dropped %s, which is within retention", n)
		}
	}
	for _, base := range []string{"usage_events", "agent_activity", "external_traffic"} {
		for _, m := range []time.Time{kept, thisMonth} {
			name := base + "_" + m.Format("200601")
			if n := scalar[int](t, conn, "", `SELECT count(*) FROM pg_class WHERE relname = $1`, name); n != 1 {
				t.Errorf("%s was dropped", name)
			}
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM pg_class WHERE relname = $1`, base+"_default"); n != 1 {
			t.Errorf("%s_default was dropped", base)
		}
	}
}

// DB-US-36: a deleted team stays a row, and its usage, cost, revisions and audit stay readable. A
// persistent team is marked deleted; an ephemeral team also records its teardown.
func TestDeletedTeamKeepsItsHistory(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	history := []string{"usage_events", "cost_daily", "config_revisions", "audit_log"}
	refs := func() map[string]int {
		out := map[string]int{}
		rows, err := conn.Query(ctx, `SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
			JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'team_id' AND NOT a.attisdropped
			WHERE n.nspname = 'afs' AND c.relkind IN ('r', 'p') AND NOT c.relispartition`)
		if err != nil {
			t.Fatal(err)
		}
		tables, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		for _, tb := range tables {
			out[tb] = scalar[int](t, conn, "", `SELECT count(*) FROM afs.`+pgx.Identifier{tb}.Sanitize()+` WHERE team_id = $1`, teamB)
		}
		return out
	}
	before := refs()
	for _, tb := range history {
		if before[tb] == 0 {
			t.Fatalf("fixture has no %s row for team B", tb)
		}
	}
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `SET LOCAL ROLE afs_reconciler;
			UPDATE afs.teams SET state = 'deleted', deleted_at = now() WHERE id = '`+teamB+`';
			UPDATE afs.teams SET state = 'deleted', deleted_at = now(), torn_down_at = now(), teardown_reason = 'manual' WHERE id = '`+swarmB+`'`)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{teamB, swarmB} {
		if st := scalar[string](t, conn, "", `SELECT state FROM afs.teams WHERE id = $1`, id); st != "deleted" {
			t.Fatalf("%s state %q", id, st)
		}
	}
	after := refs()
	for tb, n := range before {
		if after[tb] < n {
			t.Errorf("%s: team B rows %d -> %d", tb, n, after[tb])
		}
	}
	for _, reader := range []string{appAdmin, "SET LOCAL ROLE afs_readonly"} {
		for _, tb := range history {
			cols := "count(*)"
			if tb == "audit_log" {
				cols = "count(id)" // afs_readonly reads audit metadata columns only
			}
			if n := scalar[int](t, conn, reader, `SELECT `+cols+` FROM afs.`+tb+` WHERE team_id = $1`, teamB); n < before[tb] {
				t.Errorf("%q reads %d of %d %s rows of the deleted team", reader, n, before[tb], tb)
			}
		}
	}
}

// DB-US-3: concurrent reservations serialize on the counter row and never pass the limit.
func TestConcurrentReservationsNeverOverbook(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	const bud = "bud_01JD3Z5Y8K2M4N6P8Q0R2S4TE3"
	if _, err := conn.Exec(ctx, `INSERT INTO afs.budgets (id, team_id, period, amount_usd) VALUES ('`+bud+`', '`+teamA+`', 'monthly', 100);
		INSERT INTO afs.spend_counters (budget_id, period_start, limit_usd, spent_usd) VALUES ('`+bud+`', '2026-11-01', 100, 99.50)`); err != nil {
		t.Fatal(err)
	}
	const callers = 50
	conns := make([]*pgx.Conn, callers)
	for i := range conns {
		c, err := pgx.ConnectConfig(ctx, conn.Config().Copy())
		if err != nil {
			t.Fatal(err)
		}
		conns[i] = c
		defer func() { _ = c.Close(context.Background()) }()
	}
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		granted int
		errs    []error
		start   = make(chan struct{})
	)
	for _, c := range conns {
		wg.Add(1)
		go func(c *pgx.Conn) {
			defer wg.Done()
			<-start
			var ok bool
			err := pgx.BeginFunc(ctx, c, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_gateway`); err != nil {
					return err
				}
				return tx.QueryRow(ctx, `SELECT afs.reserve_spend($1, '2026-11-01', 0.10)`, bud).Scan(&ok)
			})
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errs = append(errs, err)
			} else if ok {
				granted++
			}
		}(c)
	}
	close(start)
	wg.Wait()
	if len(errs) > 0 {
		t.Fatalf("%d calls failed, first: %v", len(errs), errs[0])
	}
	if granted != 5 {
		t.Errorf("%d of %d reservations granted, want exactly 5", granted, callers)
	}
	if full := scalar[bool](t, conn, "", `SELECT spent_usd + reserved_usd = 100 FROM afs.spend_counters WHERE budget_id = $1`, bud); !full {
		t.Error("spent + reserved is not exactly the limit")
	}
}

// DB-US-7: every migration from 000003 states its lock impact in its header comment.
func TestMigrationsStateLockImpact(t *testing.T) {
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range migs {
		if m.Version < 3 {
			continue
		}
		var header []string
		for _, line := range strings.Split(m.Up, "\n") {
			if !strings.HasPrefix(line, "--") {
				break
			}
			header = append(header, line)
		}
		if !strings.Contains(strings.ToLower(strings.Join(header, "\n")), "lock impact") {
			t.Errorf("%06d_%s: header does not state its lock impact", m.Version, m.Name)
		}
	}
	if _, err := fs.Stat(migrations.FS, "000003_agent_singleton_secret_paths.up.sql"); err != nil {
		t.Fatal(err)
	}
}
