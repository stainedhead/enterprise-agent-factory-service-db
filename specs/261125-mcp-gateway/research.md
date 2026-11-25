# Research

- Patterns reused: `afs.caller_sees_team`, `afs.gateway_sees_team` (000023) for per-namespace gateways,
  `afs.caller_is_security_operator` (000012), `touch_row`, `record_revision`, `notify_desired_state`, day partitions
  like `ensure_usage_partition`, append-only triggers like `audit_log`.
- `record_revision` and `notify_desired_state` take the row's `id`; tables with composite keys get a generated `id`
  column instead of another special case in those shared functions.
- PL/pgSQL `IF NOT (… OR NULL)` is NULL and does not raise: the scope guard of `team_mcp_servers` coalesces.
