# Research

## Inputs read

- Root database contract section 7.4 (tables, columns, constraint names, error mapping), CD-42 (a route default
  is `default_route` plus a model name in `default_model_id`), CD-43 (built-in entries ship off with placeholder URLs).
- Root PRD `model-endpoint-gateway-PRD.md` sections 7 (data), 7.3 (provider policy), 7.4 (Bedrock off), 9.4
  (cost), 11 and 11.1 (security), Appendix C.1 and D.2.
- Migrations 000003 (`secret_path`), 000013 (`notify_desired_state`, `touch_row`), 000018
  (`touch_row_runner_exempt`), 000022 (`subject_models_check`, `record_revision`, `team_guardrail_guard`,
  `service_settings_orchestration_guard`, `model_admission`, `effective_agent_models`).

## Error mapping the API relies on

| Constraint | SQLSTATE |
|---|---|
| `model_endpoints_slug_taken` | 23505 |
| `provider_disabled`, `no_fallback_model`, `endpoint_credential_path`, `endpoint_base_url_placeholder`, `agent_routes_team`, `agents_default_route_allowed` | 23514 |
| Selections a team-admin may not make | 42501 |

## Findings

- SQL-standard function bodies (`RETURN ...`) record dependencies on the tables they read, so the down migration
  must drop those functions before the tables.
- Constraint names generated for inline column checks (`<table>_<column>_check`) collide with named table
  constraints; the table constraints use distinct names (`model_endpoints_base_url_scheme`, ...).
- A guard that keys on `current_user = 'afs_app'` must be SECURITY INVOKER; the helpers it calls are SECURITY
  DEFINER with a fixed `search_path` and must be granted to `afs_app`.
- BEFORE triggers run before CHECK constraints, so a guard must step aside when a CHECK should report.
- Docker is not available in this environment: the integration tests ran on a local PostgreSQL 16; CI runs 17.
