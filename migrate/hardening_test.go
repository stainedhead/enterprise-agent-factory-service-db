package migrate_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Tests for 000013: guardrails, service catalog and binding writes, budget exhaustion mode, the
// temporary ceiling override, spend periods and held reservations, the change feed and retention.
func TestHardeningSpendPeriodsAndChangeFeed(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)

	// run executes sql in a transaction after setup and returns the rows it changed.
	run := func(setup, sql string, args ...any) (int64, error) {
		var n int64
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if setup != "" {
				if _, err := tx.Exec(ctx, setup); err != nil {
					return err
				}
			}
			tag, err := tx.Exec(ctx, sql, args...)
			n = tag.RowsAffected()
			return err
		})
		return n, err
	}
	teamAdmin := `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC1'; SET LOCAL afs.team_ids = '` + teamA + `'`
	serviceAdmin := `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC9'; SET LOCAL afs.service_admin = 'on'`
	const budgetA = "bud_01JD3Z5Y8K2M4N6P8Q0R2S4TC2"
	if _, err := conn.Exec(ctx, `INSERT INTO afs.budgets (id, team_id, period, amount_usd) VALUES ($1, $2, 'monthly', 4000)`, budgetA, teamA); err != nil {
		t.Fatal(err)
	}

	t.Run("only service admins set the ceiling, quotas and override", func(t *testing.T) {
		for _, sql := range []string{
			`UPDATE afs.teams SET max_budget_usd = 9000 WHERE id = $1`,
			`UPDATE afs.teams SET quotas = '{"cpu": "999"}' WHERE id = $1`,
			`UPDATE afs.teams SET ceiling_override_usd = 9000, ceiling_override_expires_at = now() + interval '1 day' WHERE id = $1`,
		} {
			if _, err := run(teamAdmin, sql, teamA); sqlState(err) != "42501" {
				t.Errorf("%s by a team-admin: want 42501, got %v", sql, err)
			}
		}
		if _, err := run(serviceAdmin, `UPDATE afs.teams SET max_budget_usd = 6000 WHERE id = $1`, teamA); err != nil {
			t.Errorf("service admin raising the ceiling: %v", err)
		}
		if _, err := run(serviceAdmin, `UPDATE afs.teams SET max_budget_usd = 3000 WHERE id = $1`, teamA); sqlState(err) != "23514" {
			t.Errorf("ceiling below the current budget: want 23514, got %v", err)
		}
	})

	t.Run("a temporary override raises the ceiling until it expires", func(t *testing.T) {
		if _, err := run(serviceAdmin, `UPDATE afs.teams SET ceiling_override_usd = 100, ceiling_override_expires_at = now() + interval '1 day' WHERE id = $1`, teamA); sqlState(err) != "23514" {
			t.Errorf("override below the base ceiling: want 23514, got %v", err)
		}
		if _, err := run(serviceAdmin, `UPDATE afs.teams SET ceiling_override_usd = 8000 WHERE id = $1`, teamA); sqlState(err) != "23514" {
			t.Errorf("override without an expiry: want 23514, got %v", err)
		}
		if _, err := run(serviceAdmin, `UPDATE afs.teams SET ceiling_override_usd = 8000, ceiling_override_expires_at = now() + interval '1 day' WHERE id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		if _, err := run(teamAdmin, `UPDATE afs.budgets SET amount_usd = 7500 WHERE id = $1`, budgetA); err != nil {
			t.Errorf("budget under the override: %v", err)
		}
		if _, err := run(serviceAdmin, `UPDATE afs.teams SET ceiling_override_usd = NULL, ceiling_override_expires_at = NULL WHERE id = $1`, teamA); sqlState(err) != "23514" {
			t.Errorf("clearing the override while the budget needs it: want 23514, got %v", err)
		}
		// What the reconciler does at expiry: lower the budget, then clear the override.
		if _, err := run(`SET LOCAL ROLE afs_reconciler`, `UPDATE afs.budgets SET amount_usd = 6000 WHERE id = $1`, budgetA); err != nil {
			t.Fatal(err)
		}
		if _, err := run(`SET LOCAL ROLE afs_reconciler`, `UPDATE afs.teams SET ceiling_override_usd = NULL, ceiling_override_expires_at = NULL WHERE id = $1`, teamA); err != nil {
			t.Errorf("reconciler clearing the override: %v", err)
		}
	})

	t.Run("notify-only budgets are a service admin choice for persistent teams", func(t *testing.T) {
		if _, err := run(teamAdmin, `UPDATE afs.budgets SET on_exhaust = 'notify' WHERE id = $1`, budgetA); sqlState(err) != "42501" {
			t.Errorf("team-admin choosing notify: want 42501, got %v", err)
		}
		if _, err := run(serviceAdmin, `UPDATE afs.budgets SET on_exhaust = 'notify' WHERE id = $1`, budgetA); err != nil {
			t.Errorf("service admin choosing notify: %v", err)
		}
		const eph = "team_01JD3Z5Y8K2M4N6P8Q0R2S4TC3"
		_, err := run("", `INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule)
			VALUES ('`+eph+`', 'poc', 'POC', 'ephemeral', 'CC9', 'p@example.com', 100, now() + interval '3 days', 'at_expiry');
			INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TC4', '`+eph+`', 'lifetime', 50, 'notify')`)
		if sqlState(err) != "23514" {
			t.Errorf("notify-only on an ephemeral team: want 23514, got %v", err)
		}
	})

	t.Run("the service catalog, settings and enabled models are service admin writes", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'anthropic', 'Claude Sonnet')`); err != nil {
			t.Fatal(err)
		}
		denied := []string{
			`INSERT INTO afs.model_prices (model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok) VALUES ('claude-sonnet', now(), 0, 0)`,
			`INSERT INTO afs.models (id, provider, display_name) VALUES ('rogue', 'x', 'Rogue')`,
			`INSERT INTO afs.storage_classes (id, volume_type) VALUES ('fast', 'io2')`,
			`INSERT INTO afs.team_models (team_id, model_id) VALUES ('` + teamA + `', 'claude-sonnet')`,
		}
		for _, sql := range denied {
			if _, err := run(teamAdmin, sql); sqlState(err) != "42501" {
				t.Errorf("%s by a team caller: want 42501, got %v", sql, err)
			}
		}
		if n, err := run(teamAdmin, `UPDATE afs.service_settings SET value = '7' WHERE key = 'teams.ephemeral_max_days'`); err != nil || n != 0 {
			t.Errorf("team caller changed a setting: %d rows, %v", n, err)
		}
		if _, err := run(serviceAdmin, `INSERT INTO afs.team_models (team_id, model_id) VALUES ($1, 'claude-sonnet')`, teamA); err != nil {
			t.Errorf("service admin enabling a model: %v", err)
		}
		var n int
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, teamAdmin); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.models`).Scan(&n)
		}); err != nil || n != 1 {
			t.Errorf("team caller reads %d models, want 1 (%v)", n, err)
		}
	})

	t.Run("bindings: service roles by service admins, team roles in your own team", func(t *testing.T) {
		insert := `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ($1, $2, $3, 'group', 'g')`
		if _, err := run(teamAdmin, insert, "rb_01JD3Z5Y8K2M4N6P8Q0R2S4TC5", "service_admin", nil); sqlState(err) != "42501" {
			t.Errorf("team-admin granting service_admin: want 42501, got %v", err)
		}
		if _, err := run(teamAdmin, insert, "rb_01JD3Z5Y8K2M4N6P8Q0R2S4TC6", "team_admin", teamB); sqlState(err) != "42501" {
			t.Errorf("binding on another team: want 42501, got %v", err)
		}
		if _, err := run(teamAdmin, insert, "rb_01JD3Z5Y8K2M4N6P8Q0R2S4TC7", "team_viewer", teamA); err != nil {
			t.Errorf("binding on own team: %v", err)
		}
		if _, err := run(serviceAdmin, insert, "rb_01JD3Z5Y8K2M4N6P8Q0R2S4TC8", "security_operator", nil); err != nil {
			t.Errorf("service admin granting security_operator: %v", err)
		}
	})

	t.Run("a person changes only their own user row", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `INSERT INTO afs.users (id, oidc_issuer, oidc_subject, email, display_name)
			VALUES ('usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC1', 'https://idp.example.com', 's1', 'a@example.com', 'A'),
			       ('usr_01JD3Z5Y8K2M4N6P8Q0R2S4TCA', 'https://idp.example.com', 's2', 'b@example.com', 'B')`); err != nil {
			t.Fatal(err)
		}
		if n, err := run(teamAdmin, `UPDATE afs.users SET display_name = 'X' WHERE id = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TCA'`); err != nil || n != 0 {
			t.Errorf("changed someone else's row: %d, %v", n, err)
		}
		if n, err := run(teamAdmin, `UPDATE afs.users SET last_login_at = now() WHERE id = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC1'`); err != nil || n != 1 {
			t.Errorf("own row: %d, %v", n, err)
		}
	})

	t.Run("spend periods open on demand and stuck reservations are released", func(t *testing.T) {
		gateway := `SET LOCAL ROLE afs_gateway`
		period := time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)
		var limit float64
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, gateway); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT afs.ensure_spend_counter($1, $2)`, budgetA, period).Scan(&limit)
		}); err != nil || limit != 6000 {
			t.Fatalf("ensure_spend_counter = %v, %v; want 6000", limit, err)
		}
		var held, tooBig *string
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, gateway); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT afs.ensure_spend_counter($1, $2)`, budgetA, period).Scan(&limit); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT afs.reserve_spend_held($1, $2, 10, 'gw-0')::text`, budgetA, period).Scan(&held); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT afs.reserve_spend_held($1, $2, 99999, 'gw-0')::text`, budgetA, period).Scan(&tooBig)
		}); err != nil || held == nil || tooBig != nil {
			t.Fatalf("held=%v tooBig=%v err=%v", held, tooBig, err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.spend_reservations SET created_at = now() - interval '1 hour', expires_at = now() - interval '1 minute'`); err != nil {
			t.Fatal(err)
		}
		var released int
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_reconciler`); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT afs.release_expired_reservations()`).Scan(&released)
		}); err != nil || released != 1 {
			t.Fatalf("released %d, %v", released, err)
		}
		var reserved, spent float64
		if err := conn.QueryRow(ctx, `SELECT reserved_usd, spent_usd FROM afs.spend_counters WHERE budget_id = $1 AND period_start = $2`, budgetA, period).Scan(&reserved, &spent); err != nil || reserved != 0 || spent != 0 {
			t.Errorf("after release reserved=%v spent=%v (%v)", reserved, spent, err)
		}
		var settled bool
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, gateway); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT afs.settle_reservation($1::uuid, 2)`, *held).Scan(&settled)
		}); err != nil || settled {
			t.Errorf("settling a released reservation returned %v, %v; want false", settled, err)
		}
		if _, err := run(gateway, `SELECT afs.ensure_spend_counter('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TZZ', now())`); sqlState(err) != "23503" {
			t.Errorf("unknown budget: want 23503, got %v", err)
		}
	})

	t.Run("desired-state changes are announced", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `LISTEN afs_desired_state`); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.teams SET description = 'changed' WHERE id = $1`, teamB); err != nil {
			t.Fatal(err)
		}
		wctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		n, err := conn.WaitForNotification(wctx)
		if err != nil {
			t.Fatal(err)
		}
		if want := "teams:" + teamB + ":" + teamB; n.Payload != want {
			t.Errorf("payload %q, want %q", n.Payload, want)
		}
		if _, err := conn.Exec(ctx, `UNLISTEN afs_desired_state`); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("old monthly partitions are dropped by the reconciler", func(t *testing.T) {
		var names []string
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_reconciler`); err != nil {
				return err
			}
			for _, m := range []string{"2020-01-01", time.Now().UTC().Format("2006-01-02")} {
				if _, err := tx.Exec(ctx, `SELECT afs.ensure_usage_partition($1)`, m); err != nil {
					return err
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
		if strings.Join(names, ",") != "usage_events_202001" {
			t.Errorf("dropped %v, want only usage_events_202001", names)
		}
		if _, err := run(`SET LOCAL ROLE afs_reconciler`, `SELECT afs.drop_partitions_older_than(0)`); sqlState(err) != "22023" {
			t.Errorf("keeping zero months: want 22023, got %v", err)
		}
	})

	t.Run("runtime settings are checked", func(t *testing.T) {
		for key, bad := range map[string]string{
			"api.cors_origins":                `["http://console.example.com"]`,
			"gateway.reservation_ttl_seconds": `5`,
			"reports.idle_cpu_millicores":     `"fifty"`,
		} {
			if _, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = $2::jsonb WHERE key = $1`, key, bad); sqlState(err) != "23514" {
				t.Errorf("%s = %s: want 23514, got %v", key, bad, err)
			}
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '["https://console.example.com"]' WHERE key = 'api.cors_origins'`); err != nil {
			t.Errorf("valid origin list: %v", err)
		}
	})
}
