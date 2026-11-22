package migrate_test

// Migration 000020, Paperclip team collaboration (spec 261122-paperclip-collaboration; -db PRD DB-US-44 to
// DB-US-57). Each test names the PRD story it proves; subtests carry the names the PRD's "Proven by" lines use.

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

const collabDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// cid builds a valid prefixed id for the tests of this file: cid("agt", 7).
func cid(prefix string, n int) string { return fmt.Sprintf("%s_01JD3Z5Y8K2M4N6P8Q0R2S%04d", prefix, n) }

var (
	tplCollab = cid("tpl", 1)
	tplWorker = cid("tpl", 2)
	collA     = cid("agt", 1) // team A's collaboration agent
	wrkA      = cid("agt", 2)
	wrkA2     = cid("agt", 3)
	collB     = cid("agt", 4)
	wrkB      = cid("agt", 5)
	adminA    = "SET LOCAL afs.team_ids = '" + teamA + "'; SET LOCAL afs.actor = 'usr_a'"
)

// runAs runs sql under SET LOCAL ROLE role (plus extra settings) in one transaction that commits on success.
func runAs(t *testing.T, conn *pgx.Conn, role, extra, sql string, args ...any) error {
	t.Helper()
	return pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), "SET LOCAL ROLE "+role+"; SET LOCAL afs.actor = 'usr_test'"+orEmpty(extra)); err != nil {
			return err
		}
		_, err := tx.Exec(t.Context(), sql, args...)
		return err
	})
}

func orEmpty(extra string) string {
	if extra == "" {
		return ""
	}
	return "; " + extra
}

// queryAs runs a query under a role and returns the first column of every row as text.
func queryAs(t *testing.T, conn *pgx.Conn, role, extra, sql string, args ...any) ([]string, error) {
	t.Helper()
	var out []string
	err := pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), "SET LOCAL ROLE "+role+"; SET LOCAL afs.actor = 'usr_test'"+orEmpty(extra)); err != nil {
			return err
		}
		rows, err := tx.Query(t.Context(), sql, args...)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (string, error) {
			var v any
			if err := r.Scan(&v); err != nil {
				return "", err
			}
			return fmt.Sprint(v), nil
		})
		return err
	})
	return out, err
}

func wantState(t *testing.T, err error, want string) {
	t.Helper()
	if got := sqlState(err); got != want {
		t.Fatalf("want SQLSTATE %s, got %q (%v)", want, got, err)
	}
}

func wantOK(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func mustExec(t *testing.T, conn *pgx.Conn, sql string, args ...any) {
	t.Helper()
	if _, err := conn.Exec(t.Context(), sql, args...); err != nil {
		t.Fatalf("%s: %v", strings.Fields(sql)[0], err)
	}
}

func count(t *testing.T, conn *pgx.Conn, sql string, args ...any) int {
	t.Helper()
	return scalar[int](t, conn, "", sql, args...)
}

// newCollab returns a migrated database with teams A and B, a model, a paperclip and a plain agent template.
func newCollab(t *testing.T) *pgx.Conn {
	t.Helper()
	conn := migrated(t)
	seedTeams(t, conn)
	mustExec(t, conn, `
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+teamA+`', 'claude-sonnet'), ('`+teamB+`', 'claude-sonnet');
INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities) VALUES
 ('`+tplCollab+`', 'paperclip', 'paperclip', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{paperclip}'),
 ('`+tplWorker+`', 'omp', 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{}')`)
	return conn
}

func addAgent(t *testing.T, conn *pgx.Conn, id, team, name, role string, tpl any, identity string) error {
	t.Helper()
	_, err := conn.Exec(t.Context(), `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, role, template_id, iam_identity)
		VALUES ($1, $2, $3, 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'claude-sonnet', $4, $5, $6)`, id, team, name, role, tpl, identity)
	return err
}

// collabAgents adds a collaboration agent and a worker to teams A and B (ids collA, wrkA, collB, wrkB).
func collabAgents(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	wantOK(t, addAgent(t, conn, collA, teamA, "paperclip", "collaboration", tplCollab, "dedicated"))
	wantOK(t, addAgent(t, conn, wrkA, teamA, "indexer", "worker", nil, "team_shared"))
	wantOK(t, addAgent(t, conn, collB, teamB, "paperclip", "collaboration", tplCollab, "dedicated"))
	wantOK(t, addAgent(t, conn, wrkB, teamB, "scanner", "worker", nil, "team_shared"))
}

// withCollab adds the team_collaboration rows of teams A and B on top of collabAgents.
func withCollab(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	collabAgents(t, conn)
	mustExec(t, conn, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2), ($3, $4)`, teamA, collA, teamB, collB)
}

// DB-US-44.
func TestCollaborationAgent(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	t.Run("role defaults to worker and existing rows are workers", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, wrkA, teamA, "indexer", "worker", nil, "team_shared"))
		mustExec(t, conn, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id)
			VALUES ($1, $2, 'plain', 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'claude-sonnet')`, wrkA2, teamA)
		if got := scalar[string](t, conn, "", `SELECT role FROM afs.agents WHERE id = $1`, wrkA2); got != "worker" {
			t.Fatalf("default role %q", got)
		}
	})
	t.Run("unknown role 23514", func(t *testing.T) {
		wantState(t, addAgent(t, conn, cid("agt", 20), teamA, "odd", "boss", nil, "team_shared"), "23514")
	})
	t.Run("second collaboration agent 23505", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, collA, teamA, "paperclip", "collaboration", tplCollab, "dedicated"))
		err := addAgent(t, conn, cid("agt", 21), teamA, "paperclip2", "collaboration", tplCollab, "dedicated")
		wantState(t, err, "23505")
		if !strings.Contains(err.Error(), "agents_team_collaboration_uq") {
			t.Errorf("wrong constraint: %v", err)
		}
	})
	t.Run("deleting agent still blocks, deleted agent frees the slot", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleting' WHERE id = $1`, collA)
		wantState(t, addAgent(t, conn, cid("agt", 22), teamA, "paperclip3", "collaboration", tplCollab, "dedicated"), "23505")
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, collA)
		wantOK(t, addAgent(t, conn, cid("agt", 22), teamA, "paperclip3", "collaboration", tplCollab, "dedicated"))
	})
	t.Run("another team unaffected", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, collB, teamB, "paperclip", "collaboration", tplCollab, "dedicated"))
	})
	t.Run("role is immutable 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET role = 'collaboration' WHERE id = $1`, wrkA)
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET role = 'worker' WHERE id = $1`, collB)
		wantState(t, err, "23514")
		mustExec(t, conn, `UPDATE afs.agents SET description = 'fine' WHERE id = $1`, collB)
		mustExec(t, conn, `UPDATE afs.agents SET role = 'worker' WHERE id = $1`, wrkA) // same value: allowed
	})
	t.Run("template must have paperclip 23514", func(t *testing.T) {
		wantState(t, addAgent(t, conn, cid("agt", 23), teamB, "other", "collaboration", tplWorker, "dedicated"), "23514")
	})
	t.Run("template id required 23514", func(t *testing.T) {
		wantState(t, addAgent(t, conn, cid("agt", 24), teamB, "other", "collaboration", nil, "dedicated"), "23514")
	})
	t.Run("dedicated identity required 23514", func(t *testing.T) {
		wantState(t, addAgent(t, conn, cid("agt", 25), teamB, "other", "collaboration", tplCollab, "team_shared"), "23514")
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET iam_identity = 'team_shared' WHERE id = $1`, collB)
		wantState(t, err, "23514")
	})
	t.Run("snapshots cannot be turned off 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET snapshot_schedule = 'off' WHERE id = $1`, collB)
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, role, template_id, iam_identity, snapshot_schedule)
			VALUES ($1, $2, 'off', 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'claude-sonnet', 'collaboration', $3, 'dedicated', 'off')`, cid("agt", 26), teamA, tplCollab)
		wantState(t, err, "23514")
	})
	t.Run("worker on a paperclip template 23514", func(t *testing.T) {
		wantState(t, addAgent(t, conn, cid("agt", 27), teamB, "wk", "worker", tplCollab, "team_shared"), "23514")
	})
	t.Run("legacy worker without template accepted", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, cid("agt", 28), teamB, "legacy", "worker", nil, "team_shared"))
	})
}

// DB-US-44.
func TestAgentTemplateCapabilities(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	ins := func(id string, n int, caps string) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities)
			VALUES ($1, $2, 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`', `+caps+`)`, id, fmt.Sprintf("tpl-x%d", n))
		return err
	}
	t.Run("check accepts paperclip", func(t *testing.T) {
		wantOK(t, ins(cid("tpl", 10), 10, `'{paperclip}'`))
		wantOK(t, ins(cid("tpl", 11), 11, `'{}'`))
		if got := scalar[string](t, conn, "", `SELECT capabilities::text FROM afs.agent_templates WHERE name = 'omp'`); got != "{}" {
			t.Errorf("existing template reads %q", got)
		}
	})
	t.Run("unknown value, duplicate and nine elements 23514", func(t *testing.T) {
		wantState(t, ins(cid("tpl", 12), 12, `'{gpu}'`), "23514")
		wantState(t, ins(cid("tpl", 13), 13, `'{paperclip,paperclip}'`), "23514")
		wantState(t, ins(cid("tpl", 14), 14, `ARRAY['paperclip','a','b','c','d','e','f','g','h']`), "23514")
		wantState(t, ins(cid("tpl", 15), 15, `'{NULL}'`), "23514")
	})
	t.Run("removal with a live collaboration agent 55000", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, collA, teamA, "paperclip", "collaboration", tplCollab, "dedicated"))
		_, err := conn.Exec(ctx, `UPDATE afs.agent_templates SET capabilities = '{}' WHERE id = $1`, tplCollab)
		wantState(t, err, "55000")
	})
	t.Run("addition with a live worker 55000", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, wrkA, teamA, "indexer", "worker", tplWorker, "team_shared"))
		_, err := conn.Exec(ctx, `UPDATE afs.agent_templates SET capabilities = '{paperclip}' WHERE id = $1`, tplWorker)
		wantState(t, err, "55000")
	})
	t.Run("change with no live agent", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agent_templates SET capabilities = '{}' WHERE id = $1`, cid("tpl", 10))
		mustExec(t, conn, `UPDATE afs.agent_templates SET capabilities = '{paperclip}' WHERE id = $1`, cid("tpl", 11))
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, collA)
		mustExec(t, conn, `UPDATE afs.agent_templates SET capabilities = '{}' WHERE id = $1`, tplCollab)
	})
	t.Run("team caller cannot write", func(t *testing.T) {
		err := runAs(t, conn, "afs_app", adminA, `INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest)
			VALUES ($1, 'sneaky', 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`')`, cid("tpl", 16))
		wantState(t, err, "42501")
		var rows int64
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, "SET LOCAL ROLE afs_app; "+adminA); err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, `UPDATE afs.agent_templates SET capabilities = '{paperclip}' WHERE id = $1`, tplWorker)
			rows = tag.RowsAffected()
			return err
		})
		wantOK(t, err)
		if rows != 0 {
			t.Errorf("team caller changed %d template rows", rows)
		}
	})
}

// DB-US-48: the collaborator role.
func TestRoleCollaborator(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	mustExec(t, conn, `INSERT INTO afs.users (id, oidc_issuer, oidc_subject, email, display_name) VALUES ($1, 'https://idp.example.com', 'sub-1', 'a@example.com', 'A')`, cid("usr", 1))
	t.Run("team binding", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, user_id) VALUES ($1, 'team_collaborator', $2, 'user', $3)`, cid("rb", 1), teamA, cid("usr", 1))
	})
	t.Run("team key", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at)
			VALUES ($1, $2, 'collab', 'team_collaborator', 'afs_k_cc', decode(repeat('01', 32), 'hex'), now() + interval '30 days')`, cid("key", 1), teamA)
	})
	t.Run("service level refused 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, user_id) VALUES ($1, 'team_collaborator', NULL, 'user', $2)`, cid("rb", 2), cid("usr", 1))
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at)
			VALUES ($1, NULL, 'svc', 'team_collaborator', 'afs_k_dd', decode(repeat('02', 32), 'hex'), now() + interval '30 days')`, cid("key", 2))
		wantState(t, err, "23514")
	})
	t.Run("old roles still accepted", func(t *testing.T) {
		for i, r := range []string{"team_admin", "team_viewer"} {
			mustExec(t, conn, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ($1, $2, $3, 'group', $4)`, cid("rb", 10+i), r, teamA, "grp-"+r)
		}
		mustExec(t, conn, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ($1, 'service_admin', NULL, 'group', 'grp-svc')`, cid("rb", 20))
		mustExec(t, conn, `INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at)
			VALUES ($1, NULL, 'sec', 'security_operator', 'afs_k_ee', decode(repeat('03', 32), 'hex'), now() + interval '30 days')`, cid("key", 3))
		_, err := conn.Exec(ctx, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ($1, 'team_boss', $2, 'group', 'x')`, cid("rb", 21), teamA)
		wantState(t, err, "23514")
	})
}

// DB-US-48: the per-team guardrail.
func TestTeamGuardrailMayExpose(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	t.Run("team admin 42501", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.teams SET may_expose_collaboration = false WHERE id = $1`, teamA), "42501")
	})
	t.Run("service admin", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.teams SET may_expose_collaboration = false WHERE id = $1`, teamA))
		if scalar[bool](t, conn, "", `SELECT may_expose_collaboration FROM afs.teams WHERE id = $1`, teamA) {
			t.Fatal("guardrail not changed")
		}
		if !scalar[bool](t, conn, "", `SELECT may_expose_collaboration FROM afs.teams WHERE id = $1`, teamB) {
			t.Fatal("default is not true")
		}
	})
	t.Run("earlier guarded columns still 42501", func(t *testing.T) {
		for _, col := range []string{"may_add_external_systems = true", "may_manage_aws_accounts = true", "max_budget_usd = 10", "quotas = '{\"agents\": 5}'"} {
			if err := runAs(t, conn, "afs_app", adminA, `UPDATE afs.teams SET `+col+` WHERE id = $1`, teamA); sqlState(err) != "42501" {
				t.Errorf("%s: want 42501, got %v", col, err)
			}
		}
	})
	t.Run("reconciler state update unaffected", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.teams SET state = 'suspended' WHERE id = $1`, teamA))
		_ = ctx
	})
}

// DB-US-48: seven settings, their defaults and ranges.
func TestServiceSettingRanges(t *testing.T) {
	conn := newCollab(t)
	set := func(key, value string) error {
		_, err := conn.Exec(t.Context(), `UPDATE afs.service_settings SET value = $2::jsonb WHERE key = $1`, key, value)
		return err
	}
	t.Run("seeded defaults", func(t *testing.T) {
		want := map[string]string{"collab.base_domain": "null", "collab.public_endpoints": "true", "collab.allowed_source_cidrs": "[]",
			"collab.session_ttl_minutes": "480", "collab.content_scan": `"block"`, "collab.max_body_mb": "25", "collab.denied_spike_threshold": "50"}
		for k, v := range want {
			if got := scalar[string](t, conn, "", `SELECT value::text FROM afs.service_settings WHERE key = $1`, k); got != v {
				t.Errorf("%s = %s, want %s", k, got, v)
			}
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.service_settings WHERE key LIKE 'collab.%'`); n != 7 {
			t.Errorf("%d collab settings", n)
		}
	})
	cases := []struct {
		key        string
		ok, refuse []string
	}{
		{"collab.base_domain", []string{`"collab.example.com"`, `"a.b.c.example.com"`, "null", `"x1.io"`}, []string{`"localhost"`, `"Collab.example.com"`, `"collab.example.com."`, `"a_b.example.com"`, `"-a.example.com"`, `"a..example.com"`, `5`, `"` + strings.Repeat("a", 64) + `.example.com"`, `"a.b"`[:3] + `"`, `true`}},
		{"collab.public_endpoints", []string{"true", "false"}, []string{`"true"`, "1", "null"}},
		{"collab.allowed_source_cidrs", []string{`[]`, `["10.0.0.0/8", "2001:db8::/32"]`, `["192.0.2.0/24"]`}, []string{`["10.0.0.1"]`, `["not-a-cidr/8"]`, `[1]`, `"10.0.0.0/8"`, `["10.0.0.1/8"]`}},
		{"collab.session_ttl_minutes", []string{"15", "1440", "480"}, []string{"14", "1441", "480.5", `"480"`, "null"}},
		{"collab.content_scan", []string{`"block"`, `"warn"`, `"off"`}, []string{`"strict"`, "true", `"BLOCK"`}},
		{"collab.max_body_mb", []string{"1", "100"}, []string{"0", "101", "2.5", `"25"`}},
		{"collab.denied_spike_threshold", []string{"1", "100000"}, []string{"0", "100001", "1.5", `"50"`}},
	}
	for _, c := range cases {
		t.Run(c.key, func(t *testing.T) {
			for _, v := range c.ok {
				if err := set(c.key, v); err != nil {
					t.Errorf("%s = %s refused: %v", c.key, v, err)
				}
			}
			for _, v := range c.refuse {
				if err := set(c.key, v); sqlState(err) != "23514" {
					t.Errorf("%s = %s: want 23514, got %v", c.key, v, err)
				}
			}
		})
	}
	t.Run("too many cidrs", func(t *testing.T) {
		var items []string
		for i := range 101 {
			items = append(items, fmt.Sprintf(`"10.%d.0.0/16"`, i))
		}
		wantState(t, set("collab.allowed_source_cidrs", "["+strings.Join(items, ",")+"]"), "23514")
		wantOK(t, set("collab.allowed_source_cidrs", "["+strings.Join(items[:100], ",")+"]"))
	})
	t.Run("other keys unaffected", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.service_settings (key, value) VALUES ('collab.future_flag', '"x"')`)
		mustExec(t, conn, `INSERT INTO afs.service_settings (key, value) VALUES ('other.thing', '[1]')`)
	})
}

// DB-US-47: the provider's collaboration client.
func TestIdentityProviderCollabClient(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	const arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/idp/collab-AbCdEf"
	ins := func(n int, client, secret any) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.identity_providers (id, name, kind, issuer_url, client_id, collab_client_id, collab_client_secret_arn)
			VALUES ($1, $2, 'okta', $3, 'console', $4, $5)`, cid("idp", n), fmt.Sprintf("idp%d", n), fmt.Sprintf("https://idp%d.example.com", n), client, secret)
		return err
	}
	t.Run("format 23514", func(t *testing.T) {
		wantOK(t, ins(1, "0oa1.client:x@y", arn))
		wantState(t, ins(2, "bad client", nil), "23514")
		wantState(t, ins(3, "", nil), "23514")
		wantState(t, ins(4, strings.Repeat("a", 256), nil), "23514")
		wantOK(t, ins(5, nil, nil))
	})
	t.Run("secret without client 23514", func(t *testing.T) {
		wantState(t, ins(6, nil, arn), "23514")
	})
	t.Run("arn pattern 23514", func(t *testing.T) {
		wantState(t, ins(7, "c", "not-an-arn"), "23514")
		wantState(t, ins(8, "c", "arn:aws:s3:::bucket"), "23514")
	})
	t.Run("service admin writes, team admin cannot", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.identity_providers SET collab_client_id = 'new' WHERE id = $1`, cid("idp", 5)))
		err := runAs(t, conn, "afs_app", adminA, `UPDATE afs.identity_providers SET collab_client_id = 'hijack' WHERE id = $1`, cid("idp", 5))
		if err != nil && sqlState(err) != "42501" {
			t.Fatal(err)
		}
		if got := scalar[string](t, conn, "", `SELECT collab_client_id FROM afs.identity_providers WHERE id = $1`, cid("idp", 5)); got != "new" {
			t.Errorf("team admin changed the client: %s", got)
		}
	})
}

// DB-US-45.
func TestTeamCollaboration(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	collabAgents(t, conn)
	t.Run("defaults", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamA, collA)
		var web, rest bool
		var mode string
		var v, g int64
		wantOK(t, conn.QueryRow(ctx, `SELECT web_ui_enabled, rest_api_enabled, registration_mode, version, generation FROM afs.team_collaboration WHERE team_id = $1`, teamA).Scan(&web, &rest, &mode, &v, &g))
		if !web || rest || mode != "manual" || v != 1 || g != 1 {
			t.Fatalf("defaults %v %v %s %d %d", web, rest, mode, v, g)
		}
	})
	t.Run("agent must be a collaboration agent 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamB, wrkB)
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `UPDATE afs.team_collaboration SET agent_id = $2 WHERE team_id = $1`, teamA, wrkA)
		wantState(t, err, "23514")
	})
	t.Run("agent of another team 23503", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamB, collA)
		wantState(t, err, "23503")
	})
	t.Run("registration mode check 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.team_collaboration SET registration_mode = 'auto' WHERE team_id = $1`, teamA)
		wantState(t, err, "23514")
	})
	gen := func() (int64, int64) {
		var v, g int64
		wantOK(t, conn.QueryRow(ctx, `SELECT version, generation FROM afs.team_collaboration WHERE team_id = $1`, teamA).Scan(&v, &g))
		return v, g
	}
	t.Run("generation bumps on a spec change only", func(t *testing.T) {
		v0, g0 := gen()
		for i, col := range []string{"web_ui_enabled = false", "rest_api_enabled = true", "registration_mode = 'managed'"} {
			mustExec(t, conn, `UPDATE afs.team_collaboration SET `+col+` WHERE team_id = $1`, teamA)
			v, g := gen()
			if v != v0+int64(i)+1 || g != g0+int64(i)+1 {
				t.Fatalf("%s: version %d generation %d", col, v, g)
			}
		}
		v1, g1 := gen()
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = false WHERE team_id = $1`, teamA) // same value
		v2, g2 := gen()
		if v2 != v1+1 || g2 != g1 {
			t.Fatalf("a no-op update moved generation: %d -> %d", g1, g2)
		}
	})
	t.Run("revision and change feed payload", func(t *testing.T) {
		if n := count(t, conn, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'team_collaboration' AND resource_id = $1`, teamA); n < 2 {
			t.Fatalf("%d revisions keyed by the team id", n)
		}
		mustExec(t, conn, `LISTEN afs_desired_state`)
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = true WHERE team_id = $1`, teamA)
		wctx, cancel := context_withTimeout(t)
		defer cancel()
		n, err := conn.WaitForNotification(wctx)
		wantOK(t, err)
		if want := "team_collaboration:" + teamA + ":"; n.Payload != want {
			t.Errorf("payload %q, want %q", n.Payload, want)
		}
	})
	t.Run("app writes only the three columns", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.team_collaboration SET web_ui_enabled = false, rest_api_enabled = false, registration_mode = 'manual' WHERE team_id = $1`, teamA))
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.team_collaboration SET agent_id = agent_id WHERE team_id = $1`, teamA), "42501")
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.team_collaboration SET generation = 9 WHERE team_id = $1`, teamA), "42501")
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+teamB+"'", `INSERT INTO afs.team_collaboration (team_id, agent_id, web_ui_enabled) VALUES ($1, $2, false)`, teamB, collB))
	})
	t.Run("no delete for the API 42501", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", adminA, `DELETE FROM afs.team_collaboration WHERE team_id = $1`, teamA), "42501")
	})
	t.Run("reconciler and readonly are read-only", func(t *testing.T) {
		for _, role := range []string{"afs_reconciler", "afs_readonly"} {
			if _, err := queryAs(t, conn, role, "", `SELECT team_id FROM afs.team_collaboration`); err != nil {
				t.Errorf("%s cannot read: %v", role, err)
			}
			wantState(t, runAs(t, conn, role, "", `UPDATE afs.team_collaboration SET web_ui_enabled = true`), "42501")
			wantState(t, runAs(t, conn, role, "", `DELETE FROM afs.team_collaboration`), "42501")
		}
		for _, role := range []string{"afs_edge", "afs_billing", "afs_gateway"} {
			_, err := queryAs(t, conn, role, "", `SELECT 1 FROM afs.team_collaboration`)
			wantState(t, err, "42501")
		}
	})
	t.Run("guardrails leave the stored choice unchanged", func(t *testing.T) {
		before := scalar[string](t, conn, "", `SELECT version || '/' || generation FROM afs.team_collaboration WHERE team_id = $1`, teamA)
		mustExec(t, conn, `UPDATE afs.teams SET may_expose_collaboration = false WHERE id = $1`, teamA)
		mustExec(t, conn, `UPDATE afs.service_settings SET value = 'false' WHERE key = 'collab.public_endpoints'`)
		if after := scalar[string](t, conn, "", `SELECT version || '/' || generation FROM afs.team_collaboration WHERE team_id = $1`, teamA); after != before {
			t.Errorf("row changed: %s -> %s", before, after)
		}
	})
	t.Run("resource status kind accepted", func(t *testing.T) {
		for i, cond := range []string{"EndpointReady", "PaperclipReady", "RegistrationHealthy", "UnmanagedPaperclipAgents"} {
			_ = i
			wantOK(t, runAs(t, conn, "afs_reconciler", "", `INSERT INTO afs.resource_status (resource_kind, resource_id, team_id, conditions)
				VALUES ('team_collaboration', $1, $1, jsonb_build_array(jsonb_build_object('type', $2::text, 'status', 'True')))
				ON CONFLICT (resource_kind, resource_id) DO UPDATE SET conditions = EXCLUDED.conditions`, teamA, cond))
		}
	})
}

// DB-US-46.
func TestAgentCollaboration(t *testing.T) {
	conn := newCollab(t)
	ctx := t.Context()
	collabAgents(t, conn)
	mustExec(t, conn, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamA, collA)
	t.Run("no rows after migration", func(t *testing.T) {
		if n := count(t, conn, `SELECT count(*) FROM afs.agent_collaboration`); n != 0 {
			t.Fatalf("%d rows", n)
		}
	})
	ins := func(agent string, connect bool) error {
		return runAs(t, conn, "afs_app", adminA, `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, $3)`, teamA, agent, connect)
	}
	row := func(agent string) (string, int64, int64) {
		var st string
		var v, g int64
		wantOK(t, conn.QueryRow(ctx, `SELECT link_state, version, generation FROM afs.agent_collaboration WHERE agent_id = $1`, agent).Scan(&st, &v, &g))
		return st, v, g
	}
	t.Run("worker only 23514", func(t *testing.T) {
		wantState(t, ins(collA, true), "23514")
	})
	t.Run("connect needs a collaboration row 55000", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+teamB+"'", `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, true)`, teamB, wrkB), "55000")
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+teamB+"'", `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, false)`, teamB, wrkB))
	})
	t.Run("link state set by trigger", func(t *testing.T) {
		wantOK(t, ins(wrkA, true))
		if st, _, _ := row(wrkA); st != "pending" {
			t.Fatalf("state %s", st)
		}
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET link_state = 'linked' WHERE agent_id = $1`, wrkA))
		if st, _, _ := row(wrkA); st != "linked" {
			t.Fatalf("state %s", st)
		}
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET connect = false WHERE agent_id = $1`, wrkA))
		if st, _, _ := row(wrkA); st != "disabled" {
			t.Fatalf("state %s", st)
		}
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET connect = true WHERE agent_id = $1`, wrkA))
		if st, _, _ := row(wrkA); st != "pending" {
			t.Fatalf("state %s", st)
		}
		// A caller-supplied link_state on insert is overwritten (owner session, for column grants cannot supply it).
		wantOK(t, addAgent(t, conn, wrkA2, teamA, "indexer2", "worker", nil, "team_shared"))
		mustExec(t, conn, `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect, link_state) VALUES ($1, $2, false, 'linked')`, teamA, wrkA2)
		if st, _, _ := row(wrkA2); st != "disabled" {
			t.Fatalf("supplied state kept: %s", st)
		}
	})
	t.Run("app cannot write link columns 42501", func(t *testing.T) {
		for _, set := range []string{"link_state = 'linked'", "last_synced_at = now()", "last_error = 'x'"} {
			wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET `+set+` WHERE agent_id = $1`, wrkA), "42501")
		}
		wantState(t, runAs(t, conn, "afs_app", adminA, `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect, link_state) VALUES ($1, $2, true, 'linked')`, teamA, collB), "42501")
	})
	t.Run("reconciler writes link columns", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET paperclip_agent_id = 'pc-1', link_state = 'failed', last_synced_at = now(), last_error = 'timeout' WHERE agent_id = $1`, wrkA))
		wantState(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET connect = false WHERE agent_id = $1`, wrkA), "42501")
		wantState(t, runAs(t, conn, "afs_reconciler", "", `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, true)`, teamA, wrkB), "42501")
	})
	t.Run("managed mode locks paperclip_agent_id for the API 55000", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_collaboration SET registration_mode = 'managed' WHERE team_id = $1`, teamA)
		wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET paperclip_agent_id = 'pc-2' WHERE agent_id = $1`, wrkA), "55000")
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET paperclip_agent_id = 'pc-2' WHERE agent_id = $1`, wrkA))
	})
	t.Run("manual mode lets the API record it", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_collaboration SET registration_mode = 'manual' WHERE team_id = $1`, teamA)
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET paperclip_agent_id = 'pc-3' WHERE agent_id = $1`, wrkA))
	})
	t.Run("agent id format 23514", func(t *testing.T) {
		for _, bad := range []string{"has space", "", strings.Repeat("a", 129), "a/b"} {
			wantState(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET paperclip_agent_id = $2 WHERE agent_id = $1`, wrkA, bad), "23514")
		}
	})
	t.Run("last error length 23514", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET last_error = $2 WHERE agent_id = $1`, wrkA, strings.Repeat("e", 501)), "23514")
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET last_error = $2 WHERE agent_id = $1`, wrkA, strings.Repeat("e", 500)))
	})
	t.Run("upsert under column grants", func(t *testing.T) {
		up := `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, $3)
			ON CONFLICT (team_id, agent_id) DO UPDATE SET connect = EXCLUDED.connect`
		wantOK(t, runAs(t, conn, "afs_app", adminA, up, teamA, wrkA, false))
		wantOK(t, runAs(t, conn, "afs_app", adminA, up, teamA, wrkA, true))
		if st, _, _ := row(wrkA); st != "pending" {
			t.Fatalf("state after upsert %s", st)
		}
	})
	t.Run("generation bumps on connect and agent id only", func(t *testing.T) {
		_, _, g0 := row(wrkA)
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.agent_collaboration SET link_state = 'linked', last_synced_at = now(), last_error = NULL WHERE agent_id = $1`, wrkA))
		if _, _, g := row(wrkA); g != g0 {
			t.Fatalf("link columns bumped generation %d -> %d", g0, g)
		}
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET paperclip_agent_id = 'pc-9' WHERE agent_id = $1`, wrkA))
		if _, _, g := row(wrkA); g != g0+1 {
			t.Fatalf("agent id did not bump generation: %d", g)
		}
		wantOK(t, runAs(t, conn, "afs_app", adminA, `UPDATE afs.agent_collaboration SET connect = false WHERE agent_id = $1`, wrkA))
		if _, _, g := row(wrkA); g != g0+2 {
			t.Fatalf("connect did not bump generation: %d", g)
		}
	})
	t.Run("revision key and notify payload", func(t *testing.T) {
		if n := count(t, conn, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'agent_collaboration' AND resource_id = $1`, teamA+"/"+wrkA); n < 2 {
			t.Fatalf("%d revisions", n)
		}
		mustExec(t, conn, `LISTEN afs_desired_state`)
		mustExec(t, conn, `UPDATE afs.agent_collaboration SET connect = connect WHERE agent_id = $1`, wrkA)
		wctx, cancel := context_withTimeout(t)
		defer cancel()
		n, err := conn.WaitForNotification(wctx)
		wantOK(t, err)
		if want := "agent_collaboration:" + teamA + ":"; n.Payload != want {
			t.Errorf("payload %q, want %q", n.Payload, want)
		}
	})
}

func context_withTimeout(t *testing.T) (context.Context, context.CancelFunc) {
	t.Helper()
	return context.WithTimeout(t.Context(), 2*time.Second)
}

// DB-US-57: a swarm template that names a collaboration agent gets one with its team.
func TestSwarmCollaboration(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	const reconciler = "SET LOCAL ROLE afs_reconciler; SET LOCAL afs.actor = 'system:afs-reconciler'"
	tplOff, tplPlain := cid("tpl", 2), cid("tpl", 3)
	spec := func(collab string) string {
		return `{"costCenter": "CC900", "ownerEmail": "secops@example.com",` + collab + `
		  "pools": [{"name": "fixer", "template": "omp", "image": "ghcr.io/x/omp@` + collabDigest + `", "modelId": "claude-sonnet", "workers": 1}]}`
	}
	swt := func(n int) string { return cid("swt", n) }
	wo := func(n int) string { return cid("wo", n) }
	mustExec(t, conn, `
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities, enabled) VALUES
 ('`+tplCollab+`', 'paperclip', 'paperclip', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{paperclip}', true),
 ('`+tplOff+`', 'paperclip-off', 'paperclip', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{paperclip}', false),
 ('`+tplPlain+`', 'omp', 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{}', true)`)
	swarms := []struct {
		n    int
		spec string
	}{
		{1, spec(`"collaboration": {"templateId": "` + tplCollab + `"},`)},
		{2, spec(`"collaboration": {"templateId": "` + tplCollab + `", "image": "ghcr.io/y/paperclip@` + collabDigest + `"},`)},
		{3, spec(`"collaboration": {"templateId": "` + tplOff + `"},`)},
		{4, spec(`"collaboration": {"templateId": "` + tplPlain + `"},`)},
		{5, spec(`"collaboration": {"templateId": "tpl_01JD3Z5Y8K2M4N6P8Q0R2S9999"},`)},
		{6, spec(``)},
		{7, `{"costCenter": "CC900", "ownerEmail": "secops@example.com", "collaboration": {"templateId": "` + tplCollab + `"}, "pools": []}`},
		{8, spec(`"collaboration": {},`)},
	}
	for _, s := range swarms {
		mustExec(t, conn, `INSERT INTO afs.swarm_templates (id, name, kind, spec, budget_usd, ttl_hours, teardown_rule, enabled)
			VALUES ($1, $2, 'general', $3, 100, 24, 'at_expiry', true)`, swt(s.n), fmt.Sprintf("sw%d", s.n), s.spec)
		mustExec(t, conn, `INSERT INTO afs.work_orders (id, kind, title, template_id) VALUES ($1, 'general', 'wo', $2)`, wo(s.n), swt(s.n))
	}
	instantiate := func(n int) (string, error) {
		var team string
		err := in(t, conn, reconciler, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT afs.instantiate_work_order_team($1)`, wo(n)).Scan(&team)
		})
		return team, err
	}

	var team, agent string
	t.Run("collaboration agent created with the team", func(t *testing.T) {
		var err error
		team, err = instantiate(1)
		wantOK(t, err)
		got := queryRow(t, conn, `SELECT id, name, role, template, template_id, model_id, iam_identity, image, state, snapshot_schedule
			FROM afs.agents WHERE team_id = $1 AND role = 'collaboration'`, team)
		agent = got[0]
		want := []string{agent, "paperclip", "collaboration", "paperclip", tplCollab, "claude-sonnet", "dedicated", "ghcr.io/x/omp@" + collabDigest, "enabled", "daily"}
		if strings.Join(got, "|") != strings.Join(want, "|") {
			t.Fatalf("agent %v, want %v", got, want)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.team_collaboration WHERE team_id = $1 AND agent_id = $2 AND web_ui_enabled AND NOT rest_api_enabled`, team, agent); n != 1 {
			t.Fatalf("team_collaboration rows %d", n)
		}
	})
	t.Run("agent.created event and audit", func(t *testing.T) {
		if n := count(t, conn, `SELECT count(*) FROM afs.outbox_events WHERE event_type = 'agent.created' AND aggregate_id = $1 AND team_id = $2
			AND payload -> 'data' ->> 'agentId' = $1`, agent, team); n != 1 {
			t.Fatalf("agent.created events %d", n)
		}
		if got := scalar[string](t, conn, "", `SELECT after ->> 'collaborationAgentId' FROM afs.audit_log WHERE action = 'InstantiateWorkOrderTeam' AND team_id = $1`, team); got != agent {
			t.Fatalf("audit names %q", got)
		}
	})
	t.Run("explicit image wins", func(t *testing.T) {
		team2, err := instantiate(2)
		wantOK(t, err)
		if got := scalar[string](t, conn, "", `SELECT image FROM afs.agents WHERE team_id = $1 AND role = 'collaboration'`, team2); got != "ghcr.io/y/paperclip@"+collabDigest {
			t.Fatalf("image %q", got)
		}
	})
	t.Run("boot secrets recorded against the agent", func(t *testing.T) {
		arnOf := func(name string) string {
			return scalar[string](t, conn, "", `SELECT 'arn:aws:secretsmanager:us-east-1:111122223333:secret:' || afs.secret_path($1, $2, NULL, $3) || '-AbCdEf'`, team, agent, name)
		}
		for name, env := range map[string]string{ //nolint:gosec // secret names and environment variable names, no values
			"paperclip-better-auth-secret":         "BETTER_AUTH_SECRET",
			"paperclip-tool-action-signing-secret": "PAPERCLIP_TOOL_ACTION_SIGNING_SECRET",
			"paperclip-secrets-master-key":         "PAPERCLIP_SECRETS_MASTER_KEY",
		} {
			var id string
			err := in(t, conn, reconciler, func(tx pgx.Tx) error {
				return tx.QueryRow(ctx, `SELECT afs.record_work_order_secret($1, $2, $3, '', $4, 'env', $5)`,
					wo(1), agent, name, arnOf(name), env).Scan(&id)
			})
			wantOK(t, err)
			if got := queryRow(t, conn, `SELECT s.managed_by, s.origin, b.delivery, b.target FROM afs.secrets s
				JOIN afs.agent_secret_bindings b ON b.secret_id = s.id WHERE s.id = $1`, id); strings.Join(got, "|") != "afs|managed|env|"+env {
				t.Fatalf("%s: %v", name, got)
			}
		}
		again := func(name, delivery, target string) error {
			return in(t, conn, reconciler, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `SELECT afs.record_work_order_secret($1, $2, $3, '', $4, $5, $6)`, wo(1), agent, name, arnOf(name), delivery, target)
				return err
			})
		}
		wantOK(t, again("paperclip-better-auth-secret", "env", "BETTER_AUTH_SECRET"))
		if n := count(t, conn, `SELECT count(*) FROM afs.secrets WHERE agent_id = $1`, agent); n != 3 {
			t.Fatalf("idempotent call made %d secrets", n)
		}
		wantState(t, again("gh-token", "env", "GH_TOKEN"), "23514")
		wantState(t, again("paperclip-better-auth-secret", "file", "BETTER_AUTH_SECRET"), "23514")
		wantState(t, again("paperclip-better-auth-secret", "env", "OTHER"), "23514")
	})
	t.Run("the agent id must be this team's collaboration agent", func(t *testing.T) {
		wrk := cid("agt", 40)
		mustExec(t, conn, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES ($1, $2, 'worker-x', 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'claude-sonnet')`, wrk, team)
		err := in(t, conn, reconciler, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.record_work_order_secret($1, $2, 'paperclip-better-auth-secret', '', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/x/y-AbCdEf', 'env', 'BETTER_AUTH_SECRET')`, wo(1), wrk)
			return err
		})
		wantState(t, err, "23514")
		err = in(t, conn, reconciler, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.record_work_order_secret($1, $2, 'paperclip-better-auth-secret', '', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/x/y-AbCdEf', 'env', 'BETTER_AUTH_SECRET')`, wo(1), cid("agt", 41))
			return err
		})
		wantState(t, err, "23514")
	})
	refused := map[string]struct {
		n     int
		state string
	}{
		"disabled collaboration template":    {3, "23514"},
		"template without the capability":    {4, "23514"},
		"unknown collaboration template":     {5, "23514"},
		"collaboration without a templateId": {8, "23514"},
		"no pool to take the model from":     {7, "23514"},
	}
	for name, c := range refused {
		t.Run("refused: "+name, func(t *testing.T) {
			_, err := instantiate(c.n)
			wantState(t, err, c.state)
			if n := count(t, conn, `SELECT count(*) FROM afs.teams WHERE kind = 'ephemeral'`); n != 2 {
				t.Fatalf("a failed instantiate left %d teams", n)
			}
			if st := scalar[string](t, conn, "", `SELECT status FROM afs.work_orders WHERE id = $1`, wo(c.n)); st != "open" {
				t.Fatalf("work order %s", st)
			}
		})
	}
	t.Run("a template without collaboration is unchanged", func(t *testing.T) {
		team6, err := instantiate(6)
		wantOK(t, err)
		if n := count(t, conn, `SELECT count(*) FROM afs.agents WHERE team_id = $1`, team6) + count(t, conn, `SELECT count(*) FROM afs.team_collaboration WHERE team_id = $1`, team6); n != 0 {
			t.Fatalf("%d collaboration rows", n)
		}
	})
}

// queryRow returns the columns of the first row as text, NULL for null, as the superuser.
func queryRow(t *testing.T, conn *pgx.Conn, sql string, args ...any) []string {
	t.Helper()
	rows, err := conn.Query(t.Context(), sql, args...)
	wantOK(t, err)
	defer rows.Close()
	if !rows.Next() {
		wantOK(t, rows.Err())
		t.Fatalf("no row: %s", sql)
	}
	vals, err := rows.Values()
	wantOK(t, err)
	out := make([]string, len(vals))
	for i, v := range vals {
		if v == nil {
			out[i] = "NULL"
		} else {
			out[i] = fmt.Sprint(v)
		}
	}
	return out
}

// DB-US-1 for the new team-owned tables: a team sees and writes only its own rows.
func TestCollaborationRowLevelSecurity(t *testing.T) {
	conn := newCollab(t)
	withCollab(t, conn)
	mustExec(t, conn, `
INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ('`+teamA+`', '`+wrkA+`', true), ('`+teamB+`', '`+wrkB+`', true);
INSERT INTO afs.collaboration_access (bucket_start, team_id, surface, principal_kind, principal_id, outcome, requests) VALUES
 (date_trunc('hour', now()), '`+teamA+`', 'web_ui', 'anonymous', '', 'allowed', 1),
 (date_trunc('hour', now()), '`+teamB+`', 'web_ui', 'anonymous', '', 'allowed', 1);
INSERT INTO afs.collab_hostname_holds (slug, team_id, held_until) VALUES
 ('gone-a', '`+teamA+`', now() + interval '1 day'), ('gone-b', '`+teamB+`', now() + interval '1 day')`)
	asA := "SET LOCAL afs.team_ids = '" + teamA + "'"
	tables := []struct{ name, key string }{
		{"team_collaboration", "team_id"}, {"agent_collaboration", "team_id"},
		{"collaboration_access", "team_id"}, {"collab_hostname_holds", "team_id"},
	}
	for _, tb := range tables {
		t.Run(tb.name, func(t *testing.T) {
			own, err := queryAs(t, conn, "afs_app", asA, `SELECT `+tb.key+` FROM afs.`+tb.name)
			wantOK(t, err)
			if len(own) != 1 || own[0] != teamA {
				t.Fatalf("team A sees %v", own)
			}
			none, err := queryAs(t, conn, "afs_app", "", `SELECT `+tb.key+` FROM afs.`+tb.name)
			wantOK(t, err)
			if len(none) != 0 {
				t.Fatalf("no team context sees %v", none)
			}
			all, err := queryAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `SELECT `+tb.key+` FROM afs.`+tb.name)
			wantOK(t, err)
			if len(all) != 2 {
				t.Fatalf("service admin sees %v", all)
			}
			ro, err := queryAs(t, conn, "afs_readonly", "", `SELECT `+tb.key+` FROM afs.`+tb.name)
			wantOK(t, err)
			if len(ro) != 2 {
				t.Fatalf("afs_readonly sees %v", ro)
			}
		})
	}
	t.Run("team A cannot write team B's rows", func(t *testing.T) {
		for _, sql := range []string{
			`UPDATE afs.team_collaboration SET web_ui_enabled = false WHERE team_id = '` + teamB + `'`,
			`UPDATE afs.agent_collaboration SET connect = false WHERE team_id = '` + teamB + `'`,
		} {
			tag, err := execTag(t, conn, "afs_app", asA, sql)
			wantOK(t, err)
			if tag != 0 {
				t.Errorf("%s changed %d rows", sql, tag)
			}
		}
		for _, sql := range []string{
			`INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ('` + teamB + `', '` + wrkB + `', true)`,
		} {
			err := runAs(t, conn, "afs_app", asA, sql)
			if err == nil {
				t.Errorf("%s was allowed", sql)
			}
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.team_collaboration WHERE team_id = $1 AND web_ui_enabled`, teamB); n != 1 {
			t.Fatal("team B's settings changed")
		}
	})
	t.Run("holds and access counts are read-only for the app", func(t *testing.T) {
		for _, sql := range []string{
			`INSERT INTO afs.collab_hostname_holds (slug, team_id, held_until) VALUES ('x', '` + teamA + `', now())`,
			`DELETE FROM afs.collab_hostname_holds`,
			`UPDATE afs.collab_hostname_holds SET held_until = now()`,
			`DELETE FROM afs.collaboration_access`,
			`DELETE FROM afs.team_collaboration`,
			`DELETE FROM afs.agent_collaboration`,
		} {
			wantState(t, runAs(t, conn, "afs_app", asA, sql), "42501")
		}
	})
}

// execTag runs a statement under a role and returns the rows it affected.
func execTag(t *testing.T, conn *pgx.Conn, role, extra, sql string, args ...any) (int64, error) {
	t.Helper()
	var n int64
	err := pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), "SET LOCAL ROLE "+role+"; SET LOCAL afs.actor = 'usr_test'"+orEmpty(extra)); err != nil {
			return err
		}
		tag, err := tx.Exec(t.Context(), sql, args...)
		n = tag.RowsAffected()
		return err
	})
	return n, err
}

// DB-US-45, review FR-1: the settings row must point at a live collaboration agent.
func TestTeamCollaborationDeadAgent(t *testing.T) {
	conn := newCollab(t)
	collabAgents(t, conn)
	add := func() error {
		_, err := conn.Exec(t.Context(), `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamA, collA)
		return err
	}
	t.Run("deleting 55000", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleting' WHERE id = $1`, collA)
		wantState(t, add(), "55000")
	})
	t.Run("deleted 55000", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, collA)
		wantState(t, add(), "55000")
		if n := count(t, conn, `SELECT count(*) FROM afs.team_collaboration WHERE team_id = $1`, teamA); n != 0 {
			t.Fatal("a row was stored for a dead agent")
		}
	})
	live := cid("agt", 50)
	t.Run("update of agent_id to a dead agent 55000", func(t *testing.T) {
		wantOK(t, addAgent(t, conn, live, teamA, "paperclip2", "collaboration", tplCollab, "dedicated"))
		mustExec(t, conn, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamA, live)
		wantState(t, mustErr(conn, t, `UPDATE afs.team_collaboration SET agent_id = $1 WHERE team_id = $2`, collA, teamA), "55000")
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = false WHERE team_id = $1`, teamA)
	})
	t.Run("enabled and paused agents are accepted", func(t *testing.T) {
		mustExec(t, conn, `DELETE FROM afs.team_collaboration WHERE team_id = $1`, teamA)
		for _, state := range []string{"enabled", "paused"} {
			mustExec(t, conn, `UPDATE afs.agents SET state = $2 WHERE id = $1`, live, state)
			mustExec(t, conn, `INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, teamA, live)
			mustExec(t, conn, `DELETE FROM afs.team_collaboration WHERE team_id = $1`, teamA)
		}
	})
}

func mustErr(conn *pgx.Conn, t *testing.T, sql string, args ...any) error {
	t.Helper()
	_, err := conn.Exec(t.Context(), sql, args...)
	return err
}
