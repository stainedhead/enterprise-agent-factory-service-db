-- 000025: security operators and team readers of the MCP catalog (release 1.3.0; MCP gateway PRD §8, §13).
--
-- Found by the -restapi integration tests of 000024:
--   1. A security operator who approves, rejects, suspends or resumes a server, or decides a primitive, writes the
--      contract's outbox event. Those rows have no team (enterprise servers)
--      or another team's id (team servers), so afs_app's team-scoped outbox policy refused them.
--   2. Security operators read every team's MCP ledger and usage (PRD §8): the review function covered the event
--      list, but the usage report reads afs.mcp_events and afs.mcp_usage_daily directly.
--   3. A team sees whether the shared credential of an enterprise server it uses is set. The row holds an ARN and
--      state only (never a value); team readers get SELECT on the shared rows, not on other teams' rows.
--
-- Lock impact: CREATE POLICY takes a brief ACCESS EXCLUSIVE lock on outbox_events, mcp_events, mcp_usage_daily and
-- mcp_credentials. No data changes.

CREATE POLICY app_operator_mcp_events ON afs.outbox_events FOR INSERT TO afs_app
  WITH CHECK (afs.caller_is_security_operator()
              AND aggregate_kind IN ('mcp_servers', 'mcp_primitives')
              AND (event_type LIKE 'mcp\_server.%' OR event_type LIKE 'mcp\_primitive.%'));

CREATE POLICY app_security_read ON afs.mcp_events FOR SELECT TO afs_app USING (afs.caller_is_security_operator());
CREATE POLICY app_security_read ON afs.mcp_usage_daily FOR SELECT TO afs_app USING (afs.caller_is_security_operator());

CREATE POLICY app_shared_credential_read ON afs.mcp_credentials FOR SELECT TO afs_app USING (scope = '_shared');
