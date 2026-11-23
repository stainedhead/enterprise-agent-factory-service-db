package migrate_test

// Migration 000022, team orchestration agent and model access (spec 261123-orchestration-and-model-access; -db PRD
// DB-US-58 to DB-US-61). Each test names the story it proves; subtests carry the names the PRD's "Proven by" lines use.

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// hasConstraint reports whether err is a PostgreSQL error raised for the named constraint.
func hasConstraint(err error, name string) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.ConstraintName == name
}

var (
	tplOrch     = cid("tpl", 40) // Paperclip orchestration template
	tplOrchBuzz = cid("tpl", 41) // Buzz orchestration template
)

// seedOrchestrationRuntime gives Paperclip a template and an image repository in orchestration.tools, so that
// create_orchestration_agent and instantiate_work_order_team have a runtime to start. A fresh database has none.
func seedOrchestrationRuntime(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	mustExec(t, conn, `
INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities, default_resources) VALUES
 ('`+tplOrch+`', 'orchestration-paperclip', 'paperclip', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{orchestration,tool:paperclip}', '{"cpu": "2", "memory": "8Gi"}')`)
	mustExec(t, conn, `UPDATE afs.service_settings
		SET value = jsonb_set(jsonb_set(value, '{paperclip,templateId}', to_jsonb($1::text)), '{paperclip,imageRepository}', '"ghcr.io/x/paperclip"')
		WHERE key = 'orchestration.tools'`, tplOrch)
}

const adminSess = "SET LOCAL ROLE afs_app; SET LOCAL afs.service_admin = 'on'; SET LOCAL afs.actor = 'usr_admin'"

// orchWorld is a database exactly as the migrations leave it, with three priced models and a Paperclip runtime.
func orchWorld(t *testing.T) *pgx.Conn {
	t.Helper()
	conn := migratedStrict(t)
	mustExec(t, conn, `
INSERT INTO afs.models (id, provider, display_name) VALUES
 ('claude-sonnet', 'Anthropic', 'Claude Sonnet'), ('claude-haiku', 'Anthropic', 'Claude Haiku'), ('claude-opus', 'Anthropic', 'Claude Opus');
INSERT INTO afs.model_prices (model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok) VALUES
 ('claude-sonnet', now() - interval '1 day', 3, 15), ('claude-haiku', now() - interval '1 day', 1, 5), ('claude-opus', now() - interval '1 day', 15, 75)`)
	seedOrchestrationRuntime(t, conn)
	return conn
}

// createArgs are the arguments of afs.create_orchestration_agent after the team and the agent id.
const createDefaults = `NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL`

// orchTeam creates team n with its orchestration agent in one transaction, as CreateTeam does.
func orchTeam(t *testing.T, conn *pgx.Conn, n int, limit string) (team, agent string) {
	t.Helper()
	team, agent = cid("team", n), cid("agt", n)
	err := in(t, conn, adminSess, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd, max_collaboration_exposure)
			VALUES ($1, $2, $2, 'CC1', 'o@example.com', 100, $3)`, team, fmt.Sprintf("team-%d", n), limit); err != nil {
			return err
		}
		_, err := tx.Exec(t.Context(), `SELECT afs.create_orchestration_agent($1, $2, `+createDefaults+`)`, team, agent)
		return err
	})
	wantOK(t, err)
	return team, agent
}

func TestOrchestrationAgent(t *testing.T) {
	conn := orchWorld(t)
	ctx := t.Context()
	teamX, orchX := orchTeam(t, conn, 1, "public")
	_, orchY := orchTeam(t, conn, 2, "public")
	addWorker := func(id, team, name string, tpl any) error {
		return addAgent(t, conn, id, team, name, "worker", tpl, "team_shared")
	}

	t.Run("second live orchestration agent 23505", func(t *testing.T) {
		err := addAgent(t, conn, cid("agt", 11), teamX, "second", "orchestration", tplOrch, "dedicated")
		wantState(t, err, "23505")
		if !hasConstraint(err, "agents_team_orchestration_uq") {
			t.Errorf("wrong constraint: %v", err)
		}
	})
	t.Run("team without one at commit 23514", func(t *testing.T) {
		err := in(t, conn, adminSess, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd)
				VALUES ($1, 'bare', 'Bare', 'CC1', 'o@example.com', 10)`, cid("team", 9))
			return err
		})
		wantState(t, err, "23514")
		if !hasConstraint(err, "teams_orchestration_required") {
			t.Errorf("wrong constraint: %v", err)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.teams WHERE id = $1`, cid("team", 9)); n != 0 {
			t.Error("the team was committed")
		}
	})
	t.Run("a team that is already deleting needs none at commit", func(t *testing.T) {
		wantOK(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd, state)
				VALUES ($1, 'going', 'Going', 'CC1', 'o@example.com', 10, 'deleting')`, cid("team", 10))
			return err
		}))
	})
	t.Run("direct afs_app insert of role orchestration 23514", func(t *testing.T) {
		err := runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, role, template_id, iam_identity)
			VALUES ($1, $2, 'other', 'paperclip', 'ghcr.io/x/paperclip@`+collabDigest+`', 'claude-sonnet', 'orchestration', $3, 'dedicated')`, cid("agt", 12), cid("team", 10), tplOrch)
		wantState(t, err, "23514")
		if !hasConstraint(err, "agents_role_reserved") {
			t.Errorf("wrong constraint: %v", err)
		}
	})
	t.Run("role orchestration needs template, identity and snapshots", func(t *testing.T) {
		teamZ := cid("team", 10)
		wantState(t, addAgent(t, conn, cid("agt", 13), teamZ, "a-one", "orchestration", nil, "dedicated"), "23514")
		wantState(t, addAgent(t, conn, cid("agt", 13), teamZ, "a-one", "orchestration", tplOrch, "team_shared"), "23514")
		_, err := conn.Exec(ctx, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, role, template_id, iam_identity, snapshot_schedule)
			VALUES ($1, $2, 'a-two', 'paperclip', 'ghcr.io/x/paperclip@`+collabDigest+`', 'claude-sonnet', 'orchestration', $3, 'dedicated', 'off')`, cid("agt", 14), teamZ, tplOrch)
		wantState(t, err, "23514")
		mustExec(t, conn, `INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest) VALUES ($1, 'plain', 'omp', ARRAY['`+collabDigest+`'], '`+collabDigest+`')`, cid("tpl", 42))
		wantState(t, addAgent(t, conn, cid("agt", 15), teamZ, "a-three", "orchestration", cid("tpl", 42), "dedicated"), "23514")
		wantState(t, addAgent(t, conn, cid("agt", 16), teamZ, "a-four", "worker", tplOrch, "team_shared"), "23514")
	})
	t.Run("role is immutable 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET role = 'worker' WHERE id = $1`, orchX)
		wantState(t, err, "23514")
	})
	t.Run("delete guard: a live team refused, a deleting team allowed", func(t *testing.T) {
		for _, set := range []string{`state = 'deleting'`, `state = 'deleted', deleted_at = now()`, `deleted_at = now()`} {
			_, err := conn.Exec(ctx, `UPDATE afs.agents SET `+set+` WHERE id = $1`, orchY)
			wantState(t, err, "23514")
			if !hasConstraint(err, "agents_orchestration_required") {
				t.Errorf("wrong constraint: %v", err)
			}
		}
		mustExec(t, conn, `UPDATE afs.teams SET state = 'deleting' WHERE id = $1`, cid("team", 2))
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleting' WHERE id = $1`, orchY)
		mustExec(t, conn, `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, orchY)
		if n := count(t, conn, `SELECT count(*) FROM afs.team_collaboration WHERE team_id = $1`, cid("team", 2)); n != 0 {
			t.Error("the route row stayed after the orchestration agent was deleted")
		}
	})
	t.Run("reserved name for agents and pools", func(t *testing.T) {
		err := addWorker(cid("agt", 17), teamX, "orchestrator", nil)
		wantState(t, err, "23514")
		if !hasConstraint(err, "agents_name_reserved") {
			t.Errorf("wrong constraint: %v", err)
		}
		swarm := cid("team", 30)
		wantOK(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule)
				VALUES ($1, 'swarm-o', 'Swarm', 'ephemeral', 'CC1', 'o@example.com', 100, now() + interval '3 days', 'at_expiry')`, swarm); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust) VALUES ($1, $2, 'lifetime', 50, 'block')`, cid("bud", 30), swarm); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, `+createDefaults+`)`, swarm, cid("agt", 30))
			return err
		}))
		_, err = conn.Exec(ctx, `INSERT INTO afs.agent_pools (id, team_id, name, template, image, model_id) VALUES ($1, $2, 'orchestrator', 'omp', 'ghcr.io/x/omp@`+collabDigest+`', 'claude-sonnet')`, cid("pool", 1), swarm)
		wantState(t, err, "23514")
		if !hasConstraint(err, "agent_pools_name_reserved") {
			t.Errorf("wrong constraint: %v", err)
		}
		// The creation function names it orchestrator, so the reserved name is the orchestration agent's own.
		if got := scalar[string](t, conn, "", `SELECT name FROM afs.agents WHERE id = $1`, orchX); got != "orchestrator" {
			t.Errorf("orchestration agent named %q", got)
		}
	})
	t.Run("a worker of another team is unaffected", func(t *testing.T) {
		wantOK(t, addWorker(cid("agt", 18), teamX, "indexer", nil))
	})
	t.Run("no function source names the collaboration role", func(t *testing.T) {
		rows, err := conn.Query(ctx, `SELECT p.proname FROM pg_proc p WHERE p.pronamespace = 'afs'::regnamespace
			AND p.prosrc ~ $$role\s*(<>|=|IN)\s*(\(\s*)?'collaboration'$$`)
		wantOK(t, err)
		names, err := pgx.CollectRows(rows, pgx.RowTo[string])
		wantOK(t, err)
		if len(names) != 0 {
			t.Errorf("functions still naming the collaboration role: %v", names)
		}
	})
}

func TestCreateOrchestrationAgent(t *testing.T) {
	conn := orchWorld(t)
	ctx := t.Context()
	insertTeam := func(tx pgx.Tx, n int, limit string) (string, string) {
		team, agent := cid("team", n), cid("agt", n)
		if _, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd, max_collaboration_exposure)
			VALUES ($1, $2, $2, 'CC1', 'o@example.com', 100, $3)`, team, fmt.Sprintf("team-%d", n), limit); err != nil {
			t.Fatal(err)
		}
		return team, agent
	}
	create := func(n int, limit, sess, args string) error {
		return in(t, conn, sess, func(tx pgx.Tx) error {
			team, agent := insertTeam(tx, n, limit)
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, `+args+`)`, team, agent)
			return err
		})
	}

	t.Run("happy path writes agent, team_collaboration, agent_models, audit and both outbox rows", func(t *testing.T) {
		wantOK(t, create(1, "public", adminSess, `NULL, 'paperclip', 'public', 'off', 'manual', 'selected', ARRAY['claude-sonnet','claude-haiku'], 'claude-haiku', NULL, NULL, NULL`))
		team, agent := cid("team", 1), cid("agt", 1)
		checks := map[string]string{
			`SELECT role || '|' || name || '|' || iam_identity || '|' || snapshot_schedule || '|' || snapshot_retain_count || '|' || storage_on_delete || '|' || storage_size_gib FROM afs.agents WHERE id = '` + agent + `'`: "orchestration|orchestrator|dedicated|daily|14|snapshot_then_delete|20",
			`SELECT image || '|' || template || '|' || template_id FROM afs.agents WHERE id = '` + agent + `'`:                                                                                                                "ghcr.io/x/paperclip@" + collabDigest + "|paperclip|" + tplOrch,
			`SELECT resources::text FROM afs.agents WHERE id = '` + agent + `'`:                                                                                                                                               `{"cpu": "1", "memory": "4Gi"}`,
			`SELECT model_access || '|' || default_model_id || '|' || model_id FROM afs.agents WHERE id = '` + agent + `'`:                                                                                                    "selected|claude-haiku|claude-haiku",
			`SELECT string_agg(model_id, ',' ORDER BY model_id) FROM afs.agent_models WHERE agent_id = '` + agent + `'`:                                                                                                       "claude-haiku,claude-sonnet",
			`SELECT tool || '|' || web_ui_exposure || '|' || web_api_exposure || '|' || registration_mode || '|' || web_ui_enabled || '|' || rest_api_enabled FROM afs.team_collaboration WHERE team_id = '` + team + `'`:     "paperclip|public|off|manual|true|false",
			`SELECT orchestration_required::text FROM afs.teams WHERE id = '` + team + `'`:                                                                                                                                    "true",
			`SELECT count(*)::text FROM afs.audit_log WHERE action = 'CreateOrchestrationAgent' AND resource_id = '` + agent + `' AND actor_id = 'usr_admin'`:                                                                 "1",
			`SELECT string_agg(event_type, ',' ORDER BY event_type) FROM afs.outbox_events WHERE team_id = '` + team + `' AND event_type IN ('agent.created', 'orchestration.created')`:                                       "agent.created,orchestration.created",
			`SELECT count(*)::text FROM afs.outbox_events WHERE team_id = '` + team + `' AND payload ? 'id' AND payload ? 'occurredAt' AND payload ? 'data'`:                                                                  "2",
		}
		for q, want := range checks {
			if got := scalar[string](t, conn, "", q); got != want {
				t.Errorf("%s\n got %q, want %q", q, got, want)
			}
		}
	})
	t.Run("defaults: tool, levels capped by the limit, models all, resources and volume from settings", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"private"' WHERE key = 'orchestration.default_web_ui_exposure'`)
		wantOK(t, create(2, "private", adminSess, createDefaults2))
		got := scalar[string](t, conn, "", `SELECT c.tool || '|' || c.web_ui_exposure || '|' || c.web_api_exposure || '|' || c.registration_mode || '|' || a.model_access || '|' || a.default_model_id || '|' || a.resources::text
			FROM afs.team_collaboration c JOIN afs.agents a ON a.team_id = c.team_id WHERE c.team_id = $1`, cid("team", 2))
		if got != `paperclip|private|off|manual|all|claude-sonnet|{"cpu": "1", "memory": "4Gi"}` {
			t.Errorf("defaults: %s", got)
		}
		// Default level above a team's limit is capped to it.
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"public"' WHERE key = 'orchestration.default_limit'`)
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"public"' WHERE key = 'orchestration.default_web_ui_exposure'`)
		wantOK(t, create(3, "private", adminSess, createDefaults2))
		if got := scalar[string](t, conn, "", `SELECT web_ui_exposure FROM afs.team_collaboration WHERE team_id = $1`, cid("team", 3)); got != "private" {
			t.Errorf("default level not capped by the team limit: %s", got)
		}
	})
	t.Run("an explicit level above the limit is refused", func(t *testing.T) {
		err := create(4, "private", adminSess, `NULL, 'paperclip', 'public', NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL`)
		wantState(t, err, "23514")
		if !hasConstraint(err, "team_collaboration_exposure_limit") {
			t.Errorf("wrong constraint: %v", err)
		}
	})
	t.Run("disabled tool 23514", func(t *testing.T) {
		err := create(5, "public", adminSess, `NULL, 'buzz', NULL, NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL`)
		wantState(t, err, "23514")
		if !hasConstraint(err, "orchestration_tool_not_enabled") {
			t.Errorf("wrong constraint: %v", err)
		}
	})
	t.Run("unset runtime 55000", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = jsonb_set(jsonb_set(value, '{buzz,enabled}', 'true'), '{paperclip,imageRepository}', 'null') WHERE key = 'orchestration.tools'`)
		err := create(6, "public", adminSess, createDefaults2)
		wantState(t, err, "55000")
		if !hasConstraint(err, "orchestration_runtime_unset") {
			t.Errorf("wrong constraint: %v", err)
		}
		err = create(6, "public", adminSess, `NULL, 'buzz', NULL, NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL`)
		wantState(t, err, "55000")
		if n := count(t, conn, `SELECT count(*) FROM afs.teams WHERE id = $1`, cid("team", 6)); n != 0 {
			t.Error("a failed creation left the team behind")
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = jsonb_set(jsonb_set(value, '{buzz,enabled}', 'false'), '{paperclip,imageRepository}', '"ghcr.io/x/paperclip"') WHERE key = 'orchestration.tools'`)
	})
	t.Run("a non-admin caller 42501", func(t *testing.T) {
		err := create(7, "public", "SET LOCAL ROLE afs_app; SET LOCAL afs.service_admin = 'off'; SET LOCAL afs.team_ids = '"+cid("team", 7)+"'", createDefaults2)
		// The team insert is refused by row-level security for a non-admin first; the function check is proven below.
		if sqlState(err) != "42501" {
			t.Fatalf("got %v", err)
		}
		wantState(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd) VALUES ($1, 'nonadmin', 'N', 'CC1', 'o@example.com', 10)`, cid("team", 8)); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `SET LOCAL afs.service_admin = 'off'; SET LOCAL afs.team_ids = '`+cid("team", 8)+`'`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, `+createDefaults2+`)`, cid("team", 8), cid("agt", 8))
			return err
		}), "42501")
	})
	t.Run("only afs_app may execute it", func(t *testing.T) {
		for _, role := range []string{"afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly", "afs_edge"} {
			_, err := queryAs(t, conn, role, "", `SELECT afs.create_orchestration_agent('team_x', 'agt_x', `+createDefaults2+`)`)
			wantState(t, err, "42501")
		}
	})
	t.Run("a deleting team 55000, a bad agent id 22023, a second agent 23505", func(t *testing.T) {
		wantState(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd, state) VALUES ($1, 'dying', 'D', 'CC1', 'o@example.com', 10, 'deleting')`, cid("team", 20)); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, `+createDefaults2+`)`, cid("team", 20), cid("agt", 20))
			return err
		}), "55000")
		wantState(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, 'agt_bad', `+createDefaults2+`)`, cid("team", 1))
			return err
		}), "22023")
		err := in(t, conn, adminSess, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, 'orchestrator-two', NULL, NULL, NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL)`, cid("team", 1), cid("agt", 21))
			return err
		})
		wantState(t, err, "23505")
		if !hasConstraint(err, "agents_team_orchestration_uq") {
			t.Errorf("wrong constraint: %v", err)
		}
	})
	t.Run("no default model 23514", func(t *testing.T) {
		wantState(t, create(21, "public", adminSess, `NULL, NULL, NULL, NULL, NULL, 'all', NULL, NULL, NULL, NULL, NULL`), "23514")
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"claude-haiku"' WHERE key = 'models.default_model_id'`)
		wantOK(t, create(21, "public", adminSess, `NULL, NULL, NULL, NULL, NULL, 'all', NULL, NULL, NULL, NULL, NULL`))
		if got := scalar[string](t, conn, "", `SELECT default_model_id FROM afs.agents WHERE id = $1`, cid("agt", 21)); got != "claude-haiku" {
			t.Errorf("default model from the setting: %s", got)
		}
	})
}

// createDefaults2 is createDefaults after the team and agent id: name, tool, two levels, registration, access, ids,
// default model, resources, volume, on-delete.
const createDefaults2 = `NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL`
