package migrate_test

// Migration 000022 itself (spec 261123-orchestration-and-model-access; NFR upgrade safety): existing rows keeping
// their meaning, the seeds on an upgraded and on a fresh database, up/down/up, the down migration restoring the
// 000021 catalog, and the Buzz secrets.

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

const orchestrationVersion = 22

// atBefore022 returns a database migrated to 000021 and the full migration list.
func atBefore022(t *testing.T) (*pgx.Conn, []migrate.Migration) {
	t.Helper()
	conn := connect(t)
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if len(migs) < orchestrationVersion || migs[orchestrationVersion-1].Version != orchestrationVersion {
		t.Fatalf("migration %d is not at its place", orchestrationVersion)
	}
	if n, err := migrate.Up(t.Context(), conn, migs[:orchestrationVersion-1]); err != nil || n != orchestrationVersion-1 {
		t.Fatalf("up to 21: n=%d err=%v", n, err)
	}
	return conn, migs
}

// seed21 is a 1.0.1 database: two teams, a collaboration agent and a worker in team A, models, an inference profile.
func seed21(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	seedTeams(t, conn)
	mustExec(t, conn, `
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet'), ('claude-haiku', 'Anthropic', 'Claude Haiku');
INSERT INTO afs.team_models (team_id, model_id, inference_profile_arn) VALUES
 ('`+teamA+`', 'claude-sonnet', 'arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/abc123'),
 ('`+teamA+`', 'claude-haiku', 'not-an-arn-but-stored');
INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities) VALUES
 ('`+tplCollab+`', 'paperclip', 'paperclip', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{paperclip}'),
 ('`+tplWorker+`', 'omp', 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{}');
UPDATE afs.service_settings SET value = '"collab.example.com"' WHERE key = 'collab.base_domain'`)
	wantOK(t, addAgent(t, conn, collA, teamA, "paperclip", "collaboration", tplCollab, "dedicated"))
	wantOK(t, addAgent(t, conn, wrkA, teamA, "indexer", "worker", nil, "team_shared"))
	mustExec(t, conn, `INSERT INTO afs.team_collaboration (team_id, agent_id, web_ui_enabled, rest_api_enabled) VALUES ($1, $2, true, false)`, teamA, collA)
}

func TestMigration000022(t *testing.T) {
	t.Run("existing rows keep their meaning", func(t *testing.T) {
		conn, migs := atBefore022(t)
		ctx := t.Context()
		seed21(t, conn)
		before := queryRow(t, conn, `SELECT (SELECT version::text FROM afs.agents WHERE id = $1), (SELECT version::text FROM afs.teams WHERE id = $2),
			(SELECT generation::text FROM afs.team_collaboration WHERE team_id = $2), (SELECT version::text FROM afs.team_collaboration WHERE team_id = $2)`, wrkA, teamA)
		if n, err := migrate.Up(ctx, conn, migs[:orchestrationVersion]); err != nil || n != 1 {
			t.Fatalf("up: n=%d err=%v", n, err)
		}
		checks := map[string]string{
			`SELECT role FROM afs.agents WHERE id = '` + collA + `'`:                                                        "orchestration",
			`SELECT role FROM afs.agents WHERE id = '` + wrkA + `'`:                                                         "worker",
			`SELECT capabilities::text FROM afs.agent_templates WHERE id = '` + tplCollab + `'`:                             "{orchestration,tool:paperclip}",
			`SELECT capabilities::text FROM afs.agent_templates WHERE id = '` + tplWorker + `'`:                             "{}",
			`SELECT tool FROM afs.team_collaboration WHERE team_id = '` + teamA + `'`:                                       "paperclip",
			`SELECT web_ui_exposure || '|' || web_api_exposure FROM afs.team_collaboration WHERE team_id = '` + teamA + `'`: "public|off",
			`SELECT max_collaboration_exposure FROM afs.teams WHERE id = '` + teamA + `'`:                                   "public",
			`SELECT orchestration_required::text FROM afs.teams WHERE id = '` + teamA + `'`:                                 "false",
			`SELECT model_access FROM afs.teams WHERE id = '` + teamA + `'`:                                                 "selected",
			`SELECT model_access || '|' || default_model_id FROM afs.agents WHERE id = '` + wrkA + `'`:                      "all|claude-sonnet",
			`SELECT count(*)::text FROM afs.team_inference_profiles`:                                                        "1",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'orchestration.public_base_domain'`:                "collab.example.com",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'orchestration.default_limit'`:                     "public",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'orchestration.default_web_ui_exposure'`:           "public",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'orchestration.default_web_api_exposure'`:          "off",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'models.service_access'`:                           "selected",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'models.default_team_access'`:                      "all",
			`SELECT value #>> '{paperclip,templateId}' FROM afs.service_settings WHERE key = 'orchestration.tools'`:         tplCollab,
			`SELECT value #>> '{paperclip,imageRepository}' FROM afs.service_settings WHERE key = 'orchestration.tools'`:    "ghcr.io/x/img",
			`SELECT value #>> '{buzz,enabled}' FROM afs.service_settings WHERE key = 'orchestration.tools'`:                 "false",
			`SELECT afs.schema_version()::text`:                                                                             "22",
			`SELECT count(*)::text FROM afs.agents WHERE role = 'collaboration'`:                                            "0",
		}
		for q, want := range checks {
			if got := scalar[string](t, conn, "", q); got != want {
				t.Errorf("%s: got %q, want %q", q, got, want)
			}
		}
		after := queryRow(t, conn, `SELECT (SELECT version::text FROM afs.agents WHERE id = $1), (SELECT version::text FROM afs.teams WHERE id = $2),
			(SELECT generation::text FROM afs.team_collaboration WHERE team_id = $2), (SELECT version::text FROM afs.team_collaboration WHERE team_id = $2)`, wrkA, teamA)
		if strings.Join(before, "|") != strings.Join(after, "|") {
			t.Errorf("the migration changed versions or the generation: %v -> %v", before, after)
		}
		// The 1.0.1 setting names stay readable.
		if got := scalar[string](t, conn, "", `SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'collab.base_domain'`); got != "collab.example.com" {
			t.Errorf("collab.base_domain %q", got)
		}
	})

	t.Run("a fresh database has the closed defaults", func(t *testing.T) {
		conn := migratedStrict(t)
		for q, want := range map[string]string{
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'orchestration.default_limit'`:                                     "private",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'orchestration.default_web_ui_exposure'`:                           "private",
			`SELECT value::text FROM afs.service_settings WHERE key = 'orchestration.public_base_domain'`:                                   "null",
			`SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'models.service_access'`:                                           "all",
			`SELECT value::text FROM afs.service_settings WHERE key = 'orchestration.default_volume_gib'`:                                   "20",
			`SELECT value #>> '{paperclip,default}' FROM afs.service_settings WHERE key = 'orchestration.tools'`:                            "true",
			`SELECT value::text FROM afs.service_settings WHERE key = 'orchestration.tools' AND value #> '{paperclip,templateId}' = 'null'`: scalar[string](t, conn, "", `SELECT value::text FROM afs.service_settings WHERE key = 'orchestration.tools'`),
		} {
			if got := scalar[string](t, conn, "", q); got != want {
				t.Errorf("%s: got %q, want %q", q, got, want)
			}
		}
	})

	t.Run("down restores the 000021 catalog and keeps the data", func(t *testing.T) {
		conn, migs := atBefore022(t)
		ctx := t.Context()
		seed21(t, conn)
		want := catalog(t, conn)
		if n, err := migrate.Up(ctx, conn, migs[:orchestrationVersion]); err != nil || n != 1 {
			t.Fatalf("up: n=%d err=%v", n, err)
		}
		if catalog(t, conn) == want {
			t.Fatal("the catalog did not change; the comparison proves nothing")
		}
		if n, err := migrate.Down(ctx, conn, migs, 1); err != nil || n != 1 {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		if got := catalog(t, conn); got != want {
			t.Fatalf("down did not restore the 000021 catalog: %s", firstDifference(want, got))
		}
		for q, wantv := range map[string]string{
			`SELECT role FROM afs.agents WHERE id = '` + collA + `'`:                                  "collaboration",
			`SELECT capabilities::text FROM afs.agent_templates WHERE id = '` + tplCollab + `'`:       "{paperclip}",
			`SELECT web_ui_enabled::text FROM afs.team_collaboration WHERE team_id = '` + teamA + `'`: "true",
			`SELECT count(*)::text FROM afs.team_models WHERE team_id = '` + teamA + `'`:              "2",
		} {
			if got := scalar[string](t, conn, "", q); got != wantv {
				t.Errorf("%s: got %q, want %q", q, got, wantv)
			}
		}
		if n, err := migrate.Up(ctx, conn, migs[:orchestrationVersion]); err != nil || n != 1 {
			t.Fatalf("up again: n=%d err=%v", n, err)
		}
	})

	t.Run("down after use: a team on Buzz is taken back to the Paperclip schema", func(t *testing.T) {
		conn := orchWorld(t)
		migs, _ := migrate.Load(migrations.FS)
		enableBuzz(t, conn)
		orchTeam(t, conn, 1, "public")
		orchTeamTool(t, conn, 2, "public", "buzz")
		if n, err := migrate.Down(t.Context(), conn, migs, 1); err != nil || n != 1 {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.agents WHERE role = 'collaboration'`); n != 2 {
			t.Errorf("%d collaboration agents after down", n)
		}
		if n, err := migrate.Up(t.Context(), conn, migs); err != nil || n != 1 {
			t.Fatalf("up again: n=%d err=%v", n, err)
		}
	})
}

// DB-US-59: the capability vocabulary of an agent template.
func TestOrchestrationCapabilities(t *testing.T) {
	conn := migratedStrict(t)
	seq := new(int)
	ins := func(caps string) error {
		*seq++
		_, err := conn.Exec(t.Context(), `INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities)
			VALUES ($1, $2, 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`', $3::text[])`, cid("tpl", 100+*seq), fmt.Sprintf("cap-%d", *seq), caps)
		return err
	}
	t.Run("accepted", func(t *testing.T) {
		for _, c := range []string{"{}", "{orchestration,tool:paperclip}", "{orchestration,tool:buzz}"} {
			wantOK(t, ins(c))
		}
	})
	t.Run("refused 23514", func(t *testing.T) {
		for _, c := range []string{"{orchestration}", "{tool:paperclip}", "{orchestration,tool:paperclip,tool:buzz}", "{tool:other,orchestration}", "{orchestration,orchestration,tool:buzz}"} {
			wantState(t, ins(c), "23514")
		}
	})
	t.Run("the legacy paperclip capability is rewritten", func(t *testing.T) {
		wantOK(t, ins("{paperclip}"))
		if got := scalar[string](t, conn, "", `SELECT capabilities::text FROM afs.agent_templates WHERE name = $1`, fmt.Sprintf("cap-%d", *seq)); got != "{orchestration,tool:paperclip}" {
			t.Errorf("capabilities %s", got)
		}
	})
	t.Run("a template in use by a live orchestration agent keeps its capability 55000", func(t *testing.T) {
		w := orchWorld(t)
		orchTeam(t, w, 1, "public")
		_, err := w.Exec(t.Context(), `UPDATE afs.agent_templates SET capabilities = '{orchestration,tool:buzz}' WHERE id = $1`, tplOrch)
		wantState(t, err, "55000")
		_, err = w.Exec(t.Context(), `UPDATE afs.agent_templates SET capabilities = '{}' WHERE id = $1`, tplOrch)
		wantState(t, err, "55000")
	})
}

// DB-US-59: Buzz keeps its keys under the reconciler's reserved names, like Paperclip.
func TestBuzzManagedSecrets(t *testing.T) {
	conn := orchWorld(t)
	ctx := t.Context()
	enableBuzz(t, conn)
	team, agent := orchTeamTool(t, conn, 1, "public", "buzz")
	worker := cid("agt", 31)
	wantOK(t, addAgent(t, conn, worker, team, "indexer", "worker", nil, "team_shared"))
	mustExec(t, conn, `INSERT INTO afs.agent_collaboration (team_id, agent_id, connect) VALUES ($1, $2, true)`, team, worker)
	arn := func(a, name string) string {
		return scalar[string](t, conn, "", `SELECT 'arn:aws:secretsmanager:us-east-1:111122223333:secret:' || afs.secret_path($1, $2, $3) || '-AbCdEf'`, team, a, name)
	}
	t.Run("the reconciler records a buzz secret below the agent's buzz path", func(t *testing.T) {
		a := arn(agent, "buzz/signing-key")
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, managed_by, agent_id)
			VALUES ($1, $2, 'x', $3, 'registered', 'buzz', $4)`, cid("sec", 1), team, a, agent))
		if got := scalar[string](t, conn, "", `SELECT name FROM afs.secrets WHERE id = $1`, cid("sec", 1)); got != "buzz-signing-key" {
			t.Errorf("derived name %q", got)
		}
	})
	t.Run("a path outside the prefix 23514", func(t *testing.T) {
		err := runAs(t, conn, "afs_reconciler", "", `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, managed_by, agent_id)
			VALUES ($1, $2, 'x', $3, 'registered', 'buzz', $4)`, cid("sec", 2), team, arn(agent, "signing-key"), agent)
		wantState(t, err, "23514")
		if !hasConstraint(err, "secrets_buzz_prefix") {
			t.Errorf("wrong constraint %v", err)
		}
	})
	t.Run("afs_app cannot write buzz secrets, the reconciler cannot write user secrets", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, managed_by, agent_id)
			VALUES ($1, $2, 'x', $3, 'registered', 'buzz', $4)`, cid("sec", 3), team, arn(agent, "buzz/other"), agent), "42501")
		wantState(t, runAs(t, conn, "afs_reconciler", "", `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, managed_by)
			VALUES ($1, $2, 'mine', $3, 'managed', 'user')`, cid("sec", 4), team, scalar[string](t, conn, "", `SELECT 'arn:aws:secretsmanager:us-east-1:111122223333:secret:' || afs.secret_path($1, NULL, NULL, 'mine') || '-AbCdEf'`, team)), "42501")
	})
	t.Run("a buzz secret is registered, not managed 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.secrets (id, team_id, name, secrets_manager_arn, origin, managed_by, agent_id)
			VALUES ($1, $2, 'y', $3, 'managed', 'buzz', $4)`, cid("sec", 5), team, arn(agent, "buzz/y"), agent)
		wantState(t, err, "23514")
	})
	t.Run("the agent key of a Buzz team has Buzz's name and target", func(t *testing.T) {
		var id string
		wantOK(t, in(t, conn, "SET LOCAL ROLE afs_reconciler; SET LOCAL afs.actor = 'system:afs-reconciler'", func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT afs.record_collab_agent_key($1, $2, $3)`, team, worker, arn(worker, "buzz-agent-private-key")).Scan(&id)
		}))
		if got := queryRow(t, conn, `SELECT s.name, s.managed_by, b.target FROM afs.secrets s JOIN afs.agent_secret_bindings b ON b.secret_id = s.id WHERE s.id = $1`, id); strings.Join(got, "|") != "buzz-agent-private-key|afs|BUZZ_PRIVATE_KEY" {
			t.Errorf("key %v", got)
		}
		var removed bool
		wantOK(t, in(t, conn, "SET LOCAL ROLE afs_reconciler; SET LOCAL afs.actor = 'system:afs-reconciler'", func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT afs.remove_collab_agent_key($1, $2)`, team, worker).Scan(&removed)
		}))
		if !removed || count(t, conn, `SELECT count(*) FROM afs.secrets WHERE id = $1`, id) != 0 {
			t.Error("the buzz key was not removed")
		}
	})
	t.Run("a work order secret on a Buzz team's agent is refused: Buzz has no boot secrets", func(t *testing.T) {
		if n := count(t, conn, `SELECT count(*) FROM afs.secrets WHERE agent_id = $1 AND managed_by = 'afs'`, agent); n != 0 {
			t.Errorf("%d afs secrets on a fresh Buzz agent", n)
		}
	})
}
