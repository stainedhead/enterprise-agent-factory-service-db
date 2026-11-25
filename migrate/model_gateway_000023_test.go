package migrate_test

// Migration 000023, team model gateway, routes and provider switches (spec 261125-model-endpoint-gateway; root PRD
// model-endpoint-gateway-PRD.md Appendix C.1 TC-DB-01 to TC-DB-15 and D.2 MEG-DB-1 to MEG-DB-7; database contract
// section 7.4). Each test names the test case it proves.

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

const gatewayVersion = 23

// Built-in catalog entries seeded by 000023.
const (
	epOpenRouter = "mep_00000000000000000000000001"
	epNous       = "mep_00000000000000000000000002"
	epOpenCode   = "mep_00000000000000000000000003"
	epAzure      = "mep_00000000000000000000000004"
	epVertex     = "mep_00000000000000000000000005"
)

var (
	epOpenAI = cid("mep", 1) // service endpoint openai-prod on api.openai.com, created by gwWorld
	epCorp   = cid("mep", 2) // service endpoint corp-llm, corporate, internal
)

// teamAdmin is an afs_app session of a team-admin of team (not a service admin).
func teamAdmin(team string) string {
	return "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_t'; SET LOCAL afs.team_ids = '" + team + "'"
}

// gwWorld is orchWorld with two teams (and their orchestration agents) and a priced service endpoint openai-prod
// (switched on, models gpt-x priced and gpt-free unpriced), plus a corporate service endpoint corp-llm.
func gwWorld(t *testing.T) (conn *pgx.Conn, team1, orch1, team2, orch2 string) {
	t.Helper()
	conn = orchWorld(t)
	team1, orch1 = orchTeam(t, conn, 1, "public")
	team2, orch2 = orchTeam(t, conn, 2, "public")
	mustExec(t, conn, `
INSERT INTO afs.model_endpoints (id, slug, display_name, location, base_url, auth_kind, pricing_mode, enabled) VALUES
 ('`+epOpenAI+`', 'openai-prod', 'OpenAI', 'external', 'https://api.openai.com/v1', 'bearer', 'per_token', true),
 ('`+epCorp+`', 'corp-llm', 'Corporate LLM', 'corporate', 'https://llm.corp.example.com/v1', 'none', 'free', true);
INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES
 ('`+epOpenAI+`', 'gpt-x', 16384), ('`+epOpenAI+`', 'gpt-free', 1024), ('`+epCorp+`', 'llama-corp', 4096);
INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd) VALUES
 ('`+epOpenAI+`', 'gpt-x', now() - interval '1 day', 2, 8)`)
	return conn, team1, orch1, team2, orch2
}

func lines(t *testing.T, conn *pgx.Conn, settings, sql string, args ...any) string {
	t.Helper()
	var out []string
	wantOK(t, in(t, conn, settings, func(tx pgx.Tx) error {
		rows, err := tx.Query(t.Context(), sql, args...)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	}))
	return strings.Join(out, ",")
}

// routeAdmission renders afs.route_admission as slug/model=reason, ok when admitted.
func routeAdmission(t *testing.T, conn *pgx.Conn, kind, subject string) string {
	t.Helper()
	return lines(t, conn, "", `SELECT slug || '/' || model_name || '=' || coalesce(reason, 'ok') FROM afs.route_admission($1, $2)`, kind, subject)
}

func effectiveRoutes(t *testing.T, conn *pgx.Conn, subject string) string {
	t.Helper()
	return lines(t, conn, "", `SELECT slug || '/' || model_name || CASE WHEN is_default THEN '*' ELSE '' END
		FROM afs.effective_agent_routes WHERE subject_id = $1 ORDER BY slug, model_name`, subject)
}

func wantConstraint(t *testing.T, err error, state, constraint string) {
	t.Helper()
	wantState(t, err, state)
	if constraint != "" && !hasConstraint(err, constraint) {
		t.Fatalf("want constraint %s, got %v", constraint, err)
	}
}

// TC-DB-14, MEG-DB-5: the providers and built-in catalog entries of a fresh install.
func TestGatewaySeeds(t *testing.T) {
	conn := migratedStrict(t)
	if got := lines(t, conn, "", `SELECT provider || '=' || enabled || '/' || team_selection FROM afs.inference_providers ORDER BY provider`); got !=
		"azure=false/service_admin,bedrock=true/team_admin,google=false/service_admin,nous=true/team_admin,openai=true/team_admin,opencode=true/team_admin,openrouter=true/team_admin,other=true/team_admin" {
		t.Errorf("providers %s", got)
	}
	if got := lines(t, conn, "", `SELECT slug || '=' || provider || '/' || enabled || '/' || builtin || '/' || auth_kind FROM afs.model_endpoints ORDER BY slug`); got !=
		"azure-openai=azure/false/true/azure_federated,nous-portal=nous/false/true/bearer,opencode=opencode/false/true/bearer,openrouter=openrouter/false/true/bearer,vertex-ai=google/false/true/google_federated" {
		t.Errorf("built-in endpoints %s", got)
	}
	if n := count(t, conn, `SELECT count(*) FROM afs.endpoint_models`); n != 0 {
		t.Errorf("%d models seeded; built-ins ship with none", n)
	}
	if got := scalar[bool](t, conn, "", `SELECT requires_terms FROM afs.model_endpoints WHERE slug = 'openrouter'`); !got {
		t.Error("openrouter has extra terms")
	}
	if got := scalar[string](t, conn, "", `SELECT afs.schema_version()::text`); got != "23" {
		t.Errorf("schema version %s", got)
	}
	t.Run("provider_for_host", func(t *testing.T) {
		for host, want := range map[string]string{
			"api.openai.com":                          "openai",
			"API.OpenAI.com":                          "openai",
			"myres.openai.azure.com":                  "azure",
			"a.b.services.ai.azure.com":               "azure",
			"openai.azure.com":                        "other",
			"aiplatform.googleapis.com":               "google",
			"us-central1-aiplatform.googleapis.com":   "google",
			"bedrock-runtime.us-east-1.amazonaws.com": "bedrock",
			"openrouter.ai":                           "openrouter",
			"inference-api.nousresearch.com":          "nous",
			"opencode.ai":                             "opencode",
			"evil-api.openai.com.example.net":         "other",
			"":                                        "other",
		} {
			if got := scalar[string](t, conn, "", `SELECT afs.provider_for_host($1)`, host); got != want {
				t.Errorf("%q: %s, want %s", host, got, want)
			}
		}
	})
	t.Run("provider_enabled", func(t *testing.T) {
		for p, want := range map[string]bool{"bedrock": true, "azure": false, "internal": true, "nope": false} {
			if got := scalar[bool](t, conn, "", `SELECT afs.provider_enabled($1)`, p); got != want {
				t.Errorf("%s: %v", p, got)
			}
		}
	})
	t.Run("hosts are FQDN globs, at most 20", func(t *testing.T) {
		for _, h := range []string{"{https://x.com}", "{x}", "{*.}", "{a..b.com}", "{" + strings.Repeat("a.com,", 20) + "a.com}"} {
			_, err := conn.Exec(t.Context(), `INSERT INTO afs.inference_providers (provider, display_name, hosts, enabled) VALUES ('mistral', 'Mistral', $1::text[], true)`, h)
			wantState(t, err, "23514")
		}
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'",
			`INSERT INTO afs.inference_providers (provider, display_name, hosts, enabled) VALUES ('mistral', 'Mistral', '{api.mistral.ai}', true)`))
		if got := scalar[string](t, conn, "", `SELECT afs.provider_for_host('api.mistral.ai')`); got != "mistral" {
			t.Errorf("added provider: %s", got)
		}
		_, err := conn.Exec(t.Context(), `INSERT INTO afs.inference_providers (provider, display_name, enabled) VALUES ('internal', 'x', true)`)
		wantState(t, err, "23514")
	})
}

// TC-DB-01, TC-DB-02, MEG-DB-1: endpoint slugs and shapes.
func TestModelEndpointConstraints(t *testing.T) {
	conn, team1, _, team2, _ := gwWorld(t)
	mustExec(t, conn, `UPDATE afs.teams SET may_add_model_endpoints = true WHERE id IN ($1, $2)`, team1, team2)
	seq := 10
	// ins inserts an endpoint; cols and vals (each starting ", ") override the defaults.
	ins := func(team any, slug, cols, vals string) error {
		seq++
		override := map[string]bool{}
		for _, c := range strings.Split(cols, ",") {
			override[strings.TrimSpace(c)] = true
		}
		var dc, dv string
		for _, d := range [][2]string{{"owner", "'o'"}, {"purpose", "'p'"}, {"location", "'external'"},
			{"base_url", "'https://h.example.com/v1'"}, {"auth_kind", "'bearer'"}, {"pricing_mode", "'per_token'"}} {
			if !override[d[0]] {
				dc += ", " + d[0]
				dv += ", " + d[1]
			}
		}
		_, err := conn.Exec(t.Context(), `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name`+dc+cols+`)
			VALUES ($1, $2, $3, 'X'`+dv+vals+`)`, cid("mep", seq), team, slug)
		return err
	}
	t.Run("TC-DB-01 slugs", func(t *testing.T) {
		wantConstraint(t, ins(nil, "Bad_Slug", "", ""), "23514", "model_endpoints_slug_check")
		wantConstraint(t, ins(nil, "bedrock", "", ""), "23514", "model_endpoints_slug_check")
		wantConstraint(t, ins(nil, "x", "", ""), "23514", "model_endpoints_slug_check")
		wantConstraint(t, ins(nil, "openrouter", "", ""), "23505", "model_endpoints_slug_taken")
		wantConstraint(t, ins(team1, "openai-prod", "", ""), "23505", "model_endpoints_slug_taken")
		wantOK(t, ins(team1, "team-llm", "", ""))
		wantConstraint(t, ins(team1, "team-llm", "", ""), "23505", "model_endpoints_slug_taken")
		wantOK(t, ins(team2, "team-llm", "", "")) // another team may use the same slug
		wantConstraint(t, ins(nil, "team-llm", "", ""), "23505", "model_endpoints_slug_taken")
	})
	t.Run("TC-DB-02 owner, purpose and location", func(t *testing.T) {
		_, err := conn.Exec(t.Context(), `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, $2, 'no-owner', 'X', 'external', 'https://h.example.com', 'bearer', 'per_token')`, cid("mep", 90), team1)
		wantConstraint(t, err, "23514", "model_endpoints_owner_purpose_check")
		wantConstraint(t, ins(nil, "svc-vllm", ", location", ", 'in_namespace'"), "23514", "model_endpoints_in_namespace_check")
	})
	t.Run("rejected shapes", func(t *testing.T) {
		for name, c := range map[string]struct {
			team                   any
			cols, vals, constraint string
		}{
			"http external":           {nil, ", base_url", ", 'http://h.example.com'", "model_endpoints_base_url_scheme"},
			"http corporate":          {nil, ", location, base_url", ", 'corporate', 'http://h.example.com'", "model_endpoints_base_url_scheme"},
			"no protocol":             {nil, ", protocols", ", '{}'", "model_endpoints_protocols_check"},
			"unknown protocol":        {nil, ", protocols", ", '{anthropic_messages}'", "model_endpoints_protocols_check"},
			"twice the same protocol": {nil, ", protocols", ", '{openai_chat,openai_chat}'", "model_endpoints_protocols_check"},
			"header without its name": {nil, ", auth_kind", ", 'header'", "model_endpoints_auth_header_kind"},
			"metrics port outside":    {nil, ", metrics_port", ", 9100", "model_endpoints_metrics_port_location"},
			"team shared credential":  {team1, ", credential_mode", ", 'shared'", "model_endpoints_team_credential_check"},
			"team with extra terms":   {team1, ", requires_terms", ", true", "model_endpoints_team_terms_check"},
			"timeout too long":        {nil, ", timeout_seconds", ", 3601", "model_endpoints_timeout_seconds_check"},
			"body too large":          {nil, ", max_body_mib", ", 101", "model_endpoints_max_body_mib_check"},
			"ca bundle not PEM":       {nil, ", ca_bundle", ", 'not a pem'", "model_endpoints_ca_bundle_check"},
			"azure federation off az": {nil, ", auth_kind", ", 'azure_federated'", "model_endpoints_auth_kind_provider"},
			"internal external":       {nil, ", provider", ", 'internal'", "model_endpoints_provider_check"},
			"in-namespace other ns":   {team1, ", location, base_url, auth_kind", ", 'in_namespace', 'http://vllm.afs-t-team-2.svc:8000', 'none'", "model_endpoints_in_namespace_host"},
			"bad pricing mode":        {nil, ", pricing_mode", ", 'monthly'", ""},
		} {
			t.Run(name, func(t *testing.T) {
				cols, vals := c.cols, c.vals
				if strings.Contains(cols, "pricing_mode") {
					_, err := conn.Exec(t.Context(), `INSERT INTO afs.model_endpoints (id, slug, display_name, location, base_url, auth_kind, pricing_mode)
						VALUES ($1, 'bad-mode', 'X', 'external', 'https://h.example.com', 'bearer', 'monthly')`, cid("mep", 91))
					wantState(t, err, "23514")
					return
				}
				wantConstraint(t, ins(c.team, fmt.Sprintf("shape-%d", seq), cols, vals), "23514", c.constraint)
			})
		}
		_, err := conn.Exec(t.Context(), `INSERT INTO afs.model_endpoints (id, slug, display_name, provider, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, 'unknown-provider', 'X', 'nope', 'external', 'https://h.example.com', 'bearer', 'per_token')`, cid("mep", 92))
		wantConstraint(t, err, "23503", "model_endpoints_provider_fkey")
	})
	t.Run("accepted shapes and the derived provider", func(t *testing.T) {
		wantOK(t, ins(team1, "ns-vllm", ", location, base_url, auth_kind, pricing_mode, metrics_port", ", 'in_namespace', 'http://vllm.afs-t-team-1.svc.cluster.local:8000/v1', 'none', 'capacity', 9100"))
		wantOK(t, ins(team1, "ns-short", ", location, base_url, auth_kind", ", 'in_namespace', 'http://vllm:8000/v1', 'none'"))
		wantOK(t, ins(team1, "team-openai", ", base_url", ", 'https://api.openai.com/v1'"))
		wantOK(t, ins(team1, "team-corp", ", location, base_url", ", 'corporate', 'https://llm.corp.example.com'"))
		wantOK(t, ins(nil, "svc-other", ", provider", ", 'openai'"))
		wantOK(t, ins(team1, "team-claims", ", provider", ", 'openai'")) // a team cannot choose its provider
		wantOK(t, ins(nil, "svc-header", ", auth_kind, auth_header", ", 'header', 'api-key'"))
		got := lines(t, conn, "", `SELECT slug || '=' || provider FROM afs.model_endpoints WHERE slug IN ('ns-vllm', 'ns-short', 'team-openai', 'team-corp', 'svc-other', 'team-claims', 'corp-llm') ORDER BY slug`)
		if got != "corp-llm=internal,ns-short=internal,ns-vllm=internal,svc-other=openai,team-claims=other,team-corp=internal,team-openai=openai" {
			t.Errorf("providers %s", got)
		}
	})
	t.Run("level, slug and built-in flag are fixed; built-ins stay", func(t *testing.T) {
		_, err := conn.Exec(t.Context(), `UPDATE afs.model_endpoints SET slug = 'renamed' WHERE id = $1`, epOpenAI)
		wantConstraint(t, err, "55000", "model_endpoints_identity_immutable")
		_, err = conn.Exec(t.Context(), `UPDATE afs.model_endpoints SET team_id = $2 WHERE id = $1`, epOpenAI, team1)
		wantState(t, err, "55000")
		_, err = conn.Exec(t.Context(), `DELETE FROM afs.model_endpoints WHERE id = $1`, epNous)
		wantState(t, err, "55000")
		mustExec(t, conn, `DELETE FROM afs.model_endpoints WHERE slug = 'svc-header'`)
	})
	t.Run("CD-43 placeholders block switching a built-in on", func(t *testing.T) {
		_, err := conn.Exec(t.Context(), `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, epVertex)
		wantState(t, err, "23514") // google is off: provider_disabled comes first
		mustExec(t, conn, `UPDATE afs.inference_providers SET enabled = true WHERE provider IN ('azure', 'google')`)
		_, err = conn.Exec(t.Context(), `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, epAzure)
		wantConstraint(t, err, "23514", "endpoint_base_url_placeholder")
		mustExec(t, conn, `UPDATE afs.model_endpoints SET base_url = 'https://myres.openai.azure.com/openai/v1', enabled = true WHERE id = $1`, epAzure)
	})
	t.Run("external system link: service catalog or own team", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.teams SET may_add_external_systems = true WHERE id = $1`, team2)
		mustExec(t, conn, `INSERT INTO afs.external_systems (id, team_id, slug, name, category, owner, purpose, endpoints)
			VALUES ($1, $2, 'b-llm', 'B LLM', 'llm', 'o', 'p', '{llm.b.example.com}')`, cid("ext", 1), team2)
		wantConstraint(t, ins(team1, "linked", ", external_system_id", ", '"+cid("ext", 1)+"'"), "23503", "model_endpoints_external_system_id_fkey")
		wantOK(t, ins(team2, "linked", ", external_system_id", ", '"+cid("ext", 1)+"'"))
	})
}

// TC-DB-03 (with TestCrossTeamWritesChangeNothing), TC-DB-04, TC-DB-13, MEG-DB-4: who may write what.
func TestModelGatewayPermissions(t *testing.T) {
	conn, team1, _, team2, _ := gwWorld(t)
	ctx := t.Context()
	newTeamEndpoint := func(team, id, slug string) error {
		return runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team+"'", `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, $2, $3, 'Mine', 'o', 'p', 'external', 'https://llm.team.example.com', 'bearer', 'free')`, id, team, slug)
	}
	t.Run("TC-DB-04 the team switches are service-admin only", func(t *testing.T) {
		for _, set := range []string{"may_add_model_endpoints = true", "gateway_deployment = 'per_namespace'"} {
			wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `UPDATE afs.teams SET `+set+` WHERE id = $1`, team1), "42501")
		}
		_, err := conn.Exec(ctx, `UPDATE afs.teams SET gateway_deployment = 'sideways' WHERE id = $1`, team1)
		wantState(t, err, "23514")
		wantState(t, newTeamEndpoint(team1, cid("mep", 20), "mine"), "42501")
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.teams SET may_add_model_endpoints = true, gateway_deployment = 'per_namespace' WHERE id = $1`, team1))
		wantOK(t, newTeamEndpoint(team1, cid("mep", 20), "mine"))
		// Team A cannot declare an endpoint for team B, nor a service endpoint.
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, $2, 'theirs', 'X', 'o', 'p', 'external', 'https://h.example.com', 'bearer', 'free')`, cid("mep", 21), team2), "42501")
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.model_endpoints (id, slug, display_name, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, 'svc-by-team', 'X', 'external', 'https://h.example.com', 'bearer', 'free')`, cid("mep", 22)), "42501")
		// A service endpoint is read by every team but changed by none.
		if n, err := asApp(t, conn, "SET LOCAL afs.team_ids = '"+team1+"'", `UPDATE afs.model_endpoints SET enabled = false WHERE id = $1`, epOpenAI); err != nil || n != 0 {
			t.Errorf("team updated a service endpoint: %d %v", n, err)
		}
		if n := scalar[int](t, conn, teamAdmin(team1), `SELECT count(*) FROM afs.model_endpoints WHERE team_id IS NULL`); n != 7 {
			t.Errorf("team sees %d service endpoints", n)
		}
	})
	t.Run("TC-DB-04 extra terms need a service admin", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, epOpenRouter)
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epOpenRouter), "42501")
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id, selected_by) VALUES ($1, $2, 'team_admin')`, team1, epOpenRouter))
		if got := scalar[string](t, conn, "", `SELECT selected_by FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team1, epOpenRouter); got != "service_admin" {
			t.Errorf("selected_by %s", got)
		}
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `DELETE FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team1, epOpenRouter), "42501")
		// A team-admin opts in and out of an ordinary endpoint, recorded as team_admin whatever it claims.
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id, selected_by) VALUES ($1, $2, 'service_admin')`, team1, epOpenAI))
		if got := scalar[string](t, conn, "", `SELECT selected_by FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team1, epOpenAI); got != "team_admin" {
			t.Errorf("selected_by %s", got)
		}
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `DELETE FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team1, epOpenAI))
		// Team A cannot opt team B in.
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team2, epOpenAI), "42501")
		// A team's own endpoint is not selected: it is always in the set.
		_, err := conn.Exec(ctx, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, cid("mep", 20))
		wantConstraint(t, err, "23514", "team_model_endpoints_service_only")
	})
	t.Run("TC-DB-13 the provider policy is service-admin only", func(t *testing.T) {
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `UPDATE afs.inference_providers SET enabled = false WHERE provider = 'openrouter'`), "42501")
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.inference_providers (provider, display_name, hosts, enabled) VALUES ('mine', 'Mine', '{x.example.com}', true)`), "42501")
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.inference_providers SET hosts = '{}' WHERE provider = 'openai'`), "42501") // not a granted column
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `DELETE FROM afs.inference_providers WHERE provider = 'openai'`), "42501")
		before := scalar[int64](t, conn, "", `SELECT version FROM afs.inference_providers WHERE provider = 'azure'`)
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'; SET LOCAL afs.actor = 'usr_admin'", `UPDATE afs.inference_providers SET enabled = true WHERE provider = 'azure'`))
		if got := queryRow(t, conn, `SELECT version, changed_by FROM afs.inference_providers WHERE provider = 'azure'`); got[0] != fmt.Sprint(before+1) || got[1] != "usr_admin" {
			t.Errorf("version and changed_by %v", got)
		}
		_, err := conn.Exec(ctx, `UPDATE afs.inference_providers SET provider = 'azure2' WHERE provider = 'azure'`)
		wantState(t, err, "55000")
		_, err = conn.Exec(ctx, `UPDATE afs.inference_providers SET fallback_model = 'azure-openai/gpt' WHERE provider = 'azure'`)
		wantConstraint(t, err, "23514", "inference_providers_fallback_bedrock")
		// Azure is service-selected: a team-admin cannot opt in to its endpoints; a service admin can.
		mustExec(t, conn, `UPDATE afs.model_endpoints SET base_url = 'https://myres.openai.azure.com/openai/v1', enabled = true WHERE id = $1`, epAzure)
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epAzure), "42501")
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epAzure))
	})
	t.Run("TC-DB-03 team A sees none of team B's gateway rows", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.teams SET may_add_model_endpoints = true WHERE id = $1`, team2)
		wantOK(t, newTeamEndpoint(team2, cid("mep", 23), "b-llm"))
		mustExec(t, conn, `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES ($1, 'b-model', 100)`, cid("mep", 23))
		for _, tbl := range []string{"model_endpoints", "endpoint_models", "endpoint_credentials", "team_model_endpoints"} {
			if n := scalar[int](t, conn, teamAdmin(team1), `SELECT count(*) FROM afs.`+tbl+` WHERE team_id = $1`, team2); n != 0 {
				t.Errorf("%s: team 1 sees %d rows of team 2", tbl, n)
			}
		}
		// Writing a model under team B's endpoint is refused (the copied team is B's).
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens, team_id) VALUES ($1, 'sneak', 1, $2)`, cid("mep", 23), team1), "42501")
	})
	t.Run("per-namespace gateways read their own team and the service rows", func(t *testing.T) {
		gw := "SET LOCAL ROLE afs_gateway; SET LOCAL afs.team_ids = '" + team1 + "'"
		if got := lines(t, conn, gw, `SELECT DISTINCT coalesce(team_id, 'service') FROM afs.model_endpoints ORDER BY 1`); got != "service,"+team1 {
			t.Errorf("per-namespace gateway sees %s", got)
		}
		if n := scalar[int](t, conn, "SET LOCAL ROLE afs_gateway", `SELECT count(DISTINCT team_id) FROM afs.model_endpoints`); n != 2 {
			t.Errorf("shared gateway sees %d teams", n)
		}
		if _, err := queryAs(t, conn, "afs_gateway", "", `SELECT * FROM afs.provider_statements`); sqlState(err) != "42501" {
			t.Errorf("gateway reads statements: %v", err)
		}
	})
}

// MEG-DB-4: the grants of section 7.4.6, role by role.
func TestModelGatewayGrants(t *testing.T) {
	conn := migratedStrict(t)
	tables := []string{"inference_providers", "model_endpoints", "endpoint_models", "endpoint_model_prices", "endpoint_price_proposals",
		"endpoint_credentials", "endpoint_federations", "endpoint_capacity_costs", "team_model_endpoints", "agent_model_endpoints",
		"pool_model_endpoints", "provider_statements"}
	has := func(role, tbl, priv string) bool {
		return scalar[bool](t, conn, "", `SELECT has_table_privilege($1, 'afs.'||$2, $3)`, role, tbl, priv)
	}
	for _, tbl := range tables {
		if !has("afs_readonly", tbl, "SELECT") || !has("afs_reconciler", tbl, "SELECT") {
			t.Errorf("%s: readonly and reconciler read every 000023 table", tbl)
		}
		if has("afs_gateway", tbl, "SELECT") != (tbl != "provider_statements") {
			t.Errorf("%s: gateway SELECT", tbl)
		}
		for _, role := range []string{"afs_gateway", "afs_reconciler", "afs_readonly", "afs_edge"} {
			for _, priv := range []string{"INSERT", "DELETE"} {
				if has(role, tbl, priv) {
					t.Errorf("%s may %s %s", role, priv, tbl)
				}
			}
		}
		if has("afs_edge", tbl, "SELECT") {
			t.Errorf("afs_edge reads %s", tbl)
		}
	}
	for tbl, want := range map[string]bool{"model_endpoints": true, "endpoint_model_prices": true, "endpoint_capacity_costs": true,
		"provider_statements": true, "endpoint_federations": true, "endpoint_credentials": false, "team_model_endpoints": false} {
		if has("afs_billing", tbl, "SELECT") != want {
			t.Errorf("billing SELECT %s want %v", tbl, want)
		}
	}
	if !has("afs_billing", "endpoint_price_proposals", "INSERT") || has("afs_billing", "endpoint_model_prices", "INSERT") {
		t.Error("billing proposes, it does not price")
	}
	col := func(role, tbl, column, priv string) bool {
		return scalar[bool](t, conn, "", `SELECT has_column_privilege($1, 'afs.'||$2, $3, $4)`, role, tbl, column, priv)
	}
	for _, c := range []string{"status", "last_error", "checked_at"} {
		if !col("afs_gateway", "endpoint_federations", c, "UPDATE") {
			t.Errorf("gateway updates federation %s", c)
		}
	}
	if col("afs_gateway", "endpoint_federations", "tenant_id", "UPDATE") || !col("afs_reconciler", "endpoint_credentials", "status", "UPDATE") ||
		col("afs_reconciler", "endpoint_credentials", "secret_arn", "UPDATE") {
		t.Error("column grants")
	}
	for _, c := range []string{"enabled", "team_selection", "disabled_reason", "fallback_model"} {
		if !col("afs_app", "inference_providers", c, "UPDATE") {
			t.Errorf("afs_app updates inference_providers.%s", c)
		}
	}
	if col("afs_app", "inference_providers", "hosts", "UPDATE") || has("afs_app", "inference_providers", "DELETE") || has("afs_app", "provider_statements", "UPDATE") {
		t.Error("afs_app writes too much")
	}
	for fn, roles := range map[string][]string{
		"afs.route_admission(text, text)": {"afs_app", "afs_gateway", "afs_reconciler", "afs_readonly"},
		"afs.provider_enabled(text)":      {"afs_app", "afs_gateway", "afs_reconciler", "afs_billing", "afs_readonly"},
		"afs.provider_for_host(text)":     {"afs_app", "afs_gateway", "afs_reconciler"},
	} {
		for _, r := range roles {
			if !scalar[bool](t, conn, "", `SELECT has_function_privilege($1, $2, 'EXECUTE')`, r, fn) {
				t.Errorf("%s cannot execute %s", r, fn)
			}
		}
		if scalar[bool](t, conn, "", `SELECT has_function_privilege('afs_edge', $1, 'EXECUTE')`, fn) {
			t.Errorf("afs_edge executes %s", fn)
		}
	}
	// TC-DB-06: no new column can hold a secret value.
	if n := count(t, conn, `SELECT count(*) FROM information_schema.columns WHERE table_schema = 'afs' AND table_name = ANY ($1)
		AND column_name ~ '(value|password|plaintext|secret_string|api_key|token$)'`, tables); n != 0 {
		t.Errorf("%d value-like columns in the 000023 tables", n)
	}
}

// TC-DB-05, MEG-DB-3: credentials live at _gateway paths, never as values.
func TestEndpointCredentials(t *testing.T) {
	conn, team1, _, _, _ := gwWorld(t)
	ctx := t.Context()
	mustExec(t, conn, `UPDATE afs.teams SET may_add_model_endpoints = true WHERE id = $1`, team1)
	mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode)
		VALUES ($1, $2, 'mine', 'Mine', 'o', 'p', 'external', 'https://llm.team.example.com', 'bearer', 'free'),
		       ($3, $2, 'ns-free', 'NS', 'o', 'p', 'in_namespace', 'http://vllm:8000', 'none', 'free')`, cid("mep", 30), team1, cid("mep", 31))
	mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, slug, display_name, location, base_url, auth_kind, pricing_mode, credential_mode)
		VALUES ($1, 'shared-key', 'Shared', 'external', 'https://shared.example.com', 'bearer', 'free', 'shared')`, cid("mep", 32))
	arn := func(path string) string {
		return "arn:aws:secretsmanager:us-east-1:111122223333:secret:" + path + "-AbCdEf"
	}
	if got := scalar[string](t, conn, "", `SELECT afs.secret_path($1, '_gateway', 'openai-prod')`, team1); got != "afs/afs-t-team-1/_gateway/openai-prod" {
		t.Fatalf("secret_path %s", got)
	}
	put := func(settings, endpoint, scope string, team any, a string) error {
		return in(t, conn, settings, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO afs.endpoint_credentials (endpoint_id, scope, team_id, secret_arn) VALUES ($1, $2, $3, $4)`, endpoint, scope, team, a)
			return err
		})
	}
	ta := teamAdmin(team1)
	t.Run("TC-DB-05 a path other than _gateway/<route> 23514", func(t *testing.T) {
		for _, a := range []string{
			arn("afs/afs-t-team-1/_shared/openai-prod"),
			arn("afs/afs-t-team-1/_gateway/other-route"),
			arn("afs/afs-t-team-2/_gateway/openai-prod"),
			"arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-team-1/_gateway/openai-prod",
			"afs/afs-t-team-1/_gateway/openai-prod",
		} {
			wantConstraint(t, put(ta, epOpenAI, team1, team1, a), "23514", "endpoint_credential_path")
		}
	})
	t.Run("per-team credentials of a service endpoint and of the team's own", func(t *testing.T) {
		wantOK(t, put(ta, epOpenAI, team1, team1, arn("afs/afs-t-team-1/_gateway/openai-prod")))
		wantOK(t, put(ta, cid("mep", 30), team1, team1, arn("afs/afs-t-team-1/_gateway/mine")))
	})
	t.Run("shared credentials: service admins, at the service path", func(t *testing.T) {
		wantState(t, put(ta, cid("mep", 32), "_shared", nil, arn("afs/_service/gateway/shared-key")), "42501")
		wantOK(t, put(appAdmin, cid("mep", 32), "_shared", nil, arn("afs/_service/gateway/shared-key")))
		wantConstraint(t, put(appAdmin, cid("mep", 32), team1, team1, arn("afs/afs-t-team-1/_gateway/shared-key")), "23514", "endpoint_credentials_scope")
		wantConstraint(t, put(appAdmin, epOpenAI, "_shared", nil, arn("afs/_service/gateway/openai-prod")), "23514", "endpoint_credentials_scope")
	})
	t.Run("scope and team agree; no credential for auth none", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.endpoint_credentials (endpoint_id, scope, team_id, secret_arn) VALUES ($1, '_shared', $2, 'x')`, epOpenAI, team1)
		wantConstraint(t, err, "23514", "endpoint_credentials_scope_check")
		wantConstraint(t, put("", cid("mep", 31), team1, team1, arn("afs/afs-t-team-1/_gateway/ns-free")), "23514", "endpoint_credentials_auth_kind")
		team2 := cid("team", 2)
		wantConstraint(t, put("", cid("mep", 30), team2, team2, arn("afs/afs-t-team-2/_gateway/mine")), "23514", "endpoint_credentials_endpoint_team")
	})
	t.Run("the reconciler records status without a new version", func(t *testing.T) {
		before := scalar[int64](t, conn, "", `SELECT version FROM afs.endpoint_credentials WHERE endpoint_id = $1`, epOpenAI)
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.endpoint_credentials SET status = 'missing' WHERE endpoint_id = $1`, epOpenAI))
		if v := scalar[int64](t, conn, "", `SELECT version FROM afs.endpoint_credentials WHERE endpoint_id = $1`, epOpenAI); v != before {
			t.Errorf("version %d -> %d", before, v)
		}
		wantState(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.endpoint_credentials SET secret_arn = 'x' WHERE endpoint_id = $1`, epOpenAI), "42501")
		mustExec(t, conn, `UPDATE afs.endpoint_credentials SET rotated_at = now() WHERE endpoint_id = $1`, epOpenAI)
		if v := scalar[int64](t, conn, "", `SELECT version FROM afs.endpoint_credentials WHERE endpoint_id = $1`, epOpenAI); v != before+1 {
			t.Errorf("a rotation keeps the version %d", v)
		}
	})
}

// MEG-DB-1: route models, prices, proposals, capacity costs, federations and statements.
func TestEndpointModelsPricesAndMetadata(t *testing.T) {
	conn, team1, _, _, _ := gwWorld(t)
	ctx := t.Context()
	t.Run("route models", func(t *testing.T) {
		for _, name := range []string{"/abs", " lead", strings.Repeat("m", 201), "tab\there", ""} {
			_, err := conn.Exec(ctx, `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES ($1, $2, 10)`, epOpenAI, name)
			wantState(t, err, "23514")
		}
		for _, n := range []int{0, 1000001} {
			_, err := conn.Exec(ctx, `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES ($1, 'm', $2)`, epOpenAI, n)
			wantState(t, err, "23514")
		}
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens, team_id) VALUES ($1, 'google/gemini-2.5-pro', 8192, $2)`, epOpenAI, team1))
		if got := scalar[*string](t, conn, "", `SELECT team_id FROM afs.endpoint_models WHERE model_name = 'google/gemini-2.5-pro'`); got != nil {
			t.Errorf("team_id is copied from the endpoint (NULL), got %v", *got)
		}
		mustExec(t, conn, `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) SELECT $1, 'bulk-' || g, 10 FROM generate_series(1, 497) g`, epOpenAI)
		_, err := conn.Exec(ctx, `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES ($1, 'one-too-many', 10)`, epOpenAI)
		wantConstraint(t, err, "23514", "endpoint_models_limit")
		mustExec(t, conn, `DELETE FROM afs.endpoint_models WHERE model_name LIKE 'bulk-%'`)
	})
	t.Run("prices are append-only and written by service admins", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.endpoint_model_prices SET input_per_mtok_usd = 0 WHERE endpoint_id = $1`, epOpenAI)
		wantConstraint(t, err, "55000", "endpoint_model_prices_append_only")
		_, err = conn.Exec(ctx, `DELETE FROM afs.endpoint_model_prices WHERE endpoint_id = $1`, epOpenAI)
		wantConstraint(t, err, "55000", "endpoint_model_prices_append_only")
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team1+"'", `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd)
			VALUES ($1, 'gpt-free', now(), 0, 0)`, epOpenAI), "42501")
		for _, c := range []string{"input_per_mtok_usd = -1", "request_fee_usd = -1", "cached_input_per_mtok_usd = -1"} {
			_, err := conn.Exec(ctx, `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd, request_fee_usd, cached_input_per_mtok_usd)
				SELECT $1, 'gpt-free', now(), 1, 1, 0, NULL FROM (SELECT 1) x WHERE false`, epOpenAI)
			wantOK(t, err)
			col := strings.Fields(c)[0]
			_, err = conn.Exec(ctx, `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd, `+col+`)
				VALUES ($1, 'gpt-free', now(), 1, 1, -1)`, epOpenAI)
			if col == "input_per_mtok_usd" {
				_, err = conn.Exec(ctx, `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd) VALUES ($1, 'gpt-free', now(), -1, 1)`, epOpenAI)
			}
			wantState(t, err, "23514")
		}
		_, err = conn.Exec(ctx, `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd, source) VALUES ($1, 'gpt-free', now(), 1, 1, 'guess')`, epOpenAI)
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd) VALUES ($1, 'not-listed', now(), 1, 1)`, epOpenAI)
		wantState(t, err, "23503")
	})
	t.Run("proposals: the billing job proposes, a service admin approves", func(t *testing.T) {
		prop := func(id string) error {
			return runAs(t, conn, "afs_billing", "", `INSERT INTO afs.endpoint_price_proposals (id, endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd)
				VALUES ($1, $2, 'gpt-free', now() - interval '1 hour', 0.5, 1.5)`, id, epOpenAI)
		}
		wantOK(t, prop(cid("epp", 1)))
		wantState(t, prop(cid("epp", 2)), "23505") // one pending per model
		_, err := conn.Exec(ctx, `INSERT INTO afs.endpoint_price_proposals (id, endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd, state)
			VALUES ($1, $2, 'gpt-x', now(), 1, 1, 'approved')`, cid("epp", 3), epOpenAI)
		wantConstraint(t, err, "23514", "endpoint_price_proposals_pending")
		wantState(t, runAs(t, conn, "afs_billing", "", `UPDATE afs.endpoint_price_proposals SET state = 'approved' WHERE id = $1`, cid("epp", 1)), "42501")
		if n, err := asApp(t, conn, "SET LOCAL afs.team_ids = '"+team1+"'", `UPDATE afs.endpoint_price_proposals SET state = 'approved' WHERE id = $1`, cid("epp", 1)); err != nil || n != 0 {
			t.Errorf("a team approved a price: %d %v", n, err)
		}
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.endpoint_price_proposals SET state = 'superseded' WHERE id = $1`, cid("epp", 1)), "42501")
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'; SET LOCAL afs.actor = 'usr_admin'", `UPDATE afs.endpoint_price_proposals SET state = 'approved' WHERE id = $1`, cid("epp", 1)))
		if got := queryRow(t, conn, `SELECT input_per_mtok_usd::text, approved_by, source, (effective_from >= now() - interval '1 minute')::text FROM afs.endpoint_model_prices WHERE model_name = 'gpt-free'`); strings.Join(got, "|") != "0.500000|usr_admin|price_list|true" {
			t.Errorf("approved price %v", got)
		}
		_, err = conn.Exec(ctx, `UPDATE afs.endpoint_price_proposals SET state = 'rejected' WHERE id = $1`, cid("epp", 1))
		wantState(t, err, "55000")
		wantOK(t, prop(cid("epp", 4)))
		wantOK(t, runAs(t, conn, "afs_billing", "", `UPDATE afs.endpoint_price_proposals SET state = 'superseded' WHERE id = $1`, cid("epp", 4)))
	})
	t.Run("capacity costs", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, slug, display_name, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, 'gpu-pool', 'GPU', 'corporate', 'https://gpu.corp.example.com', 'none', 'capacity')`, cid("mep", 40))
		cost := func(settings, endpoint, amounts string) error {
			return in(t, conn, settings, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO afs.endpoint_capacity_costs (endpoint_id, team_id, effective_from, monthly_usd, hourly_usd) VALUES ($1, $2, '2026-11-01', `+amounts+`)`, endpoint, team1)
				return err
			})
		}
		wantConstraint(t, cost("", cid("mep", 40), "10, 1"), "23514", "endpoint_capacity_costs_amount_check")
		wantConstraint(t, cost("", cid("mep", 40), "NULL, NULL"), "23514", "endpoint_capacity_costs_amount_check")
		wantConstraint(t, cost("", epOpenAI, "10, NULL"), "23514", "endpoint_capacity_costs_mode")
		wantState(t, cost(teamAdmin(team1), cid("mep", 40), "10, NULL"), "42501")
		wantOK(t, cost(appAdmin, cid("mep", 40), "10, NULL"))
		if n := scalar[int](t, conn, teamAdmin(team1), `SELECT count(*) FROM afs.endpoint_capacity_costs`); n != 1 {
			t.Errorf("team reads its capacity cost: %d", n)
		}
		_, err := conn.Exec(ctx, `UPDATE afs.endpoint_capacity_costs SET allocation = 'by_magic'`)
		wantState(t, err, "23514")
	})
	t.Run("federations: identifiers only, written by service admins, status by the gateway", func(t *testing.T) {
		fed := func(settings, endpoint, kind, cols, vals string) error {
			return in(t, conn, settings, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO afs.endpoint_federations (endpoint_id, team_id, kind`+cols+`) VALUES ($1, $2, $3`+vals+`)`, endpoint, team1, kind)
				return err
			})
		}
		az := ", tenant_id, client_id"
		azv := ", '11111111-2222-3333-4444-555555555555', '66666666-7777-8888-9999-000000000000'"
		gc := ", project_number, pool_id, provider_id, project_id, location"
		gcv := ", '123456789012', 'afs-pool', 'aws-afs', 'team-one-ai', 'us-central1'"
		wantConstraint(t, fed("", epAzure, "azure", ", tenant_id", ", '11111111-2222-3333-4444-555555555555'"), "23514", "endpoint_federations_fields_check")
		wantConstraint(t, fed("", epAzure, "azure", az+", project_id", azv+", 'team-one-ai'"), "23514", "endpoint_federations_fields_check")
		wantState(t, fed("", epAzure, "azure", az, ", 'not-a-uuid', '66666666-7777-8888-9999-000000000000'"), "23514")
		wantConstraint(t, fed("", epAzure, "google", gc, gcv), "23514", "endpoint_federations_kind")
		wantConstraint(t, fed("", epOpenAI, "azure", az, azv), "23514", "endpoint_federations_kind")
		wantState(t, fed("", epVertex, "google", gc, ", 'abc', 'afs-pool', 'aws-afs', 'team-one-ai', 'us-central1'"), "23514")
		wantState(t, fed(teamAdmin(team1), epAzure, "azure", az, azv), "42501")
		wantOK(t, fed(appAdmin, epAzure, "azure", az, azv))
		wantOK(t, fed(appAdmin, epVertex, "google", gc, gcv))
		before := scalar[int64](t, conn, "", `SELECT version FROM afs.endpoint_federations WHERE endpoint_id = $1`, epAzure)
		wantOK(t, runAs(t, conn, "afs_gateway", "SET LOCAL afs.team_ids = '"+team1+"'", `UPDATE afs.endpoint_federations SET status = 'failing', last_error = 'AADSTS70021', checked_at = now() WHERE endpoint_id = $1`, epAzure))
		if v := scalar[int64](t, conn, "", `SELECT version FROM afs.endpoint_federations WHERE endpoint_id = $1`, epAzure); v != before {
			t.Errorf("gateway status bumped the version %d -> %d", before, v)
		}
		wantState(t, runAs(t, conn, "afs_gateway", "", `UPDATE afs.endpoint_federations SET tenant_id = NULL WHERE endpoint_id = $1`, epAzure), "42501")
		// A per-namespace gateway of another team changes nothing.
		if n := scalar[int](t, conn, "SET LOCAL ROLE afs_gateway; SET LOCAL afs.team_ids = '"+cid("team", 2)+"'", `SELECT count(*) FROM afs.endpoint_federations`); n != 0 {
			t.Errorf("team 2's gateway sees %d federations of team 1", n)
		}
	})
	t.Run("provider statements", func(t *testing.T) {
		stmt := func(settings, id, period, rows string) error {
			return in(t, conn, settings, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO afs.provider_statements (id, endpoint_id, period, source, rows) VALUES ($1, $2, $3::date, 'nous_statement', $4::jsonb)`, id, epNous, period, rows)
				return err
			})
		}
		good := `[{"teamId": "` + team1 + `", "model": "hermes-4-70b", "amountUsd": 12.5, "tokens": 1000}]`
		for _, bad := range []string{`{}`, `[{"teamId": "x", "model": "m", "amountUsd": 1}]`, `[{"teamId": "` + team1 + `", "model": "m"}]`,
			`[{"teamId": "` + team1 + `", "model": "m", "amountUsd": -1}]`, `[{"teamId": "` + team1 + `", "model": "m", "amountUsd": 1, "tokens": 1.5}]`,
			`[{"teamId": "` + team1 + `", "model": "m", "amountUsd": 1, "extra": true}]`} {
			wantState(t, stmt("", cid("pst", 1), "2026-10-01", bad), "23514")
		}
		wantState(t, stmt("", cid("pst", 1), "2026-10-15", good), "23514")
		wantState(t, stmt(teamAdmin(team1), cid("pst", 1), "2026-10-01", good), "42501")
		wantOK(t, stmt(appAdmin, cid("pst", 1), "2026-10-01", good))
		wantState(t, stmt(appAdmin, cid("pst", 2), "2026-10-01", good), "23505")
		if n := scalar[int](t, conn, teamAdmin(team1), `SELECT count(*) FROM afs.provider_statements`); n != 0 {
			t.Errorf("a team reads statements: %d", n)
		}
		if n := scalar[int](t, conn, "SET LOCAL ROLE afs_billing", `SELECT count(*) FROM afs.provider_statements`); n != 1 {
			t.Errorf("billing reads %d statements", n)
		}
		_, err := conn.Exec(ctx, `UPDATE afs.model_endpoints SET enabled = enabled WHERE id = $1`, epNous)
		wantOK(t, err)
	})
}

// TC-DB-07, TC-DB-08, TC-DB-11, TC-DB-12, MEG-DB-3: the effective set and the admission reasons in order.
func TestRouteAdmission(t *testing.T) {
	conn, team1, orch1, team2, _ := gwWorld(t)
	ctx := t.Context()
	worker := cid("agt", 70)
	wantOK(t, addAgent(t, conn, worker, team1, "routed", "worker", nil, "team_shared"))
	mustExec(t, conn, `UPDATE afs.agents SET route_access = 'selected' WHERE id = $1`, worker)
	adminT1 := "SET LOCAL afs.team_ids = '" + team1 + "'"

	t.Run("TC-DB-08 a switched-on endpoint reaches no team until it opts in", func(t *testing.T) {
		if got := effectiveRoutes(t, conn, orch1); got != "" {
			t.Errorf("before opt-in: %q", got)
		}
		if got := routeAdmission(t, conn, "agent", orch1); !strings.Contains(got, "openai-prod/gpt-x=route_not_enabled_for_team") {
			t.Errorf("admission %s", got)
		}
		wantOK(t, runAs(t, conn, "afs_app", adminT1, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epOpenAI))
		if got := effectiveRoutes(t, conn, orch1); got != "openai-prod/gpt-x" {
			t.Errorf("after opt-in: %q (gpt-free has no price)", got)
		}
		if got := effectiveRoutes(t, conn, orch1+"-none"); got != "" {
			t.Error("unknown subject")
		}
		if got := lines(t, conn, "", `SELECT DISTINCT subject_id FROM afs.effective_agent_routes WHERE team_id = $1 ORDER BY 1`, team2); got != "" {
			t.Errorf("team 2 got routes: %s", got)
		}
	})
	t.Run("TC-DB-07 reasons in order", func(t *testing.T) {
		// Agent level: selected with no rows.
		if got := routeAdmission(t, conn, "agent", worker); got != "corp-llm/llama-corp=route_not_enabled_for_team,openai-prod/gpt-free=route_not_enabled_for_agent,openai-prod/gpt-x=route_not_enabled_for_agent" {
			t.Errorf("agent: %s", got)
		}
		wantOK(t, runAs(t, conn, "afs_app", adminT1, `INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) VALUES ($1, $2, $3)`, team1, worker, epOpenAI))
		if got := routeAdmission(t, conn, "agent", worker); !strings.Contains(got, "openai-prod/gpt-free=model_not_priced") || !strings.Contains(got, "openai-prod/gpt-x=ok") {
			t.Errorf("priced: %s", got)
		}
		// A disabled model is absent: model_not_on_route is the gateway's.
		mustExec(t, conn, `UPDATE afs.endpoint_models SET enabled = false WHERE endpoint_id = $1 AND model_name = 'gpt-free'`, epOpenAI)
		if got := routeAdmission(t, conn, "agent", worker); strings.Contains(got, "gpt-free") {
			t.Errorf("a disabled model is listed: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.endpoint_models SET enabled = true WHERE endpoint_id = $1 AND model_name = 'gpt-free'`, epOpenAI)
		// Service level beats team and agent; provider beats service.
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = false WHERE id = $1`, epOpenAI)
		if got := routeAdmission(t, conn, "agent", worker); !strings.Contains(got, "openai-prod/gpt-x=route_not_enabled_for_service") {
			t.Errorf("service: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.inference_providers SET enabled = false WHERE provider = 'openai'`)
		if got := routeAdmission(t, conn, "agent", worker); !strings.Contains(got, "openai-prod/gpt-x=provider_disabled") || !strings.Contains(got, "openai-prod/gpt-free=provider_disabled") {
			t.Errorf("provider: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.inference_providers SET enabled = true WHERE provider = 'openai'`)
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, epOpenAI)
		// A future price does not make a model callable.
		mustExec(t, conn, `INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd) VALUES ($1, 'gpt-free', now() + interval '1 day', 0, 0)`, epOpenAI)
		if got := routeAdmission(t, conn, "agent", worker); !strings.Contains(got, "openai-prod/gpt-free=model_not_priced") {
			t.Errorf("future price: %s", got)
		}
		// A free route needs no price.
		wantOK(t, runAs(t, conn, "afs_app", adminT1, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epCorp))
		if got := routeAdmission(t, conn, "agent", orch1); !strings.Contains(got, "corp-llm/llama-corp=ok") {
			t.Errorf("free: %s", got)
		}
		if got := routeAdmission(t, conn, "pool", worker); got != "" {
			t.Errorf("a kind mismatch returns nothing: %s", got)
		}
	})
	t.Run("agent routes: only the team's set, at most 50", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) VALUES ($1, $2, $3)`, team1, worker, epNous)
		wantConstraint(t, err, "23514", "agent_routes_team")
		mustExec(t, conn, `UPDATE afs.teams SET may_add_model_endpoints = true WHERE id = $1`, team2)
		mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, $2, 'b-only', 'B', 'o', 'p', 'external', 'https://b.example.com', 'bearer', 'free')`, cid("mep", 71), team2)
		_, err = conn.Exec(ctx, `INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) VALUES ($1, $2, $3)`, team1, worker, cid("mep", 71))
		wantConstraint(t, err, "23514", "agent_routes_team")
		mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, slug, display_name, location, base_url, auth_kind, pricing_mode, enabled)
			SELECT 'mep_01JD3Z5Y8K2M4N6P8Q0R2S' || lpad(g::text, 4, '0'), 'bulk-' || g, 'B', 'corporate', 'https://b.corp.example.com', 'none', 'free', true FROM generate_series(1000, 1049) g`)
		mustExec(t, conn, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) SELECT $1, 'mep_01JD3Z5Y8K2M4N6P8Q0R2S' || lpad(g::text, 4, '0') FROM generate_series(1000, 1049) g`, team1)
		mustExec(t, conn, `INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) SELECT $1, $2, 'mep_01JD3Z5Y8K2M4N6P8Q0R2S' || lpad(g::text, 4, '0') FROM generate_series(1000, 1048) g`, team1, worker)
		_, err = conn.Exec(ctx, `INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) VALUES ($1, $2, 'mep_01JD3Z5Y8K2M4N6P8Q0R2S1049')`, team1, worker)
		wantConstraint(t, err, "23514", "agent_model_endpoints_limit")
		mustExec(t, conn, `DELETE FROM afs.model_endpoints WHERE slug LIKE 'bulk-%'`)
	})
	t.Run("TC-DB-11 switching an endpoint off and on keeps the opt-ins", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = false WHERE id = $1`, epOpenAI)
		if got := effectiveRoutes(t, conn, orch1); strings.Contains(got, "openai-prod") {
			t.Errorf("off: %s", got)
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.team_model_endpoints WHERE endpoint_id = $1`, epOpenAI); n != 1 {
			t.Errorf("opt-ins %d", n)
		}
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, epOpenAI)
		if got := effectiveRoutes(t, conn, orch1); !strings.Contains(got, "openai-prod/gpt-x") {
			t.Errorf("on again: %s", got)
		}
	})
	t.Run("TC-DB-12 a provider switched off: service and team endpoints, internal unaffected", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.teams SET may_add_model_endpoints = true WHERE id = $1`, team1)
		mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode, enabled) VALUES
			($1, $2, 'team-openai', 'T', 'o', 'p', 'external', 'https://api.openai.com/v1', 'bearer', 'free', true),
			($3, $2, 'team-vllm', 'V', 'o', 'p', 'in_namespace', 'http://vllm:8000/v1', 'none', 'capacity', true)`, cid("mep", 72), team1, cid("mep", 73))
		mustExec(t, conn, `INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES ($1, 'gpt-team', 100), ($2, 'qwen', 100)`, cid("mep", 72), cid("mep", 73))
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.inference_providers SET enabled = false, disabled_reason = 'policy' WHERE provider = 'openai'`))
		got := routeAdmission(t, conn, "agent", orch1)
		for _, want := range []string{"openai-prod/gpt-x=provider_disabled", "team-openai/gpt-team=provider_disabled", "team-vllm/qwen=ok", "corp-llm/llama-corp=ok"} {
			if !strings.Contains(got, want) {
				t.Errorf("want %s in %s", want, got)
			}
		}
		if got := effectiveRoutes(t, conn, orch1); got != "corp-llm/llama-corp,team-vllm/qwen" {
			t.Errorf("effective while off: %s", got)
		}
		// A team endpoint whose host is the disabled provider's is refused at create and update.
		_, err := conn.Exec(ctx, `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, $2, 'sneaky', 'S', 'o', 'p', 'external', 'https://api.openai.com/v1', 'bearer', 'free')`, cid("mep", 74), team1)
		wantConstraint(t, err, "23514", "provider_disabled")
		mustExec(t, conn, `INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode)
			VALUES ($1, $2, 'mover', 'M', 'o', 'p', 'external', 'https://llm.team.example.com', 'bearer', 'free')`, cid("mep", 75), team1)
		_, err = conn.Exec(ctx, `UPDATE afs.model_endpoints SET base_url = 'https://api.openai.com/v1' WHERE id = $1`, cid("mep", 75))
		wantConstraint(t, err, "23514", "provider_disabled")
		// An endpoint of the disabled provider can be switched off and edited while off, not switched on.
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = false WHERE id = $1`, cid("mep", 72))
		mustExec(t, conn, `UPDATE afs.model_endpoints SET display_name = 'Renamed' WHERE id = $1`, cid("mep", 72))
		_, err = conn.Exec(ctx, `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, cid("mep", 72))
		wantConstraint(t, err, "23514", "provider_disabled")
		// Turning it back on restores everything.
		mustExec(t, conn, `UPDATE afs.inference_providers SET enabled = true, disabled_reason = NULL WHERE provider = 'openai'`)
		if got := effectiveRoutes(t, conn, orch1); !strings.Contains(got, "openai-prod/gpt-x") {
			t.Errorf("on again: %s", got)
		}
	})
	t.Run("gateway and app read admission with their scopes", func(t *testing.T) {
		gw := "SET LOCAL ROLE afs_gateway; SET LOCAL afs.team_ids = '" + team1 + "'"
		if got := lines(t, conn, gw, `SELECT count(*)::text FROM afs.route_admission('agent', $1) WHERE reason IS NULL`, orch1); got == "0" {
			t.Error("the team's gateway admits nothing")
		}
		if got := lines(t, conn, teamAdmin(team2), `SELECT count(*)::text FROM afs.effective_agent_routes WHERE team_id = $1`, team1); got != "0" {
			t.Errorf("team 2 reads team 1's routes: %s", got)
		}
	})
}

// CD-42, MEG-DB-2: a default model may be a route model.
func TestRouteDefaultModels(t *testing.T) {
	conn, team1, orch1, _, _ := gwWorld(t)
	ctx := t.Context()
	mustExec(t, conn, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epOpenAI)
	w := cid("agt", 80)
	newWorker := func(id, def string) error {
		return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, iam_identity)
				VALUES ($1, $2, $3, 'omp', 'ghcr.io/x/img@`+collabDigest+`', $4, 'team_shared')`, id, team1, "w"+id[len(id)-3:], def)
			return err
		})
	}
	t.Run("<route>/<model> is split into default_route and the model name", func(t *testing.T) {
		wantOK(t, newWorker(w, "openai-prod/gpt-x"))
		if got := queryRow(t, conn, `SELECT default_route, default_model_id, model_id FROM afs.agents WHERE id = $1`, w); strings.Join(got, "|") != "openai-prod|gpt-x|gpt-x" {
			t.Errorf("split %v", got)
		}
		if got := effectiveRoutes(t, conn, w); got != "openai-prod/gpt-x*" {
			t.Errorf("is_default %s", got)
		}
		if got := lines(t, conn, "", `SELECT model_id FROM afs.effective_agent_models WHERE subject_id = $1 AND is_default`, w); got != "" {
			t.Errorf("a Bedrock model is the default too: %s", got)
		}
	})
	t.Run("a default that is no model at all 23503", func(t *testing.T) {
		wantConstraint(t, newWorker(cid("agt", 81), "claude-nope"), "23503", "agents_default_model_id_fkey")
		wantConstraint(t, newWorker(cid("agt", 81), "openai-prod/not-listed"), "23503", "agents_default_model_id_fkey")
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET model_id = 'claude-nope' WHERE id = $1`, orch1)
		wantConstraint(t, err, "23503", "agents_default_model_id_fkey")
	})
	t.Run("a route default outside the agent's routes at commit 23514", func(t *testing.T) {
		wantConstraint(t, newWorker(cid("agt", 82), "openai-prod/gpt-free"), "23514", "agents_default_route_allowed") // unpriced
		_, err := conn.Exec(ctx, `UPDATE afs.agents SET route_access = 'selected' WHERE id = $1`, w)
		wantConstraint(t, err, "23514", "agents_default_route_allowed")
		wantOK(t, pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `UPDATE afs.agents SET route_access = 'selected' WHERE id = $1`, w); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) VALUES ($1, $2, $3)`, team1, w, epOpenAI)
			return err
		}))
		_, err = conn.Exec(ctx, `DELETE FROM afs.agent_model_endpoints WHERE agent_id = $1`, w)
		wantConstraint(t, err, "23514", "agents_default_route_allowed")
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET default_route = 'corp-llm', default_model_id = 'llama-corp' WHERE id = $1`, w)
		wantConstraint(t, err, "23514", "agents_default_route_allowed")
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET default_route = 'Bad Route' WHERE id = $1`, w)
		wantConstraint(t, err, "23514", "agents_default_route_check")
		_, err = conn.Exec(ctx, `UPDATE afs.agents SET route_access = 'some' WHERE id = $1`, w)
		wantState(t, err, "23514")
	})
	t.Run("back to a Bedrock default: the 000022 checks apply again", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET default_route = NULL, default_model_id = 'claude-haiku' WHERE id = $1`, w)
		if got := queryRow(t, conn, `SELECT coalesce(default_route, '-'), default_model_id, model_id FROM afs.agents WHERE id = $1`, w); strings.Join(got, "|") != "-|claude-haiku|claude-haiku" {
			t.Errorf("bedrock again %v", got)
		}
		mustExec(t, conn, `UPDATE afs.agents SET model_access = 'selected' WHERE id = $1 AND false`, w)
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE afs.agents SET model_access = 'selected' WHERE id = $1`, w)
			return err
		})
		wantConstraint(t, err, "23514", "agents_models_selection_nonempty")
		// With a route default, an agent in selected model access may have no Bedrock model.
		wantOK(t, pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE afs.agents SET model_access = 'selected', default_route = 'openai-prod', default_model_id = 'gpt-x' WHERE id = $1`, w)
			return err
		}))
	})
	t.Run("a Bedrock model in use as a default keeps its row", func(t *testing.T) {
		_, err := conn.Exec(ctx, `DELETE FROM afs.models WHERE id = 'claude-sonnet'`)
		wantConstraint(t, err, "23503", "agents_default_model_id_fkey")
		_, err = conn.Exec(ctx, `UPDATE afs.models SET id = 'claude-sonnet-2' WHERE id = 'claude-sonnet'`)
		wantState(t, err, "23503")
		mustExec(t, conn, `UPDATE afs.models SET display_name = 'Sonnet' WHERE id = 'claude-sonnet'`)
		mustExec(t, conn, `INSERT INTO afs.models (id, provider, display_name) VALUES ('unused', 'x', 'x')`)
		mustExec(t, conn, `DELETE FROM afs.models WHERE id = 'unused'`)
	})
	t.Run("the service default may be a route model; create_orchestration_agent takes it", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '"openai-prod/nope"' WHERE key = 'models.default_model_id'`)
		wantConstraint(t, err, "23514", "service_settings_models_check")
		_, err = conn.Exec(ctx, `UPDATE afs.service_settings SET value = to_jsonb($1::text) WHERE key = 'models.default_model_id'`, "openai-prod/"+strings.Repeat("m", 230))
		wantConstraint(t, err, "23514", "service_settings_models_check")
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"openai-prod/gpt-x"' WHERE key = 'models.default_model_id'`)
		team, agent := cid("team", 5), cid("agt", 85)
		wantOK(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd) VALUES ($1, 'team-5', 'T5', 'CC1', 'o@example.com', 10)`, team); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `SELECT afs.create_orchestration_agent($1, $2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)`, team, agent)
			return err
		}))
		if got := queryRow(t, conn, `SELECT default_route, default_model_id FROM afs.agents WHERE id = $1`, agent); strings.Join(got, "|") != "openai-prod|gpt-x" {
			t.Errorf("orchestration agent default %v", got)
		}
		if got := scalar[string](t, conn, "", `SELECT selected_by FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team, epOpenAI); got != "service_admin" {
			t.Errorf("the new team is selected for the service default route: %s", got)
		}
	})
}

// TC-DB-15, MEG-DB-6: Bedrock can be turned off only with a route fallback selected for every team.
func TestBedrockOffGuard(t *testing.T) {
	conn, team1, orch1, team2, _ := gwWorld(t)
	ctx := t.Context()
	off := func() error {
		return runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.inference_providers SET enabled = false, fallback_model = 'openai-prod/gpt-x' WHERE provider = 'bedrock'`)
	}
	t.Run("with a Bedrock service default: no_fallback_model", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"claude-sonnet"' WHERE key = 'models.default_model_id'`)
		wantConstraint(t, off(), "23514", "no_fallback_model")
		mustExec(t, conn, `UPDATE afs.service_settings SET value = 'null' WHERE key = 'models.default_model_id'`)
		wantConstraint(t, off(), "23514", "no_fallback_model")
	})
	t.Run("with a route default not selected for every team: no_fallback_model", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"openai-prod/gpt-x"' WHERE key = 'models.default_model_id'`)
		mustExec(t, conn, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epOpenAI)
		wantConstraint(t, off(), "23514", "no_fallback_model")
	})
	t.Run("with the route off, or its provider off: no_fallback_model", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team2, epOpenAI)
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = false WHERE id = $1`, epOpenAI)
		wantConstraint(t, off(), "23514", "no_fallback_model")
		mustExec(t, conn, `UPDATE afs.model_endpoints SET enabled = true WHERE id = $1`, epOpenAI)
		mustExec(t, conn, `UPDATE afs.endpoint_models SET enabled = false WHERE endpoint_id = $1 AND model_name = 'gpt-x'`, epOpenAI)
		wantConstraint(t, off(), "23514", "no_fallback_model")
		mustExec(t, conn, `UPDATE afs.endpoint_models SET enabled = true WHERE endpoint_id = $1 AND model_name = 'gpt-x'`, epOpenAI)
	})
	t.Run("with a valid fallback, selected in the same transaction: Bedrock turns off", func(t *testing.T) {
		mustExec(t, conn, `DELETE FROM afs.team_model_endpoints WHERE team_id = $1`, team2)
		wantOK(t, in(t, conn, adminSess, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id)
				SELECT t.id, $1 FROM afs.teams t WHERE t.state <> 'deleted' ON CONFLICT DO NOTHING`, epOpenAI); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE afs.inference_providers SET enabled = false, fallback_model = 'openai-prod/gpt-x' WHERE provider = 'bedrock'`)
			return err
		}))
		if got := scalar[bool](t, conn, "", `SELECT afs.provider_enabled('bedrock')`); got {
			t.Fatal("bedrock still on")
		}
		if n := count(t, conn, `SELECT count(*) FROM afs.effective_agent_models`); n != 0 {
			t.Errorf("%d Bedrock models still effective", n)
		}
		if got := admission(t, conn, "agent", orch1); !strings.Contains(got, "claude-sonnet=provider_disabled") {
			t.Errorf("model admission %s", got)
		}
	})
	t.Run("while Bedrock is off the fallback stays usable", func(t *testing.T) {
		_, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = '"claude-sonnet"' WHERE key = 'models.default_model_id'`)
		wantConstraint(t, err, "23514", "no_fallback_model")
		wantConstraint(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.inference_providers SET enabled = false WHERE provider = 'openai'`), "23514", "no_fallback_model")
		// Turning another provider off is fine.
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.inference_providers SET enabled = false WHERE provider = 'nous'`))
		// A new team is selected for the fallback, so the rule keeps holding.
		team3, _ := orchTeam(t, conn, 3, "public")
		if n := count(t, conn, `SELECT count(*) FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team3, epOpenAI); n != 1 {
			t.Errorf("new team not selected for the fallback")
		}
		if got := queryRow(t, conn, `SELECT default_route, default_model_id FROM afs.agents WHERE team_id = $1 AND role = 'orchestration'`, team3); strings.Join(got, "|") != "openai-prod|gpt-x" {
			// orchTeam passes claude-sonnet explicitly; the agent keeps it.
			if got[1] != "claude-sonnet" {
				t.Errorf("orchestration agent default %v", got)
			}
		}
		// Team-admins cannot opt out of a service-admin selection.
		wantState(t, runAs(t, conn, "afs_app", "SET LOCAL afs.team_ids = '"+team3+"'", `DELETE FROM afs.team_model_endpoints WHERE team_id = $1 AND endpoint_id = $2`, team3, epOpenAI), "42501")
	})
	t.Run("Bedrock back on: Bedrock models return", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_app", "SET LOCAL afs.service_admin = 'on'", `UPDATE afs.inference_providers SET enabled = true WHERE provider = 'bedrock'`))
		if got := effective(t, conn, orch1); !strings.Contains(got, "claude-sonnet*") {
			t.Errorf("Bedrock models back: %s", got)
		}
	})
}

// MEG-DB-2: usage rows of route calls and route costs.
func TestRouteUsageAndCost(t *testing.T) {
	conn, team1, orch1, _, _ := gwWorld(t)
	ctx := t.Context()
	use := func(model, endpoint any, name any, outcome string) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.usage_events (occurred_at, team_id, agent_id, model_id, endpoint_id, model_name, request_id, outcome, usage_source, reasoning_tokens, ttft_ms, upstream_ms, gateway_ms, http_status)
			VALUES (now(), $1, $2, $3, $4, $5, 'req', $6, 'response', 10, 120, 900, 3, 200)`, team1, orch1, model, endpoint, name, outcome)
		return err
	}
	wantOK(t, use(nil, epOpenAI, "gpt-x", "ok"))
	wantOK(t, use("claude-sonnet", nil, nil, "ok"))
	wantOK(t, use(nil, nil, nil, "rejected_model"))
	wantConstraint(t, use(nil, nil, nil, "ok"), "23514", "usage_events_route_check")
	wantConstraint(t, use("claude-sonnet", epOpenAI, "gpt-x", "ok"), "23514", "usage_events_route_check")
	for _, c := range []string{"usage_source = 'guessed'", "http_status = 42", "ttft_ms = -1", "reasoning_tokens = -1"} {
		_, err := conn.Exec(ctx, `UPDATE afs.usage_events SET `+c+` WHERE endpoint_id IS NOT NULL`)
		wantState(t, err, "23514")
	}
	for _, src := range []string{"route", "route_capacity"} {
		_, err := conn.Exec(ctx, `INSERT INTO afs.cost_daily (team_id, day, source, model_id, cost_usd) VALUES ($1, current_date, $2, 'openai-prod/gpt-x', 1)`, team1, src)
		wantOK(t, err)
	}
	_, err := conn.Exec(ctx, `INSERT INTO afs.cost_daily (team_id, day, source, cost_usd) VALUES ($1, current_date, 'routes', 1)`, team1)
	wantState(t, err, "23514")
	if n := count(t, conn, `SELECT count(*) FROM afs.usage_events WHERE endpoint_id = $1 AND gateway_ms = 3`, epOpenAI); n != 1 {
		t.Errorf("route usage rows %d", n)
	}
}

// TC-DB-09, MEG-DB-7: every new table announces a change on afs_desired_state.
func TestModelGatewayChangeFeed(t *testing.T) {
	conn, team1, orch1, _, _ := gwWorld(t)
	ctx := t.Context()
	mustExec(t, conn, `UPDATE afs.teams SET may_add_model_endpoints = true WHERE id = $1`, team1)
	if _, err := conn.Exec(ctx, `LISTEN afs_desired_state`); err != nil {
		t.Fatal(err)
	}
	ep := cid("mep", 60)
	steps := []struct{ sql, payload string }{
		{`UPDATE afs.inference_providers SET disabled_reason = 'x' WHERE provider = 'opencode'`, "inference_providers::opencode"},
		{`INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, owner, purpose, location, base_url, auth_kind, pricing_mode, enabled)
			VALUES ('` + ep + `', '` + team1 + `', 'feed', 'F', 'o', 'p', 'external', 'https://feed.example.com', 'bearer', 'per_token', true)`, "model_endpoints:" + team1 + ":" + ep},
		{`INSERT INTO afs.endpoint_models (endpoint_id, model_name, max_output_tokens) VALUES ('` + ep + `', 'm', 1)`, "endpoint_models:" + team1 + ":" + ep},
		{`INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd) VALUES ('` + ep + `', 'm', now(), 1, 1)`, "endpoint_model_prices:" + team1 + ":" + ep},
		{`INSERT INTO afs.endpoint_price_proposals (id, endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd) VALUES ('` + cid("epp", 60) + `', '` + ep + `', 'm', now(), 1, 1)`, "endpoint_price_proposals:" + team1 + ":" + cid("epp", 60)},
		{`INSERT INTO afs.endpoint_credentials (endpoint_id, scope, team_id, secret_arn) VALUES ('` + ep + `', '` + team1 + `', '` + team1 + `', 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/afs-t-team-1/_gateway/feed-AbCdEf')`, "endpoint_credentials:" + team1 + ":" + ep},
		{`INSERT INTO afs.endpoint_federations (endpoint_id, team_id, kind, tenant_id, client_id) VALUES ('` + epAzure + `', '` + team1 + `', 'azure', '11111111-2222-3333-4444-555555555555', '66666666-7777-8888-9999-000000000000')`, "endpoint_federations:" + team1 + ":" + epAzure},
		{`INSERT INTO afs.endpoint_capacity_costs (endpoint_id, team_id, effective_from, monthly_usd) SELECT '` + epCorp + `', '` + team1 + `', '2026-11-01', 1 FROM (SELECT 1) x WHERE false`, ""},
		{`UPDATE afs.model_endpoints SET pricing_mode = 'capacity' WHERE id = '` + epCorp + `'`, "model_endpoints::" + epCorp},
		{`INSERT INTO afs.endpoint_capacity_costs (endpoint_id, team_id, effective_from, monthly_usd) VALUES ('` + epCorp + `', '` + team1 + `', '2026-11-01', 1)`, "endpoint_capacity_costs:" + team1 + ":" + epCorp},
		{`INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ('` + team1 + `', '` + epOpenAI + `')`, "team_model_endpoints:" + team1 + ":" + epOpenAI},
		{`INSERT INTO afs.agent_model_endpoints (team_id, agent_id, endpoint_id) VALUES ('` + team1 + `', '` + orch1 + `', '` + epOpenAI + `')`, "agent_model_endpoints:" + team1 + ":" + epOpenAI},
		{`INSERT INTO afs.provider_statements (id, endpoint_id, period, source, rows) VALUES ('` + cid("pst", 60) + `', '` + epNous + `', '2026-10-01', 'nous_statement', '[]')`, "provider_statements::" + cid("pst", 60)},
		{`DELETE FROM afs.team_model_endpoints WHERE team_id = '` + team1 + `' AND endpoint_id = '` + epOpenAI + `'`, "team_model_endpoints:" + team1 + ":" + epOpenAI},
	}
	for _, s := range steps {
		if _, err := conn.Exec(ctx, s.sql); err != nil {
			t.Fatalf("%s: %v", s.sql, err)
		}
		if s.payload == "" {
			continue
		}
		var got []string
		deadline := time.Now().Add(2 * time.Second)
		found := false
		for time.Now().Before(deadline) && !found {
			wctx, cancel := context.WithDeadline(ctx, deadline)
			n, err := conn.WaitForNotification(wctx)
			cancel()
			if err != nil {
				break
			}
			got = append(got, n.Payload)
			found = n.Payload == s.payload
		}
		if !found {
			t.Errorf("%s: no %q in %v", strings.Fields(s.sql)[0]+" "+strings.Fields(s.sql)[2], s.payload, got)
		}
	}
	// A pool's route selection announces itself too (swarm teams hold pools).
	if n := count(t, conn, `SELECT count(*) FROM pg_trigger WHERE tgrelid = 'afs.pool_model_endpoints'::regclass AND tgname = 'pool_model_endpoints_notify'`); n != 1 {
		t.Error("pool_model_endpoints has no notify trigger")
	}
	// Revisions carry readable composite ids.
	if got := scalar[string](t, conn, "", `SELECT resource_id FROM afs.config_revisions WHERE resource_kind = 'agent_model_endpoints' ORDER BY id DESC LIMIT 1`); got != team1+"/"+orch1+"/"+epOpenAI {
		t.Errorf("revision id %s", got)
	}
}

// TC-DB-10, MEG-DB-7: up, down, up of 000023, with data.
func TestMigration000023(t *testing.T) {
	t.Run("down restores the 000022 catalog and keeps the data; up again", func(t *testing.T) {
		conn := connect(t)
		ctx := t.Context()
		migs, err := migrate.Load(migrations.FS)
		if err != nil {
			t.Fatal(err)
		}
		if len(migs) < gatewayVersion || migs[gatewayVersion-1].Version != gatewayVersion {
			t.Fatalf("migration %d is not at its place", gatewayVersion)
		}
		if n, err := migrate.Up(ctx, conn, migs[:gatewayVersion-2]); err != nil || n != gatewayVersion-2 {
			t.Fatalf("up to 21: n=%d err=%v", n, err)
		}
		seed21(t, conn) // a 1.0.1 database, brought to 1.1.0
		if n, err := migrate.Up(ctx, conn, migs[:gatewayVersion-1]); err != nil || n != 1 {
			t.Fatalf("up to 22: n=%d err=%v", n, err)
		}
		mustExec(t, conn, `INSERT INTO afs.usage_events (occurred_at, team_id, agent_id, model_id, request_id, outcome) VALUES (now(), $1, $2, 'claude-sonnet', 'r1', 'ok')`, teamA, wrkA)
		want := catalog(t, conn)
		before := queryRow(t, conn, `SELECT (SELECT version::text FROM afs.agents WHERE id = $1), (SELECT version::text FROM afs.teams WHERE id = $2), (SELECT count(*)::text FROM afs.usage_events)`, wrkA, teamA)
		if n, err := migrate.Up(ctx, conn, migs[:gatewayVersion]); err != nil || n != 1 {
			t.Fatalf("up: n=%d err=%v", n, err)
		}
		if got := queryRow(t, conn, `SELECT (SELECT version::text FROM afs.agents WHERE id = $1), (SELECT version::text FROM afs.teams WHERE id = $2), (SELECT count(*)::text FROM afs.usage_events)`, wrkA, teamA); strings.Join(got, "|") != strings.Join(before, "|") {
			t.Errorf("the migration changed existing rows: %v -> %v", before, got)
		}
		if got := queryRow(t, conn, `SELECT route_access, coalesce(default_route, '-'), default_model_id FROM afs.agents WHERE id = $1`, wrkA); strings.Join(got, "|") != "all|-|claude-sonnet" {
			t.Errorf("existing agent %v", got)
		}
		if got := queryRow(t, conn, `SELECT may_add_model_endpoints::text, gateway_deployment FROM afs.teams WHERE id = $1`, teamA); strings.Join(got, "|") != "false|shared" {
			t.Errorf("existing team %v", got)
		}
		if catalog(t, conn) == want {
			t.Fatal("the catalog did not change; the comparison proves nothing")
		}
		// Route usage on the way down keeps its model as <route>/<model>.
		mustExec(t, conn, `INSERT INTO afs.usage_events (occurred_at, team_id, endpoint_id, model_name, request_id, outcome) VALUES (now(), $1, $2, 'hermes', 'r2', 'ok')`, teamA, epNous)
		mustExec(t, conn, `INSERT INTO afs.cost_daily (team_id, day, source, model_id, cost_usd) VALUES ($1, current_date, 'route', 'nous-portal/hermes', 1)`, teamA)
		if n, err := migrate.Down(ctx, conn, migs, 1); err != nil || n != 1 {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		mustExec(t, conn, `DELETE FROM afs.usage_events WHERE request_id = 'r2'; DELETE FROM afs.cost_daily WHERE model_id = 'nous-portal/hermes'`)
		if got := catalog(t, conn); got != want {
			t.Fatalf("down did not restore the 000022 catalog: %s", firstDifference(want, got))
		}
		if n, err := migrate.Up(ctx, conn, migs[:gatewayVersion]); err != nil || n != 1 {
			t.Fatalf("up again: n=%d err=%v", n, err)
		}
	})
	t.Run("down keeps route usage as <route>/<model> and refuses route defaults", func(t *testing.T) {
		conn, team1, _, _, _ := gwWorld(t)
		migs, _ := migrate.Load(migrations.FS)
		mustExec(t, conn, `INSERT INTO afs.usage_events (occurred_at, team_id, endpoint_id, model_name, request_id, outcome) VALUES (now(), $1, $2, 'gpt-x', 'r3', 'ok')`, team1, epOpenAI)
		mustExec(t, conn, `INSERT INTO afs.team_model_endpoints (team_id, endpoint_id) VALUES ($1, $2)`, team1, epOpenAI)
		wantOK(t, addAgent(t, conn, cid("agt", 90), team1, "routed", "worker", nil, "team_shared"))
		mustExec(t, conn, `UPDATE afs.agents SET default_route = 'openai-prod', default_model_id = 'gpt-x' WHERE id = $1`, cid("agt", 90))
		if _, err := migrate.Down(t.Context(), conn, migs, 1); sqlState(err) != "55000" {
			t.Fatalf("down with a route default: %v", err)
		}
		mustExec(t, conn, `UPDATE afs.agents SET default_route = NULL, default_model_id = 'claude-sonnet' WHERE id = $1`, cid("agt", 90))
		if n, err := migrate.Down(t.Context(), conn, migs, 1); err != nil || n != 1 {
			t.Fatalf("down: n=%d err=%v", n, err)
		}
		if got := scalar[string](t, conn, "", `SELECT model_id FROM afs.usage_events WHERE request_id = 'r3'`); got != "openai-prod/gpt-x" {
			t.Errorf("route usage after down: %s", got)
		}
		if n, err := migrate.Up(t.Context(), conn, migs); err != nil || n != 1 {
			t.Fatalf("up again: n=%d err=%v", n, err)
		}
	})
}
