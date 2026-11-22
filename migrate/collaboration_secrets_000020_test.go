package migrate_test

// Migration 000020: cleanup, hostname hold, managed secrets, key functions, swarm collaboration.

import (
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5/pgconn"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// collabARN builds the ARN Secrets Manager would assign below a team's namespace path.
func collabARN(ns, agent, name string) string {
	return "arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/" + ns + "/" + agent + "/" + name + "-AbCdEf"
}

const nsA = "afs-t-payments"

// DB-US-50.
func TestCollaborationCleanup(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	withCollab(t, conn)
	wantOK(t, addAgent(t, conn, wrkA2, teamA, "indexer2", "worker", nil, "team_shared"))
	mustExec(t, conn, `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, true), ($1, $3, false)`, teamA, wrkA, wrkA2)
	hasRoute := func(team string) bool {
		return count(t, conn, `SELECT count(*) FROM afs.team_collaboration WHERE team_id = $1`, team) == 1
	}
	t.Run("worker state change ignored", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleting' WHERE id = $1`, wrkA)
		mustExec(t, conn, `UPDATE afs.agents SET state = 'enabled' WHERE id = $1`, wrkA)
		if !hasRoute(teamA) {
			t.Fatal("route row removed by a worker's state change")
		}
	})
	t.Run("paused and enabled keep it", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET state = 'paused' WHERE id = $1`, collA)
		mustExec(t, conn, `UPDATE afs.agents SET state = 'enabled' WHERE id = $1`, collA)
		if !hasRoute(teamA) {
			t.Fatal("pause removed the route row")
		}
	})
	t.Run("deleting removes the route row", func(t *testing.T) {
		if !hasRoute(teamB) {
			t.Fatal("fixture")
		}
		mustExec(t, conn, `LISTEN afs_desired_state`)
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agents SET state = 'deleting' WHERE id = $1`, collA))
		if hasRoute(teamA) {
			t.Fatal("route row survived")
		}
		if !hasRoute(teamB) {
			t.Fatal("another team's route row was removed")
		}
	})
	t.Run("every connected agent disconnects and rolls", func(t *testing.T) {
		var connect bool
		var st string
		var g int64
		wantOK(t, conn.QueryRow(ctx, `SELECT connect, link_state, generation FROM afs.agent_collaboration WHERE agent_id = $1`, wrkA).Scan(&connect, &st, &g))
		if connect || st != "disabled" || g != 2 {
			t.Fatalf("connect %v state %s generation %d", connect, st, g)
		}
	})
	t.Run("unconnected links untouched", func(t *testing.T) {
		var g, v int64
		wantOK(t, conn.QueryRow(ctx, `SELECT generation, version FROM afs.agent_collaboration WHERE agent_id = $1`, wrkA2).Scan(&g, &v))
		if g != 1 || v != 1 {
			t.Fatalf("generation %d version %d", g, v)
		}
	})
	t.Run("deleted after deleting is a no-op", func(t *testing.T) {
		before := count(t, conn, `SELECT count(*) FROM afs.config_revisions`)
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, collA))
		// only the agent's own revision is new
		if d := count(t, conn, `SELECT count(*) FROM afs.config_revisions`) - before; d != 1 {
			t.Fatalf("%d new revisions, want 1", d)
		}
	})
	t.Run("revisions and notifications written", func(t *testing.T) {
		if n := count(t, conn, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'team_collaboration' AND resource_id = $1 AND operation = 'DELETE'`, teamA); n != 1 {
			t.Errorf("%d DELETE revisions", n)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'agent_collaboration' AND operation = 'UPDATE' AND resource_id = $1`, teamA+"/"+wrkA); n < 1 {
			t.Errorf("%d UPDATE revisions", n)
		}
		seen := map[string]bool{}
		for range 12 {
			wctx, cancel := context_withTimeout(t)
			n, err := conn.WaitForNotification(wctx)
			cancel()
			if err != nil {
				break
			}
			seen[n.Payload] = true
		}
		for _, want := range []string{"team_collaboration:" + teamA + ":", "agent_collaboration:" + teamA + ":"} {
			if !seen[want] {
				t.Errorf("no notification %q in %v", want, seen)
			}
		}
	})
	t.Run("works for the reconciler and the API", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agents SET state = 'deleting' WHERE id = $1`, collB))
		if hasRoute(teamB) {
			t.Fatal("reconciler's delete left the route row")
		}
	})
}

// DB-US-53.
func TestHostnameHold(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	collabAgents(t, conn)
	del := func(team string) {
		t.Helper()
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.teams SET state = 'deleted', deleted_at = now() WHERE id = $1`, team))
	}
	slugTeam := func(id, slug string) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd) VALUES ($1, $2, 'New', 'CC1', 'n@example.com', 10)`, id, slug)
		return err
	}
	t.Run("hold created on delete of a team that had a collaboration agent", func(t *testing.T) {
		del(teamA)
		var team string
		var days float64
		wantOK(t, conn.QueryRow(ctx, `SELECT team_id, extract(epoch FROM held_until - now()) / 86400 FROM afs.collab_hostname_holds WHERE slug = 'payments'`).Scan(&team, &days))
		if team != teamA || days < 29.9 || days > 30.1 {
			t.Fatalf("hold %s %.2f days", team, days)
		}
	})
	t.Run("deleted collaboration agent does not lose the hold", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, collB))
		del(teamB)
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_hostname_holds WHERE slug = 'search'`); n != 1 {
			t.Fatalf("%d holds", n)
		}
	})
	t.Run("no hold for a team without one", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd) VALUES ($1, 'plain', 'Plain', 'CC1', 'p@example.com', 10)`, cid("team", 3))
		del(cid("team", 3))
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_hostname_holds WHERE slug = 'plain'`); n != 0 {
			t.Fatalf("%d holds", n)
		}
	})
	t.Run("reuse refused 23505 collab_hostname_held", func(t *testing.T) {
		err := slugTeam(cid("team", 4), "payments")
		wantState(t, err, "23505")
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.ConstraintName != "collab_hostname_held" {
			t.Errorf("constraint: %v", err)
		}
		if err := slugTeam(cid("team", 5), "fresh"); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("expired hold allows reuse", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.collab_hostname_holds SET held_until = now() - interval '1 day' WHERE slug = 'search'`)
		// the old team row still owns the slug (UNIQUE across deleted rows): the hold no longer says so itself
		err := slugTeam(cid("team", 6), "search")
		if err != nil && !strings.Contains(err.Error(), "teams_slug_key") {
			t.Fatalf("expired hold refused with %v", err)
		}
	})
	t.Run("hold extended not duplicated", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.collab_hostname_holds SET held_until = now() + interval '1 day' WHERE slug = 'payments'`)
		mustExec(t, conn, `UPDATE afs.teams SET state = 'active', deleted_at = NULL WHERE id = $1`, teamA)
		del(teamA)
		var n int
		var days float64
		wantOK(t, conn.QueryRow(ctx, `SELECT count(*), max(extract(epoch FROM held_until - now()) / 86400) FROM afs.collab_hostname_holds WHERE slug = 'payments'`).Scan(&n, &days))
		if n != 1 || days < 29.9 {
			t.Fatalf("%d rows, %.2f days", n, days)
		}
	})
	t.Run("reconciler purges expired holds", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `DELETE FROM afs.collab_hostname_holds WHERE held_until < now()`))
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_hostname_holds WHERE slug = 'search'`); n != 0 {
			t.Fatalf("expired hold survived")
		}
		for _, role := range []string{"afs_app", "afs_readonly"} {
			if _, err := queryAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `SELECT slug FROM afs.collab_hostname_holds`); err != nil {
				t.Errorf("%s cannot read: %v", role, err)
			}
		}
	})
	t.Run("direct inserts refused 42501", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_reconciler", "afs_readonly", "afs_edge"} {
			wantState(t, runAs(t, conn, role, "", `INSERT INTO afs.collab_hostname_holds (slug, team_id, held_until) VALUES ('x', 'y', now())`), "42501")
		}
		wantState(t, runAs(t, conn, "afs_app", "", `DELETE FROM afs.collab_hostname_holds`), "42501")
	})
}

func secretInsert(id, team, name, arn, origin, managedBy string, agent, pool any) (string, []any) {
	return `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, managed_by, agent_id, pool_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		[]any{id, team, name, arn, origin, managedBy, agent, pool}
}

func putSecret(t *testing.T, conn *pgx.Conn, role, extra, id, team, name, arn, origin, managedBy string, agent, pool any) error {
	t.Helper()
	sql, args := secretInsert(id, team, name, arn, origin, managedBy, agent, pool)
	if role == "" {
		_, err := conn.Exec(t.Context(), sql, args...)
		return err
	}
	return runAs(t, conn, role, extra, sql, args...)
}

// DB-US-49.
func TestManagedSecrets(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	withCollab(t, conn)
	n := 0
	sid := func() string { n++; return cid("sec", n) }
	pcARN := func(rest string) string { return collabARN(nsA, "paperclip", "paperclip/"+rest) }
	t.Run("managed_by default and immutability", func(t *testing.T) {
		id := sid()
		wantOK(t, putSecret(t, conn, "", "", id, teamA, "plain", collabARN(nsA, "_shared", "plain"), "managed", "user", nil, nil))
		if got := scalar[string](t, conn, "", `SELECT managed_by FROM afs.secrets WHERE id = $1`, id); got != "user" {
			t.Fatalf("managed_by %s", got)
		}
		mustExec(t, conn, `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin) VALUES ($1, $2, 'dflt', $3, 'managed')`, sid(), teamA, collabARN(nsA, "_shared", "dflt"))
		for _, to := range []string{"afs", "paperclip"} {
			_, err := conn.Exec(ctx, `UPDATE afs.secrets SET managed_by = $2 WHERE id = $1`, id, to)
			wantState(t, err, "55000")
		}
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.secrets SET managed_by = 'afs' WHERE id = $1`, id), "55000")
	})
	t.Run("reserved names matrix", func(t *testing.T) {
		boot := []string{"paperclip-better-auth-secret", "paperclip-tool-action-signing-secret", "paperclip-secrets-master-key", "paperclip-board-api-key"}
		for _, nm := range []string{"paperclip"} {
			for _, by := range []string{"user", "afs"} {
				wantState(t, putSecret(t, conn, "", "", sid(), teamA, nm, collabARN(nsA, "paperclip", nm), "managed", by, collA, nil), "23514")
			}
		}
		for _, nm := range boot {
			wantState(t, putSecret(t, conn, "", "", sid(), teamA, nm, collabARN(nsA, "paperclip", nm), "managed", "user", collA, nil), "23514")
			wantOK(t, putSecret(t, conn, "afs_app", adminA, sid(), teamA, nm, collabARN(nsA, "paperclip", nm), "managed", "afs", collA, nil))
		}
		// agent api key: user or afs, a worker only
		wantOK(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-agent-api-key", collabARN(nsA, "indexer", "paperclip-agent-api-key"), "managed", "user", wrkA, nil))
		wantOK(t, addAgent(t, conn, wrkA2, teamA, "indexer2", "worker", nil, "team_shared"))
		wantOK(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-agent-api-key", collabARN(nsA, "indexer2", "paperclip-agent-api-key"), "managed", "afs", wrkA2, nil))
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-agent-api-key", collabARN(nsA, "paperclip", "paperclip-agent-api-key"), "managed", "user", collA, nil), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-agent-api-key", collabARN(nsA, "_shared", "paperclip-agent-api-key"), "managed", "user", nil, nil), "23514")
		// any other paperclip-* belongs to paperclip only; every other name to the user
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-extra", collabARN(nsA, "paperclip", "paperclip-extra"), "managed", "user", collA, nil), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "ordinary", collabARN(nsA, "paperclip", "ordinary"), "managed", "afs", collA, nil), "23514")
		wantOK(t, putSecret(t, conn, "", "", sid(), teamA, "ordinary", collabARN(nsA, "paperclip", "ordinary"), "managed", "user", collA, nil))
	})
	t.Run("paperclip name needs a collaboration agent", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "afs_reconciler", "", sid(), teamA, "x", collabARN(nsA, "indexer", "paperclip/a"), "registered", "paperclip", wrkA, nil), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-better-auth-secret", collabARN(nsA, "indexer", "paperclip-better-auth-secret"), "managed", "afs", wrkA, nil), "23514")
	})
	t.Run("agent api key only on a worker", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "", "", sid(), teamB, "paperclip-agent-api-key", collabARN("afs-t-search", "paperclip", "paperclip-agent-api-key"), "managed", "afs", collB, nil), "23514")
	})
	t.Run("paperclip scope refused for shared and pool", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "afs_reconciler", "", sid(), teamA, "x", collabARN(nsA, "_shared", "paperclip/a"), "registered", "paperclip", nil, nil), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "x", collabARN(nsA, "_shared", "paperclip/a"), "registered", "paperclip", nil, cid("pool", 1)), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamA, "paperclip-better-auth-secret", collabARN(nsA, "_shared", "paperclip-better-auth-secret"), "managed", "afs", nil, nil), "23514")
	})
	var firstPC string
	t.Run("paperclip row path from arn", func(t *testing.T) {
		firstPC = sid()
		wantOK(t, putSecret(t, conn, "afs_reconciler", "", firstPC, teamA, "ignored", pcARN("company-1/openai"), "registered", "paperclip", collA, nil))
		var path, name, origin string
		wantOK(t, conn.QueryRow(ctx, `SELECT path, name, origin FROM afs.secrets WHERE id = $1`, firstPC).Scan(&path, &name, &origin))
		if path != "afs/"+nsA+"/paperclip/paperclip/company-1/openai" || name != "paperclip-company-1-openai" || origin != "registered" {
			t.Fatalf("path %s name %s origin %s", path, name, origin)
		}
	})
	t.Run("arn outside the prefix 23514", func(t *testing.T) {
		for _, a := range []string{collabARN(nsA, "paperclip", "elsewhere"), collabARN(nsA, "paperclip", "paperclip"), collabARN("afs-t-search", "paperclip", "paperclip/x"), collabARN(nsA, "indexer", "paperclip/x")} {
			wantState(t, putSecret(t, conn, "afs_reconciler", "", sid(), teamA, "x", a, "registered", "paperclip", collA, nil), "23514")
		}
	})
	t.Run("name sanitising, cut and collision suffix", func(t *testing.T) {
		id1, id2, id3 := sid(), sid(), sid()
		wantOK(t, putSecret(t, conn, "afs_reconciler", "", id1, teamA, "x", pcARN("Company_2/Key.v2"), "registered", "paperclip", collA, nil))
		if got := scalar[string](t, conn, "", `SELECT name FROM afs.secrets WHERE id = $1`, id1); got != "paperclip-company-2-key-v2" {
			t.Fatalf("name %q", got)
		}
		wantOK(t, putSecret(t, conn, "afs_reconciler", "", id2, teamA, "x", pcARN("company-2/key_v2"), "registered", "paperclip", collA, nil))
		got := scalar[string](t, conn, "", `SELECT name FROM afs.secrets WHERE id = $1`, id2)
		if !regexp.MustCompile(`^paperclip-company-2-key-v2-[0-9a-f]{4}$`).MatchString(got) {
			t.Fatalf("collision name %q", got)
		}
		wantOK(t, putSecret(t, conn, "afs_reconciler", "", id3, teamA, "x", pcARN(strings.Repeat("Long/", 30)), "registered", "paperclip", collA, nil))
		if l := len(scalar[string](t, conn, "", `SELECT name FROM afs.secrets WHERE id = $1`, id3)); l != 63 {
			t.Fatalf("cut name length %d", l)
		}
	})
	t.Run("app cannot write paperclip rows 42501", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "afs_app", adminA, sid(), teamA, "x", pcARN("app/x"), "registered", "paperclip", collA, nil), "42501")
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.secrets SET description = 'x' WHERE id = $1`, firstPC), "42501")
		wantState(t, runAs(t, conn, "afs_app", adminA, `DELETE FROM afs.secrets WHERE id = $1`, firstPC), "42501")
	})
	t.Run("reconciler writes paperclip rows only 42501", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "afs_reconciler", "", sid(), teamA, "paperclip-better-auth-secret", collabARN(nsA, "paperclip", "paperclip-better-auth-secret"), "managed", "afs", collA, nil), "42501")
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.secrets SET description = 'rotated' WHERE id = $1`, firstPC))
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.secrets SET secrets_manager_arn = $2 WHERE id = $1`, firstPC, strings.Replace(pcARN("company-1/openai"), "AbCdEf", "ZzZzZz", 1)))
	})
	t.Run("reconciler cannot write user rows", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "afs_reconciler", "", sid(), teamA, "mine", collabARN(nsA, "_shared", "mine"), "managed", "user", nil, nil), "42501")
		id := sid()
		wantOK(t, putSecret(t, conn, "", "", id, teamA, "mine2", collabARN(nsA, "_shared", "mine2"), "managed", "user", nil, nil))
		wantState(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.secrets SET description = 'x' WHERE id = $1`, id), "42501")
		wantState(t, runAs(t, conn, "afs_reconciler", "", `DELETE FROM afs.secrets WHERE id = $1`, id), "42501")
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `DELETE FROM afs.secrets WHERE id = $1`, firstPC))
	})
	t.Run("binding refused 23514", func(t *testing.T) {
		id := sid()
		wantOK(t, putSecret(t, conn, "afs_reconciler", "", id, teamA, "x", pcARN("bind/me"), "registered", "paperclip", collA, nil))
		_, err := conn.Exec(ctx, `INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target) VALUES ($1, $2, $3, 'env', 'PC_X')`, teamA, collA, id)
		wantState(t, err, "23514")
		if n := count(t, conn, `SELECT count(*) FROM afs.agent_secret_bindings s JOIN afs.secrets x ON x.id = s.secret_id WHERE x.name = 'paperclip-better-auth-secret' AND x.team_id = $1`, teamA); n != 0 {
			t.Fatalf("unexpected binding")
		}
		bid := scalar[string](t, conn, "", `SELECT id FROM afs.secrets WHERE team_id = $1 AND name = 'paperclip-better-auth-secret'`, teamA)
		mustExec(t, conn, `INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target) VALUES ($1, $2, $3, 'env', 'BETTER_AUTH_SECRET')`, teamA, collA, bid)
	})
	t.Run("boot secrets cannot be deleted 55000", func(t *testing.T) {
		bid := scalar[string](t, conn, "", `SELECT id FROM afs.secrets WHERE team_id = $1 AND name = 'paperclip-secrets-master-key'`, teamA)
		wantState(t, runAs(t, conn, "afs_app", adminA, `DELETE FROM afs.secrets WHERE id = $1`, bid), "55000")
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.secrets SET last_changed_at = now(), current_version_id = 'v2' WHERE id = $1`, bid))
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.secrets SET secrets_manager_arn = $2 WHERE id = $1`, bid, collabARN(nsA, "paperclip", "paperclip-secrets-master-key")[:len(collabARN(nsA, "paperclip", "paperclip-secrets-master-key"))-6]+"QqQqQq"), "55000")
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, collA)
		wantOK(t, runAs(t, conn, "afs_app", adminA, `DELETE FROM afs.secrets WHERE id = $1`, bid))
	})
	t.Run("origin and managed_by check", func(t *testing.T) {
		wantState(t, putSecret(t, conn, "", "", sid(), teamB, "reg", collabARN("afs-t-search", "_shared", "reg"), "registered", "user", nil, nil), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamB, "x", collabARN("afs-t-search", "paperclip", "paperclip/y"), "managed", "paperclip", collB, nil), "23514")
		wantState(t, putSecret(t, conn, "", "", sid(), teamB, "x", collabARN("afs-t-search", "_shared", "x"), "managed", "robot", nil, nil), "23514")
	})
	t.Run("isolation with another team's secrets", func(t *testing.T) {
		wantOK(t, putSecret(t, conn, "", "", sid(), teamB, "b-secret", collabARN("afs-t-search", "_shared", "b-secret"), "managed", "user", nil, nil))
		got, err := queryAs(t, conn, "afs_app", adminA, `SELECT name FROM afs.secrets WHERE team_id = $1`, teamB)
		wantOK(t, err)
		if len(got) != 0 {
			t.Fatalf("team A sees %v", got)
		}
		if err := putSecret(t, conn, "afs_app", adminA, sid(), teamB, "sneak", collabARN("afs-t-search", "_shared", "sneak"), "managed", "user", nil, nil); err == nil {
			t.Fatal("team A inserted a secret for team B")
		}
	})
}

// DB-US-56.
func TestCollabKeyFunctions(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	withCollab(t, conn)
	mustExec(t, conn, `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, true)`, teamA, wrkA)
	wantOK(t, addAgent(t, conn, wrkA2, teamA, "indexer2", "worker", nil, "team_shared"))
	keyARN := func(agent, name, suffix string) string {
		return strings.Replace(collabARN(nsA, agent, name), "AbCdEf", suffix, 1)
	}
	call := func(role, sql string, args ...any) (string, error) {
		var out string
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, "SET LOCAL ROLE "+role+"; SET LOCAL afs.actor = 'system:afs-reconciler'"); err != nil {
				return err
			}
			var v any
			if err := tx.QueryRow(ctx, sql, args...).Scan(&v); err != nil {
				return err
			}
			out = strings.TrimSpace(strings.ReplaceAll(toString(v), "\n", " "))
			return nil
		})
		return out, err
	}
	rec := `SELECT afs.record_collab_agent_key($1, $2, $3)`
	t.Run("manual registration 55000", func(t *testing.T) {
		_, err := call("afs_reconciler", rec, teamA, wrkA, keyARN("indexer", "paperclip-agent-api-key", "AbCdEf"))
		wantState(t, err, "55000")
		mustExec(t, conn, `UPDATE afs.team_collaboration SET registration_mode = 'managed' WHERE team_id = $1`, teamA)
	})
	var secret string
	t.Run("record creates secret and binding", func(t *testing.T) {
		var err error
		secret, err = call("afs_reconciler", rec, teamA, wrkA, keyARN("indexer", "paperclip-agent-api-key", "AbCdEf"))
		wantOK(t, err)
		var by, origin, target string
		wantOK(t, conn.QueryRow(ctx, `SELECT s.managed_by, s.origin, b.target FROM afs.secrets s JOIN afs.agent_secret_bindings b ON b.secret_id = s.id WHERE s.id = $1`, secret).Scan(&by, &origin, &target))
		if by != "afs" || origin != "managed" || target != "PAPERCLIP_AGENT_API_KEY" {
			t.Fatalf("%s %s %s", by, origin, target)
		}
	})
	t.Run("idempotent rotation reuses the row", func(t *testing.T) {
		again, err := call("afs_reconciler", rec, teamA, wrkA, keyARN("indexer", "paperclip-agent-api-key", "ZzZzZz"))
		wantOK(t, err)
		if again != secret {
			t.Fatalf("new row %s", again)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.agent_secret_bindings WHERE agent_id = $1`, wrkA); n != 1 {
			t.Fatalf("%d bindings", n)
		}
		if got := scalar[string](t, conn, "", `SELECT secrets_manager_arn FROM afs.secrets WHERE id = $1`, secret); !strings.HasSuffix(got, "ZzZzZz") {
			t.Fatalf("arn %s", got)
		}
	})
	t.Run("not connected 55000", func(t *testing.T) {
		_, err := call("afs_reconciler", rec, teamA, wrkA2, keyARN("indexer2", "paperclip-agent-api-key", "AbCdEf"))
		wantState(t, err, "55000")
	})
	t.Run("not a worker 55000", func(t *testing.T) {
		_, err := call("afs_reconciler", rec, teamA, collA, keyARN("paperclip", "paperclip-agent-api-key", "AbCdEf"))
		wantState(t, err, "55000")
	})
	t.Run("unknown agent P0002", func(t *testing.T) {
		_, err := call("afs_reconciler", rec, teamA, cid("agt", 99), keyARN("x", "paperclip-agent-api-key", "AbCdEf"))
		wantState(t, err, "P0002")
	})
	t.Run("arn path must match 23514", func(t *testing.T) {
		for _, a := range []string{keyARN("other", "paperclip-agent-api-key", "AbCdEf"), keyARN("indexer", "wrong-name", "AbCdEf"), "not-an-arn"} {
			_, err := call("afs_reconciler", rec, teamA, wrkA, a)
			wantState(t, err, "23514")
		}
	})
	t.Run("board key has no binding", func(t *testing.T) {
		id, err := call("afs_reconciler", `SELECT afs.record_collab_board_key($1, $2, $3)`, teamA, collA, keyARN("paperclip", "paperclip-board-api-key", "AbCdEf"))
		wantOK(t, err)
		if n := count(t, conn, `SELECT count(*) FROM afs.agent_secret_bindings WHERE secret_id = $1`, id); n != 0 {
			t.Fatal("board key is bound")
		}
		again, err := call("afs_reconciler", `SELECT afs.record_collab_board_key($1, $2, $3)`, teamA, collA, keyARN("paperclip", "paperclip-board-api-key", "QqQqQq"))
		wantOK(t, err)
		if again != id {
			t.Fatal("not idempotent")
		}
		if got := scalar[string](t, conn, "", `SELECT managed_by FROM afs.secrets WHERE id = $1`, id); got != "afs" {
			t.Fatal(got)
		}
	})
	t.Run("board key needs a live collaboration agent 55000", func(t *testing.T) {
		_, err := call("afs_reconciler", `SELECT afs.record_collab_board_key($1, $2, $3)`, teamA, wrkA, keyARN("indexer", "paperclip-board-api-key", "AbCdEf"))
		wantState(t, err, "55000")
		_, err = call("afs_reconciler", `SELECT afs.record_collab_board_key($1, $2, $3)`, teamA, cid("agt", 98), keyARN("x", "paperclip-board-api-key", "AbCdEf"))
		wantState(t, err, "P0002")
		_, err = call("afs_reconciler", `SELECT afs.record_collab_board_key($1, $2, $3)`, teamA, collA, "bad")
		wantState(t, err, "23514")
	})
	t.Run("remove returns true then false", func(t *testing.T) {
		got, err := call("afs_reconciler", `SELECT afs.remove_collab_agent_key($1, $2)`, teamA, wrkA)
		wantOK(t, err)
		if got != "true" {
			t.Fatal(got)
		}
		got, err = call("afs_reconciler", `SELECT afs.remove_collab_agent_key($1, $2)`, teamA, wrkA)
		wantOK(t, err)
		if got != "false" {
			t.Fatal(got)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.secrets WHERE name = 'paperclip-agent-api-key'`); n != 0 {
			t.Fatal("secret remains")
		}
	})
	t.Run("audit rows and no outbox rows", func(t *testing.T) {
		for _, a := range []string{"RecordCollabAgentKey", "RemoveCollabAgentKey", "RecordCollabBoardKey"} {
			var typ, actor string
			wantOK(t, conn.QueryRow(ctx, `SELECT actor_type, actor_id FROM afs.audit_log WHERE action = $1 LIMIT 1`, a).Scan(&typ, &actor))
			if typ != "system" || actor != "system:afs-reconciler" {
				t.Errorf("%s audited as %s %s", a, typ, actor)
			}
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.outbox_events`); n != 0 {
			t.Fatalf("%d outbox rows", n)
		}
	})
	t.Run("only the reconciler may call 42501", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_gateway", "afs_billing", "afs_readonly", "afs_edge"} {
			for _, q := range []string{rec, `SELECT afs.remove_collab_agent_key($1, $2)`} {
				args := []any{teamA, wrkA, keyARN("indexer", "paperclip-agent-api-key", "AbCdEf")}
				if strings.Contains(q, "remove") {
					args = args[:2]
				}
				_, err := call(role, q, args...)
				wantState(t, err, "42501")
			}
			_, err := call(role, `SELECT afs.record_collab_board_key($1, $2, $3)`, teamA, collA, keyARN("paperclip", "paperclip-board-api-key", "AbCdEf"))
			wantState(t, err, "42501")
		}
	})
	t.Run("afs_app still cannot insert afs rows for a paperclip name it may not own", func(t *testing.T) {
		// a worker's key row by the API is allowed (manual registration); a paperclip-managed row never is
		wantState(t, putSecret(t, conn, "afs_app", adminA, cid("sec", 70), teamA, "x", collabARN(nsA, "paperclip", "paperclip/z"), "registered", "paperclip", collA, nil), "42501")
	})
}

func toString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case bool:
		if x {
			return "true"
		}
		return "false"
	default:
		return strings.TrimSpace(fmtSprint(v))
	}
}

func fmtSprint(v any) string { return fmt.Sprint(v) }
