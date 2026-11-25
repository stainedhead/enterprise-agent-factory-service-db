# Changelog

All notable changes to this repository. Versions follow semver. `-db` and `-restapi` release in lockstep
with the same version number.

## v1.3.0 (2026-11-25)

Schema migrations 000001–000026. Not yet tagged. Lockstep with `-restapi` 1.3.0. Spec `specs/261125-mcp-gateway/`.

- **000024 Governed MCP servers** (database contract section 7.5, decisions CD-50 to CD-52; root `mcp-gateway-PRD.md`, MCP-DB-1 to MCP-DB-7):
  - `mcp_servers` (enterprise and team, slugs never shared between them, review transitions, publish needs approval), `mcp_hosted_specs` (pinned image digests), `mcp_primitives` (digest pinning, held changes, the gateway cannot approve)
  - opt-in per team (`team_mcp_servers`, needs the team's own gateway), narrowing per agent and pool, `mcp_policies` at service, team, agent and pool level; defaults switched on for new teams
  - `mcp_credentials` (ARNs at `_gateway/mcp/<slug>`), single-use `mcp_oauth_states`, append-only `mcp_reviews`, `mcp_federation_states`, `mcp_query_captures`, per-agent and per-pool federated identities
  - the append-only, day-partitioned `mcp_events` ledger (query text only inside a capture window) and `mcp_usage_daily`
  - `afs.mcp_admission` and the view `effective_agent_mcp`; review queue and cross-team ledger functions for security operators
  - `teams.may_add_mcp_servers` and `mcp_placement`; `mcp_access` and `mcp_mode` on agents and pools; `external_systems.category` `mcp`; `mcp.*` settings
  - row-level security on every new team-owned table (per-namespace gateways see their teams only), grants per role, revisions and the change feed
- **000025 Security operator and team reader access** (found by the `-restapi` integration tests of 000024):
  - a security operator writes the `mcp_server.*` and `mcp_primitive.*` outbox events of the reviews it makes, on enterprise and any team's servers (`app_operator_mcp_events`), and nothing else
  - security operators read every team's `mcp_events` and `mcp_usage_daily` (usage reports), as the PRD's ledger access says
  - a team reads the shared (`_shared`) credential rows of enterprise servers, so it sees whether the credential is set; it cannot change them and never sees another team's
- **000026 OAuth connect without a stored verifier:** `mcp_oauth_states.code_verifier_arn` becomes optional. `afs-api` derives the PKCE verifier from the state with a keyed HMAC, so it never reads a secret back at the callback.
- **Upgrade:** no table rewrite and no new role.

## v1.2.0 (2026-11-25)

Schema migrations 000001–000023. Not yet tagged. Lockstep with `-restapi` 1.2.0. Spec `specs/261125-model-endpoint-gateway/`.

- **000023 Team model gateway** (database contract section 7.4, decisions CD-42 and CD-43; root `model-endpoint-gateway-PRD.md`, MEG-DB-1 to MEG-DB-7):
  - `inference_providers`: one switch per provider, Bedrock included; Azure and Google off and service-selected; `afs.provider_for_host`, `afs.provider_enabled`; Bedrock cannot be turned off without a valid route fallback (`no_fallback_model`)
  - `model_endpoints` (service and team rows, provider derived from the host), five built-in catalog entries off with placeholder URLs (`endpoint_base_url_placeholder`), `endpoint_models`, append-only `endpoint_model_prices`, `endpoint_price_proposals`, `endpoint_capacity_costs`
  - `endpoint_credentials` (ARNs at `<prefix>/<namespace>/_gateway/<route>` or `<prefix>/_service/gateway/<route>`), `endpoint_federations` (identifiers only), `provider_statements`
  - `team_model_endpoints`, `agent_model_endpoints`, `pool_model_endpoints`; `teams.may_add_model_endpoints` and `gateway_deployment`; `route_access` and `default_route` on agents and pools (CD-42: the foreign keys of `default_model_id`/`model_id` become a trigger that applies while `default_route` is NULL)
  - the view `effective_agent_routes` and `afs.route_admission`; `effective_agent_models` and `model_admission` honour the Bedrock switch
  - `usage_events` route and timing columns (`model_id` nullable); `cost_daily` sources `route` and `route_capacity`; `models.default_model_id` may be a `<route>/<model>`
  - row-level security on every new team-owned table, grants per role, revisions and the change feed
- **Upgrade:** no table rewrite and no new role; see `user-docs/operations.md`.

## v1.1.0 (2026-11-23)

Schema migrations 000001–000022. Not yet tagged. Lockstep with `-restapi` 1.1.0. Spec `specs/261123-orchestration-and-model-access/`.

- **000022 Team orchestration agent and model access** (database contract section 7.3, decisions CD-13 to CD-25):
  - agent role `collaboration` becomes `orchestration`: exactly one live per team, created with the team, never removed while the team lives, the reserved name `orchestrator`
  - tool choice Paperclip or Buzz (`team_collaboration.tool`, template capabilities `orchestration`, `tool:paperclip`, `tool:buzz`); a tool change takes a `pre_tool_change` volume snapshot kept 90 days
  - exposure levels `off`, `private`, `public` for the Web UI and the Web API, within a team limit (`teams.max_collaboration_exposure`) that only service admins set
  - `afs.orchestration_routes()` and `afs.orchestration_settings()` for `afs-edge`; `collab_routes()` recomputed; access counts carry the exposure
  - `afs.create_orchestration_agent` and an updated `afs.instantiate_work_order_team`
  - model access: `all` or `selected` for teams, agents and pools (`agent_models`, `pool_models`), `default_model_id`, `team_inference_profiles`, the view `effective_agent_models` and `afs.model_admission`
  - the `orchestration.*` and `models.*` service settings; `collab.base_domain` and `collab.public_endpoints` become read-only aliases
  - Buzz keeps its keys under reserved secret names, like Paperclip
- **Compatibility until 2.0.0:** the 1.0.1 columns and functions stay in step (`web_ui_enabled`, `rest_api_enabled`, `may_expose_collaboration`, `agents.model_id`, `team_models.inference_profile_arn`, `collab_routes`, `collab_settings`).
- **Upgrade:** rebuilding the primary key of `collaboration_access` takes an `ACCESS EXCLUSIVE` lock on it; run in a quiet period. See `user-docs/operations.md`.

## v1.0.1 (2026-11-22)

First tagged release. Schema migrations 000001–000021.

- **000020 Paperclip team collaboration:**
  - collaboration agent role and template capabilities
  - `team_collaboration` and `agent_collaboration`
  - `secrets.managed_by` and the reserved Paperclip secret names
  - the `team_collaborator` role and the `collab.*` settings
  - the `afs_edge` role with SECURITY DEFINER functions only: routes, principals, server-side sessions and one-time handoffs, access counts
  - the reconciler key functions
  - the 30-day hostname hold
  - swarm collaboration agents
- **000021 collab_routes provider client ids** (security review finding 6): `afs.collab_routes()` also returns `provider_client_id` (console) and `provider_cli_client_id` (CLI, nullable) of the team's identity provider, so `afs-edge` accepts REST bearer tokens from CLI and console SSO. The function is dropped and recreated with the same grants; no table is touched.
- Operators run `afs-migrate bootstrap-roles` before applying 000020, so the `afs_edge` role exists.
- 000001–000019: the feature-complete schema (teams, agents, identities, secrets, budgets and spend, usage, reports, work orders, audit, RLS).
