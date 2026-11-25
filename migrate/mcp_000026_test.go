package migrate_test

// Migration 000026, OAuth connect states without a stored verifier (API contract CD-48).

import (
	"bytes"
	"testing"
)

func TestMcpOAuthStateWithoutVerifier(t *testing.T) {
	conn := mcpWorld(t)
	ctx := t.Context()
	server(t, conn, mcpTA, teamA, "crm", "approved", false)
	hash := bytes.Repeat([]byte{7}, 32)
	insert := func(team string) error {
		return runAs(t, conn, "afs_app", "SET LOCAL afs.actor = 'usr_a'; "+onlyTeamA,
			`INSERT INTO afs.mcp_oauth_states (state_hash, team_id, server_id, expires_at) VALUES ($1, $2, $3, now() + interval '10 minutes')`,
			hash, team, mcpTA)
	}
	t.Run("a team admin writes a state with no verifier", func(t *testing.T) { wantOK(t, insert(teamA)) })
	t.Run("not for another team", func(t *testing.T) { wantState(t, insert(teamB), "42501") })
	t.Run("the callback claims it once", func(t *testing.T) {
		var team, srv, by string
		var arn *string
		if err := conn.QueryRow(ctx, `SELECT team_id, server_id, created_by, code_verifier_arn FROM afs.claim_mcp_oauth_state($1)`, hash).
			Scan(&team, &srv, &by, &arn); err != nil || team != teamA || srv != mcpTA || by != "usr_a" || arn != nil {
			t.Fatalf("claim = %s %s %s %v %v", team, srv, by, arn, err)
		}
		if n := scalar[int](t, conn, "", `SELECT count(*) FROM afs.claim_mcp_oauth_state('\x0707070707070707070707070707070707070707070707070707070707070707'::bytea)`); n != 0 {
			t.Errorf("second claim returned %d rows", n)
		}
	})
}
