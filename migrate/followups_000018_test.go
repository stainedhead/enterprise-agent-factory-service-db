package migrate_test

// Proofs for migration 000018: the follow-ups -restapi found while integrating (X-DB-8 to X-DB-10, the
// agent_secret_bindings revision and change feed, and the report schedule version bump).

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// X-DB-9: the agent activity report reads one agent over a range, any state.
func TestAgentActivityAgentTimeIndex(t *testing.T) {
	conn := migrated(t)
	var def string
	err := conn.QueryRow(t.Context(), `
		SELECT pg_get_indexdef(i.indexrelid)
		  FROM pg_index i
		 WHERE i.indrelid = 'afs.agent_activity'::regclass AND i.indpred IS NULL AND NOT i.indisunique
		   AND (SELECT array_agg(a.attname::text ORDER BY k.ord)
		          FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord)
		          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum)
		       = ARRAY['agent_id', 'bucket_start']`).Scan(&def)
	if err != nil {
		t.Fatalf("no full index on afs.agent_activity (agent_id, bucket_start): %v", err)
	}
	if strings.Contains(def, "DESC") || strings.Contains(def, "WHERE") {
		t.Errorf("index %q should be ascending and full", def)
	}
}

const (
	rollupTag = "SELECT afs.current_team_tag_set('" + teamA + "')"
)

// X-DB-8: daily rollups of agent activity and external traffic, filled by a function the reconciler calls.
func TestDailyRollups(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	// seedOtherTeams creates the model; team A's agents are added here (seedAgents would insert it twice).
	if _, err := conn.Exec(ctx, `INSERT INTO afs.team_models (team_id, model_id) VALUES ($1, 'claude-sonnet')`, teamA); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `
		INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES
		 ($2, $1, 'reviewer-bot', 'omp-review', 'ghcr.io/x/omp@sha256:`+strings.Repeat("a", 64)+`', 'claude-sonnet'),
		 ($3, $1, 'incident-scribe', 'hermes-ops', 'ghcr.io/x/hermes@sha256:`+strings.Repeat("d", 64)+`', 'claude-sonnet')`, teamA, agentA1, agentA2); err != nil {
		t.Fatal(err)
	}
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := conn.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	exec(`INSERT INTO afs.team_tags (team_id, key, value) VALUES ($1, 'env', 'prod')`, teamA)
	tagA := scalar[string](t, conn, "", rollupTag)
	exec(`INSERT INTO afs.agent_activity (bucket_start, team_id, agent_id, state, active_seconds, model_calls, input_tokens, output_tokens, cost_usd, tag_set_id) VALUES
		('2026-11-20 10:00:00+00', $1, $2, 'working', 200, 2, 2000, 500, 0.02, $4),
		('2026-11-20 10:05:00+00', $1, $2, 'idle', 0, 0, 0, 0, 0, $4),
		('2026-11-20 10:10:00+00', $1, $2, 'paused', 0, 0, 0, 0, 0, NULL),
		('2026-11-20 10:15:00+00', $1, $2, 'blocked_budget', 0, 0, 0, 0, 0, NULL),
		('2026-11-21 00:00:00+00', $1, $2, 'working', 300, 1, 1000, 100, 0.01, NULL),
		('2026-11-20 10:00:00+00', $1, $3, 'idle', 0, 0, 0, 0, 0, $4)`, teamA, agentA1, agentA2, tagA)
	exec(`INSERT INTO afs.external_traffic (bucket_start, team_id, agent_id, system_id, host, port, verdict, denied_reason, connections, requests, errors, bytes_out, bytes_in, tag_set_id) VALUES
		('2026-11-20 10:00:00+00', $1, $2, NULL, 'api.github.com', 443, 'allowed', NULL, 5, 10, 1, 100, 1000, $3),
		('2026-11-20 10:05:00+00', $1, $2, NULL, 'api.github.com', 443, 'allowed', NULL, 3, NULL, NULL, 50, 500, $3),
		('2026-11-20 10:05:00+00', $1, $2, NULL, 'evil.example.com', 443, 'denied', 'not_in_catalog', 2, NULL, NULL, 0, 0, $3),
		('2026-11-20 10:10:00+00', $1, $2, NULL, 'evil.example.com', 8443, 'denied', 'not_in_catalog', 1, NULL, NULL, 0, 0, $3),
		('2026-11-21 00:00:00+00', $1, $2, NULL, 'api.github.com', 443, 'allowed', NULL, 1, NULL, NULL, 10, 10, NULL)`, teamA, agentA1, tagA)

	asRecon := func(fn func(tx pgx.Tx) error) error {
		return in(t, conn, "SET LOCAL ROLE afs_reconciler; SET LOCAL afs.actor = 'system:afs-reconciler'", fn)
	}

	t.Run("only the reconciler runs the rollup", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_gateway", "afs_billing", "afs_readonly"} {
			err := in(t, conn, "SET LOCAL ROLE "+role, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `SELECT afs.rollup_reports_daily('2026-11-20', '2026-11-21')`)
				return err
			})
			if sqlState(err) != "42501" {
				t.Errorf("%s: want 42501, got %v", role, err)
			}
		}
		for _, bad := range []string{`SELECT afs.rollup_reports_daily('2026-11-21', '2026-11-20')`,
			`SELECT afs.rollup_reports_daily('2025-01-01', '2026-11-20')`} {
			err := asRecon(func(tx pgx.Tx) error { _, err := tx.Exec(ctx, bad); return err })
			if sqlState(err) != "22023" {
				t.Errorf("%s: want 22023, got %v", bad, err)
			}
		}
	})

	run := func() {
		t.Helper()
		err := asRecon(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.rollup_reports_daily('2026-11-20', '2026-11-21')`)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	run()

	// The rollup, read the way a report reads it, equals the five-minute tables' own daily views.
	const activityFromRollup = `
		SELECT team_id, agent_id, day, sum(working_seconds)::bigint AS working_seconds, sum(idle_seconds)::bigint AS idle_seconds,
		       sum(off_seconds)::bigint AS off_seconds, sum(impaired_seconds)::bigint AS impaired_seconds,
		       sum(active_seconds)::bigint AS active_seconds, sum(model_calls)::bigint AS model_calls,
		       sum(input_tokens)::bigint AS input_tokens, sum(output_tokens)::bigint AS output_tokens, sum(cost_usd)::text AS cost_usd
		  FROM afs.agent_activity_rollup_daily WHERE team_id = $1 GROUP BY 1, 2, 3 ORDER BY 1, 2, 3`
	const activityFromView = `
		SELECT team_id, agent_id, day, working_seconds::bigint AS working_seconds, idle_seconds::bigint AS idle_seconds, off_seconds::bigint AS off_seconds, impaired_seconds::bigint AS impaired_seconds, active_seconds::bigint AS active_seconds,
		       model_calls::bigint AS model_calls, input_tokens::bigint AS input_tokens, output_tokens::bigint AS output_tokens, cost_usd::text AS cost_usd
		  FROM afs.agent_activity_daily WHERE team_id = $1 ORDER BY 1, 2, 3`
	compare := func(t *testing.T, a, b string, wantRows int) {
		t.Helper()
		ra, err := conn.Query(ctx, a, teamA)
		if err != nil {
			t.Fatal(err)
		}
		rowsA, err := pgx.CollectRows(ra, pgx.RowToMap)
		if err != nil {
			t.Fatal(err)
		}
		rb, err := conn.Query(ctx, b, teamA)
		if err != nil {
			t.Fatal(err)
		}
		rowsB, err := pgx.CollectRows(rb, pgx.RowToMap)
		if err != nil {
			t.Fatal(err)
		}
		if len(rowsA) != wantRows || len(rowsB) != wantRows {
			t.Fatalf("rows: rollup %d, view %d, want %d", len(rowsA), len(rowsB), wantRows)
		}
		for i := range rowsA {
			va, vb := rowsA[i], rowsB[i]
			for k, v := range vb {
				if fmt.Sprint(va[k]) != fmt.Sprint(v) {
					t.Errorf("row %d %s: rollup %v, view %v", i, k, va[k], v)
				}
			}
		}
	}
	t.Run("activity rollup matches the daily view", func(t *testing.T) {
		compare(t, activityFromRollup, activityFromView, 3)
		type sums struct {
			Working, Idle, Off, Impaired, Active, Calls int64
			Cost                                        string
		}
		got, err := pgx.CollectOneRow(mustQuery(t, conn, `
			SELECT working_seconds, idle_seconds, off_seconds, impaired_seconds, active_seconds, model_calls, cost_usd::text
			  FROM afs.agent_activity_rollup_daily WHERE agent_id = $1 AND day = '2026-11-20' AND tag_set_id = $2`, agentA1, tagA),
			pgx.RowToStructByPos[sums])
		if err != nil {
			t.Fatal(err)
		}
		if got.Working != 300 || got.Idle != 300 || got.Active != 200 || got.Calls != 2 || got.Cost != "0.020000" {
			t.Errorf("tagged group: %+v", got)
		}
		// Samples written with no tag set stay in their own group, so a report can sum or split them.
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.agent_activity_rollup_daily WHERE agent_id = $1 AND day = '2026-11-20'`, agentA1); n != 2 {
			t.Errorf("groups for agent on 2026-11-20 = %d, want 2 (tagged and untagged)", n)
		}
	})
	t.Run("traffic rollup matches the daily view", func(t *testing.T) {
		const fromRollup = `
			SELECT team_id, agent_id, day, sum(connections)::bigint AS c, sum(requests)::bigint AS r, sum(errors)::bigint AS e,
			       sum(bytes_out)::bigint AS bo, sum(bytes_in)::bigint AS bi, sum(denied_connections)::bigint AS d
			  FROM afs.external_traffic_rollup_daily WHERE team_id = $1 GROUP BY 1, 2, 3 ORDER BY 1, 2, 3`
		const fromView = `
			SELECT team_id, agent_id, day, sum(connections)::bigint AS c, sum(requests)::bigint AS r, sum(errors)::bigint AS e,
			       sum(bytes_out)::bigint AS bo, sum(bytes_in)::bigint AS bi, sum(denied_connections)::bigint AS d
			  FROM afs.external_traffic_daily WHERE team_id = $1 GROUP BY 1, 2, 3 ORDER BY 1, 2, 3`
		ra, _ := pgx.CollectRows(mustQuery(t, conn, fromRollup, teamA), pgx.RowToMap)
		rb, _ := pgx.CollectRows(mustQuery(t, conn, fromView, teamA), pgx.RowToMap)
		if len(ra) != 2 || len(rb) != 2 {
			t.Fatalf("rows: rollup %d, view %d, want 2", len(ra), len(rb))
		}
		for i := range ra {
			for k, v := range rb[i] {
				if ra[i][k] != v {
					t.Errorf("day %v %s: rollup %v, view %v", rb[i]["day"], k, ra[i][k], v)
				}
			}
		}
		// Unmatched hosts keep their host; denied reasons are kept.
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.external_traffic_rollup_daily
			WHERE agent_id = $1 AND day = '2026-11-20' AND unmatched_host = 'evil.example.com' AND denied_reasons = ARRAY['not_in_catalog'] AND denied_connections = 3`, agentA1); n != 1 {
			t.Errorf("denied traffic to an unmatched host: %d rows, want 1", n)
		}
		// A request count stays NULL when no proxy saw the traffic (as in the view).
		if v := scalar[*int64](t, conn, "", `SELECT requests FROM afs.external_traffic_rollup_daily WHERE agent_id = $1 AND day = '2026-11-21'`, agentA1); v != nil {
			t.Errorf("requests with no proxy data = %d, want NULL", *v)
		}
	})
	t.Run("rerunning is idempotent and picks up late samples", func(t *testing.T) {
		run()
		compare(t, activityFromRollup, activityFromView, 3)
		exec(`INSERT INTO afs.agent_activity (bucket_start, team_id, agent_id, state, active_seconds, model_calls, tag_set_id)
			VALUES ('2026-11-20 10:20:00+00', $1, $2, 'working', 100, 1, $3)`, teamA, agentA1, tagA)
		run()
		if n := scalar[int64](t, conn, "", `SELECT working_seconds FROM afs.agent_activity_rollup_daily WHERE agent_id = $1 AND day = '2026-11-20' AND tag_set_id = $2`, agentA1, tagA); n != 600 {
			t.Errorf("working seconds after a late sample = %d, want 600", n)
		}
		// Days outside the run are untouched, and a run with no samples for a day leaves no row behind.
		exec(`DELETE FROM afs.agent_activity WHERE bucket_start = '2026-11-21 00:00:00+00'`)
		run()
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.agent_activity_rollup_daily WHERE day = '2026-11-21' AND team_id = $1`, teamA); n != 0 {
			t.Errorf("rows for a day whose samples are gone = %d, want 0", n)
		}
	})
	t.Run("the convenience form recomputes the most recent days", func(t *testing.T) {
		err := asRecon(func(tx pgx.Tx) error {
			var n int
			if err := tx.QueryRow(ctx, `SELECT afs.rollup_reports_recent(2)`).Scan(&n); err != nil {
				return err
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		// seedOtherTeams wrote team B samples for the current hour.
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.agent_activity_rollup_daily WHERE team_id = $1`, teamB); n < 1 {
			t.Errorf("team B rollup rows = %d, want at least 1", n)
		}
	})
	t.Run("reads follow row-level security; only the function writes", func(t *testing.T) {
		count := func(settings, table string) int {
			return scalar[int](t, conn, settings, `SELECT count(*) FROM afs.`+table)
		}
		for _, table := range []string{"agent_activity_rollup_daily", "external_traffic_rollup_daily"} {
			if n := count("SET LOCAL ROLE afs_readonly", table); n == 0 {
				t.Errorf("%s: readonly sees no rows", table)
			}
			if n := count(appTeamA, table); n == 0 {
				t.Errorf("%s: team A sees none of its rows", table)
			}
			var other int
			err := in(t, conn, appTeamA, func(tx pgx.Tx) error {
				return tx.QueryRow(ctx, `SELECT count(*) FROM afs.`+table+` WHERE team_id <> $1`, teamA).Scan(&other)
			})
			if err != nil || other != 0 {
				t.Errorf("%s: team A sees %d rows of other teams (%v)", table, other, err)
			}
			if n := count(appAdmin, table); n <= count(appTeamA, table) {
				t.Errorf("%s: a service admin should see more than team A", table)
			}
			for _, role := range []string{"afs_app", "afs_reconciler", "afs_billing", "afs_gateway"} {
				err := in(t, conn, "SET LOCAL ROLE "+role, func(tx pgx.Tx) error {
					_, err := tx.Exec(ctx, `DELETE FROM afs.`+table)
					return err
				})
				if sqlState(err) != "42501" {
					t.Errorf("%s: %s direct write: want 42501, got %v", table, role, err)
				}
			}
		}
	})
}

func mustQuery(t *testing.T, conn *pgx.Conn, sql string, args ...any) pgx.Rows {
	t.Helper()
	rows, err := conn.Query(t.Context(), sql, args...)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// Restore rebuilds bindings from revisions and the reconciler hears about binding changes.
func TestAgentSecretBindingsRevisionsAndChangeFeed(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedAgents(t, conn)
	const sec = "sec_01JD3Z5Y8K2M4N6P8Q0R2S4T71"
	if _, err := conn.Exec(ctx, `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin) VALUES
		($1, $2, 'log-token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-payments/_shared/log-token-AbCdEf', 'managed')`, sec, teamA); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `LISTEN afs_desired_state`); err != nil {
		t.Fatal(err)
	}
	if _, err := asApp(t, conn, appTeamA, `INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target) VALUES ($1, $2, $3, 'env', 'LOG_TOKEN')`, teamA, agentA1, sec); err != nil {
		t.Fatal(err)
	}
	if _, err := asApp(t, conn, appTeamA, `DELETE FROM afs.agent_secret_bindings WHERE agent_id = $1`, agentA1); err != nil {
		t.Fatal(err)
	}
	rid := teamA + "/" + agentA1 + "/LOG_TOKEN"
	rows, err := conn.Query(ctx, `SELECT operation, snapshot->>'secret_id', snapshot->>'target', changed_by, team_id
		FROM afs.config_revisions WHERE resource_kind = 'agent_secret_bindings' AND resource_id = $1 ORDER BY id`, rid)
	if err != nil {
		t.Fatal(err)
	}
	type rev struct{ Op, Secret, Target, By, Team string }
	revs, err := pgx.CollectRows(rows, pgx.RowToStructByPos[rev])
	if err != nil {
		t.Fatal(err)
	}
	if len(revs) != 2 || revs[0].Op != "INSERT" || revs[1].Op != "DELETE" {
		t.Fatalf("revisions %+v, want INSERT then DELETE keyed %s", revs, rid)
	}
	if revs[0].Secret != sec || revs[0].Target != "LOG_TOKEN" || revs[0].By != "usr_a" || revs[0].Team != teamA {
		t.Errorf("snapshot %+v", revs[0])
	}
	// Two changes, two notifications, ids only.
	for i := range 2 {
		n, err := conn.WaitForNotification(t.Context())
		if err != nil {
			t.Fatalf("notification %d: %v", i, err)
		}
		if n.Payload != "agent_secret_bindings:"+teamA+":" {
			t.Errorf("payload %q", n.Payload)
		}
	}
	// A secret in another namespace's key does not collide with a plain team key.
	if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'agent_secret_bindings' AND resource_id = $1`, teamA); n != 0 {
		t.Errorf("binding revisions keyed by the bare team id: %d", n)
	}
}

// X-DB-10: afs_billing reads the price list sync setting and the model of each team, nothing more.
func TestBillingReadsPriceSyncSettingAndTeamModels(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	asBilling := func(sql string) error {
		return in(t, conn, "SET LOCAL ROLE afs_billing", func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, sql)
			return err
		})
	}
	for _, ok := range []string{
		`SELECT value FROM afs.service_settings WHERE key = 'pricing.price_list_sync'`,
		`SELECT key, value FROM afs.service_settings`,
		`SELECT team_id, model_id FROM afs.team_models`,
		`SELECT team_id, model_id, inference_profile_arn FROM afs.team_models`,
	} {
		if err := asBilling(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, denied := range []string{
		`SELECT description FROM afs.service_settings`,
		`SELECT updated_by FROM afs.service_settings`,
		`UPDATE afs.service_settings SET value = 'false' WHERE key = 'pricing.price_list_sync'`,
		`SELECT version FROM afs.team_models`,
		`UPDATE afs.team_models SET inference_profile_arn = 'x'`,
	} {
		if err := asBilling(denied); sqlState(err) != "42501" {
			t.Errorf("%s: want 42501, got %v", denied, err)
		}
	}
	if n := scalar[int](t, conn, "SET LOCAL ROLE afs_billing", `SELECT count(*) FROM afs.team_models`); n < 2 {
		t.Errorf("billing sees %d team models, want every team's", n)
	}
}

// Runner-owned columns of a report schedule do not move the client's ETag.
func TestReportScheduleRunStateKeepsVersion(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	const id = "rsc_01JD3Z5Y8K2M4N6P8Q0R2S4TB9"
	version := func() int64 {
		return scalar[int64](t, conn, "", `SELECT version FROM afs.report_schedules WHERE id = $1`, id)
	}
	updatedAt := func() string {
		return scalar[string](t, conn, "", `SELECT updated_at::text FROM afs.report_schedules WHERE id = $1`, id)
	}
	asBilling := func(sql string) error {
		return in(t, conn, "SET LOCAL ROLE afs_billing", func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, sql, id)
			return err
		})
	}
	v0, u0 := version(), updatedAt()
	if err := asBilling(`UPDATE afs.report_schedules SET last_run_at = now(), last_status = 'sent', last_error = NULL,
		next_run_at = next_run_at + interval '7 days' WHERE id = $1`); err != nil {
		t.Fatal(err)
	}
	if v := version(); v != v0 || updatedAt() != u0 {
		t.Errorf("a scheduled run moved version %d -> %d or updated_at", v0, v)
	}
	if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.report_schedules WHERE id = $1 AND last_status = 'sent'`, id); n != 1 {
		t.Fatal("run state was not recorded")
	}
	// A person's edit bumps, and so does a change that mixes runner and other columns.
	if _, err := asApp(t, conn, appAdmin, `UPDATE afs.report_schedules SET name = 'renamed' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if v := version(); v != v0+1 {
		t.Errorf("rename: version %d, want %d", v, v0+1)
	}
	if _, err := conn.Exec(ctx, `UPDATE afs.report_schedules SET enabled = false, last_status = 'failed' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if v := version(); v != v0+2 {
		t.Errorf("mixed update: version %d, want %d", v, v0+2)
	}
	// An update that changes nothing still bumps, as before.
	if _, err := conn.Exec(ctx, `UPDATE afs.report_schedules SET name = name WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if v := version(); v != v0+3 {
		t.Errorf("no-op update: version %d, want %d", v, v0+3)
	}
	// The If-Match pattern still works against the unchanged version.
	n, err := asApp(t, conn, appAdmin, `UPDATE afs.report_schedules SET cadence = 'daily' WHERE id = $1 AND version = $2`, id, v0)
	if err != nil || n != 0 {
		t.Errorf("stale If-Match matched %d rows (%v)", n, err)
	}
}
