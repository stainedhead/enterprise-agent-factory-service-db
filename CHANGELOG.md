# Changelog

All notable changes to this repository. Versions follow semver. `-db` and `-restapi` release in lockstep
with the same version number.

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
