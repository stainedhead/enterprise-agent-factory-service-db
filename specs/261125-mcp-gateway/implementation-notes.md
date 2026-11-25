# Implementation notes

- BEFORE triggers run before CHECK constraints, so a credential with a wrong scope is refused by the path guard
  (`mcp_credential_path`) before `mcp_credentials_scope_team`; both are 23514 and map to 400.
- The 000024 RLS uses `afs.gateway_sees_team` for `afs_gateway`: a per-namespace gateway sees its teams and the
  enterprise rows only. The ledger insert requires `afs.team_ids` (MCP is served by team gateways only, CD-44).
- `afs.create_team` does not exist as a function; default servers are switched on by an AFTER INSERT trigger on
  `teams` (and when a team moves to its own gateway), which covers `instantiate_work_order_team` too.
- `mcp_primitives` has no revision trigger (the gateway touches `last_seen` on every refresh); its notify trigger fires
  only on a change that can alter a decision.
- Local runs use PostgreSQL 16 (17 is not installable here); CI runs `postgres:17`.
