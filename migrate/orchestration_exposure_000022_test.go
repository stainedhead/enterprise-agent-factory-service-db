package migrate_test

// Migration 000022, exposure levels, tool choice, settings, edge routes and snapshots (spec
// 261123-orchestration-and-model-access; -db PRD DB-US-59 and DB-US-60).

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// enableBuzz gives Buzz an orchestration template and turns the tool on.
func enableBuzz(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	mustExec(t, conn, `
INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities, default_resources) VALUES
 ('`+tplOrchBuzz+`', 'orchestration-buzz', 'buzz', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{orchestration,tool:buzz}', '{"cpu": "1", "memory": "4Gi"}')`)
	mustExec(t, conn, `UPDATE afs.service_settings
		SET value = jsonb_set(jsonb_set(jsonb_set(value, '{buzz,enabled}', 'true'), '{buzz,templateId}', to_jsonb($1::text)), '{buzz,imageRepository}', '"ghcr.io/x/buzz"')
		WHERE key = 'orchestration.tools'`, tplOrchBuzz)
}

// orchTeamTool is orchTeam for a named tool.
func orchTeamTool(t *testing.T, conn *pgx.Conn, n int, limit, tool string) (team, agent string) {
	t.Helper()
	team, agent = cid("team", n), cid("agt", n)
	wantOK(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.Context(), `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd, max_collaboration_exposure)
			VALUES ($1, $2, $2, 'CC1', 'o@example.com', 100, $3)`, team, fmt.Sprintf("team-%d", n), limit); err != nil {
			return err
		}
		_, err := tx.Exec(t.Context(), `SELECT afs.create_orchestration_agent($1, $2, NULL, $3, NULL, NULL, NULL, NULL, NULL, 'claude-sonnet', NULL, NULL, NULL)`, team, agent, tool)
		return err
	}))
	return team, agent
}

func levels(t *testing.T, conn *pgx.Conn, team string) string {
	t.Helper()
	return strings.Join(queryRow(t, conn, `SELECT web_ui_exposure, web_api_exposure, web_ui_enabled::text, rest_api_enabled::text FROM afs.team_collaboration WHERE team_id = $1`, team), "|")
}

// DB-US-59.
func TestCollaborationExposure(t *testing.T) {
	conn := orchWorld(t)
	ctx := t.Context()
	enableBuzz(t, conn)
	teamPub, _ := orchTeam(t, conn, 1, "public")
	teamPriv, _ := orchTeam(t, conn, 2, "private")
	teamOff, _ := orchTeam(t, conn, 3, "off")
	teamBuzz, _ := orchTeamTool(t, conn, 4, "public", "buzz")

	t.Run("defaults are capped by the team limit", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"public"' WHERE key = 'orchestration.default_limit'`)
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"public"' WHERE key = 'orchestration.default_web_ui_exposure'`)
		_, _ = orchTeam(t, conn, 5, "private")
		if got := levels(t, conn, cid("team", 5)); got != "private|off|true|false" {
			t.Errorf("levels %s", got)
		}
		_, _ = orchTeam(t, conn, 6, "off")
		if got := levels(t, conn, cid("team", 6)); got != "off|off|false|false" {
			t.Errorf("levels %s", got)
		}
		if got := levels(t, conn, teamBuzz); got != "off|off|false|false" {
			t.Errorf("buzz levels %s", got)
		}
	})
	t.Run("level and boolean stay in step", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_exposure = 'private' WHERE team_id = $1`, teamPub)
		if got := levels(t, conn, teamPub); got != "private|off|true|false" {
			t.Errorf("after level private: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = false WHERE team_id = $1`, teamPub)
		if got := levels(t, conn, teamPub); got != "off|off|false|false" {
			t.Errorf("after boolean false: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = true, rest_api_enabled = true WHERE team_id = $1`, teamPub)
		if got := levels(t, conn, teamPub); got != "public|public|true|true" {
			t.Errorf("after boolean true under a public limit: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_exposure = 'off', web_api_exposure = 'off' WHERE team_id = $1`, teamPub)
		if got := levels(t, conn, teamPub); got != "off|off|false|false" {
			t.Errorf("after levels off: %s", got)
		}
	})
	t.Run("true under a private limit gives private, under an off limit gives off", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = true WHERE team_id = $1`, teamPriv)
		if got := levels(t, conn, teamPriv); got != "private|off|true|false" {
			t.Errorf("private limit: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = true WHERE team_id = $1`, teamOff)
		if got := levels(t, conn, teamOff); got != "off|off|false|false" {
			t.Errorf("off limit: %s", got)
		}
	})
	t.Run("a level above the limit 23514", func(t *testing.T) {
		for _, c := range []struct{ team, set string }{
			{teamPriv, `web_ui_exposure = 'public'`}, {teamPriv, `web_api_exposure = 'public'`},
			{teamOff, `web_ui_exposure = 'private'`}, {teamOff, `web_api_exposure = 'private'`},
		} {
			_, err := conn.Exec(ctx, `UPDATE afs.team_collaboration SET `+c.set+` WHERE team_id = $1`, c.team)
			wantState(t, err, "23514")
			if !hasConstraint(err, "team_collaboration_exposure_limit") {
				t.Errorf("%s: wrong constraint %v", c.set, err)
			}
		}
	})
	t.Run("afs_app cannot insert a team_collaboration row", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'",
			`INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES ($1, $2)`, cid("team", 9), cid("agt", 9)), "42501")
	})
	t.Run("a level above a lowered limit survives an unrelated update", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_exposure = 'public' WHERE team_id = $1`, teamPub)
		mustExec(t, conn, `UPDATE afs.teams SET max_collaboration_exposure = 'private' WHERE id = $1`, teamPub)
		mustExec(t, conn, `UPDATE afs.team_collaboration SET registration_mode = 'managed' WHERE team_id = $1`, teamPub)
		if got := levels(t, conn, teamPub); got != "public|off|true|false" {
			t.Errorf("levels %s", got)
		}
		_, err := conn.Exec(ctx, `UPDATE afs.team_collaboration SET web_api_exposure = 'public' WHERE team_id = $1`, teamPub)
		wantState(t, err, "23514")
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_exposure = 'private' WHERE team_id = $1`, teamPub)
	})
	t.Run("the booleans and the limit boolean stay in step (compatibility)", func(t *testing.T) {
		if got := scalar[string](t, conn, "", `SELECT may_expose_collaboration::text FROM afs.teams WHERE id = $1`, teamOff); got != "false" {
			t.Errorf("may_expose_collaboration %s", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET may_expose_collaboration = true WHERE id = $1`, teamOff)
		if got := scalar[string](t, conn, "", `SELECT max_collaboration_exposure FROM afs.teams WHERE id = $1`, teamOff); got != "public" {
			t.Errorf("limit after may_expose true: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.teams SET max_collaboration_exposure = 'off' WHERE id = $1`, teamOff)
		if got := scalar[string](t, conn, "", `SELECT may_expose_collaboration::text FROM afs.teams WHERE id = $1`, teamOff); got != "false" {
			t.Errorf("may_expose after limit off: %s", got)
		}
	})
	t.Run("Buzz refuses both surfaces and manual registration", func(t *testing.T) {
		for _, c := range []struct{ set, constraint string }{
			{`web_ui_exposure = 'private'`, "team_collaboration_surface_supported"},
			{`web_api_exposure = 'public'`, "team_collaboration_surface_supported"},
			{`registration_mode = 'manual'`, "team_collaboration_registration_supported"},
		} {
			_, err := conn.Exec(ctx, `UPDATE afs.team_collaboration SET `+c.set+` WHERE team_id = $1`, teamBuzz)
			wantState(t, err, "23514")
			if !hasConstraint(err, c.constraint) {
				t.Errorf("%s: wrong constraint %v", c.set, err)
			}
		}
		// The boolean of a surface the tool lacks stays off.
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_enabled = true, rest_api_enabled = true WHERE team_id = $1`, teamBuzz)
		if got := levels(t, conn, teamBuzz); got != "off|off|false|false" {
			t.Errorf("buzz after booleans: %s", got)
		}
		if got := scalar[string](t, conn, "", `SELECT registration_mode FROM afs.team_collaboration WHERE team_id = $1`, teamBuzz); got != "managed" {
			t.Errorf("buzz registration %s", got)
		}
	})
	t.Run("a tool change re-checks both surfaces", func(t *testing.T) {
		// Paperclip team with the Web UI on, changed to Buzz with the levels still set: refused at the row.
		mustExec(t, conn, `UPDATE afs.team_collaboration SET web_ui_exposure = 'private' WHERE team_id = $1`, teamPub)
		_, err := conn.Exec(ctx, `UPDATE afs.team_collaboration SET tool = 'buzz', registration_mode = 'managed' WHERE team_id = $1`, teamPub)
		wantState(t, err, "23514")
		if !hasConstraint(err, "team_collaboration_surface_supported") {
			t.Errorf("wrong constraint %v", err)
		}
	})
	t.Run("the tool and the agent's template must agree at commit", func(t *testing.T) {
		_, agent := orchTeam(t, conn, 7, "off")
		team := cid("team", 7)
		_, err := conn.Exec(ctx, `UPDATE afs.team_collaboration SET tool = 'buzz', registration_mode = 'managed' WHERE team_id = $1`, team)
		wantState(t, err, "23514")
		if !hasConstraint(err, "team_collaboration_tool_template") {
			t.Errorf("wrong constraint %v", err)
		}
		// Either order inside one transaction is accepted once both agree.
		wantOK(t, pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `UPDATE afs.agents SET template_id = $1, template = 'buzz' WHERE id = $2`, tplOrchBuzz, agent); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE afs.team_collaboration SET tool = 'buzz', registration_mode = 'managed' WHERE team_id = $1`, team)
			return err
		}))
		// Changing the agent's template away from the tool's capability alone is refused too.
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET template_id = $1 WHERE id = $2`, tplOrch, agent)
		wantState(t, err, "23514")
	})
	t.Run("a tool change bumps the generation", func(t *testing.T) {
		if got := scalar[int](t, conn, "", `SELECT generation FROM afs.team_collaboration WHERE team_id = $1`, cid("team", 7)); got < 2 {
			t.Errorf("generation %d", got)
		}
	})
}

// DB-US-59: the volume snapshot taken before a tool change.
func TestToolChangeSnapshot(t *testing.T) {
	conn := orchWorld(t)
	team, agent := orchTeam(t, conn, 1, "public")
	other, _ := orchTeam(t, conn, 2, "public")
	asTeam := "SET LOCAL afs.team_ids = '" + team + "'"
	ins := `INSERT INTO afs.agent_volume_snapshots (id, team_id, agent_id, reason, tool, retain_until) VALUES ($1, $2, $3, $4, $5, $6)`
	retain := time.Now().Add(90 * 24 * time.Hour)
	t.Run("afs_app may record pre_tool_change with the tool and a retention", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 1), team, agent, "pre_tool_change", "paperclip", retain))
		wantOK(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 2), team, agent, "manual", nil, nil))
	})
	t.Run("without the tool or retention 23514", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 3), team, agent, "pre_tool_change", nil, retain), "23514")
		wantState(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 4), team, agent, "pre_tool_change", "buzz", nil), "23514")
		wantState(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 5), team, agent, "pre_tool_change", "other", retain), "23514")
	})
	t.Run("afs_app may not record other reasons, or for another team", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 6), team, agent, "scheduled", nil, nil), "42501")
		wantState(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 7), team, agent, "pre_delete", nil, nil), "42501")
		wantState(t, runAs(t, conn, "afs_app", asTeam, ins, cid("vsnap", 8), other, cid("agt", 2), "pre_tool_change", "paperclip", retain), "42501")
	})
	t.Run("the reconciler reads tool and retain_until", func(t *testing.T) {
		rows, err := queryAs(t, conn, "afs_reconciler", "", `SELECT tool FROM afs.agent_volume_snapshots WHERE reason = 'pre_tool_change'`)
		wantOK(t, err)
		if len(rows) != 1 || rows[0] != "paperclip" {
			t.Errorf("rows %v", rows)
		}
	})
}

// DB-US-59, DB-US-61: the orchestration.* and models.* service settings.
func TestOrchestrationSettings(t *testing.T) {
	conn := orchWorld(t)
	enableBuzz(t, conn)
	set := func(key, value string) error {
		_, err := conn.Exec(t.Context(), `UPDATE afs.service_settings SET value = $2::jsonb WHERE key = $1`, key, value)
		return err
	}
	bad := func(key, value string) {
		t.Helper()
		if got := sqlState(set(key, value)); got != "23514" {
			t.Errorf("%s = %s: want 23514, got %q", key, value, got)
		}
	}
	t.Run("orchestration ranges", func(t *testing.T) {
		for _, c := range [][2]string{
			{"orchestration.public_base_domain", `"Not A Domain"`}, {"orchestration.private_base_domain", `5`},
			{"orchestration.public_endpoints", `"yes"`}, {"orchestration.private_endpoints", `1`},
			{"orchestration.default_limit", `"world"`}, {"orchestration.default_web_ui_exposure", `true`},
			{"orchestration.default_web_api_exposure", `"x"`},
			{"orchestration.default_volume_gib", `9`}, {"orchestration.default_volume_gib", `1001`}, {"orchestration.default_volume_gib", `20.5`},
			{"orchestration.default_volume_gib", `"20"`}, {"orchestration.default_resources", `{"cpu": 2, "memory": "8Gi"}`}, {"orchestration.default_resources", `[]`},
		} {
			bad(c[0], c[1])
		}
		for _, c := range [][2]string{
			{"orchestration.private_base_domain", `"internal.example.com"`}, {"orchestration.public_base_domain", `null`},
			{"orchestration.default_volume_gib", `1000`}, {"orchestration.default_volume_gib", `10`},
			{"orchestration.default_resources", `{"cpu": "2", "memory": "8Gi"}`},
		} {
			wantOK(t, set(c[0], c[1]))
		}
	})
	t.Run("orchestration.tools: exactly one default, enabled, a template with both capabilities", func(t *testing.T) {
		tools := func(f string) string {
			return scalar[string](t, conn, "", `SELECT `+f+` FROM afs.service_settings WHERE key = 'orchestration.tools'`)
		}
		bothDefault := tools(`jsonb_set(value, '{buzz,default}', 'true')::text`)
		bad("orchestration.tools", bothDefault)
		noDefault := tools(`jsonb_set(value, '{paperclip,default}', 'false')::text`)
		bad("orchestration.tools", noDefault)
		disabledDefault := tools(`jsonb_set(value, '{paperclip,enabled}', 'false')::text`)
		bad("orchestration.tools", disabledDefault)
		profile := tools(`jsonb_set(value, '{buzz,webUi}', 'true')::text`)
		bad("orchestration.tools", profile)
		bad("orchestration.tools", `[]`)
		bad("orchestration.tools", `{"paperclip": {}}`)
		err := set("orchestration.tools", tools(`jsonb_set(value, '{buzz,templateId}', to_jsonb($$tpl_01JD3Z5Y8K2M4N6P8Q0R2S9999$$::text))::text`))
		wantState(t, err, "23514")
		if !hasConstraint(err, "orchestration_tools_template") {
			t.Errorf("unknown template: %v", err)
		}
		// A template with the orchestration capability but the other tool's.
		err = set("orchestration.tools", tools(`jsonb_set(value, '{buzz,templateId}', to_jsonb('`+tplOrch+`'::text))::text`))
		wantState(t, err, "23514")
		if !hasConstraint(err, "orchestration_tools_template") {
			t.Errorf("wrong tool capability: %v", err)
		}
		wantOK(t, set("orchestration.tools", tools(`jsonb_set(jsonb_set(value, '{buzz,default}', 'true'), '{paperclip,default}', 'false')::text`)))
	})
	t.Run("default levels not above the default limit", func(t *testing.T) {
		wantOK(t, set("orchestration.default_limit", `"public"`))
		wantOK(t, set("orchestration.default_web_ui_exposure", `"public"`))
		err := set("orchestration.default_limit", `"private"`)
		wantState(t, err, "23514")
		if !hasConstraint(err, "service_settings_orchestration_check") {
			t.Errorf("limit below the default level: %v", err)
		}
		wantOK(t, set("orchestration.default_web_ui_exposure", `"private"`))
		wantOK(t, set("orchestration.default_limit", `"private"`))
		wantState(t, set("orchestration.default_web_api_exposure", `"public"`), "23514")
	})
	t.Run("models.* ranges", func(t *testing.T) {
		for _, c := range [][2]string{
			{"models.service_access", `"some"`}, {"models.service_access", `true`}, {"models.default_team_access", `"none"`},
			{"models.default_team_models", `"claude-sonnet"`}, {"models.default_team_models", `[1]`}, {"models.default_team_models", `["claude-nope"]`},
			{"models.default_model_id", `5`}, {"models.default_model_id", `"claude-nope"`}, {"models.default_model_id", `""`},
		} {
			bad(c[0], c[1])
		}
		many := make([]string, 101)
		for i := range many {
			many[i] = fmt.Sprintf(`"m%d"`, i)
		}
		bad("models.default_team_models", "["+strings.Join(many, ",")+"]")
		wantOK(t, set("models.default_team_models", `["claude-sonnet", "claude-haiku"]`))
		wantOK(t, set("models.default_model_id", `"claude-haiku"`))
		wantOK(t, set("models.default_model_id", `null`))
		wantOK(t, set("models.service_access", `"selected"`))
		wantOK(t, set("models.default_team_access", `"selected"`))
	})
	t.Run("collab.base_domain and collab.public_endpoints are read-only aliases for afs_app", func(t *testing.T) {
		for _, key := range []string{"collab.base_domain", "collab.public_endpoints"} {
			err := runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.service_settings SET value = 'null' WHERE key = $1`, key)
			wantState(t, err, "23514")
			if !hasConstraint(err, "service_settings_alias_read_only") {
				t.Errorf("%s: %v", key, err)
			}
		}
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'",
			`UPDATE afs.service_settings SET value = '"alias.example.com"' WHERE key = 'orchestration.public_base_domain'`))
		if got := scalar[string](t, conn, "", `SELECT value #>> '{}' FROM afs.service_settings WHERE key = 'collab.base_domain'`); got != "alias.example.com" {
			t.Errorf("alias %q", got)
		}
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'",
			`UPDATE afs.service_settings SET value = 'false' WHERE key = 'orchestration.public_endpoints'`))
		if got := scalar[string](t, conn, "", `SELECT value::text FROM afs.service_settings WHERE key = 'collab.public_endpoints'`); got != "false" {
			t.Errorf("alias %q", got)
		}
	})
	t.Run("a team admin cannot write the settings", func(t *testing.T) {
		before := scalar[string](t, conn, "", `SELECT value::text FROM afs.service_settings WHERE key = 'orchestration.default_limit'`)
		err := runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+cid("team", 1)+"'",
			`UPDATE afs.service_settings SET value = '"public"' WHERE key = 'orchestration.default_limit'`)
		if err != nil && sqlState(err) != "42501" {
			t.Fatal(err)
		}
		if after := scalar[string](t, conn, "", `SELECT value::text FROM afs.service_settings WHERE key = 'orchestration.default_limit'`); after != before {
			t.Errorf("a team caller changed the setting: %s -> %s", before, after)
		}
	})
	t.Run("the change feed fires for models.* and orchestration.* only", func(t *testing.T) {
		mustExec(t, conn, `LISTEN afs_desired_state`)
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '30' WHERE key = 'teams.ephemeral_max_days'`)
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"selected"' WHERE key = 'models.default_team_access'`)
		wctx, cancel := context_withTimeout(t)
		defer cancel()
		n, err := conn.WaitForNotification(wctx)
		wantOK(t, err)
		if n.Payload != "service_settings::models.default_team_access" {
			t.Errorf("payload %q", n.Payload)
		}
	})
}
