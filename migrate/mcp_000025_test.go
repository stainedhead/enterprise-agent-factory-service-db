package migrate_test

// Migration 000025, security operators and team readers of the MCP catalog (MCP gateway PRD §8, §13).

import "testing"

func TestMcpOperatorAccess(t *testing.T) {
	conn := mcpWorld(t)
	ctx := t.Context()
	server(t, conn, mcpE, "", "tickets", "approved", true)
	server(t, conn, mcpTB, teamB, "docs", "pending_review", false)
	outbox := func(kind, typ, team string) error {
		return runAs(t, conn, "afs_app", "SET LOCAL afs.actor = 'usr_sec'; SET LOCAL afs.security_operator = 'on'",
			`INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES ($1, $2, 'x', nullif($3, ''), '{}')`,
			typ, kind, team)
	}
	t.Run("a security operator writes the MCP review events of enterprise and any team's servers", func(t *testing.T) {
		wantOK(t, outbox("mcp_servers", "mcp_server.approved", ""))
		wantOK(t, outbox("mcp_servers", "mcp_server.suspended", teamB))
		wantOK(t, outbox("mcp_primitives", "mcp_primitive.blocked", ""))
	})
	t.Run("and no other event", func(t *testing.T) {
		wantState(t, outbox("teams", "team.updated", teamB), "42501")
		wantState(t, outbox("mcp_servers", "team.updated", ""), "42501")
		wantState(t, outbox("mcp_query_captures", "mcp_query_capture.started", ""), "42501")
		err := runAs(t, conn, "afs_app", "SET LOCAL afs.actor = 'usr_a'; "+onlyTeamA,
			`INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES ('mcp_server.approved', 'mcp_servers', 'x', $1, '{}')`, teamB)
		wantState(t, err, "42501")
	})
	t.Run("security operators read every team's ledger and usage; a team reads only its own", func(t *testing.T) {
		for _, team := range []string{teamA, teamB} {
			mustExec(t, conn, `INSERT INTO afs.mcp_events (at, request_id, team_id, method, outcome) VALUES (now(), 'r', $1, 'tools/list', 'ok')`, team)
			mustExec(t, conn, `INSERT INTO afs.mcp_usage_daily (day, team_id, agent_or_pool, server_id, method, name, outcome, calls)
				VALUES (current_date, $1, '', '', 'tools/list', '', 'ok', 1)`, team)
		}
		for _, table := range []string{"afs.mcp_events", "afs.mcp_usage_daily"} {
			if n := scalar[int](t, conn, secOp, `SELECT count(*) FROM `+table); n != 2 {
				t.Errorf("security operator reads %d rows of %s, want 2", n, table)
			}
			if n := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM `+table); n != 1 {
				t.Errorf("team A reads %d rows of %s, want 1", n, table)
			}
		}
	})
	t.Run("a team sees an enterprise server's shared credential, not another team's", func(t *testing.T) {
		_, err := conn.Exec(ctx, `INSERT INTO afs.mcp_credentials (id, server_id, scope, kind, secret_arn, status) VALUES ($1, $2, '_shared', 'static', $3, 'set')`,
			cid("mcr", 1), mcpE, arnBase+"afs/_service/gateway/mcp/tickets-AbCdEf")
		wantOK(t, err)
		_, err = conn.Exec(ctx, `INSERT INTO afs.mcp_credentials (id, server_id, scope, team_id, kind, secret_arn, status) VALUES ($1, $2, $3, $3, 'static', $4, 'set')`,
			cid("mcr", 2), mcpE, teamB, arnBase+"afs/afs-t-search/_gateway/mcp/tickets-AbCdEf")
		wantOK(t, err)
		if n := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.mcp_credentials`); n != 1 {
			t.Errorf("team A sees %d credentials, want the shared one", n)
		}
		n, err := asApp(t, conn, onlyTeamA, `UPDATE afs.mcp_credentials SET status = 'expired' WHERE scope = '_shared'`)
		if err != nil || n != 0 {
			t.Errorf("team A changed the shared credential: %d %v", n, err)
		}
	})
}
