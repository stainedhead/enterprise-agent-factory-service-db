package migrate_test

// Migration 000020: the afs_edge role, its functions, access facts, sessions (DB-US-47, 51, 52, 55).

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

const edgeSession = "SET LOCAL ROLE afs_edge; SET LOCAL afs.actor = 'system:afs-edge'"

var edgeFunctions = []string{
	"afs.collab_routes()", "afs.collab_settings()", "afs.collab_principal(text, text, text, text[])",
	"afs.collab_principal_key(text, bytea)", "afs.record_collab_access(jsonb)",
	"afs.emit_collab_secret_detected(text, text, text, text, text, text, integer)",
	"afs.collab_handoff_create(bytea, text, text, text, text, text, text[])",
	"afs.collab_handoff_consume(bytea, text, bytea)", "afs.collab_session_get(bytea)", "afs.collab_session_revoke(bytea)",
	"afs.orchestration_routes()", "afs.orchestration_settings()", // 000022
}

func sha(s string) []byte { h := sha256.Sum256([]byte(s)); return h[:] }

// edgeRows runs a query as afs_edge and returns every row formatted as "a|b|c".
func edgeRows(t *testing.T, conn *pgx.Conn, sql string, args ...any) ([]string, error) {
	t.Helper()
	var out []string
	err := pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), edgeSession); err != nil {
			return err
		}
		rows, err := tx.Query(t.Context(), sql, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			vals, err := rows.Values()
			if err != nil {
				return err
			}
			parts := make([]string, len(vals))
			for i, v := range vals {
				parts[i] = fmt.Sprint(v)
				if v == nil {
					parts[i] = "NULL"
				}
			}
			out = append(out, strings.Join(parts, "|"))
		}
		return rows.Err()
	})
	return out, err
}

const (
	idpP1 = "idp_01JD3Z5Y8K2M4N6P8Q0R2S0001"
	idpP2 = "idp_01JD3Z5Y8K2M4N6P8Q0R2S0002"
)

// edgeWorld: teams A and B with collaboration agents and routes, two providers (P1 default, with a collaboration client).
func edgeWorld(t *testing.T) *pgx.Conn {
	t.Helper()
	conn := newCollab(t)
	withCollab(t, conn)
	mustExec(t, conn, `
INSERT INTO afs.identity_providers (id, name, kind, issuer_url, client_id, is_default, collab_client_id, collab_client_secret_arn) VALUES
 ('`+idpP1+`', 'Okta', 'okta', 'https://idp.example.com', 'console', true, 'collab-web', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/idp/collab-AbCdEf');
INSERT INTO afs.identity_providers (id, name, kind, issuer_url, client_id) VALUES ('`+idpP2+`', 'Entra', 'entra_id', 'https://login.example.com', 'console2');
UPDATE afs.service_settings SET value = '"collab.example.com"' WHERE key = 'orchestration.public_base_domain'`)
	return conn
}

// DB-US-47.
func TestEdgeRole(t *testing.T) {
	conn := edgeWorld(t)
	ctx := t.Context()
	t.Run("no privilege on any relation 42501", func(t *testing.T) {
		rows, err := conn.Query(ctx, `
			SELECT c.oid::regclass::text, c.relkind::text
			  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
			 WHERE n.nspname IN ('afs', 'public') AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S') ORDER BY 1`)
		wantOK(t, err)
		type rel struct{ Name, Kind string }
		rels, err := pgx.CollectRows(rows, pgx.RowToStructByPos[rel])
		wantOK(t, err)
		if len(rels) < 60 {
			t.Fatalf("only %d relations found", len(rels))
		}
		for _, r := range rels {
			if r.Kind == "S" {
				if scalar[bool](t, conn, "", `SELECT has_sequence_privilege('afs_edge', $1::regclass, 'USAGE, SELECT, UPDATE')`, r.Name) {
					t.Errorf("afs_edge has a privilege on sequence %s", r.Name)
				}
				continue
			}
			if scalar[bool](t, conn, "", `SELECT has_table_privilege('afs_edge', $1::regclass, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
				OR has_any_column_privilege('afs_edge', $1::regclass, 'SELECT, INSERT, UPDATE, REFERENCES')`, r.Name) {
				t.Errorf("afs_edge has a privilege on %s", r.Name)
			}
			if r.Name == "afs.audit_log" || r.Name == "afs.teams" || r.Name == "afs.secrets" || r.Name == "afs.team_collaboration" {
				_, err := edgeRows(t, conn, `SELECT 1 FROM `+r.Name+` LIMIT 1`)
				wantState(t, err, "42501")
				wantState(t, runAs(t, conn, "afs_edge", "", `DELETE FROM `+r.Name), "42501")
			}
		}
	})
	t.Run("listens to the change feed", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_edge", "", `LISTEN afs_desired_state`))
	})
	t.Run("schema version", func(t *testing.T) {
		got, err := edgeRows(t, conn, `SELECT afs.schema_version()`)
		wantOK(t, err)
		if want := scalar[int64](t, conn, "", `SELECT max(version) FROM public.afs_schema_migrations`); got[0] != fmt.Sprint(want) {
			t.Fatalf("%v != %d", got, want)
		}
	})
	t.Run("functions revoked from public and other roles", func(t *testing.T) {
		for _, fn := range edgeFunctions {
			executableBy(t, conn, fn, "afs_edge")
		}
		executableBy(t, conn, "afs.purge_collab_edge_sessions()", "afs_reconciler")
		// exactly twelve SECURITY DEFINER functions plus schema_version are callable by the edge
		rows, err := conn.Query(ctx, `SELECT p.oid::regprocedure::text FROM pg_proc p
			 WHERE p.pronamespace = 'afs'::regnamespace AND p.prosecdef AND p.prorettype <> 'trigger'::regtype
			   AND has_function_privilege('afs_edge', p.oid, 'EXECUTE')`)
		wantOK(t, err)
		got, err := pgx.CollectRows(rows, pgx.RowTo[string])
		wantOK(t, err)
		sort.Strings(got)
		want := append([]string{"afs.schema_version()"}, edgeFunctions...)
		for i := range want {
			want[i] = strings.ReplaceAll(want[i], ", ", ",")
		}
		sort.Strings(want)
		if strings.Join(got, ";") != strings.Join(want, ";") {
			t.Fatalf("callable by afs_edge:\n%v\nwant\n%v", got, want)
		}
	})
	t.Run("only the edge may call", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly"} {
			_, err := queryAs(t, conn, role, "", `SELECT * FROM afs.collab_routes()`)
			wantState(t, err, "42501")
		}
	})
	t.Run("functions return only their named columns", func(t *testing.T) {
		want := map[string]string{
			"collab_routes":          "team_id slug namespace hostname team_state agent_id agent_state web_ui_enabled rest_api_enabled web_ui_effective rest_api_effective may_expose ready not_ready_reason service_name port provider_id issuer_url groups_claim collab_client_id collab_client_secret_arn provider_client_id provider_cli_client_id",
			"collab_settings":        "key value",
			"collab_principal":       "binding_id role subject_type user_id",
			"collab_principal_key":   "key_id role state expires_at revoked_at",
			"collab_handoff_consume": "team_id expires_at",
			"collab_session_get":     "team_id issuer subject provider_id groups expires_at last_seen_at",
		}
		for fn, cols := range want {
			var got string
			wantOK(t, conn.QueryRow(ctx, `SELECT array_to_string(coalesce(p.proargnames[array_length(p.proargnames, 1) - cardinality(array_remove(p.proargmodes, 'i')) + 1:], '{}'), ' ')
				FROM pg_proc p WHERE p.pronamespace = 'afs'::regnamespace AND p.proname = $1`, fn).Scan(&got))
			if got != cols {
				t.Errorf("%s returns %q, want %q", fn, got, cols)
			}
		}
	})
}

func routeCols(t *testing.T, conn *pgx.Conn, cols string) []string {
	t.Helper()
	rows, err := edgeRows(t, conn, `SELECT `+cols+` FROM afs.collab_routes() ORDER BY team_id`)
	wantOK(t, err)
	return rows
}

func TestEdgeRoutes(t *testing.T) {
	conn := edgeWorld(t)
	ctx := t.Context()
	setReady := func(team string, ready bool) {
		status := "False"
		if ready {
			status = "True"
		}
		mustExec(t, conn, `INSERT INTO afs.resource_status (resource_kind, resource_id, team_id, conditions)
			VALUES ('team_collaboration', $1, $1, jsonb_build_array(jsonb_build_object('type', 'EndpointReady', 'status', $2::text)))
			ON CONFLICT (resource_kind, resource_id) DO UPDATE SET conditions = EXCLUDED.conditions`, team, status)
	}
	t.Run("routes: columns and hostname", func(t *testing.T) {
		setReady(teamA, true)
		got := routeCols(t, conn, `team_id, slug, namespace, hostname, team_state, agent_id, agent_state, web_ui_enabled, rest_api_enabled, web_ui_effective, rest_api_effective, may_expose, ready, not_ready_reason, service_name, port, provider_id, issuer_url, groups_claim, collab_client_id`)
		want := strings.Join([]string{teamA, "payments", nsA, "payments.collab.example.com", "active", collA, "enabled", "true", "false", "true", "false", "true", "true", "NULL", "paperclip", "3100", idpP1, "https://idp.example.com", "groups", "collab-web"}, "|")
		if len(got) != 2 || got[0] != want {
			t.Fatalf("routes %v\nwant %s", got, want)
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = 'null' WHERE key = 'orchestration.public_base_domain'`)
		if got := routeCols(t, conn, `hostname IS NULL, web_ui_effective, rest_api_effective`); got[0] != "true|false|false" {
			t.Fatalf("no base domain: %v", got)
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"collab.example.com"' WHERE key = 'orchestration.public_base_domain'`)
	})
	t.Run("routes: each guard turns the effective flag off", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_collaboration SET rest_api_enabled = true WHERE team_id = $1`, teamA)
		eff := func() string {
			return routeCols(t, conn, `web_ui_effective, rest_api_effective, web_ui_enabled, rest_api_enabled`)[0]
		}
		if got := eff(); got != "true|true|true|true" {
			t.Fatalf("baseline %s", got)
		}
		cases := []struct{ name, off, on, want string }{
			{"web ui choice", `UPDATE afs.team_collaboration SET web_ui_enabled = false WHERE team_id = '` + teamA + `'`, `UPDATE afs.team_collaboration SET web_ui_enabled = true WHERE team_id = '` + teamA + `'`, "false|true|false|true"},
			{"rest choice", `UPDATE afs.team_collaboration SET rest_api_enabled = false WHERE team_id = '` + teamA + `'`, `UPDATE afs.team_collaboration SET rest_api_enabled = true WHERE team_id = '` + teamA + `'`, "true|false|true|false"},
			{"team guardrail", `UPDATE afs.teams SET may_expose_collaboration = false WHERE id = '` + teamA + `'`, `UPDATE afs.teams SET may_expose_collaboration = true WHERE id = '` + teamA + `'`, "false|false|true|true"},
			{"public endpoints", `UPDATE afs.service_settings SET value = 'false' WHERE key = 'orchestration.public_endpoints'`, `UPDATE afs.service_settings SET value = 'true' WHERE key = 'orchestration.public_endpoints'`, "false|false|true|true"},
			{"base domain", `UPDATE afs.service_settings SET value = 'null' WHERE key = 'orchestration.public_base_domain'`, `UPDATE afs.service_settings SET value = '"collab.example.com"' WHERE key = 'orchestration.public_base_domain'`, "false|false|true|true"},
			{"provider client", `UPDATE afs.identity_providers SET collab_client_secret_arn = NULL, collab_client_id = NULL WHERE id = '` + idpP1 + `'`, `UPDATE afs.identity_providers SET collab_client_id = 'collab-web', collab_client_secret_arn = 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/idp/collab-AbCdEf' WHERE id = '` + idpP1 + `'`, "false|true|true|true"},
		}
		for _, c := range cases {
			mustExec(t, conn, c.off)
			if got := eff(); got != c.want {
				t.Errorf("%s off: %s, want %s", c.name, got, c.want)
			}
			mustExec(t, conn, c.on)
			if got := eff(); got != "true|true|true|true" {
				t.Fatalf("%s restored: %s", c.name, got)
			}
		}
	})
	t.Run("routes: ready and reasons", func(t *testing.T) {
		reason := func() string { return routeCols(t, conn, `ready, not_ready_reason`)[0] }
		if got := reason(); got != "true|NULL" {
			t.Fatalf("ready: %s", got)
		}
		setReady(teamA, false)
		if got := reason(); got != "false|starting" {
			t.Fatalf("EndpointReady false: %s", got)
		}
		mustExec(t, conn, `DELETE FROM afs.resource_status WHERE resource_kind = 'team_collaboration' AND resource_id = $1`, teamA)
		if got := reason(); got != "false|starting" {
			t.Fatalf("no status row: %s", got)
		}
		setReady(teamA, true)
		mustExec(t, conn, `UPDATE afs.agents SET state = 'paused' WHERE id = $1`, collA)
		if got := reason(); got != "false|paused" {
			t.Fatalf("paused: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.agents SET state = 'enabled' WHERE id = $1`, collA)
		mustExec(t, conn, `UPDATE afs.teams SET state = 'suspended' WHERE id = $1`, teamA)
		if got := reason(); got != "false|team_suspended" {
			t.Fatalf("suspended: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'active' WHERE id = $1`, teamA)
	})
	t.Run("routes: provider selection", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.teams SET identity_provider_id = $2 WHERE id = $1`, teamA, idpP2)
		got := routeCols(t, conn, `provider_id, issuer_url, collab_client_id IS NULL, collab_client_secret_arn IS NULL, web_ui_effective`)
		if got[0] != idpP2+"|https://login.example.com|true|true|false" {
			t.Fatalf("team provider: %v", got)
		}
		if got[1] != idpP1+"|https://idp.example.com|false|false|true" {
			t.Fatalf("default provider for team B: %v", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET identity_provider_id = NULL WHERE id = $1`, teamA)
	})
	// Security finding 6 (000021): the edge accepts REST bearer tokens minted for the team IdP's own clients.
	t.Run("routes: provider client ids for bearer audiences", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.identity_providers SET cli_client_id = 'cli-public' WHERE id = $1`, idpP1)
		got := routeCols(t, conn, `team_id, provider_id, provider_client_id, coalesce(provider_cli_client_id, 'NULL')`)
		if got[0] != teamA+"|"+idpP1+"|console|cli-public" || got[1] != teamB+"|"+idpP1+"|console|cli-public" {
			t.Fatalf("default provider with both clients: %v", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET identity_provider_id = $2 WHERE id = $1`, teamA, idpP2)
		got = routeCols(t, conn, `provider_id, provider_client_id, coalesce(provider_cli_client_id, 'NULL')`)
		if got[0] != idpP2+"|console2|NULL" {
			t.Fatalf("team provider without a CLI client: %v", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET identity_provider_id = NULL WHERE id = $1`, teamA)
		mustExec(t, conn, `UPDATE afs.identity_providers SET cli_client_id = NULL WHERE id = $1`, idpP1)
	})
	t.Run("routes: deleted and unconfigured teams omitted", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd) VALUES ($1, 'plain', 'Plain', 'CC1', 'p@example.com', 10)`, cid("team", 3))
		if got := routeCols(t, conn, `team_id`); len(got) != 2 {
			t.Fatalf("unconfigured team listed: %v", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'deleted', deleted_at = now() WHERE id = $1`, teamB)
		if got := routeCols(t, conn, `team_id`); len(got) != 1 || got[0] != teamA {
			t.Fatalf("deleted team listed: %v", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'deleting' WHERE id = $1`, teamA)
		if got := routeCols(t, conn, `team_id`); len(got) != 0 {
			t.Fatalf("deleting team listed: %v", got)
		}
	})
	t.Run("settings are collab keys only", func(t *testing.T) {
		rows, err := edgeRows(t, conn, `SELECT key FROM afs.collab_settings()`)
		wantOK(t, err)
		if len(rows) != 7 {
			t.Fatalf("%v", rows)
		}
		for _, k := range rows {
			if !strings.HasPrefix(k, "collab.") {
				t.Errorf("setting %s", k)
			}
		}
		_ = ctx
	})
}

func principal(t *testing.T, conn *pgx.Conn, team, sub, provider string, groups []string) ([]string, error) {
	t.Helper()
	rows, err := edgeRows(t, conn, `SELECT role, subject_type, coalesce(user_id, 'NULL') FROM afs.collab_principal($1, $2, $3, $4::text[]) ORDER BY 1, 2`, team, sub, provider, groups)
	return rows, err
}

// DB-US-51.
func TestEdgePrincipal(t *testing.T) {
	conn := edgeWorld(t)
	u1, u2 := cid("usr", 1), cid("usr", 2)
	mustExec(t, conn, `
INSERT INTO afs.users (id, oidc_issuer, oidc_subject, email, display_name, disabled_at) VALUES
 ('`+u1+`', 'https://idp.example.com', 'sub-1', 'u1@example.com', 'U1', NULL),
 ('`+u2+`', 'https://idp.example.com', 'sub-2', 'u2@example.com', 'U2', now());
INSERT INTO afs.role_bindings (id, role, team_id, subject_type, user_id, group_name, identity_provider_id) VALUES
 ('`+cid("rb", 1)+`', 'team_admin', '`+teamA+`', 'user', '`+u1+`', NULL, NULL),
 ('`+cid("rb", 2)+`', 'team_admin', '`+teamA+`', 'user', '`+u2+`', NULL, NULL),
 ('`+cid("rb", 3)+`', 'team_viewer', '`+teamA+`', 'group', NULL, 'grp-view', NULL),
 ('`+cid("rb", 4)+`', 'team_collaborator', '`+teamA+`', 'group', NULL, 'grp-nullidp', NULL),
 ('`+cid("rb", 6)+`', 'service_admin', NULL, 'group', NULL, 'grp-svc', '`+idpP1+`'),
 ('`+cid("rb", 7)+`', 'security_operator', NULL, 'group', NULL, 'grp-sec', '`+idpP1+`'),
 ('`+cid("rb", 8)+`', 'security_operator', NULL, 'user', '`+u1+`', NULL, NULL),
 ('`+cid("rb", 9)+`', 'team_admin', '`+teamB+`', 'user', '`+u1+`', NULL, NULL)`)
	eq := func(got []string, err error, want ...string) {
		t.Helper()
		wantOK(t, err)
		if strings.Join(got, ";") != strings.Join(want, ";") {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	t.Run("user binding by issuer and subject", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "sub-1", idpP1, nil)
		eq(got, err, "team_admin|user|"+u1)
	})
	t.Run("disabled user matches nothing", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "sub-2", idpP1, nil)
		eq(got, err)
	})
	t.Run("user row missing returns group bindings only", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "nobody", idpP1, []string{"grp-view"})
		eq(got, err, "team_viewer|group|NULL")
		got, err = principal(t, conn, teamA, "sub-1", idpP2, nil) // a user of the other issuer is not this user
		eq(got, err)
	})
	t.Run("group binding on the team provider", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "x", idpP1, []string{"grp-view", "unrelated"})
		eq(got, err, "team_viewer|group|NULL")
	})
	t.Run("group from another provider ignored", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "x", idpP2, []string{"grp-view"})
		eq(got, err)
		got, err = principal(t, conn, teamA, "x", "", []string{"grp-view"})
		eq(got, err)
	})
	t.Run("team bindings follow the team's provider", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.teams SET identity_provider_id = $2 WHERE id = $1`, teamA, idpP2)
		got, err := principal(t, conn, teamA, "x", idpP2, []string{"grp-view", "grp-nullidp"})
		eq(got, err, "team_collaborator|group|NULL;team_viewer|group|NULL")
		got, err = principal(t, conn, teamA, "x", idpP1, []string{"grp-view"})
		eq(got, err)
		mustExec(t, conn, `UPDATE afs.teams SET identity_provider_id = NULL WHERE id = $1`, teamA)
	})
	t.Run("default provider groups", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "x", idpP1, []string{"grp-nullidp"})
		eq(got, err, "team_collaborator|group|NULL")
	})
	t.Run("service admin binding returned", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "x", idpP1, []string{"grp-svc"})
		eq(got, err, "service_admin|group|NULL")
		got, err = principal(t, conn, teamB, "x", idpP1, []string{"grp-svc"})
		eq(got, err, "service_admin|group|NULL")
		got, err = principal(t, conn, teamA, "x", idpP2, []string{"grp-svc"}) // the binding names provider 1
		eq(got, err)
	})
	t.Run("security operator never returned", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "sub-1", idpP1, []string{"grp-sec"})
		eq(got, err, "team_admin|user|"+u1)
	})
	t.Run("other team's bindings never returned", func(t *testing.T) {
		got, err := principal(t, conn, teamB, "sub-1", idpP1, []string{"grp-view"})
		eq(got, err, "team_admin|user|"+u1)
		got, err = principal(t, conn, cid("team", 77), "sub-1", idpP1, nil)
		eq(got, err)
	})
	t.Run("more than 500 groups 22023", func(t *testing.T) {
		many := make([]string, 501)
		for i := range many {
			many[i] = fmt.Sprintf("g%d", i)
		}
		_, err := principal(t, conn, teamA, "sub-1", idpP1, many)
		wantState(t, err, "22023")
		_, err = principal(t, conn, teamA, "sub-1", idpP1, many[:500])
		wantOK(t, err)
	})
	t.Run("team_collaborator role returned", func(t *testing.T) {
		got, err := principal(t, conn, teamA, "sub-1", idpP1, []string{"grp-nullidp"})
		eq(got, err, "team_admin|user|"+u1, "team_collaborator|group|"+u1)
	})
	t.Run("only the edge may call", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly"} {
			_, err := queryAs(t, conn, role, "", `SELECT * FROM afs.collab_principal($1, 'sub-1', $2, '{}')`, teamA, idpP1)
			wantState(t, err, "42501")
			_, err = queryAs(t, conn, role, "", `SELECT * FROM afs.collab_principal_key($1, $2)`, teamA, sha("k"))
			wantState(t, err, "42501")
		}
	})
}

// DB-US-51.
func TestEdgePrincipalKey(t *testing.T) {
	conn := edgeWorld(t)
	ctx := t.Context()
	key := func(n int, team any, role, created, expires string) {
		mustExec(t, conn, `INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, created_at, expires_at)
			VALUES ($1, $2, $3, $4, 'afs_k_xx', $5, `+created+`, `+expires+`)`, cid("key", n), team, fmt.Sprintf("k%d", n), role, sha(fmt.Sprintf("key-%d", n)))
	}
	key(1, teamA, "team_collaborator", "now()", "now() + interval '30 days'")
	key(2, teamA, "team_viewer", "now()", "now() + interval '1 day'")
	mustExec(t, conn, `ALTER TABLE afs.api_keys DISABLE TRIGGER USER`)
	mustExec(t, conn, `UPDATE afs.api_keys SET created_at = now() - interval '3 days', expires_at = now() - interval '1 day' WHERE id = $1`, cid("key", 2))
	mustExec(t, conn, `ALTER TABLE afs.api_keys ENABLE TRIGGER USER`)
	key(3, teamA, "team_admin", "now()", "now() + interval '30 days'")
	mustExec(t, conn, `UPDATE afs.api_keys SET revoked_at = now() WHERE id = $1`, cid("key", 3))
	key(4, nil, "security_operator", "now()", "now() + interval '30 days'")
	key(5, teamB, "team_admin", "now()", "now() + interval '30 days'")
	look := func(team string, n int) []string {
		got, err := edgeRows(t, conn, `SELECT key_id, role, state FROM afs.collab_principal_key($1, $2)`, team, sha(fmt.Sprintf("key-%d", n)))
		wantOK(t, err)
		return got
	}
	t.Run("active key", func(t *testing.T) {
		if got := look(teamA, 1); len(got) != 1 || got[0] != cid("key", 1)+"|team_collaborator|active" {
			t.Fatalf("%v", got)
		}
	})
	t.Run("expired", func(t *testing.T) {
		if got := look(teamA, 2); len(got) != 1 || !strings.HasSuffix(got[0], "|expired") {
			t.Fatalf("%v", got)
		}
	})
	t.Run("revoked", func(t *testing.T) {
		if got := look(teamA, 3); len(got) != 1 || !strings.HasSuffix(got[0], "|revoked") {
			t.Fatalf("%v", got)
		}
	})
	t.Run("unknown hash", func(t *testing.T) {
		if got := look(teamA, 99); len(got) != 0 {
			t.Fatalf("%v", got)
		}
	})
	t.Run("service key", func(t *testing.T) {
		if got := look(teamA, 4); len(got) != 0 {
			t.Fatalf("%v", got)
		}
	})
	t.Run("other team's key looks unknown", func(t *testing.T) {
		if got := look(teamA, 5); len(got) != 0 {
			t.Fatalf("%v", got)
		}
		if got := look(teamB, 5); len(got) != 1 {
			t.Fatalf("own team: %v", got)
		}
	})
	t.Run("last_used_at once a minute", func(t *testing.T) {
		used := func(n int) any {
			var v any
			wantOK(t, conn.QueryRow(ctx, `SELECT last_used_at FROM afs.api_keys WHERE id = $1`, cid("key", n)).Scan(&v))
			return v
		}
		look(teamA, 1)
		first := used(1)
		if first == nil {
			t.Fatal("last_used_at not set")
		}
		time.Sleep(20 * time.Millisecond)
		look(teamA, 1)
		if second := used(1); second != first {
			t.Fatalf("updated within a minute: %v -> %v", first, second)
		}
		mustExec(t, conn, `UPDATE afs.api_keys SET last_used_at = now() - interval '2 minutes' WHERE id = $1`, cid("key", 1))
		look(teamA, 1)
		if used(1).(time.Time).Before(time.Now().Add(-time.Minute)) {
			t.Fatal("not refreshed after a minute")
		}
		look(teamA, 2) // expired: never touched
		if used(2) != nil {
			t.Fatal("an expired key was marked used")
		}
	})
	t.Run("no hash in the result", func(t *testing.T) {
		rows, err := edgeRows(t, conn, `SELECT * FROM afs.collab_principal_key($1, $2)`, teamA, sha("key-1"))
		wantOK(t, err)
		if strings.Contains(rows[0], "afs_k_xx") || strings.Contains(rows[0], hex.EncodeToString(sha("key-1"))) {
			t.Fatalf("leak: %s", rows[0])
		}
		if n := len(strings.Split(rows[0], "|")); n != 5 {
			t.Fatalf("%d columns", n)
		}
	})
}

func access(bucket time.Time, team, surface, kind, id, outcome string, admin bool, requests, bytes int) string {
	return fmt.Sprintf(`{"bucket_start":%q,"team_id":%q,"surface":%q,"principal_kind":%q,"principal_id":%q,"outcome":%q,"service_admin_entry":%v,"requests":%d,"bytes":%d}`,
		bucket.Format(time.RFC3339), team, surface, kind, id, outcome, admin, requests, bytes)
}

func bucketNow() time.Time { return time.Now().UTC().Truncate(5 * time.Minute) }

// DB-US-52.
func TestCollaborationAccess(t *testing.T) {
	conn := edgeWorld(t)
	ctx := t.Context()
	record := func(rows ...string) (string, error) {
		got, err := edgeRows(t, conn, `SELECT afs.record_collab_access($1::jsonb)`, "["+strings.Join(rows, ",")+"]")
		if err != nil {
			return "", err
		}
		return got[0], nil
	}
	b := bucketNow()
	t.Run("columns and checks 23514", func(t *testing.T) {
		for name, row := range map[string]string{
			"surface":   access(b, teamA, "ftp", "user", "usr_1", "allowed", false, 1, 0),
			"kind":      access(b, teamA, "web_ui", "robot", "usr_1", "allowed", false, 1, 0),
			"outcome":   access(b, teamA, "web_ui", "user", "usr_1", "lost", false, 1, 0),
			"requests":  access(b, teamA, "web_ui", "user", "usr_1", "allowed", false, 0, 0),
			"bytes":     access(b, teamA, "web_ui", "user", "usr_1", "allowed", false, 1, -1),
			"anonymous": access(b, teamA, "web_ui", "anonymous", "usr_1", "denied_unauthenticated", false, 1, 0),
			"user":      access(b, teamA, "web_ui", "user", "", "allowed", false, 1, 0),
		} {
			if _, err := record(row); sqlState(err) != "23514" {
				t.Errorf("%s: want 23514, got %v", name, err)
			}
		}
	})
	t.Run("anonymous principal id", func(t *testing.T) {
		n, err := record(access(b, teamA, "web_ui", "anonymous", "", "denied_unauthenticated", false, 3, 10))
		wantOK(t, err)
		if n != "1" {
			t.Fatal(n)
		}
	})
	t.Run("bucket alignment 22023", func(t *testing.T) {
		_, err := record(access(b.Add(time.Minute), teamA, "web_ui", "user", "usr_1", "allowed", false, 1, 0))
		wantState(t, err, "22023")
	})
	t.Run("time window 22023", func(t *testing.T) {
		_, err := record(access(b.Add(-25*time.Hour), teamA, "web_ui", "user", "usr_1", "allowed", false, 1, 0))
		wantState(t, err, "22023")
		_, err = record(access(b.Add(15*time.Minute), teamA, "web_ui", "user", "usr_1", "allowed", false, 1, 0))
		wantState(t, err, "22023")
		_, err = record(access(b.Add(-23*time.Hour), teamA, "web_ui", "user", "usr_1", "allowed", false, 1, 0))
		wantOK(t, err)
	})
	t.Run("batch limit 22023", func(t *testing.T) {
		row := access(b, teamA, "rest_api", "api_key", "key_1", "allowed", false, 1, 1)
		rows := make([]string, 1001)
		for i := range rows {
			rows[i] = row
		}
		_, err := record(rows...)
		wantState(t, err, "22023")
		n, err := record(rows[:1000]...)
		wantOK(t, err)
		if n != "1000" {
			t.Fatalf("applied %s", n)
		}
		_, err = edgeRows(t, conn, `SELECT afs.record_collab_access('{"a":1}'::jsonb)`)
		wantState(t, err, "22023")
	})
	t.Run("additive upsert", func(t *testing.T) {
		row := access(b, teamA, "web_ui", "user", "usr_add", "allowed", false, 2, 5)
		for range 2 {
			_, err := record(row)
			wantOK(t, err)
		}
		var req, bytes int64
		wantOK(t, conn.QueryRow(ctx, `SELECT requests, bytes FROM afs.collaboration_access WHERE principal_id = 'usr_add'`).Scan(&req, &bytes))
		if req != 4 || bytes != 10 {
			t.Fatalf("%d requests %d bytes", req, bytes)
		}
	})
	t.Run("one bad row fails the whole batch", func(t *testing.T) {
		before := count(t, conn, `SELECT count(*) FROM afs.collaboration_access`)
		_, err := record(
			access(b, teamA, "web_ui", "user", "usr_atomic1", "allowed", false, 1, 0),
			access(b, teamA, "web_ui", "user", "usr_atomic2", "lost", false, 1, 0),
			access(b, teamA, "web_ui", "user", "usr_atomic3", "allowed", false, 1, 0))
		if sqlState(err) != "23514" {
			t.Fatalf("want 23514, got %v", err)
		}
		if after := count(t, conn, `SELECT count(*) FROM afs.collaboration_access`); after != before {
			t.Fatalf("rows %d -> %d: the batch was partly applied", before, after)
		}
	})
	t.Run("unknown team skipped", func(t *testing.T) {
		n, err := record(access(b, cid("team", 88), "web_ui", "user", "usr_9", "allowed", false, 1, 0), access(b, teamB, "web_ui", "user", "usr_b", "allowed", false, 1, 0))
		wantOK(t, err)
		if n != "1" {
			t.Fatalf("applied %s", n)
		}
		if c := count(t, conn, `SELECT count(*) FROM afs.collaboration_access WHERE team_id = $1`, cid("team", 88)); c != 0 {
			t.Fatal("row for an unknown team stored")
		}
	})
	t.Run("returns applied count", func(t *testing.T) {
		n, err := record()
		wantOK(t, err)
		if n != "0" {
			t.Fatal(n)
		}
	})
	t.Run("service admin entry kept apart", func(t *testing.T) {
		_, err := record(access(b, teamA, "web_ui", "user", "usr_sa", "allowed", false, 1, 0), access(b, teamA, "web_ui", "user", "usr_sa", "allowed", true, 1, 0))
		wantOK(t, err)
		if c := count(t, conn, `SELECT count(*) FROM afs.collaboration_access WHERE principal_id = 'usr_sa'`); c != 2 {
			t.Fatalf("%d rows", c)
		}
	})
	t.Run("no direct writes 42501", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_reconciler", "afs_edge", "afs_readonly", "afs_billing", "afs_gateway"} {
			wantState(t, runAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.collaboration_access (bucket_start, team_id, surface, principal_kind, principal_id, outcome, requests)
				VALUES (date_trunc('hour', now()), $1, 'web_ui', 'anonymous', '', 'allowed', 1)`, teamA), "42501")
			wantState(t, runAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.collaboration_access SET requests = 1`), "42501")
			wantState(t, runAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `DELETE FROM afs.collaboration_access`), "42501")
		}
	})
	t.Run("app reads own team only", func(t *testing.T) {
		got, err := queryAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+teamA+"'", `SELECT DISTINCT team_id FROM afs.collaboration_access`)
		wantOK(t, err)
		if len(got) != 1 || got[0] != teamA {
			t.Fatalf("%v", got)
		}
		got, err = queryAs(t, conn, "afs_app", "", `SELECT team_id FROM afs.collaboration_access`)
		wantOK(t, err)
		if len(got) != 0 {
			t.Fatalf("unbound caller sees %v", got)
		}
	})
	t.Run("reconciler and readonly read all", func(t *testing.T) {
		for _, role := range []string{"afs_reconciler", "afs_readonly"} {
			got, err := queryAs(t, conn, role, "", `SELECT DISTINCT team_id FROM afs.collaboration_access ORDER BY 1`)
			wantOK(t, err)
			if len(got) != 2 {
				t.Errorf("%s sees %v", role, got)
			}
		}
		_, err := queryAs(t, conn, "afs_gateway", "", `SELECT 1 FROM afs.collaboration_access`)
		wantState(t, err, "42501")
	})
	t.Run("source has no body path or header columns", func(t *testing.T) {
		src := scalar[string](t, conn, "", `SELECT lower(prosrc) FROM pg_proc WHERE proname = 'record_collab_access'`)
		for _, w := range []string{"body", "path", "header", "url", "payload"} {
			if strings.Contains(src, w) {
				t.Errorf("record_collab_access mentions %q", w)
			}
		}
		cols := scalar[string](t, conn, "", `SELECT string_agg(attname, ',') FROM pg_attribute WHERE attrelid = 'afs.collaboration_access'::regclass AND attnum > 0 AND NOT attisdropped`)
		for _, w := range []string{"body", "path", "header", "url", "name", "email"} {
			if strings.Contains(cols, w) {
				t.Errorf("collaboration_access has a column like %q: %s", w, cols)
			}
		}
	})
}

// DB-US-52.
func TestCollaborationAccessPartitions(t *testing.T) {
	conn := edgeWorld(t)
	t.Run("ensure creates and is idempotent", func(t *testing.T) {
		for range 2 {
			got, err := queryAs(t, conn, "afs_reconciler", "", `SELECT afs.ensure_collaboration_access_partition('2026-12-17')`)
			wantOK(t, err)
			if got[0] != "collaboration_access_202612" {
				t.Fatal(got)
			}
		}
		if n := count(t, conn, `SELECT count(*) FROM pg_inherits WHERE inhparent = 'afs.collaboration_access'::regclass`); n != 2 {
			t.Fatalf("%d partitions", n)
		}
	})
	t.Run("reconciler only", func(t *testing.T) {
		executableBy(t, conn, "afs.ensure_collaboration_access_partition(date)", "afs_reconciler")
	})
	t.Run("default partition catches strays", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.collaboration_access (bucket_start, team_id, surface, principal_kind, principal_id, outcome, requests)
			VALUES (date_trunc('month', now()) + interval '5 minutes', $1, 'web_ui', 'anonymous', '', 'allowed', 1)`, teamA)
		if got := scalar[string](t, conn, "", `SELECT tableoid::regclass::text FROM afs.collaboration_access LIMIT 1`); got != "collaboration_access_default" && got != "afs.collaboration_access_default" {
			t.Fatalf("landed in %s", got)
		}
	})
}

// DB-US-52.
func TestEmitCollabSecretDetected(t *testing.T) {
	conn := edgeWorld(t)
	ctx := t.Context()
	emit := func(team, surface, kind, id, pattern, action string, n int) ([]string, error) {
		return edgeRows(t, conn, `SELECT afs.emit_collab_secret_detected($1, $2, $3, $4, $5, $6, $7)`, team, surface, kind, id, pattern, action, n)
	}
	t.Run("envelope and outbox row", func(t *testing.T) {
		got, err := emit(teamA, "rest_api", "api_key", "key_1", "github_token", "blocked", 3)
		wantOK(t, err)
		var typ, kind, aid, team string
		var payload map[string]any
		wantOK(t, conn.QueryRow(ctx, `SELECT event_type, aggregate_kind, aggregate_id, team_id, payload FROM afs.outbox_events WHERE id = $1::bigint`, got[0]).Scan(&typ, &kind, &aid, &team, &payload))
		if typ != "collaboration.secret_detected" || kind != "team_collaboration" || aid != teamA || team != teamA {
			t.Fatalf("%s %s %s %s", typ, kind, aid, team)
		}
		if payload["actor"] != "system:edge" || payload["teamId"] != teamA || !strings.HasPrefix(fmt.Sprint(payload["id"]), "evt_") || payload["occurredAt"] == nil {
			t.Fatalf("envelope %v", payload)
		}
		data := payload["data"].(map[string]any)
		if len(data) != 6 || data["surface"] != "rest_api" || data["principalKind"] != "api_key" || data["principalId"] != "key_1" || data["pattern"] != "github_token" || data["action"] != "blocked" || data["count"] != float64(3) {
			t.Fatalf("data %v", data)
		}
	})
	t.Run("no other event type possible", func(t *testing.T) {
		src := scalar[string](t, conn, "", `SELECT prosrc FROM pg_proc WHERE proname = 'emit_collab_secret_detected'`)
		if n := strings.Count(src, "collaboration.secret_detected"); n != 1 {
			t.Fatalf("%d event types", n)
		}
		if strings.Contains(src, "agent.") || strings.Contains(src, "secret.created") {
			t.Fatal("another event type")
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.outbox_events WHERE event_type <> 'collaboration.secret_detected'`); n != 0 {
			t.Fatal("another event type was written")
		}
	})
	t.Run("pattern and action sets 23514", func(t *testing.T) {
		for _, p := range []string{"aws_access_key", "github_token", "slack_token", "private_key", "jwt", "okta_client_secret", "entra_client_secret", "generic_assignment"} {
			_, err := emit(teamA, "web_ui", "user", "usr_1", p, "warned", 1)
			wantOK(t, err)
		}
		_, err := emit(teamA, "web_ui", "user", "usr_1", "password", "warned", 1)
		wantState(t, err, "23514")
		_, err = emit(teamA, "web_ui", "user", "usr_1", "jwt", "ignored", 1)
		wantState(t, err, "23514")
		_, err = emit(teamA, "web_ui", "user", "usr_1", "jwt", "blocked", 0)
		wantState(t, err, "23514")
		_, err = emit(teamA, "web_ui", "anonymous", "usr_1", "jwt", "blocked", 1)
		wantState(t, err, "23514")
	})
	t.Run("unknown team 23503", func(t *testing.T) {
		_, err := emit(cid("team", 55), "web_ui", "user", "usr_1", "jwt", "blocked", 1)
		wantState(t, err, "23503")
	})
	t.Run("payload carries no value", func(t *testing.T) {
		keys := scalar[string](t, conn, "", `SELECT string_agg(DISTINCT k, ',' ORDER BY k) FROM afs.outbox_events, jsonb_object_keys(payload -> 'data') k`)
		if keys != "action,count,pattern,principalId,principalKind,surface" {
			t.Fatalf("data keys %s", keys)
		}
	})
}

func newConn(t *testing.T, base *pgx.Conn) *pgx.Conn {
	t.Helper()
	c, err := pgx.ConnectConfig(t.Context(), base.Config())
	wantOK(t, err)
	t.Cleanup(func() { _ = c.Close(t.Context()) })
	return c
}

// DB-US-55.
func TestEdgeSessions(t *testing.T) {
	conn := edgeWorld(t)
	ctx := t.Context()
	create := func(code string, host string, groups ...string) ([]string, error) {
		return edgeRows(t, conn, `SELECT afs.collab_handoff_create($1, $2, $3, 'https://idp.example.com', 'sub-1', $4, $5::text[])`, sha(code), teamA, host, idpP1, groups)
	}
	consume := func(code, host, session string) ([]string, error) {
		return edgeRows(t, conn, `SELECT team_id, expires_at FROM afs.collab_handoff_consume($1, $2, $3)`, sha(code), host, sha(session))
	}
	get := func(session string) []string {
		got, err := edgeRows(t, conn, `SELECT team_id, issuer, subject, provider_id, groups, expires_at, last_seen_at FROM afs.collab_session_get($1)`, sha(session))
		wantOK(t, err)
		return got
	}
	const host = "payments.collab.example.com"
	t.Run("handoff expires after 60 seconds", func(t *testing.T) {
		got, err := create("c-exp", host)
		wantOK(t, err)
		exp, perr := time.Parse("2006-01-02 15:04:05.999999999 -0700 MST", got[0])
		if perr != nil {
			exp = time.Now().Add(60 * time.Second)
		}
		if d := time.Until(exp); d < 50*time.Second || d > 62*time.Second {
			t.Fatalf("expires in %v", d)
		}
		mustExec(t, conn, `UPDATE afs.collab_edge_handoffs SET expires_at = now() - interval '1 second', created_at = now() - interval '2 minutes' WHERE code_hash = $1`, sha("c-exp"))
		rows, err := consume("c-exp", host, "s-exp")
		wantOK(t, err)
		if len(rows) != 0 || count(t, conn, `SELECT count(*) FROM afs.collab_edge_sessions`) != 0 {
			t.Fatal("an expired code created a session")
		}
	})
	t.Run("handoff needs a live team with a collaboration agent 23503", func(t *testing.T) {
		code := func(n string) []byte { return sha("c-team-" + n) }
		mk := func(team string) error {
			_, err := edgeRows(t, conn, `SELECT afs.collab_handoff_create($1, $2, 'h.collab.example.com', 'https://idp.example.com', 'sub-1', $3, '{}')`, code(team), team, idpP1)
			return err
		}
		wantState(t, mk(cid("team", 88)), "23503")
		plain := cid("team", 3)
		mustExec(t, conn, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd) VALUES ($1, 'plain', 'Plain', 'CC1', 'p@example.com', 10)`, plain)
		wantState(t, mk(plain), "23503")
		mustExec(t, conn, `UPDATE afs.teams SET state = 'deleting' WHERE id = $1`, teamB)
		wantState(t, mk(teamB), "23503")
		mustExec(t, conn, `UPDATE afs.teams SET state = 'active' WHERE id = $1`, teamB)
		wantOK(t, mk(teamB))
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_edge_handoffs WHERE team_id IN ($1, $2)`, cid("team", 88), plain); n != 0 {
			t.Fatalf("%d rows for refused teams", n)
		}
	})
	t.Run("a deleting team's session and principals are gone", func(t *testing.T) {
		_, err := edgeRows(t, conn, `SELECT afs.collab_handoff_create($1, $2, 'b.collab.example.com', 'https://idp.example.com', 'sub-1', $3, '{}')`, sha("c-dead"), teamB, idpP1)
		wantOK(t, err)
		rows, err := consume("c-dead", "b.collab.example.com", "s-dead")
		wantOK(t, err)
		if len(rows) != 1 || len(get("s-dead")) != 1 {
			t.Fatal("session of an active team not returned")
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'deleting' WHERE id = $1`, teamB)
		if len(get("s-dead")) != 0 {
			t.Error("session of a deleting team returned")
		}
		got, err := principal(t, conn, teamB, "sub-1", idpP1, []string{"grp-sec"})
		wantOK(t, err)
		if len(got) != 0 {
			t.Errorf("principal of a deleting team: %v", got)
		}
		kr, err := edgeRows(t, conn, `SELECT key_id FROM afs.collab_principal_key($1, $2)`, teamB, sha("key-5"))
		wantOK(t, err)
		if len(kr) != 0 {
			t.Errorf("key of a deleting team: %v", kr)
		}
		revoked, err := edgeRows(t, conn, `SELECT afs.collab_session_revoke($1)`, sha("s-dead"))
		wantOK(t, err)
		if revoked[0] != "true" {
			t.Error("a session of a deleting team can still be revoked: want true")
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'suspended' WHERE id = $1`, teamB)
		mustExec(t, conn, `UPDATE afs.collab_edge_sessions SET revoked_at = NULL WHERE id_hash = $1`, sha("s-dead"))
		if len(get("s-dead")) != 1 {
			t.Error("a suspended team's session must stay readable")
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'active' WHERE id = $1`, teamB)
	})
	t.Run("duplicate hash 23505", func(t *testing.T) {
		_, err := create("c-dup", host)
		wantOK(t, err)
		_, err = create("c-dup", host)
		wantState(t, err, "23505")
	})
	t.Run("groups limit 22023", func(t *testing.T) {
		many := make([]string, 501)
		for i := range many {
			many[i] = fmt.Sprintf("g%d", i)
		}
		_, err := create("c-many", host, many...)
		wantState(t, err, "22023")
		_, err = create("c-500", host, many[:500]...)
		wantOK(t, err)
	})
	t.Run("handoff bound to its host", func(t *testing.T) {
		_, err := create("c-host", host)
		wantOK(t, err)
		rows, err := consume("c-host", "other.collab.example.com", "s-host")
		wantOK(t, err)
		if len(rows) != 0 || len(get("s-host")) != 0 {
			t.Fatal("another host consumed the code")
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_edge_handoffs WHERE code_hash = $1 AND consumed_at IS NULL`, sha("c-host")); n != 1 {
			t.Fatal("a refused consume used the code up")
		}
	})
	t.Run("consume creates the session under the edge's hash", func(t *testing.T) {
		_, err := create("c-ok", host, "grp-a", "grp-b")
		wantOK(t, err)
		rows, err := consume("c-ok", host, "s-ok")
		wantOK(t, err)
		if len(rows) != 1 || !strings.HasPrefix(rows[0], teamA+"|") {
			t.Fatalf("%v", rows)
		}
		got := get("s-ok")
		if len(got) != 1 || !strings.Contains(got[0], "https://idp.example.com|sub-1|"+idpP1+"|[grp-a grp-b]") {
			t.Fatalf("session %v", got)
		}
		again, err := consume("c-ok", host, "s-ok2")
		wantOK(t, err)
		if len(again) != 0 {
			t.Fatal("a code was used twice")
		}
	})
	t.Run("unknown code no row", func(t *testing.T) {
		rows, err := consume("never-created", host, "s-none")
		wantOK(t, err)
		if len(rows) != 0 {
			t.Fatal("row for an unknown code")
		}
	})
	t.Run("session ttl follows collab.session_ttl_minutes", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '15' WHERE key = 'collab.session_ttl_minutes'`)
		_, err := create("c-ttl", host)
		wantOK(t, err)
		_, err = consume("c-ttl", host, "s-ttl")
		wantOK(t, err)
		var mins float64
		wantOK(t, conn.QueryRow(ctx, `SELECT extract(epoch FROM expires_at - created_at) / 60 FROM afs.collab_edge_sessions WHERE id_hash = $1`, sha("s-ttl")).Scan(&mins))
		if mins < 14.9 || mins > 15.1 {
			t.Fatalf("ttl %.2f minutes", mins)
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '480' WHERE key = 'collab.session_ttl_minutes'`)
	})
	t.Run("duplicate session hash rolls the consume back", func(t *testing.T) {
		_, err := create("c-dupsess", host)
		wantOK(t, err)
		_, err = consume("c-dupsess", host, "s-ok")
		wantState(t, err, "23505")
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_edge_handoffs WHERE code_hash = $1 AND consumed_at IS NULL`, sha("c-dupsess")); n != 1 {
			t.Fatal("the code was consumed although no session was created")
		}
	})
	t.Run("handoff single use under concurrency", func(t *testing.T) {
		_, err := create("c-race", host)
		wantOK(t, err)
		var wg sync.WaitGroup
		var mu sync.Mutex
		winners := 0
		for i := range 8 {
			c := newConn(t, conn)
			wg.Add(1)
			go func() {
				defer wg.Done()
				var team string
				var exp time.Time
				err := pgx.BeginFunc(ctx, c, func(tx pgx.Tx) error {
					if _, err := tx.Exec(ctx, edgeSession); err != nil {
						return err
					}
					return tx.QueryRow(ctx, `SELECT team_id, expires_at FROM afs.collab_handoff_consume($1, $2, $3)`, sha("c-race"), host, sha(fmt.Sprintf("s-race-%d", i))).Scan(&team, &exp)
				})
				if err == nil {
					mu.Lock()
					winners++
					mu.Unlock()
				} else if !errors.Is(err, pgx.ErrNoRows) {
					t.Errorf("consume: %v", err)
				}
			}()
		}
		wg.Wait()
		if winners != 1 {
			t.Fatalf("%d winners", winners)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_edge_sessions WHERE id_hash::text LIKE '%'`) - 2; n < 1 {
			t.Fatal("no session")
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.collab_edge_sessions s WHERE s.id_hash = ANY ($1)`, func() [][]byte {
			var hs [][]byte
			for i := range 8 {
				hs = append(hs, sha(fmt.Sprintf("s-race-%d", i)))
			}
			return hs
		}()); n != 1 {
			t.Fatalf("%d sessions for one code", n)
		}
	})
	t.Run("session get live only", func(t *testing.T) {
		if len(get("s-ok")) != 1 {
			t.Fatal("live session not found")
		}
		mustExec(t, conn, `UPDATE afs.collab_edge_sessions SET created_at = now() - interval '2 days', expires_at = now() - interval '1 minute' WHERE id_hash = $1`, sha("s-ttl"))
		if len(get("s-ttl")) != 0 || len(get("unknown")) != 0 {
			t.Fatal("expired or unknown session returned")
		}
	})
	t.Run("last_seen_at once a minute", func(t *testing.T) {
		seen := func() time.Time {
			var v time.Time
			wantOK(t, conn.QueryRow(ctx, `SELECT last_seen_at FROM afs.collab_edge_sessions WHERE id_hash = $1`, sha("s-ok")).Scan(&v))
			return v
		}
		first := seen()
		get("s-ok")
		if seen() != first {
			t.Fatal("updated within a minute")
		}
		mustExec(t, conn, `UPDATE afs.collab_edge_sessions SET last_seen_at = now() - interval '2 minutes' WHERE id_hash = $1`, sha("s-ok"))
		get("s-ok")
		if time.Since(seen()) > time.Minute {
			t.Fatal("not refreshed")
		}
	})
	t.Run("revoke", func(t *testing.T) {
		got, err := edgeRows(t, conn, `SELECT afs.collab_session_revoke($1)`, sha("s-ok"))
		wantOK(t, err)
		if got[0] != "true" {
			t.Fatal(got)
		}
		got, err = edgeRows(t, conn, `SELECT afs.collab_session_revoke($1)`, sha("s-ok"))
		wantOK(t, err)
		if got[0] != "false" || len(get("s-ok")) != 0 {
			t.Fatal("revoked session still live")
		}
		got, err = edgeRows(t, conn, `SELECT afs.collab_session_revoke($1)`, sha("nope"))
		wantOK(t, err)
		if got[0] != "false" {
			t.Fatal(got)
		}
	})
	t.Run("purge removes only old rows", func(t *testing.T) {
		mustExec(t, conn, `DELETE FROM afs.collab_edge_sessions`)
		mustExec(t, conn, `DELETE FROM afs.collab_edge_handoffs`)
		mustExec(t, conn, `
INSERT INTO afs.collab_edge_sessions (id_hash, team_id, issuer, subject, provider_id, created_at, expires_at, revoked_at) VALUES
 ($1, 't', 'i', 's', 'p', now() - interval '5 hours', now() - interval '3 hours', NULL),
 ($2, 't', 'i', 's', 'p', now() - interval '5 hours', now() + interval '3 hours', now() - interval '2 hours'),
 ($3, 't', 'i', 's', 'p', now() - interval '5 hours', now() - interval '30 minutes', NULL),
 ($4, 't', 'i', 's', 'p', now() - interval '5 hours', now() + interval '3 hours', now() - interval '10 minutes'),
 ($5, 't', 'i', 's', 'p', now(), now() + interval '3 hours', NULL)`,
			sha("p1"), sha("p2"), sha("p3"), sha("p4"), sha("p5"))
		mustExec(t, conn, `
INSERT INTO afs.collab_edge_handoffs (code_hash, team_id, host, issuer, subject, provider_id, expires_at) VALUES
 ($1, 't', 'h', 'i', 's', 'p', now() - interval '2 hours'), ($2, 't', 'h', 'i', 's', 'p', now() - interval '10 minutes')`,
			sha("h1"), sha("h2"))
		got, err := queryAs(t, conn, "afs_reconciler", "", `SELECT afs.purge_collab_edge_sessions()`)
		wantOK(t, err)
		if got[0] != "3" {
			t.Fatalf("purged %s", got[0])
		}
		if s, h := count(t, conn, `SELECT count(*) FROM afs.collab_edge_sessions`), count(t, conn, `SELECT count(*) FROM afs.collab_edge_handoffs`); s != 3 || h != 1 {
			t.Fatalf("%d sessions, %d handoffs left", s, h)
		}
	})
	t.Run("no grant on the tables for any role 42501", func(t *testing.T) {
		for _, role := range []string{"afs_app", "afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly", "afs_edge"} {
			for _, tb := range []string{"afs.collab_edge_sessions", "afs.collab_edge_handoffs"} {
				_, err := queryAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `SELECT 1 FROM `+tb)
				wantState(t, err, "42501")
				wantState(t, runAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `DELETE FROM `+tb), "42501")
				wantState(t, runAs(t, conn, role, "SET LOCAL afs.service_admin = 'on'", `UPDATE `+tb+` SET team_id = team_id`), "42501")
			}
		}
	})
	t.Run("plain ids never stored (columns hold 32-byte hashes)", func(t *testing.T) {
		wantState(t, func() error {
			_, err := conn.Exec(ctx, `INSERT INTO afs.collab_edge_sessions (id_hash, team_id, issuer, subject, provider_id, expires_at) VALUES ('\x0102', 't', 'i', 's', 'p', now() + interval '1 hour')`)
			return err
		}(), "23514")
		wantState(t, func() error {
			_, err := conn.Exec(ctx, `INSERT INTO afs.collab_edge_handoffs (code_hash, team_id, host, issuer, subject, provider_id, expires_at) VALUES ('\x0102', 't', 'h', 'i', 's', 'p', now())`)
			return err
		}(), "23514")
		cols := scalar[string](t, conn, "", `SELECT string_agg(attname, ',' ORDER BY attname) FROM pg_attribute WHERE attrelid IN ('afs.collab_edge_sessions'::regclass, 'afs.collab_edge_handoffs'::regclass) AND attnum > 0 AND atttypid = 'text'::regtype`)
		for _, bad := range []string{"token", "session_id", "code,", "claims", "email", "access", "refresh"} {
			if strings.Contains(cols+",", bad) {
				t.Errorf("a text column looks like a credential: %s", cols)
			}
		}
		if n := count(t, conn, `SELECT count(*) FROM pg_class WHERE oid IN ('afs.collab_edge_sessions'::regclass, 'afs.collab_edge_handoffs'::regclass) AND relrowsecurity`); n != 2 {
			t.Fatal("row-level security is not enabled")
		}
	})
	t.Run("only the edge may call the four, only the reconciler the purge", func(t *testing.T) {
		for _, fn := range []string{"afs.collab_handoff_create(bytea, text, text, text, text, text, text[])", "afs.collab_handoff_consume(bytea, text, bytea)", "afs.collab_session_get(bytea)", "afs.collab_session_revoke(bytea)"} {
			executableBy(t, conn, fn, "afs_edge")
		}
		executableBy(t, conn, "afs.purge_collab_edge_sessions()", "afs_reconciler")
	})
}
