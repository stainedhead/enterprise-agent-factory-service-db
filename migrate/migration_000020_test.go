package migrate_test

// The migration itself (DB-41 to DB-52, NFR upgrade safety): the pre-flight for the afs_edge role, existing rows
// keeping their meaning, up/down/up, and the down migration restoring the 000019 catalog exactly.

import (
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stainedhead/enterprise-agent-factory-service-db/bootstrap"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

const firstCollaborationVersion = 20

// atBefore020 returns a database migrated to 000019 and the full migration list.
func atBefore020(t *testing.T) (*pgx.Conn, []migrate.Migration) {
	t.Helper()
	conn := connect(t)
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if len(migs) < firstCollaborationVersion || migs[firstCollaborationVersion-1].Version != firstCollaborationVersion {
		t.Fatalf("migration %d is not at its place", firstCollaborationVersion)
	}
	if n, err := migrate.Up(t.Context(), conn, migs[:firstCollaborationVersion-1]); err != nil || n != firstCollaborationVersion-1 {
		t.Fatalf("up to 19: n=%d err=%v", n, err)
	}
	return conn, migs
}

// catalog renders what a migration changes, one line per object, sorted: columns, constraints, indexes, triggers,
// functions (body, security, settings, owner-visible ACL), policies, relation and column ACLs, schema ACL and
// settings. Two equal catalogs mean the down migration put back what 000019 left.
func catalog(t *testing.T, conn *pgx.Conn) string {
	t.Helper()
	const q = `
SELECT line FROM (
  SELECT 'column ' || c.table_name || '.' || c.column_name || ' ' || c.data_type || ' ' || c.is_nullable || ' ' || coalesce(c.column_default, '') AS line
    FROM information_schema.columns c WHERE c.table_schema = 'afs'
  UNION ALL
  SELECT 'constraint ' || cl.relname || ' ' || co.conname || ' ' || pg_get_constraintdef(co.oid)
    FROM pg_constraint co JOIN pg_class cl ON cl.oid = co.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname = 'afs'
  UNION ALL
  SELECT 'index ' || indexdef FROM pg_indexes WHERE schemaname = 'afs'
  UNION ALL
  SELECT 'trigger ' || pg_get_triggerdef(tg.oid)
    FROM pg_trigger tg JOIN pg_class cl ON cl.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = cl.relnamespace
   WHERE n.nspname = 'afs' AND NOT tg.tgisinternal
  UNION ALL
  SELECT 'function ' || pg_get_functiondef(p.oid) || ' acl=' || coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(p.proacl) x), '') || ' cfg=' || coalesce(p.proconfig::text, '')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'afs'
  UNION ALL
  SELECT 'policy ' || tablename || ' ' || policyname || ' ' || cmd || ' ' || roles::text || ' ' || coalesce(qual, '') || ' ' || coalesce(with_check, '')
    FROM pg_policies WHERE schemaname = 'afs'
  UNION ALL
  SELECT 'relation ' || cl.relname || ' ' || cl.relkind::text || ' rls=' || cl.relrowsecurity::text || ' acl=' || coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(cl.relacl) x), '')
    FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname = 'afs' AND cl.relkind IN ('r', 'p', 'v', 'S')
  UNION ALL
  SELECT 'columnacl ' || cl.relname || '.' || a.attname || ' ' || (SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(a.attacl) x)
    FROM pg_attribute a JOIN pg_class cl ON cl.oid = a.attrelid JOIN pg_namespace n ON n.oid = cl.relnamespace
   WHERE n.nspname = 'afs' AND a.attacl IS NOT NULL AND NOT a.attisdropped
  UNION ALL
  SELECT 'schema ' || coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(nspacl) x), '') FROM pg_namespace WHERE nspname = 'afs'
  UNION ALL
  SELECT 'setting ' || key || ' ' || value::text FROM afs.service_settings
) x ORDER BY line`
	rows, err := conn.Query(t.Context(), q)
	if err != nil {
		t.Fatal(err)
	}
	lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(lines, "\n")
}

// firstDifference names the first differing line, so a failure is readable.
func firstDifference(a, b string) string {
	as, bs := strings.Split(a, "\n"), strings.Split(b, "\n")
	set := map[string]bool{}
	for _, l := range bs {
		set[l] = true
	}
	for _, l := range as {
		if !set[l] {
			return "only before: " + l
		}
	}
	set = map[string]bool{}
	for _, l := range as {
		set[l] = true
	}
	for _, l := range bs {
		if !set[l] {
			return "only after: " + l
		}
	}
	return "same lines, different count"
}

func TestMigration000020(t *testing.T) {
	t.Run("pre-flight refuses when afs_edge is missing", func(t *testing.T) {
		conn, migs := atBefore020(t)
		ctx := t.Context()
		// The rename and the migration run in one transaction that is always rolled back: a role is global to the
		// cluster, so it must never be renamed outside a transaction.
		tx, err := conn.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `ALTER ROLE afs_edge RENAME TO afs_edge_hidden`); err != nil {
			_ = tx.Rollback(ctx)
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx, migs[firstCollaborationVersion-1].Up)
		if rb := tx.Rollback(ctx); rb != nil {
			t.Fatal(rb)
		}
		var pg *pgconn.PgError
		if !errors.As(err, &pg) || pg.Code != "55000" || !strings.Contains(pg.Message, "bootstrap-roles") {
			t.Fatalf("want 55000 naming bootstrap-roles, got %v", err)
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM pg_roles WHERE rolname = 'afs_edge'`); n != 1 {
			t.Fatal("afs_edge is not back after the rollback")
		}
		if v, _ := migrate.Version(ctx, conn); v != firstCollaborationVersion-1 {
			t.Fatalf("version %d after a refused migration", v)
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'afs' AND c.relname = 'team_collaboration'`); n != 0 {
			t.Fatal("the refused migration left objects behind")
		}
		if n, err := migrate.Up(ctx, conn, migs[:firstCollaborationVersion]); err != nil || n != 1 {
			t.Fatalf("up with the role present: n=%d err=%v", n, err)
		}
	})

	t.Run("existing rows keep their meaning", func(t *testing.T) {
		conn, migs := atBefore020(t)
		ctx := t.Context()
		seedTeams(t, conn)
		mustExec(t, conn, `
INSERT INTO afs.identity_providers (id, name, kind, issuer_url, client_id, is_default) VALUES ('`+idpP1+`', 'Okta', 'okta', 'https://idp.example.com', 'console', true);
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+teamA+`', 'claude-sonnet');
INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest) VALUES
 ('`+tplWorker+`', 'omp', 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`');
INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES
 ('`+wrkA+`', '`+teamA+`', 'indexer', 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'claude-sonnet');
INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin) VALUES
 ('sec_01JD3Z5Y8K2M4N6P8Q0R2S0001', '`+teamA+`', 'token', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:' || afs.secret_path('`+teamA+`', NULL, NULL, 'token') || '-AbCdEf', 'managed');
INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ('`+cid("rb", 1)+`', 'team_viewer', '`+teamA+`', 'group', 'viewers');
INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at)
 VALUES ('`+cid("key", 1)+`', '`+teamA+`', 'ci', 'team_admin', 'afs_k_ab', decode(repeat('00',32),'hex'), now() + interval '30 days')`)
		before := queryRow(t, conn, `SELECT (SELECT version::text FROM afs.agents WHERE id = $1), (SELECT generation::text FROM afs.agents WHERE id = $1)`, wrkA)
		if n, err := migrate.Up(ctx, conn, migs[:firstCollaborationVersion]); err != nil || n != 1 {
			t.Fatalf("up: n=%d err=%v", n, err)
		}
		checks := map[string]string{
			`SELECT role FROM afs.agents WHERE id = '` + wrkA + `'`:                             "worker",
			`SELECT coalesce(template_id, 'NULL') FROM afs.agents WHERE id = '` + wrkA + `'`:    "NULL",
			`SELECT managed_by FROM afs.secrets WHERE name = 'token'`:                           "user",
			`SELECT origin FROM afs.secrets WHERE name = 'token'`:                               "managed",
			`SELECT capabilities::text FROM afs.agent_templates WHERE id = '` + tplWorker + `'`: "{}",
			`SELECT may_expose_collaboration::text FROM afs.teams WHERE id = '` + teamA + `'`:   "true",
			`SELECT role FROM afs.role_bindings WHERE id = '` + cid("rb", 1) + `'`:              "team_viewer",
			`SELECT role FROM afs.api_keys WHERE id = '` + cid("key", 1) + `'`:                  "team_admin",
			`SELECT count(*)::text FROM afs.team_collaboration`:                                 "0",
			`SELECT count(*)::text FROM afs.agent_collaboration`:                                "0",
			`SELECT count(*)::text FROM afs.service_settings WHERE key LIKE 'collab.%'`:         "7",
			`SELECT afs.schema_version()::text`:                                                 "20",
			`SELECT count(*)::text FROM afs.agents WHERE role <> 'worker'`:                      "0",
			`SELECT coalesce(collab_client_id, 'NULL') FROM afs.identity_providers LIMIT 1`:     "NULL",
		}
		for q, want := range checks {
			if got := scalar[string](t, conn, "", q); got != want {
				t.Errorf("%s: got %q, want %q", q, got, want)
			}
		}
		after := queryRow(t, conn, `SELECT (SELECT version::text FROM afs.agents WHERE id = $1), (SELECT generation::text FROM afs.agents WHERE id = $1)`, wrkA)
		if strings.Join(before, "|") != strings.Join(after, "|") {
			t.Errorf("the migration changed the agent's version or generation: %v -> %v", before, after)
		}
	})

	t.Run("down restores the 000019 catalog and keeps the data", func(t *testing.T) {
		conn, migs := atBefore020(t)
		ctx := t.Context()
		seedTeams(t, conn)
		mustExec(t, conn, `
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+teamA+`', 'claude-sonnet');
INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES
 ('`+wrkA+`', '`+teamA+`', 'indexer', 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'claude-sonnet')`)
		want := catalog(t, conn)
		if n, err := migrate.Up(ctx, conn, migs[:firstCollaborationVersion]); err != nil || n != 1 {
			t.Fatalf("up: n=%d err=%v", n, err)
		}
		if catalog(t, conn) == want {
			t.Fatal("the catalog did not change; the comparison proves nothing")
		}
		if n, err := migrate.Down(ctx, conn, migs, 1); err != nil || n != 1 {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		got := catalog(t, conn)
		if got != want {
			t.Fatalf("down did not restore the 000019 catalog: %s", firstDifference(want, got))
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.agents WHERE id = $1`, wrkA); n != 1 {
			t.Fatal("down lost an agent")
		}
		if n, err := migrate.Up(ctx, conn, migs[:firstCollaborationVersion]); err != nil || n != 1 {
			t.Fatalf("up again: n=%d err=%v", n, err)
		}
	})

	t.Run("down removes rows only 000020 can create", func(t *testing.T) {
		conn := newCollab(t)
		ctx := t.Context()
		migs, _ := migrate.Load(migrations.FS)
		withCollab(t, conn)
		mustExec(t, conn, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ($1, 'team_collaborator', $2, 'group', 'collab')`, cid("rb", 1), teamA)
		mustExec(t, conn, `INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at)
			VALUES ($1, $2, 'collab', 'team_collaborator', 'afs_k_ab', decode(repeat('00',32),'hex'), now() + interval '30 days')`, cid("key", 1), teamA)
		mustExec(t, conn, `INSERT INTO afs.role_bindings (id, role, team_id, subject_type, group_name) VALUES ($1, 'team_viewer', $2, 'group', 'viewers')`, cid("rb", 2), teamA)
		// 000021 sits on top of 000020: take both down.
		if n, err := migrate.Down(ctx, conn, migs, len(migs)-firstCollaborationVersion+1); err != nil || n != len(migs)-firstCollaborationVersion+1 {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		for q, want := range map[string]int{
			`SELECT count(*) FROM afs.role_bindings WHERE role = 'team_collaborator'`: 0,
			`SELECT count(*) FROM afs.role_bindings WHERE role = 'team_viewer'`:       1,
			`SELECT count(*) FROM afs.api_keys WHERE role = 'team_collaborator'`:      0,
			`SELECT count(*) FROM afs.agents WHERE team_id = '` + teamA + `'`:         2,
		} {
			if got := count(t, conn, q); got != want {
				t.Errorf("%s: %d, want %d", q, got, want)
			}
		}
	})

	t.Run("bootstrap-roles is idempotent", func(t *testing.T) {
		conn := migrated(t)
		for i := 0; i < 2; i++ {
			if _, err := conn.Exec(t.Context(), bootstrap.RolesSQL); err != nil {
				t.Fatalf("run %d: %v", i+2, err)
			}
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM pg_roles WHERE rolname = 'afs_edge' AND NOT rolcanlogin AND NOT rolsuper`); n != 1 {
			t.Fatal("afs_edge is not a login-less role")
		}
	})
}
