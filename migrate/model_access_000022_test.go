package migrate_test

// Migration 000022, model access (spec 261123-orchestration-and-model-access; -db PRD DB-US-61).

import (
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// workerWithModels creates a worker agent with the given access and models in one transaction, as the API does.
func workerWithModels(t *testing.T, conn *pgx.Conn, id, team, name, access, def string, models ...string) error {
	t.Helper()
	return pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, default_model_id, model_access, iam_identity)
			VALUES ($1, $2, $3, 'omp', 'ghcr.io/x/img@`+collabDigest+`', $4, $4, $5, 'team_shared')`, id, team, name, def, access); err != nil {
			return err
		}
		for _, m := range models {
			if _, err := tx.Exec(t.Context(), `INSERT INTO afs.agent_models (team_id, agent_id, model_id) VALUES ($1, $2, $3)`, team, id, m); err != nil {
				return err
			}
		}
		return nil
	})
}

func effective(t *testing.T, conn *pgx.Conn, subject string) string {
	t.Helper()
	rows, err := conn.Query(t.Context(), `SELECT model_id || CASE WHEN is_default THEN '*' ELSE '' END FROM afs.effective_agent_models WHERE subject_id = $1 ORDER BY model_id`, subject)
	wantOK(t, err)
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	wantOK(t, err)
	return strings.Join(got, ",")
}

func admission(t *testing.T, conn *pgx.Conn, kind, subject string) string {
	t.Helper()
	rows, err := conn.Query(t.Context(), `SELECT model_id || '=' || coalesce(reason, 'ok') FROM afs.model_admission($1, $2) ORDER BY model_id`, kind, subject)
	wantOK(t, err)
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	wantOK(t, err)
	return strings.Join(got, ",")
}

// DB-US-61.
func TestModelAccess(t *testing.T) {
	conn := orchWorld(t)
	ctx := t.Context()
	team, orch := orchTeam(t, conn, 1, "public")
	other, _ := orchTeam(t, conn, 2, "public")
	w1, w2, w3 := cid("agt", 51), cid("agt", 52), cid("agt", 53)

	t.Run("defaults are open: every priced model", func(t *testing.T) {
		if got := effective(t, conn, orch); got != "claude-haiku,claude-opus,claude-sonnet*" {
			t.Errorf("effective %s", got)
		}
		if got := admission(t, conn, "agent", orch); got != "claude-haiku=ok,claude-opus=ok,claude-sonnet=ok" {
			t.Errorf("admission %s", got)
		}
	})
	t.Run("an agent narrows to one, then to several", func(t *testing.T) {
		wantOK(t, workerWithModels(t, conn, w1, team, "one", "selected", "claude-haiku", "claude-haiku"))
		if got := effective(t, conn, w1); got != "claude-haiku*" {
			t.Errorf("one: %s", got)
		}
		wantOK(t, workerWithModels(t, conn, w2, team, "two", "selected", "claude-sonnet", "claude-sonnet", "claude-opus"))
		if got := effective(t, conn, w2); got != "claude-opus,claude-sonnet*" {
			t.Errorf("two: %s", got)
		}
		if got := admission(t, conn, "agent", w1); got != "claude-haiku=ok,claude-opus=model_not_enabled_for_agent,claude-sonnet=model_not_enabled_for_agent" {
			t.Errorf("admission %s", got)
		}
	})
	t.Run("selected with no models 23514", func(t *testing.T) {
		err := workerWithModels(t, conn, cid("agt", 60), team, "empty", "selected", "claude-haiku")
		wantState(t, err, "23514")
		if !hasConstraint(err, "agents_models_selection_nonempty") {
			t.Errorf("wrong constraint %v", err)
		}
	})
	t.Run("default outside the selection 23514", func(t *testing.T) {
		err := workerWithModels(t, conn, cid("agt", 61), team, "outside", "selected", "claude-opus", "claude-haiku")
		wantState(t, err, "23514")
		if !hasConstraint(err, "agents_default_model_allowed") {
			t.Errorf("wrong constraint %v", err)
		}
		// Changing the default of an existing agent is checked too.
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET default_model_id = 'claude-sonnet' WHERE id = $1`, w1)
		wantState(t, err, "23514")
		// model_id follows default_model_id until 2.0.0.
		mustExec(t, conn, `UPDATE afs.agents SET default_model_id = 'claude-opus' WHERE id = $1`, w2)
		if got := scalar[string](t, conn, "", `SELECT model_id FROM afs.agents WHERE id = $1`, w2); got != "claude-opus" {
			t.Errorf("model_id %s", got)
		}
		mustExec(t, conn, `UPDATE afs.agents SET model_id = 'claude-sonnet' WHERE id = $1`, w2)
		if got := scalar[string](t, conn, "", `SELECT default_model_id FROM afs.agents WHERE id = $1`, w2); got != "claude-sonnet" {
			t.Errorf("default_model_id %s", got)
		}
	})
	t.Run("removing the default from the selection, or all models, 23514", func(t *testing.T) {
		_, err := conn.Exec(ctx, `DELETE FROM afs.agent_models WHERE agent_id = $1 AND model_id = 'claude-sonnet'`, w2)
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `DELETE FROM afs.agent_models WHERE agent_id = $1`, w1)
		wantState(t, err, "23514")
		// Replacing the selection in one transaction is fine.
		wantOK(t, pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `DELETE FROM afs.agent_models WHERE agent_id = $1`, w1); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO afs.agent_models (team_id, agent_id, model_id) VALUES ($1, $2, 'claude-haiku')`, team, w1)
			return err
		}))
	})
	t.Run("a price is required to be callable", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-new', 'Anthropic', 'New')`)
		if got := effective(t, conn, orch); strings.Contains(got, "claude-new") {
			t.Errorf("an unpriced model is callable: %s", got)
		}
		if got := admission(t, conn, "agent", orch); !strings.Contains(got, "claude-new=model_not_priced") {
			t.Errorf("admission %s", got)
		}
		mustExec(t, conn, `INSERT INTO afs.model_prices (model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok) VALUES ('claude-new', now() + interval '1 day', 1, 1)`)
		if got := admission(t, conn, "agent", orch); !strings.Contains(got, "claude-new=model_not_priced") {
			t.Errorf("a future price made it callable: %s", got)
		}
		mustExec(t, conn, `INSERT INTO afs.model_prices (model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok) VALUES ('claude-new', now() - interval '1 minute', 1, 1)`)
		if got := effective(t, conn, orch); !strings.Contains(got, "claude-new") {
			t.Errorf("a priced model is not callable: %s", got)
		}
	})
	t.Run("narrowing the team leaves agent_models unchanged", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.team_models (team_id, model_id) VALUES ($1, 'claude-sonnet'), ($1, 'claude-haiku')`, team)
		mustExec(t, conn, `UPDATE afs.teams SET model_access = 'selected' WHERE id = $1`, team)
		before := count(t, conn, `SELECT count(*) FROM afs.agent_models WHERE team_id = $1`, team)
		if got := effective(t, conn, orch); got != "claude-haiku,claude-sonnet*" {
			t.Errorf("orchestration agent (all): %s", got)
		}
		if got := effective(t, conn, w2); got != "claude-sonnet*" {
			t.Errorf("w2 (sonnet, opus selected, opus not in the team): %s", got)
		}
		if got := admission(t, conn, "agent", w2); !strings.Contains(got, "claude-opus=model_not_enabled_for_team") || !strings.Contains(got, "claude-haiku=model_not_enabled_for_agent") {
			t.Errorf("admission %s", got)
		}
		if after := count(t, conn, `SELECT count(*) FROM afs.agent_models WHERE team_id = $1`, team); after != before {
			t.Errorf("agent_models changed: %d -> %d", before, after)
		}
		// A model the team does not have cannot be added to an agent.
		_, err := conn.Exec(ctx, `INSERT INTO afs.agent_models (team_id, agent_id, model_id) VALUES ($1, $2, 'claude-opus')`, team, w1)
		wantState(t, err, "23514")
		if !hasConstraint(err, "agent_models_team") {
			t.Errorf("wrong constraint %v", err)
		}
		// Widening the team makes the narrower agent's selection effective again.
		mustExec(t, conn, `UPDATE afs.teams SET model_access = 'all' WHERE id = $1`, team)
		if got := effective(t, conn, w2); got != "claude-opus,claude-sonnet*" {
			t.Errorf("after widening: %s", got)
		}
	})
	t.Run("service level", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"selected"' WHERE key = 'models.service_access'`)
		mustExec(t, conn, `UPDATE afs.models SET enabled = false WHERE id IN ('claude-opus', 'claude-new')`)
		if got := effective(t, conn, orch); got != "claude-haiku,claude-sonnet*" {
			t.Errorf("service selected: %s", got)
		}
		if got := admission(t, conn, "agent", orch); !strings.Contains(got, "claude-opus=model_not_enabled_for_service") {
			t.Errorf("admission %s", got)
		}
		err := workerWithModels(t, conn, w3, team, "needs-opus", "selected", "claude-opus", "claude-opus")
		wantState(t, err, "23514")
		if !hasConstraint(err, "agent_models_service") {
			t.Errorf("wrong constraint %v", err)
		}
		// The default model of an agent must be enabled for the service too.
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET default_model_id = 'claude-opus' WHERE id = $1`, orch)
		wantState(t, err, "23514")
	})
	t.Run("the enabled flag is fixed while the service allows all", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"all"' WHERE key = 'models.service_access'`)
		err := runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.models SET enabled = true WHERE id = 'claude-opus'`)
		wantState(t, err, "55000")
		if !hasConstraint(err, "models_enabled_fixed") {
			t.Errorf("wrong constraint %v", err)
		}
		if got := effective(t, conn, orch); !strings.Contains(got, "claude-opus") {
			t.Errorf("under all, a disabled model must be callable: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"selected"' WHERE key = 'models.service_access'`)
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.models SET enabled = true WHERE id = 'claude-opus'`))
	})
	t.Run("the first failing level is the reason, service before team before agent", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.models SET enabled = false WHERE id = 'claude-haiku'`)
		mustExec(t, conn, `UPDATE afs.teams SET model_access = 'selected' WHERE id = $1`, team)
		mustExec(t, conn, `DELETE FROM afs.team_models WHERE team_id = $1 AND model_id = 'claude-haiku'`, team)
		if got := admission(t, conn, "agent", w1); !strings.Contains(got, "claude-haiku=model_not_enabled_for_service") {
			t.Errorf("service first: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.models SET enabled = true WHERE id = 'claude-haiku'`)
		if got := admission(t, conn, "agent", w1); !strings.Contains(got, "claude-haiku=model_not_enabled_for_team") {
			t.Errorf("then team: %s", got)
		}
		if got := admission(t, conn, "agent", "agt_nobody"); got != "" {
			t.Errorf("an unknown subject has %q", got)
		}
	})
	t.Run("at most 50 models per agent 23514", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.teams SET model_access = 'all' WHERE id = $1`, other)
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"all"' WHERE key = 'models.service_access'`)
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.models (id, provider, display_name) SELECT 'bulk-' || g, 'x', 'x' FROM generate_series(1, 51) g`); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, default_model_id, model_access, iam_identity)
				VALUES ($1, $2, 'bulk', 'omp', 'ghcr.io/x/img@`+collabDigest+`', 'bulk-1', 'bulk-1', 'selected', 'team_shared')`, cid("agt", 70), other); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO afs.agent_models (team_id, agent_id, model_id) SELECT $1, $2, 'bulk-' || g FROM generate_series(1, 51) g`, other, cid("agt", 70))
			return err
		})
		wantState(t, err, "23514")
	})
	t.Run("pools use the same rules", func(t *testing.T) {
		swarm := cid("team", 80)
		wantOK(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule)
				VALUES ($1, 'swarm-m', 'Swarm', 'ephemeral', 'CC1', 'o@example.com', 100, now() + interval '3 days', 'at_expiry')`, swarm); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust) VALUES ($1, $2, 'lifetime', 50, 'block')`, cid("bud", 80), swarm); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, `+createDefaults+`)`, swarm, cid("agt", 80))
			return err
		}))
		pool := cid("pool", 80)
		mk := func(access string, models ...string) error {
			return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `INSERT INTO afs.agent_pools (id, team_id, name, template, image, model_id, default_model_id, model_access)
					VALUES ($1, $2, 'fixer', 'omp', 'ghcr.io/x/omp@`+collabDigest+`', 'claude-haiku', 'claude-haiku', $3) ON CONFLICT DO NOTHING`, pool, swarm, access); err != nil {
					return err
				}
				for _, m := range models {
					if _, err := tx.Exec(ctx, `INSERT INTO afs.pool_models (team_id, pool_id, model_id) VALUES ($1, $2, $3)`, swarm, pool, m); err != nil {
						return err
					}
				}
				return nil
			})
		}
		err := mk("selected")
		wantState(t, err, "23514")
		if !hasConstraint(err, "agents_models_selection_nonempty") {
			t.Errorf("wrong constraint %v", err)
		}
		wantOK(t, mk("selected", "claude-haiku"))
		if got := effective(t, conn, pool); got != "claude-haiku*" {
			t.Errorf("pool effective %s", got)
		}
		if got := admission(t, conn, "pool", pool); !strings.Contains(got, "claude-sonnet=model_not_enabled_for_agent") {
			t.Errorf("pool admission %s", got)
		}
		_, err = conn.Exec(ctx, `UPDATE afs.agent_pools SET default_model_id = 'claude-sonnet' WHERE id = $1`, pool)
		wantState(t, err, "23514")
	})
	t.Run("the gateway reads the view, the admission function and the settings it needs", func(t *testing.T) {
		rows, err := queryAs(t, conn, "afs_gateway", "", `SELECT model_id FROM afs.effective_agent_models WHERE subject_id = $1`, orch)
		wantOK(t, err)
		if len(rows) == 0 {
			t.Error("the gateway sees no rows")
		}
		_, err = queryAs(t, conn, "afs_gateway", "", `SELECT model_id FROM afs.model_admission('agent', $1)`, orch)
		wantOK(t, err)
		_, err = queryAs(t, conn, "afs_gateway", "", `SELECT value FROM afs.service_settings WHERE key = 'models.service_access'`)
		wantOK(t, err)
		_, err = queryAs(t, conn, "afs_gateway", "", `SELECT description FROM afs.service_settings`)
		wantState(t, err, "42501")
	})
	t.Run("afs_app sees its own team's rows only, in the view and in agent_models", func(t *testing.T) {
		rows, err := queryAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `SELECT DISTINCT team_id FROM afs.effective_agent_models`)
		wantOK(t, err)
		if len(rows) != 1 || rows[0] != team {
			t.Errorf("view rows for %v", rows)
		}
		rows, err = queryAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `SELECT DISTINCT team_id FROM afs.agent_models`)
		wantOK(t, err)
		if len(rows) != 1 || rows[0] != team {
			t.Errorf("agent_models rows for %v", rows)
		}
		// Writes for another team change nothing: the policy refuses.
		err = runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `INSERT INTO afs.agent_models (team_id, agent_id, model_id) VALUES ($1, $2, 'claude-haiku')`, other, cid("agt", 2))
		wantState(t, err, "42501")
		err = runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `DELETE FROM afs.agent_models WHERE team_id = $1`, other)
		wantOK(t, err)
	})
}

// DB-US-61: Bedrock inference profiles per team and model.
func TestTeamInferenceProfiles(t *testing.T) {
	conn := orchWorld(t)
	team, _ := orchTeam(t, conn, 1, "public")
	other, _ := orchTeam(t, conn, 2, "public")
	const arn = "arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/abc123xyz"
	ins := `INSERT INTO afs.team_inference_profiles (team_id, model_id, inference_profile_arn, state) VALUES ($1, 'claude-sonnet', $2, $3)`
	t.Run("the reconciler writes, the rules hold", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_reconciler", "", ins, team, arn, "active"))
		wantState(t, runAs(t, conn, "afs_reconciler", "", ins, team, arn, "active"), "23505")
		wantState(t, runAs(t, conn, "afs_reconciler", "", ins, other, "arn:bogus", "active"), "23514")
		wantState(t, runAs(t, conn, "afs_reconciler", "", ins, other, arn, "retiring"), "23514")
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `INSERT INTO afs.team_inference_profiles (team_id, model_id, state, retire_after)
			VALUES ($1, 'claude-haiku', 'retiring', now() + interval '7 days')`, other))
	})
	t.Run("afs_app reads its team only and writes nothing", func(t *testing.T) {
		rows, err := queryAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `SELECT team_id FROM afs.team_inference_profiles`)
		wantOK(t, err)
		if len(rows) != 1 || rows[0] != team {
			t.Errorf("rows %v", rows)
		}
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", ins, team, arn, "active"), "42501")
	})
	t.Run("team_models.inference_profile_arn follows until 2.0.0", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.team_models (team_id, model_id) VALUES ($1, 'claude-sonnet')`, team)
		mustExec(t, conn, `UPDATE afs.team_inference_profiles SET inference_profile_arn = $2 WHERE team_id = $1 AND model_id = 'claude-sonnet'`, team,
			"arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/zzz999")
		if got := scalar[string](t, conn, "", `SELECT inference_profile_arn FROM afs.team_models WHERE team_id = $1`, team); !strings.HasSuffix(got, "zzz999") {
			t.Errorf("copy %q", got)
		}
		mustExec(t, conn, `DELETE FROM afs.team_inference_profiles WHERE team_id = $1 AND model_id = 'claude-sonnet'`, team)
		if got := scalar[*string](t, conn, "", `SELECT inference_profile_arn FROM afs.team_models WHERE team_id = $1`, team); got != nil {
			t.Errorf("copy after delete %q", *got)
		}
	})
}
