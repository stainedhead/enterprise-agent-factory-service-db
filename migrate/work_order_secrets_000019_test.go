package migrate_test

// Proofs for migration 000019: afs.record_work_order_secret (RC-12 known gap from -restapi M6) and the
// event envelope on afs.instantiate_work_order_team's outbox rows.

import (
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

const reconcilerSession = "SET LOCAL ROLE afs_reconciler; SET LOCAL afs.actor = 'system:afs-reconciler'"

func TestRecordWorkOrderSecret(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedWorkOrderTemplates(t, conn)

	instantiate := func(wo string) string {
		t.Helper()
		var team string
		err := in(t, conn, reconcilerSession, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT afs.instantiate_work_order_team($1)`, wo).Scan(&team)
		})
		if err != nil {
			t.Fatal(err)
		}
		return team
	}
	pool := func(team, name string) string {
		t.Helper()
		var id string
		if err := conn.QueryRow(ctx, `SELECT id FROM afs.agent_pools WHERE team_id = $1 AND name = $2`, team, name).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	count := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := conn.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return n
	}
	// arn builds the ARN Secrets Manager would assign for the managed path of a pool secret.
	arn := func(team, poolID, name string) string {
		t.Helper()
		var path string
		if err := conn.QueryRow(ctx, `SELECT afs.secret_path($1, NULL, $2, $3)`, team, poolID, name).Scan(&path); err != nil {
			t.Fatal(err)
		}
		return "arn:aws:secretsmanager:eu-west-1:000000000000:secret:" + path + "-AbC123"
	}
	record := func(wo, poolID, name, arn string) (string, error) {
		var id string
		err := in(t, conn, reconcilerSession, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT afs.record_work_order_secret($1, $2, $3, 'GitHub token', $4, 'env', 'GH_TOKEN')`,
				wo, poolID, name, arn).Scan(&id)
		})
		return id, err
	}

	team := instantiate(woCVE)
	fixer := pool(team, "fixer")
	otherTeam := instantiate(woRace)
	otherPool := pool(otherTeam, "fixer")
	ghARN := arn(team, fixer, "gh-token")

	var secret string
	t.Run("records the secret, binding, audit and outbox", func(t *testing.T) {
		var err error
		secret, err = record(woCVE, fixer, "gh-token", ghARN)
		if err != nil {
			t.Fatal(err)
		}
		var okID bool
		var origin, path, desc, arnGot, poolID string
		if err := conn.QueryRow(ctx, `SELECT afs.ulid_ok(id, 'sec'), origin, path, description, secrets_manager_arn, pool_id
			FROM afs.secrets WHERE id = $1 AND team_id = $2 AND name = 'gh-token'`, secret, team).
			Scan(&okID, &origin, &path, &desc, &arnGot, &poolID); err != nil {
			t.Fatal(err)
		}
		if !okID || origin != "managed" || desc != "GitHub token" || arnGot != ghARN || poolID != fixer ||
			!strings.HasSuffix(path, "/fixer/gh-token") {
			t.Errorf("secret row: %v %s %s %s %s %s", okID, origin, path, desc, arnGot, poolID)
		}
		if n := count(`SELECT count(*) FROM afs.pool_secret_bindings WHERE team_id = $1 AND pool_id = $2 AND secret_id = $3
			AND delivery = 'env' AND target = 'GH_TOKEN'`, team, fixer, secret); n != 1 {
			t.Errorf("bindings: %d", n)
		}
		if n := count(`SELECT count(*) FROM afs.audit_log WHERE action = 'RecordWorkOrderSecret' AND actor_type = 'system'
			AND actor_id = 'system:afs-reconciler' AND outcome = 'allowed' AND resource_kind = 'secrets' AND resource_id = $1
			AND team_id = $2 AND pool_id = $3 AND after ->> 'workOrderId' = $4 AND after ->> 'name' = 'gh-token'`,
			secret, team, fixer, woCVE); n != 1 {
			t.Errorf("audit rows: %d", n)
		}
		var env map[string]any
		if err := conn.QueryRow(ctx, `SELECT payload FROM afs.outbox_events WHERE event_type = 'secret.created'
			AND aggregate_kind = 'secrets' AND aggregate_id = $1 AND team_id = $2`, secret, team).Scan(&env); err != nil {
			t.Fatalf("outbox: %v", err)
		}
		data, _ := env["data"].(map[string]any)
		if env["teamId"] != team || env["poolId"] != fixer || env["actor"] != "system:afs-reconciler" ||
			data["secretId"] != secret || data["name"] != "gh-token" || data["scope"] != "pool" {
			t.Errorf("envelope %v", env)
		}
		assertEnvelope(t, env)
		for _, v := range []string{"value", "secret", "password"} {
			if n := count(`SELECT count(*) FROM afs.outbox_events WHERE aggregate_id = $1 AND payload::text ~* ('"' || $2 || '"\s*:')`, secret, v); n != 0 {
				t.Errorf("payload carries a %q key", v)
			}
		}
		if n := count(`SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'secrets' AND resource_id = $1`, secret); n == 0 {
			t.Error("no secrets revision")
		}
	})
	t.Run("is idempotent on team and name", func(t *testing.T) {
		secrets := count(`SELECT count(*) FROM afs.secrets`)
		events := count(`SELECT count(*) FROM afs.outbox_events WHERE event_type = 'secret.created'`)
		audits := count(`SELECT count(*) FROM afs.audit_log WHERE action = 'RecordWorkOrderSecret'`)
		again, err := record(woCVE, fixer, "gh-token", ghARN)
		if err != nil || again != secret {
			t.Fatalf("got %s, %v; want %s", again, err, secret)
		}
		if count(`SELECT count(*) FROM afs.secrets`) != secrets ||
			count(`SELECT count(*) FROM afs.outbox_events WHERE event_type = 'secret.created'`) != events ||
			count(`SELECT count(*) FROM afs.audit_log WHERE action = 'RecordWorkOrderSecret'`) != audits {
			t.Error("a repeat call wrote rows")
		}
	})
	t.Run("refused", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.work_orders SET status = 'done' WHERE id = $1`, woRace); err != nil {
			t.Fatal(err)
		}
		for name, c := range map[string]struct{ wo, pool, name, state string }{
			"unknown work order":      {"wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCZ", fixer, "x-one", "P0002"},
			"work order without team": {woBare, fixer, "x-two", "55000"},
			"cancelled work order":    {woDone, fixer, "x-three", "55000"},
			"closed work order":       {woRace, otherPool, "x-four", "55000"},
			"unknown pool":            {woCVE, "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TZZ", "x-five", "23503"},
			"another team's pool":     {woCVE, otherPool, "x-six", "23503"},
		} {
			t.Run(name, func(t *testing.T) {
				secrets := count(`SELECT count(*) FROM afs.secrets`)
				audits := count(`SELECT count(*) FROM afs.audit_log WHERE action = 'RecordWorkOrderSecret'`)
				events := count(`SELECT count(*) FROM afs.outbox_events WHERE event_type = 'secret.created'`)
				_, err := record(c.wo, c.pool, c.name, "arn:aws:secretsmanager:eu-west-1:000000000000:secret:x-AbC123")
				if sqlState(err) != c.state {
					t.Fatalf("got %v, want %s", err, c.state)
				}
				if count(`SELECT count(*) FROM afs.secrets`) != secrets ||
					count(`SELECT count(*) FROM afs.audit_log WHERE action = 'RecordWorkOrderSecret'`) != audits ||
					count(`SELECT count(*) FROM afs.outbox_events WHERE event_type = 'secret.created'`) != events {
					t.Error("a refused call left rows behind")
				}
			})
		}
	})
	t.Run("a deleted pool is refused", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.agent_pools SET state = 'deleting' WHERE id = $1`, pool(team, "scanner")); err != nil {
			t.Fatal(err)
		}
		_, err := record(woCVE, pool(team, "scanner"), "gh-token-2", arn(team, pool(team, "scanner"), "gh-token-2"))
		if sqlState(err) != "23503" {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("an ARN that does not match the managed path is refused", func(t *testing.T) {
		_, err := record(woCVE, fixer, "gh-other", "arn:aws:secretsmanager:eu-west-1:000000000000:secret:afs/elsewhere/x-AbC123")
		if sqlState(err) != "23514" {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("only the reconciler may call it", func(t *testing.T) {
		executableBy(t, conn, "afs.record_work_order_secret(text, text, text, text, text, text, text)", "afs_reconciler")
		err := in(t, conn, appAdmin, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.record_work_order_secret($1, $2, 'gh-app', '', $3, 'env', 'GH_APP')`,
				woCVE, fixer, arn(team, fixer, "gh-app"))
			return err
		})
		if sqlState(err) != "42501" {
			t.Fatalf("afs_app: %v", err)
		}
	})
	t.Run("another team cannot see the secret", func(t *testing.T) {
		var n int
		err := in(t, conn, "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_b'; SET LOCAL afs.team_ids = '"+teamB+"'", func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.secrets WHERE id = $1`, secret).Scan(&n)
		})
		if err != nil || n != 0 {
			t.Fatalf("visible to another team: %d, %v", n, err)
		}
	})
}

// assertEnvelope checks an outbox payload against API contract section 7: {id, occurredAt, teamId, actor, data}.
func assertEnvelope(t *testing.T, env map[string]any) {
	t.Helper()
	id, _ := env["id"].(string)
	if !strings.HasPrefix(id, "evt_") || len(id) != 4+26 {
		t.Errorf("envelope id %q", id)
	}
	at, _ := env["occurredAt"].(string)
	ts, err := time.Parse(time.RFC3339, at)
	if err != nil || !strings.HasSuffix(at, "Z") || time.Since(ts) > time.Hour {
		t.Errorf("envelope occurredAt %q: %v", at, err)
	}
	if s, _ := env["teamId"].(string); s == "" {
		t.Errorf("envelope teamId missing: %v", env)
	}
	if s, _ := env["actor"].(string); s == "" {
		t.Errorf("envelope actor missing: %v", env)
	}
	if _, ok := env["data"].(map[string]any); !ok {
		t.Errorf("envelope data missing: %v", env)
	}
}

func TestInstantiateWorkOrderTeamEventEnvelope(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedWorkOrderTemplates(t, conn)
	var team string
	err := in(t, conn, reconcilerSession, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT afs.instantiate_work_order_team($1)`, woCVE).Scan(&team)
	})
	if err != nil {
		t.Fatal(err)
	}
	rows, err := conn.Query(ctx, `SELECT event_type, aggregate_id, payload FROM afs.outbox_events WHERE team_id = $1 ORDER BY id`, team)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	seen := map[string]int{}
	ids := map[string]bool{}
	for rows.Next() {
		var typ, agg string
		var env map[string]any
		if err := rows.Scan(&typ, &agg, &env); err != nil {
			t.Fatal(err)
		}
		seen[typ]++
		assertEnvelope(t, env)
		if env["teamId"] != team || env["actor"] != "system:afs-reconciler" {
			t.Errorf("%s: teamId/actor %v/%v", typ, env["teamId"], env["actor"])
		}
		if id, _ := env["id"].(string); ids[id] {
			t.Errorf("%s: duplicate event id %s", typ, id)
		} else {
			ids[id] = true
		}
		data := env["data"].(map[string]any)
		switch typ {
		case "team.created":
			if data["teamId"] != team || data["kind"] != "ephemeral" || data["workOrderId"] != woCVE {
				t.Errorf("team.created data %v", data)
			}
		case "work_order.assigned":
			if data["workOrderId"] != woCVE || data["teamId"] != team {
				t.Errorf("work_order.assigned data %v", data)
			}
		case "pool.created":
			if env["poolId"] != agg || data["poolId"] != agg || data["teamId"] != team {
				t.Errorf("pool.created envelope %v", env)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if seen["team.created"] != 1 || seen["work_order.assigned"] != 1 || seen["pool.created"] != 2 {
		t.Errorf("events %v", seen)
	}
}
