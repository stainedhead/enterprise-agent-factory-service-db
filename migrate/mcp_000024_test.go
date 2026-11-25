package migrate_test

// Migration 000024, governed MCP servers (database contract §7.5; MCP gateway PRD Appendix E.2, TC-47 to TC-62).

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

var (
	mcpE  = cid("mcp", 1) // enterprise server
	mcpE2 = cid("mcp", 2) // second enterprise server
	mcpTA = cid("mcp", 3) // team A's own server
	mcpTB = cid("mcp", 4) // team B's own server
)

const (
	gwTeamA   = "SET LOCAL afs.team_ids = '" + teamA + "'"
	secOp     = "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_sec'; SET LOCAL afs.security_operator = 'on'"
	shaPrefix = "sha256:"
	mcpImage  = "ghcr.io/x/mcp@" + collabDigest
)

func digestOf(c byte) string { return shaPrefix + strings.Repeat(string(c), 64) }

// mcpWorld: teams A and B with their own gateways, team A may add servers, two agents in team A.
func mcpWorld(t *testing.T) *pgx.Conn {
	t.Helper()
	conn := migrated(t)
	seedTeams(t, conn)
	seedAgents(t, conn)
	mustExec(t, conn, `UPDATE afs.teams SET gateway_deployment = 'per_namespace' WHERE id IN ($1, $2)`, teamA, teamB)
	mustExec(t, conn, `UPDATE afs.teams SET may_add_mcp_servers = true WHERE id = $1`, teamA)
	return conn
}

// swarm adds an ephemeral team (pools run only there) with its own gateway, and one pool in it.
func swarm(t *testing.T, conn *pgx.Conn) (team, pool string) {
	t.Helper()
	team, pool = cid("team", 60), cid("pool", 1)
	mustExec(t, conn, `INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule, gateway_deployment)
		VALUES ('`+team+`', 'swarm-s', 'Swarm S', 'ephemeral', 'CC300', 's@example.com', 500, now() + interval '7 days', 'at_work_complete', 'per_namespace');
		INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust) VALUES ('`+cid("bud", 60)+`', '`+team+`', 'lifetime', 300, 'block')`)
	mustExec(t, conn, `INSERT INTO afs.team_models (team_id, model_id) VALUES ($1, 'claude-sonnet')`, team)
	mustExec(t, conn, `INSERT INTO afs.agent_pools (id, team_id, name, template, image, model_id, workers, mcp_access) VALUES ($1, $2, 'scan', 'omp', $3, 'claude-sonnet', 2, 'selected')`,
		pool, team, "ghcr.io/x/omp@"+collabDigest)
	return team, pool
}

// server inserts a remote server as the owner (no role checks); team "" is an enterprise server.
func server(t *testing.T, conn *pgx.Conn, id, team, slug, status string, published bool) {
	t.Helper()
	mustExec(t, conn, `INSERT INTO afs.mcp_servers (id, team_id, slug, display_name, data_classification, transport, location, url, auth_kind, review_status, published)
		VALUES ($1, nullif($2, ''), $3, $3, 'internal', 'streamable_http', 'external', 'https://' || $3 || '.example.com/mcp', 'none', $4, $5)`,
		id, team, slug, status, published)
}

func primitive(t *testing.T, conn *pgx.Conn, n int, srv, name, ann, status string) string {
	t.Helper()
	id := cid("mpr", n)
	mustExec(t, conn, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, annotations, definition, digest, status)
		VALUES ($1, $2, 'tool', $3, $4::jsonb, jsonb_build_object('name', $3::text), $5, $6)`, id, srv, name, ann, digestOf('a'), status)
	return id
}

func asAdmin(t *testing.T, conn *pgx.Conn, sql string, args ...any) error {
	t.Helper()
	return in(t, conn, adminSess, func(tx pgx.Tx) error { _, err := tx.Exec(t.Context(), sql, args...); return err })
}

func mcpAdmission(t *testing.T, conn *pgx.Conn, kind, subject string) string {
	t.Helper()
	rows, err := conn.Query(t.Context(), `SELECT name || '=' || coalesce(reason, 'ok') || coalesce('@' || level, '') || coalesce('/' || rate_limit_per_minute, '')
		FROM afs.mcp_admission($1, $2) ORDER BY slug, name`, kind, subject)
	wantOK(t, err)
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	wantOK(t, err)
	return strings.Join(got, ",")
}

func TestMcpServers(t *testing.T) {
	conn := mcpWorld(t)
	ctx := t.Context()
	insert := func(id, team, slug, transport, location, url, auth, extra string) error {
		return asAdmin(t, conn, `INSERT INTO afs.mcp_servers (id, team_id, slug, display_name, data_classification, transport, location, url, auth_kind`+extra+`)
			VALUES ($1, nullif($2, ''), $3, $3, 'internal', $4, $5, nullif($6, ''), $7`+strings.Repeat(", '{}'", strings.Count(extra, ","))+`)`,
			id, team, slug, transport, location, url, auth)
	}
	t.Run("slug rules", func(t *testing.T) {
		for _, slug := range []string{"afs", "a--b", "Bad", "x", "trailing-", strings.Repeat("a", 32)} {
			wantState(t, insert(cid("mcp", 90), "", slug, "streamable_http", "external", "https://x.example.com", "none", ""), "23514")
		}
	})
	t.Run("enumerations", func(t *testing.T) {
		wantState(t, insert(cid("mcp", 90), "", "stdio-one", "stdio", "external", "https://x.example.com", "none", ""), "23514")
		wantState(t, insert(cid("mcp", 90), "", "loc-one", "streamable_http", "mars", "https://x.example.com", "none", ""), "23514")
		wantState(t, insert(cid("mcp", 90), "", "auth-one", "streamable_http", "external", "https://x.example.com", "api_key", ""), "23514")
	})
	t.Run("url: remote needs https, hosted has none and runs in the namespace", func(t *testing.T) {
		wantConstraint(t, insert(cid("mcp", 90), "", "plain", "streamable_http", "external", "http://x.example.com", "none", ""), "23514", "mcp_servers_url")
		wantConstraint(t, insert(cid("mcp", 90), "", "nourl", "streamable_http", "external", "", "none", ""), "23514", "mcp_servers_url")
		wantConstraint(t, insert(cid("mcp", 90), "", "hosted-url", "hosted", "in_namespace", "https://x.example.com", "none", ""), "23514", "mcp_servers_url")
		wantConstraint(t, insert(cid("mcp", 90), "", "hosted-ext", "hosted", "external", "", "none", ""), "23514", "mcp_servers_url")
		wantConstraint(t, insert(cid("mcp", 90), "", "remote-ns", "streamable_http", "in_namespace", "https://x.example.com", "none", ""), "23514", "mcp_servers_url")
	})
	t.Run("workload federation needs its issuer, audience and token endpoint", func(t *testing.T) {
		wantConstraint(t, insert(cid("mcp", 90), "", "fed", "streamable_http", "corporate", "https://fed.example.com", "workload_federation", ""), "23514", "mcp_servers_federation")
	})
	t.Run("slugs: unique among enterprise servers, per team, and never shared between the two", func(t *testing.T) {
		wantOK(t, insert(mcpE, "", "tickets", "streamable_http", "corporate", "https://tickets.example.com/mcp", "none", ""))
		wantConstraint(t, insert(cid("mcp", 91), "", "tickets", "streamable_http", "external", "https://t2.example.com", "none", ""), "23505", "")
		wantConstraint(t, insert(mcpTA, teamA, "tickets", "streamable_http", "external", "https://t3.example.com", "none", ""), "23505", "mcp_servers_slug_taken")
		wantOK(t, insert(mcpTA, teamA, "docs", "streamable_http", "external", "https://docs.example.com/mcp", "static", ""))
		wantOK(t, insert(mcpTB, teamB, "docs", "streamable_http", "external", "https://docs-b.example.com/mcp", "none", ""))
		wantConstraint(t, insert(cid("mcp", 92), "", "docs", "streamable_http", "external", "https://d.example.com", "none", ""), "23505", "mcp_servers_slug_taken")
	})
	t.Run("review transitions", func(t *testing.T) {
		set := func(status string) error {
			return asAdmin(t, conn, `UPDATE afs.mcp_servers SET review_status = $2 WHERE id = $1`, mcpE, status)
		}
		wantConstraint(t, set("approved"), "23514", "mcp_review_transition")
		wantConstraint(t, set("rejected"), "23514", "mcp_review_transition")
		wantOK(t, set("pending_review"))
		wantOK(t, set("draft")) // changes requested
		wantOK(t, set("pending_review"))
		wantOK(t, set("rejected"))
		wantConstraint(t, set("approved"), "23514", "mcp_review_transition")
		wantOK(t, set("draft"))
		wantOK(t, set("pending_review"))
		wantOK(t, set("approved"))
		wantOK(t, set("suspended"))
		if got := scalar[string](t, conn, "", `SELECT suspended_from FROM afs.mcp_servers WHERE id = $1`, mcpE); got != "approved" {
			t.Errorf("suspended_from %q", got)
		}
		wantConstraint(t, set("draft"), "23514", "mcp_review_transition")
		wantOK(t, set("approved"))
		wantOK(t, set("pending_review")) // a URL change sends it back
		wantOK(t, set("approved"))
	})
	t.Run("publish needs approved; team servers are never published or defaults", func(t *testing.T) {
		wantOK(t, insert(mcpE2, "", "wiki", "streamable_http", "corporate", "https://wiki.example.com/mcp", "none", ""))
		wantConstraint(t, asAdmin(t, conn, `UPDATE afs.mcp_servers SET published = true WHERE id = $1`, mcpE2), "23514", "mcp_servers_publish")
		wantOK(t, asAdmin(t, conn, `UPDATE afs.mcp_servers SET published = true WHERE id = $1`, mcpE))
		_, err := conn.Exec(ctx, `INSERT INTO afs.mcp_servers (id, team_id, slug, display_name, data_classification, transport, location, url, auth_kind, review_status, published)
			VALUES ($1, $2, 'pub', 'pub', 'internal', 'streamable_http', 'external', 'https://pub.example.com', 'none', 'approved', true)`, cid("mcp", 96), teamA)
		wantConstraint(t, err, "23514", "mcp_servers_enterprise_only")
		wantConstraint(t, asAdmin(t, conn, `UPDATE afs.mcp_servers SET default_for_new_teams = true WHERE id = $1`, mcpE2), "23514", "mcp_servers_default_published")
	})
	t.Run("only service admins write enterprise servers or a team's MCP guardrails", func(t *testing.T) {
		n, err := asApp(t, conn, onlyTeamA, `UPDATE afs.mcp_servers SET display_name = 'x' WHERE team_id IS NULL`)
		if err != nil || n != 0 {
			t.Errorf("team A changed %d enterprise servers (%v)", n, err)
		}
		if got := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.mcp_servers`); got != 3 {
			t.Errorf("team A sees %d servers, want 2 enterprise and its own", got)
		}
		_, err = asApp(t, conn, onlyTeamA, `UPDATE afs.teams SET may_add_mcp_servers = false WHERE id = $1`, teamA)
		wantState(t, err, "42501")
		_, err = asApp(t, conn, onlyTeamA, `UPDATE afs.teams SET mcp_placement = 'separate' WHERE id = $1`, teamA)
		wantState(t, err, "42501")
		wantOK(t, asAdmin(t, conn, `UPDATE afs.teams SET mcp_placement = 'separate' WHERE id = $1`, teamA))
		_, err = asApp(t, conn, "SET LOCAL afs.team_ids = '"+teamB+"'", `INSERT INTO afs.mcp_servers (id, team_id, slug, display_name, data_classification, transport, location, url, auth_kind)
			VALUES ($1, $2, 'mine', 'mine', 'internal', 'streamable_http', 'external', 'https://mine.example.com', 'none')`, cid("mcp", 93), teamB)
		wantState(t, err, "42501")
		_, err = asApp(t, conn, onlyTeamA, `INSERT INTO afs.mcp_servers (id, team_id, slug, display_name, data_classification, transport, location, url, auth_kind, review_status)
			VALUES ($1, $2, 'self-approved', 'x', 'internal', 'streamable_http', 'external', 'https://sa.example.com', 'none', 'approved')`, cid("mcp", 94), teamA)
		wantConstraint(t, err, "23514", "mcp_review_transition")
	})
	t.Run("security operators read and review every team's servers", func(t *testing.T) {
		if got := scalar[int](t, conn, secOp, `SELECT count(*) FROM afs.mcp_servers`); got != 4 {
			t.Errorf("security operator sees %d servers", got)
		}
		wantOK(t, in(t, conn, secOp, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE afs.mcp_servers SET review_status = 'pending_review' WHERE id = $1`, mcpTB)
			return err
		}))
		if got := scalar[int](t, conn, secOp, `SELECT count(*) FROM afs.mcp_review_queue() WHERE item_kind = 'server'`); got != 1 {
			t.Errorf("review queue %d", got)
		}
		_, err := asApp(t, conn, onlyTeamA, `SELECT * FROM afs.mcp_review_queue()`)
		wantState(t, err, "42501")
	})
	t.Run("the gateway's bookkeeping does not bump the version, and it cannot review", func(t *testing.T) {
		v := scalar[int](t, conn, "", `SELECT version FROM afs.mcp_servers WHERE id = $1`, mcpE)
		wantOK(t, runAs(t, conn, "afs_gateway", "", `UPDATE afs.mcp_servers SET refresh_requested_at = NULL, protocol_version = '2026-07-28' WHERE id = $1`, mcpE))
		if got := scalar[int](t, conn, "", `SELECT version FROM afs.mcp_servers WHERE id = $1`, mcpE); got != v {
			t.Errorf("version %d -> %d", v, got)
		}
		wantState(t, runAs(t, conn, "afs_gateway", "", `UPDATE afs.mcp_servers SET review_status = 'suspended' WHERE id = $1`, mcpE), "42501")
	})
	t.Run("hosted specs pin an image digest and name environment variables only", func(t *testing.T) {
		wantOK(t, insert(cid("mcp", 95), teamA, "local", "hosted", "in_namespace", "", "none", ""))
		wantConstraint(t, asAdmin(t, conn, `INSERT INTO afs.mcp_hosted_specs (server_id, image) VALUES ($1, 'ghcr.io/x/mcp:latest')`, cid("mcp", 95)), "23514", "mcp_hosted_specs_image")
		wantConstraint(t, asAdmin(t, conn, `INSERT INTO afs.mcp_hosted_specs (server_id, image, env_names) VALUES ($1, $2, '{lower}')`, cid("mcp", 95), mcpImage), "23514", "mcp_hosted_specs_env_names")
		wantOK(t, asAdmin(t, conn, `INSERT INTO afs.mcp_hosted_specs (server_id, image, env_names) VALUES ($1, $2, '{API_TOKEN}')`, cid("mcp", 95), mcpImage))
		if got := scalar[string](t, conn, "", `SELECT team_id FROM afs.mcp_hosted_specs WHERE server_id = $1`, cid("mcp", 95)); got != teamA {
			t.Errorf("hosted spec team %q", got)
		}
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.mcp_hosted_specs SET signature_verified_at = now() WHERE server_id = $1`, cid("mcp", 95)))
		wantState(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.mcp_hosted_specs SET image = $2 WHERE server_id = $1`, cid("mcp", 95), mcpImage), "42501")
	})
	t.Run("a team switches on published enterprise servers and its own, with its own gateway (CD-44)", func(t *testing.T) {
		put := func(team, srv string) error {
			_, err := asApp(t, conn, "SET LOCAL afs.team_ids = '"+team+"'", `INSERT INTO afs.team_mcp_servers (team_id, server_id, enabled) VALUES ($1, $2, true)
				ON CONFLICT (team_id, server_id) DO UPDATE SET enabled = true`, team, srv)
			return err
		}
		wantConstraint(t, put(teamA, mcpE2), "23514", "team_mcp_servers_scope")
		wantConstraint(t, put(teamA, mcpTB), "23514", "team_mcp_servers_scope")
		wantOK(t, put(teamA, mcpE))
		wantOK(t, put(teamA, mcpTA))
		mustExec(t, conn, `UPDATE afs.teams SET gateway_deployment = 'shared' WHERE id = $1`, teamB)
		wantConstraint(t, put(teamB, mcpE), "23514", "team_gateway_required")
		_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.agent_mcp_servers (team_id, agent_id, server_id) VALUES ($1, $2, $3)`, teamA, agentA1, mcpE2)
		wantConstraint(t, err, "23514", "agent_mcp_servers_team")
		_, err = asApp(t, conn, onlyTeamA, `INSERT INTO afs.agent_mcp_servers (team_id, agent_id, server_id) VALUES ($1, $2, $3)`, teamA, agentA1, mcpE)
		wantOK(t, err)
	})
	t.Run("default servers are switched on for a new team with its own gateway", func(t *testing.T) {
		wantOK(t, asAdmin(t, conn, `UPDATE afs.mcp_servers SET default_for_new_teams = true WHERE id = $1`, mcpE))
		mk := func(n int, gw string) string {
			id := cid("team", n)
			wantOK(t, asAdmin(t, conn, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, max_budget_usd, gateway_deployment)
				VALUES ($1, $2, $2, 'CC9', 'o@example.com', 100, $3)`, id, fmt.Sprintf("new-%d", n), gw))
			return id
		}
		own := mk(70, "per_namespace")
		shared := mk(71, "shared")
		if got := count(t, conn, `SELECT count(*) FROM afs.team_mcp_servers WHERE team_id = $1 AND server_id = $2 AND enabled`, own, mcpE); got != 1 {
			t.Errorf("own gateway: %d", got)
		}
		if got := count(t, conn, `SELECT count(*) FROM afs.outbox_events WHERE event_type = 'team_mcp_server.enabled' AND team_id = $1`, own); got != 1 {
			t.Errorf("outbox: %d", got)
		}
		if got := count(t, conn, `SELECT count(*) FROM afs.team_mcp_servers WHERE team_id = $1`, shared); got != 0 {
			t.Errorf("shared gateway: %d", got)
		}
		wantOK(t, asAdmin(t, conn, `UPDATE afs.teams SET gateway_deployment = 'per_namespace' WHERE id = $1`, shared))
		if got := count(t, conn, `SELECT count(*) FROM afs.team_mcp_servers WHERE team_id = $1 AND enabled`, shared); got != 1 {
			t.Errorf("after the move to its own gateway: %d", got)
		}
	})
	t.Run("an mcp external system is refused where an approved server governs the host", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.external_systems (id, slug, name, category, endpoints) VALUES ($1, 'other-mcp', 'Other', 'mcp', '{other.example.com}')`, cid("ext", 1))
		_, err := conn.Exec(ctx, `INSERT INTO afs.external_systems (id, slug, name, category, endpoints) VALUES ($1, 'tickets-raw', 'Tickets', 'mcp', '{tickets.example.com}')`, cid("ext", 2))
		wantConstraint(t, err, "23514", "governed_by_mcp_server")
		if got := scalar[string](t, conn, "", `SELECT afs.mcp_governed_host('https://tickets.example.com/x')`); got != mcpE {
			t.Errorf("governed by %q", got)
		}
	})
	t.Run("settings are validated", func(t *testing.T) {
		for k, v := range map[string]string{"mcp.team_server_approval": `"anyone"`, "mcp.query_capture_max_days": `30`,
			"mcp.default_agent_mode": `"all"`, "federation.allowed_audiences": `"x"`, "mcp.enabled": `"yes"`} {
			_, err := conn.Exec(ctx, `UPDATE afs.service_settings SET value = $2::jsonb WHERE key = $1`, k, v)
			wantConstraint(t, err, "23514", "service_settings_mcp_value")
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"security_all"' WHERE key = 'mcp.team_server_approval'`)
		if got := scalar[string](t, conn, "", `SELECT afs.mcp_approver($1, 'low') || afs.mcp_approver(NULL, 'low')`, teamA); got != "securitysecurity" {
			t.Errorf("approver %s", got)
		}
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '"team_low_security_higher"' WHERE key = 'mcp.team_server_approval'`)
		if got := scalar[string](t, conn, "", `SELECT afs.mcp_approver($1, 'low') || '/' || afs.mcp_approver($1, 'high')`, teamA); got != "team_admin/security" {
			t.Errorf("approver %s", got)
		}
	})
	t.Run("deleting a team server keeps its reviews", func(t *testing.T) {
		wantOK(t, in(t, conn, secOp, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO afs.mcp_reviews (id, server_id, approver, decision, note) VALUES ($1, $2, 'security', 'rejected', 'no')`, cid("mrv", 1), mcpTB)
			return err
		}))
		mustExec(t, conn, `DELETE FROM afs.mcp_servers WHERE id = $1`, mcpTB)
		if got := count(t, conn, `SELECT count(*) FROM afs.mcp_reviews WHERE server_id = $1 AND team_id = $2`, mcpTB, teamB); got != 1 {
			t.Errorf("reviews after delete: %d", got)
		}
	})
}

func TestMcpPrimitives(t *testing.T) {
	conn := mcpWorld(t)
	ctx := t.Context()
	server(t, conn, mcpTA, teamA, "docs", "approved", false)
	setStatus := func(id, status, extra string) error {
		_, err := asApp(t, conn, onlyTeamA, `UPDATE afs.mcp_primitives SET status = $2`+extra+` WHERE id = $1`, id, status)
		return err
	}
	t.Run("digests and names", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status) VALUES ($1, $2, 'tool', 'x', '{}', 'md5:00', 'approved')`, cid("mpr", 90), mcpTA)
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status) VALUES ($1, $2, 'widget', 'x', '{}', $3, 'approved')`, cid("mpr", 90), mcpTA, digestOf('a'))
		wantState(t, err, "23514")
		primitive(t, conn, 1, mcpTA, "search", `{}`, "pending_review")
		_, err = conn.Exec(ctx, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status) VALUES ($1, $2, 'tool', 'search', '{}', $3, 'approved')`, cid("mpr", 91), mcpTA, digestOf('a'))
		wantState(t, err, "23505")
		if got := scalar[string](t, conn, "", `SELECT team_id FROM afs.mcp_primitives WHERE id = $1`, cid("mpr", 1)); got != teamA {
			t.Errorf("team %q", got)
		}
	})
	p := cid("mpr", 1)
	t.Run("approval adopts the held definition and pins its digest", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.mcp_primitives SET pending_definition = '{"name":"search","v":2}' WHERE id = $1`, p)
		wantOK(t, setStatus(p, "approved", ""))
		got := scalar[string](t, conn, "", `SELECT definition->>'v' || coalesce(pending_definition::text, '-') || (approved_digest = digest)::text FROM afs.mcp_primitives WHERE id = $1`, p)
		if got != "2-true" {
			t.Errorf("after approval: %s", got)
		}
	})
	t.Run("transitions", func(t *testing.T) {
		wantConstraint(t, setStatus(p, "blocked", ""), "23514", "mcp_primitive_transition")
		wantConstraint(t, setStatus(p, "pending_review", ""), "23514", "mcp_primitive_transition")
		wantOK(t, setStatus(p, "pending_review", ", digest = '"+digestOf('d')+"'"))
		wantOK(t, setStatus(p, "blocked", ""))
		wantOK(t, setStatus(p, "approved", ""))
	})
	t.Run("the gateway holds a change but cannot approve it (CD-52)", func(t *testing.T) {
		gw := func(sql string, args ...any) error { return runAs(t, conn, "afs_gateway", gwTeamA, sql, args...) }
		wantConstraint(t, gw(`INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status) VALUES ($1, $2, 'tool', 'new', '{}', $3, 'approved')`,
			cid("mpr", 2), mcpTA, digestOf('a')), "23514", "mcp_primitive_transition")
		wantOK(t, gw(`INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, change, status) VALUES ($1, $2, 'tool', 'new', '{}', $3, 'new', 'pending_review')`,
			cid("mpr", 2), mcpTA, digestOf('a')))
		wantOK(t, gw(`UPDATE afs.mcp_primitives SET status = 'pending_review', digest = $2, pending_definition = '{"v":3}', change = 'compatible' WHERE id = $1`, p, digestOf('e')))
		wantConstraint(t, gw(`UPDATE afs.mcp_primitives SET status = 'approved' WHERE id = $1`, p), "42501", "mcp_gateway_cannot_approve")
		wantState(t, gw(`UPDATE afs.mcp_primitives SET approved_digest = digest WHERE id = $1`, p), "42501")
		mustExec(t, conn, `UPDATE afs.mcp_servers SET drift_policy = 'auto_approve_compatible' WHERE id = $1`, mcpTA)
		wantConstraint(t, gw(`UPDATE afs.mcp_primitives SET status = 'approved' WHERE id = $1`, cid("mpr", 2)), "42501", "mcp_gateway_cannot_approve")
		wantOK(t, gw(`UPDATE afs.mcp_primitives SET status = 'approved' WHERE id = $1`, p))
		if got := scalar[string](t, conn, "", `SELECT decided_by || ' ' || (approved_digest = $2)::text FROM afs.mcp_primitives WHERE id = $1`, p, digestOf('e')); got != "system:auto_approve true" {
			t.Errorf("auto approval: %s", got)
		}
		if got := count(t, conn, `SELECT count(*) FROM afs.mcp_reviews WHERE primitive_id = $1 AND decision = 'auto_approved' AND team_id = $2`, p, teamA); got != 1 {
			t.Errorf("auto-approval reviews: %d", got)
		}
	})
	t.Run("at most 2000 live primitives per server", func(t *testing.T) {
		server(t, conn, cid("mcp", 9), "", "big", "approved", true)
		mustExec(t, conn, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status)
			SELECT 'mpr_01JD3Z5Y8K2M4N6P8Q0R2S' || lpad(g::text, 4, '0'), $1, 'tool', 't' || g, '{}', $2, 'approved' FROM generate_series(1000, 2999) g`, cid("mcp", 9), digestOf('a'))
		_, err := conn.Exec(ctx, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status) VALUES ($1, $2, 'tool', 'one-more', '{}', $3, 'approved')`, cid("mpr", 3), cid("mcp", 9), digestOf('a'))
		wantConstraint(t, err, "23514", "mcp_primitives_limit")
		mustExec(t, conn, `UPDATE afs.mcp_primitives SET removed_at = now() WHERE id = 'mpr_01JD3Z5Y8K2M4N6P8Q0R2S1000'`)
		mustExec(t, conn, `INSERT INTO afs.mcp_primitives (id, server_id, kind, name, definition, digest, status) VALUES ($1, $2, 'tool', 'one-more', '{}', $3, 'approved')`, cid("mpr", 3), cid("mcp", 9), digestOf('a'))
	})
}

func TestMcpAdmission(t *testing.T) {
	conn := mcpWorld(t)
	server(t, conn, mcpE, "", "gh", "approved", true)
	primitive(t, conn, 1, mcpE, "read", `{"readOnlyHint": true}`, "approved")
	primitive(t, conn, 2, mcpE, "write", `{"destructiveHint": false}`, "approved")
	primitive(t, conn, 3, mcpE, "delete_repo", `{}`, "approved")
	primitive(t, conn, 4, mcpE, "zz_new", `{}`, "pending_review")
	adm := func(agent string) string { return mcpAdmission(t, conn, "agent", agent) }
	policy := func(n int, level, team, agent, name, class, effect string, rate any) {
		t.Helper()
		mustExec(t, conn, `INSERT INTO afs.mcp_policies (id, level, team_id, agent_id, server_id, name, class, effect, rate_limit_per_minute)
			VALUES ($1, $2, nullif($3, ''), nullif($4, ''), $5, nullif($6, ''), nullif($7, ''), $8, $9)`, cid("mpol", n), level, team, agent, mcpE, name, class, effect, rate)
	}
	t.Run("opt-in is off by default", func(t *testing.T) {
		if got := adm(agentA1); !strings.HasPrefix(got, "delete_repo=server_not_enabled_for_team@team,") {
			t.Errorf("%s", got)
		}
	})
	mustExec(t, conn, `INSERT INTO afs.team_mcp_servers (team_id, server_id, enabled) VALUES ($1, $2, true)`, teamA, mcpE)
	t.Run("switched on: approved primitives are allowed, held ones are not", func(t *testing.T) {
		if got := adm(agentA1); got != "delete_repo=ok,read=ok,write=ok,zz_new=primitive_pending_review@service" {
			t.Errorf("%s", got)
		}
	})
	t.Run("an agent that selects servers sees only those", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.agents SET mcp_access = 'selected' WHERE id = $1`, agentA2)
		if got := adm(agentA2); !strings.HasPrefix(got, "delete_repo=server_not_enabled_for_agent@agent,") {
			t.Errorf("%s", got)
		}
		mustExec(t, conn, `INSERT INTO afs.agent_mcp_servers (team_id, agent_id, server_id) VALUES ($1, $2, $3)`, teamA, agentA2, mcpE)
		if got := adm(agentA2); !strings.HasPrefix(got, "delete_repo=ok,") {
			t.Errorf("%s", got)
		}
	})
	t.Run("a block at any level wins over an allow at another", func(t *testing.T) {
		policy(1, "service", "", "", "delete_*", "", "block", nil)
		policy(2, "team", teamA, "", "delete_repo", "", "allow", nil)
		if got := adm(agentA1); !strings.HasPrefix(got, "delete_repo=primitive_blocked_service@service,") {
			t.Errorf("%s", got)
		}
	})
	t.Run("within a level the most specific rule wins", func(t *testing.T) {
		policy(3, "team", teamA, "", "wr*", "", "block", nil)
		policy(4, "team", teamA, "", "write", "", "allow", 30)
		policy(5, "agent", teamA, agentA1, "read", "", "allow", 10)
		if got := adm(agentA1); got != "delete_repo=primitive_blocked_service@service,read=ok/10,write=ok/30,zz_new=primitive_pending_review@service" {
			t.Errorf("%s", got)
		}
		policy(6, "agent", teamA, agentA2, "write", "", "block", nil)
		if got := adm(agentA2); !strings.Contains(got, "write=primitive_blocked_agent@agent") || !strings.Contains(got, "read=ok,") {
			t.Errorf("%s", got)
		}
	})
	t.Run("class rules apply only when the annotations are trusted", func(t *testing.T) {
		policy(7, "team", teamA, "", "", "destructive", "block", nil)
		if got := adm(agentA1); !strings.Contains(got, "zz_new=primitive_pending_review") || strings.Contains(got, "blocked_team") {
			t.Errorf("untrusted: %s", got)
		}
		mustExec(t, conn, `UPDATE afs.mcp_primitives SET status = 'approved' WHERE id = $1`, cid("mpr", 4))
		mustExec(t, conn, `UPDATE afs.mcp_servers SET trust_annotations = true WHERE id = $1`, mcpE)
		// write declares destructiveHint false; zz_new declares nothing, so it may be destructive.
		if got := adm(agentA1); got != "delete_repo=primitive_blocked_service@service,read=ok/10,write=ok/30,zz_new=primitive_blocked_team@team" {
			t.Errorf("trusted: %s", got)
		}
		mustExec(t, conn, `DELETE FROM afs.mcp_policies WHERE id = $1`, cid("mpol", 7))
	})
	t.Run("read-only mode keeps only tools marked read-only", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.team_mcp_servers SET mode = 'read_only' WHERE team_id = $1`, teamA)
		if got := adm(agentA1); got != "delete_repo=primitive_blocked_service@service,read=ok/10,write=primitive_blocked_team@team,zz_new=primitive_blocked_team@team" {
			t.Errorf("%s", got)
		}
		mustExec(t, conn, `UPDATE afs.team_mcp_servers SET mode = 'full' WHERE team_id = $1`, teamA)
	})
	t.Run("suspended and unpublished servers refuse everything", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.mcp_servers SET review_status = 'suspended' WHERE id = $1`, mcpE)
		if got := adm(agentA1); !strings.HasPrefix(got, "delete_repo=server_suspended@service,read=server_suspended") {
			t.Errorf("%s", got)
		}
		mustExec(t, conn, `UPDATE afs.mcp_servers SET review_status = 'approved', published = false WHERE id = $1`, mcpE)
		if got := adm(agentA1); !strings.HasPrefix(got, "delete_repo=server_not_published@service,") {
			t.Errorf("%s", got)
		}
		mustExec(t, conn, `UPDATE afs.mcp_servers SET published = true WHERE id = $1`, mcpE)
	})
	t.Run("removed primitives disappear; a blocked one is refused", func(t *testing.T) {
		mustExec(t, conn, `UPDATE afs.mcp_primitives SET removed_at = now() WHERE id = $1`, cid("mpr", 4))
		mustExec(t, conn, `UPDATE afs.mcp_primitives SET status = 'pending_review', digest = $2 WHERE id = $1`, cid("mpr", 2), digestOf('f'))
		mustExec(t, conn, `UPDATE afs.mcp_primitives SET status = 'blocked' WHERE id = $1`, cid("mpr", 2))
		if got := adm(agentA1); got != "delete_repo=primitive_blocked_service@service,read=ok/10,write=primitive_blocked_service@service" {
			t.Errorf("%s", got)
		}
	})
	t.Run("a team server needs approval and the team's switch", func(t *testing.T) {
		server(t, conn, mcpTA, teamA, "docs", "pending_review", false)
		primitive(t, conn, 10, mcpTA, "find", `{}`, "approved")
		if got := mcpAdmission(t, conn, "agent", agentA1); !strings.Contains(got, "find=server_not_published@team") {
			t.Errorf("%s", got)
		}
		mustExec(t, conn, `UPDATE afs.mcp_servers SET review_status = 'approved' WHERE id = $1`, mcpTA)
		mustExec(t, conn, `INSERT INTO afs.team_mcp_servers (team_id, server_id, enabled) VALUES ($1, $2, true)`, teamA, mcpTA)
		if got := mcpAdmission(t, conn, "agent", agentA1); !strings.Contains(got, "find=ok") {
			t.Errorf("%s", got)
		}
	})
	t.Run("pools are subjects too", func(t *testing.T) {
		team, pool := swarm(t, conn)
		mustExec(t, conn, `INSERT INTO afs.team_mcp_servers (team_id, server_id, enabled) VALUES ($1, $2, true)`, team, mcpE)
		if got := mcpAdmission(t, conn, "pool", pool); !strings.HasPrefix(got, "delete_repo=server_not_enabled_for_agent@pool,") {
			t.Errorf("%s", got)
		}
		mustExec(t, conn, `INSERT INTO afs.pool_mcp_servers (team_id, pool_id, server_id) VALUES ($1, $2, $3)`, team, pool, mcpE)
		mustExec(t, conn, `INSERT INTO afs.mcp_policies (id, level, team_id, pool_id, server_id, name, effect) VALUES ($1, 'pool', $2, $3, $4, 'read', 'block')`, cid("mpol", 20), team, pool, mcpE)
		if got := mcpAdmission(t, conn, "pool", pool); got != "delete_repo=primitive_blocked_service@service,read=primitive_blocked_agent@pool,write=primitive_blocked_service@service" {
			t.Errorf("%s", got)
		}
	})
	t.Run("the effective view runs with the caller's rights", func(t *testing.T) {
		seedOtherMcp := `INSERT INTO afs.team_mcp_servers (team_id, server_id, enabled) VALUES ('` + teamB + `', '` + mcpE + `', true)`
		mustExec(t, conn, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id) VALUES ($1, $2, 'b-bot', 'omp', $3, 'claude-sonnet')`,
			cid("agt", 80), teamB, "ghcr.io/x/omp@"+collabDigest)
		mustExec(t, conn, seedOtherMcp)
		if got := scalar[int](t, conn, "", `SELECT count(*) FROM afs.effective_agent_mcp WHERE subject_id = $1`, cid("agt", 80)); got != 1 {
			t.Errorf("owner sees %d rows for team B's agent", got)
		}
		if got := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.effective_agent_mcp WHERE team_id <> $1`, teamA); got != 0 {
			t.Errorf("team A sees %d rows of other teams", got)
		}
		if got := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.effective_agent_mcp WHERE subject_id = $1`, agentA1); got != 2 {
			t.Errorf("team A's agent has %d effective rows", got)
		}
		if got := scalar[int](t, conn, "SET LOCAL ROLE afs_gateway", `SELECT count(*) FROM afs.mcp_admission('agent', $1) WHERE allowed`, agentA1); got != 2 {
			t.Errorf("gateway sees %d allowed rows", got)
		}
		for team, want := range map[string]int{teamA: 1, teamB: 0} {
			if got := scalar[int](t, conn, "SET LOCAL ROLE afs_gateway; SET LOCAL afs.team_ids = '"+team+"'",
				`SELECT count(*) FROM afs.mcp_servers WHERE team_id = $1`, teamA); got != want {
				t.Errorf("gateway of %s sees %d of team A's servers", team, got)
			}
		}
		if got := scalar[int](t, conn, "SET LOCAL ROLE afs_gateway; SET LOCAL afs.team_ids = '"+teamB+"'",
			`SELECT count(*) FROM afs.mcp_primitives WHERE team_id IS NULL`); got == 0 {
			t.Error("a team gateway must see the enterprise inventory")
		}
	})
}

func TestMcpCredentials(t *testing.T) {
	conn := mcpWorld(t)
	ctx := t.Context()
	server(t, conn, mcpE, "", "tickets", "approved", true)
	server(t, conn, mcpTA, teamA, "docs", "approved", false)
	arn := func(path string) string { return arnBase + path + "-AbCdEf" }
	cred := func(n int, srv, scope, team, kind, path, subject string) error {
		_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.mcp_credentials (id, server_id, scope, team_id, kind, secret_arn, subject, status)
			VALUES ($1, $2, $3, nullif($4, ''), $5, $6, nullif($7, ''), 'set')`, cid("mcr", n), srv, scope, team, kind, arn(path), subject)
		return err
	}
	t.Run("ARNs sit at the managed gateway path", func(t *testing.T) {
		wantOK(t, cred(1, mcpTA, teamA, teamA, "static", "afs/afs-t-payments/_gateway/mcp/docs", ""))
		wantOK(t, cred(2, mcpE, teamA, teamA, "oauth_user", "afs/afs-t-payments/_gateway/mcp/tickets", "svc-payments"))
		wantConstraint(t, cred(3, mcpE, teamA, teamA, "static", "afs/afs-t-payments/_shared/tickets", ""), "23514", "mcp_credential_path")
		wantConstraint(t, cred(3, mcpTA, teamB, teamB, "static", "afs/afs-t-search/_gateway/mcp/docs", ""), "23514", "mcp_credential_path")
		wantConstraint(t, cred(4, mcpE, teamA, teamA, "oauth_user", "afs/afs-t-payments/_gateway/mcp/tickets", "other"), "23505", "")
		_, err := conn.Exec(ctx, `INSERT INTO afs.mcp_credentials (id, server_id, scope, kind, secret_arn, status) VALUES ($1, $2, '_shared', 'static', $3, 'set')`,
			cid("mcr", 5), mcpE, arn("afs/_service/gateway/mcp/tickets"))
		wantOK(t, err)
		_, err = conn.Exec(ctx, `INSERT INTO afs.mcp_credentials (id, server_id, scope, team_id, kind, secret_arn, status) VALUES ($1, $2, '_shared', $3, 'static', $4, 'set')`,
			cid("mcr", 6), mcpE, teamA, arn("afs/_service/gateway/mcp/tickets"))
		wantState(t, err, "23514")
		_, err = conn.Exec(ctx, `INSERT INTO afs.mcp_credentials (id, server_id, scope, team_id, kind, secret_arn, status) VALUES ($1, $2, $3, $4, 'static', $5, 'set')`,
			cid("mcr", 6), mcpE, teamB, teamA, arn("afs/afs-t-payments/_gateway/mcp/tickets"))
		wantConstraint(t, err, "23514", "mcp_credentials_scope_team")
		if got := scalar[string](t, conn, "", `SELECT afs.mcp_credential_path($1, 'docs')`, teamA); got != "afs/afs-t-payments/_gateway/mcp/docs" {
			t.Errorf("path %s", got)
		}
	})
	t.Run("a user-delegated credential names its account", func(t *testing.T) {
		wantConstraint(t, cred(7, mcpTA, teamA, teamA, "oauth_user", "afs/afs-t-payments/_gateway/mcp/docs", ""), "23514", "mcp_credentials_subject")
	})
	t.Run("the gateway records credential state only", func(t *testing.T) {
		wantOK(t, runAs(t, conn, "afs_gateway", "", `UPDATE afs.mcp_credentials SET status = 'expired', expires_at = now() WHERE id = $1`, cid("mcr", 2)))
		wantState(t, runAs(t, conn, "afs_gateway", "", `UPDATE afs.mcp_credentials SET secret_arn = secret_arn WHERE id = $1`, cid("mcr", 2)), "42501")
	})
	t.Run("OAuth state is single use, short lived and claimed only through the function", func(t *testing.T) {
		state := func(b string, ttl string) error {
			_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.mcp_oauth_states (state_hash, team_id, server_id, code_verifier_arn, expires_at)
				VALUES (decode(repeat($1, 32), 'hex'), $2, $3, $4, now() + $5::interval)`, b, teamA, mcpE, arn("afs/afs-t-payments/_gateway/mcp/pkce"), ttl)
			return err
		}
		wantConstraint(t, state("0a", "11 minutes"), "23514", "mcp_oauth_states_ttl")
		wantOK(t, state("0b", "5 minutes"))
		claim := func(b string) int {
			return scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.claim_mcp_oauth_state(decode(repeat($1, 32), 'hex'))`, b)
		}
		if n := claim("0b"); n != 1 {
			t.Errorf("first claim %d", n)
		}
		if n := claim("0b"); n != 0 {
			t.Errorf("second claim %d", n)
		}
		mustExec(t, conn, `INSERT INTO afs.mcp_oauth_states (state_hash, team_id, server_id, code_verifier_arn, created_at, expires_at)
			VALUES (decode(repeat('0c', 32), 'hex'), $1, $2, 'arn:aws:secretsmanager:x', now() - interval '20 minutes', now() - interval '11 minutes')`, teamA, mcpE)
		if n := claim("0c"); n != 0 {
			t.Errorf("expired claim %d", n)
		}
		_, err := asApp(t, conn, onlyTeamA, `SELECT * FROM afs.mcp_oauth_states`)
		wantState(t, err, "42501")
	})
	t.Run("reviews are append-only and need a note", func(t *testing.T) {
		_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.mcp_reviews (id, server_id, approver, decision) VALUES ($1, $2, 'team_admin', 'approved')`, cid("mrv", 1), mcpTA)
		wantConstraint(t, err, "23514", "mcp_reviews_note")
		_, err = asApp(t, conn, onlyTeamA, `INSERT INTO afs.mcp_reviews (id, server_id, approver, decision, note) VALUES ($1, $2, 'team_admin', 'approved', 'ok')`, cid("mrv", 1), mcpTA)
		wantOK(t, err)
		_, err = conn.Exec(ctx, `UPDATE afs.mcp_reviews SET note = 'changed'`)
		wantState(t, err, "42501")
		_, err = conn.Exec(ctx, `DELETE FROM afs.mcp_reviews`)
		wantState(t, err, "42501")
	})
	t.Run("federation state: the API asks for a test, the gateway records the outcome", func(t *testing.T) {
		_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.mcp_federation_states (server_id, team_id, test_requested_at) VALUES ($1, $2, now())`, mcpE, teamA)
		wantOK(t, err)
		_, err = asApp(t, conn, onlyTeamA, `UPDATE afs.mcp_federation_states SET status = 'ready'`)
		wantState(t, err, "42501")
		wantOK(t, runAs(t, conn, "afs_gateway", "", `UPDATE afs.mcp_federation_states SET status = 'failing', last_error = 'issuer not trusted', checked_at = now()`))
	})
}

func TestMcpEvents(t *testing.T) {
	conn := mcpWorld(t)
	ctx := t.Context()
	event := func(team, req, query string, ms int, outcome string) error {
		return runAs(t, conn, "afs_gateway", "SET LOCAL afs.team_ids = '"+team+"'", `INSERT INTO afs.mcp_events
			(at, request_id, team_id, agent_id, server_kind, method, name, outcome, gateway_ms, upstream_ms, request_bytes, response_bytes, query_text)
			VALUES (now(), $1, $2, $3, 'afs', 'tools/call', 'afs_search', $4, $5, 0, 10, 20, nullif($6, ''))`, req, team, agentA1, outcome, ms, query)
	}
	t.Run("the gateway writes for its own team only", func(t *testing.T) {
		wantOK(t, event(teamA, "r1", "", 5, "ok"))
		err := runAs(t, conn, "afs_gateway", gwTeamA, `INSERT INTO afs.mcp_events (at, request_id, team_id, method, outcome) VALUES (now(), 'r2', $1, 'tools/list', 'ok')`, teamB)
		wantState(t, err, "42501")
	})
	t.Run("the ledger is append-only", func(t *testing.T) {
		for _, q := range []string{`UPDATE afs.mcp_events SET outcome = 'ok'`, `DELETE FROM afs.mcp_events`, `TRUNCATE afs.mcp_events`} {
			_, err := conn.Exec(ctx, q)
			wantState(t, err, "42501")
		}
	})
	t.Run("query text is kept only while a capture window is open (CD-50)", func(t *testing.T) {
		wantOK(t, event(teamA, "r3", "find jira tickets", 7, "ok"))
		_, err := asApp(t, conn, "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.mcp_query_captures (id, reason, until) VALUES ($1, 'tune search', now() + interval '30 days')`, cid("mqc", 1))
		wantConstraint(t, err, "23514", "mcp_query_captures_window")
		_, err = asApp(t, conn, "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.mcp_query_captures (id, reason, until) VALUES ($1, 'tune search', now() + interval '2 days')`, cid("mqc", 1))
		wantOK(t, err)
		_, err = asApp(t, conn, "SET LOCAL afs.service_admin = 'on'", `INSERT INTO afs.mcp_query_captures (id, reason, until) VALUES ($1, 'again', now() + interval '2 days')`, cid("mqc", 2))
		wantConstraint(t, err, "23505", "capture_active")
		wantOK(t, event(teamA, "r4", "find jira tickets", 9, "ok"))
		got := scalar[string](t, conn, "", `SELECT string_agg(request_id || ':' || coalesce(query_text, '-') || ':' || coalesce(capture_id, '-'), ',' ORDER BY request_id) FROM afs.mcp_events WHERE request_id IN ('r3', 'r4')`)
		if got != "r3:-:-,r4:find jira tickets:"+cid("mqc", 1) {
			t.Errorf("%s", got)
		}
		wantOK(t, runAs(t, conn, "afs_reconciler", "", `UPDATE afs.mcp_query_captures SET stopped_at = now(), stopped_by = 'system:expired'`))
		if got := scalar[*string](t, conn, "SET LOCAL ROLE afs_gateway", `SELECT afs.mcp_capture_open()`); got != nil {
			t.Errorf("capture still open: %s", *got)
		}
	})
	t.Run("events land in daily partitions; old ones are dropped whole", func(t *testing.T) {
		today := "mcp_events_" + scalar[string](t, conn, "", `SELECT to_char(current_date, 'YYYYMMDD')`)
		if got := count(t, conn, `SELECT count(*) FROM afs.`+today); got != 3 {
			t.Errorf("%s holds %d rows", today, got)
		}
		if got := count(t, conn, `SELECT count(*) FROM afs.mcp_events_default`); got != 0 {
			t.Errorf("default partition holds %d rows", got)
		}
		old := scalar[string](t, conn, "", `SELECT to_char(date_trunc('month', now()) - interval '14 months', 'YYYYMMDD')`)
		mustExec(t, conn, `CREATE TABLE afs.mcp_events_`+old+` PARTITION OF afs.mcp_events FOR VALUES FROM ('`+old+`') TO ('`+old+`'::date + 1)`)
		var dropped []string
		wantOK(t, in(t, conn, "SET LOCAL ROLE afs_reconciler", func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT afs.drop_old_mcp_event_partitions()`)
			if err != nil {
				return err
			}
			dropped, err = pgx.CollectRows(rows, pgx.RowTo[string])
			return err
		}))
		if strings.Join(dropped, ",") != "mcp_events_"+old {
			t.Errorf("dropped %v", dropped)
		}
		wantOK(t, in(t, conn, "SET LOCAL ROLE afs_reconciler", func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.ensure_mcp_event_partitions(10)`)
			return err
		}))
		if got := count(t, conn, `SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'afs.mcp_events'::regclass AND c.relname ~ '^mcp_events_[0-9]{8}$'`); got != 12 {
			t.Errorf("%d daily partitions", got)
		}
	})
	t.Run("the daily rollup is idempotent", func(t *testing.T) {
		wantOK(t, event(teamA, "r5", "", 100, "tool_error"))
		for range 2 {
			wantOK(t, in(t, conn, "SET LOCAL ROLE afs_reconciler", func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `SELECT afs.rollup_mcp_usage(current_date)`)
				return err
			}))
		}
		got := scalar[string](t, conn, "", `SELECT string_agg(outcome || '=' || calls || '/' || errors || '/' || bytes_in, ',' ORDER BY outcome) FROM afs.mcp_usage_daily WHERE team_id = $1`, teamA)
		if got != "ok=3/0/30,tool_error=1/1/10" {
			t.Errorf("%s", got)
		}
	})
	t.Run("teams read their own ledger; security reads every team's through a function", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.mcp_events (at, request_id, team_id, method, outcome) VALUES (now(), 'rb', $1, 'tools/list', 'ok')`, teamB)
		if got := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.mcp_events`); got != 4 {
			t.Errorf("team A reads %d events", got)
		}
		if got := scalar[int](t, conn, secOp, `SELECT count(*) FROM afs.mcp_events_for_review(now() - interval '1 day', now() + interval '1 day', NULL, NULL, NULL)`); got != 5 {
			t.Errorf("security reads %d events", got)
		}
		_, err := asApp(t, conn, onlyTeamA, `SELECT * FROM afs.mcp_events_for_review(now() - interval '1 day', now(), NULL, NULL, NULL)`)
		wantState(t, err, "42501")
	})
}

func TestFederatedIdentities(t *testing.T) {
	conn := mcpWorld(t)
	put := func(n int, name, audience, extraCols, extraVals string) error {
		_, err := asApp(t, conn, onlyTeamA, `INSERT INTO afs.agent_federated_identities (team_id, agent_id, name, id, audience`+extraCols+`)
			VALUES ($1, $2, $3, $4, $5`+extraVals+`)`, teamA, agentA1, name, cid("afi", n), audience)
		return err
	}
	t.Run("audiences must be allowed by a service admin and never reserved", func(t *testing.T) {
		wantConstraint(t, put(1, "vault", "https://vault.example.com", "", ""), "23514", "audience_not_allowed")
		mustExec(t, conn, `UPDATE afs.service_settings SET value = '["https://vault.example.com", "api://corp-*", "sts.amazonaws.com"]' WHERE key = 'federation.allowed_audiences'`)
		wantConstraint(t, put(1, "aws", "sts.amazonaws.com", "", ""), "23514", "audience_reserved")
		wantConstraint(t, put(1, "gw", "afs-gateway", "", ""), "23514", "audience_reserved")
		wantOK(t, put(1, "vault", "https://vault.example.com", "", ""))
		wantOK(t, put(2, "corp-api", "api://corp-billing", "", ""))
		wantConstraint(t, put(3, "corp-x", "api://other", "", ""), "23514", "audience_not_allowed")
	})
	t.Run("the file and variable default from the name", func(t *testing.T) {
		got := scalar[string](t, conn, "", `SELECT file_path || ' ' || env_var || ' ' || expiration_seconds FROM afs.agent_federated_identities WHERE id = $1`, cid("afi", 2))
		if got != "/var/run/secrets/afs/federation/corp-api/token AFS_FEDERATED_TOKEN_FILE_CORP_API 3600" {
			t.Errorf("%s", got)
		}
	})
	t.Run("paths, names and lifetimes are bounded", func(t *testing.T) {
		wantState(t, put(4, "Bad", "https://vault.example.com", "", ""), "23514")
		wantState(t, put(4, "short", "https://vault.example.com", ", expiration_seconds", ", 60"), "23514")
		wantState(t, put(4, "elsewhere", "https://vault.example.com", ", file_path", ", '/etc/passwd'"), "23514")
		wantState(t, put(4, "vault", "https://vault.example.com", "", ""), "23505")
	})
	t.Run("at most ten per agent", func(t *testing.T) {
		for i := 4; i <= 11; i++ {
			wantOK(t, put(i, fmt.Sprintf("v%d", i), "https://vault.example.com", "", ""))
		}
		wantConstraint(t, put(12, "v12", "https://vault.example.com", "", ""), "23514", "federated_identity_limit")
	})
	t.Run("pools hold their own, and other teams cannot write them", func(t *testing.T) {
		team, pool := swarm(t, conn)
		inTeam := "SET LOCAL afs.team_ids = '" + team + "'"
		_, err := asApp(t, conn, inTeam, `INSERT INTO afs.pool_federated_identities (team_id, pool_id, name, id, audience) VALUES ($1, $2, 'vault', $3, 'https://vault.example.com')`, team, pool, cid("pfi", 1))
		wantOK(t, err)
		_, err = asApp(t, conn, onlyTeamA, `INSERT INTO afs.pool_federated_identities (team_id, pool_id, name, id, audience) VALUES ($1, $2, 'vault2', $3, 'https://vault.example.com')`, team, pool, cid("pfi", 2))
		wantState(t, err, "42501")
	})
}
