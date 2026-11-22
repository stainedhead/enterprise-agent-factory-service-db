# Data dictionary: paperclip-collaboration

2026-11-22. The final, authoritative dictionary is `docs/data-model.md`, updated in step 4 from the migration. This file
lists what 000020 adds, by kind. Column-level rules are in the PRD stories DB-US-44 to DB-US-57.

## Entities (tables)

| Table | Kind | Key | Team-owned | RLS | Notes |
|---|---|---|---|---|---|
| `team_collaboration` | desired state | `team_id` | yes | `app_team_scope`, `service_roles_all` | one row per team with a collaboration agent |
| `agent_collaboration` | desired state + status | `(team_id, agent_id)` | yes | as above | one row per worker ever connected |
| `collaboration_access` | fact, monthly partitions | `(bucket_start, team_id, surface, principal_kind, principal_id, outcome, service_admin_entry)` | no FK | `SELECT` policy | five-minute counts |
| `collab_hostname_holds` | guard data | `slug` | no FK | none | 30 day hold |
| `collab_edge_sessions` | credentials | `id_hash` | no FK | enabled, no policy | no grant to any role |
| `collab_edge_handoffs` | credentials | `code_hash` | no FK | enabled, no policy | no grant to any role |

## New columns on existing tables

`agents.role`, `agent_templates.capabilities`, `teams.may_expose_collaboration`, `identity_providers.collab_client_id`,
`identity_providers.collab_client_secret_arn`, `secrets.managed_by`.

## Enumerations (text plus CHECK)

`agents.role` (`worker`, `collaboration`); `registration_mode` (`manual`, `managed`); `link_state` (`pending`, `linked`,
`failed`, `disabled`); `managed_by` (`user`, `afs`, `paperclip`); `surface` (`web_ui`, `rest_api`); `principal_kind` (`user`,
`api_key`, `anonymous`); `outcome` (11 values); capabilities (`paperclip`); secret detection pattern (8 names) and action
(`blocked`, `warned`); new roles `team_collaborator` in `role_bindings.role` and `api_keys.role`.

## Settings

`collab.base_domain`, `collab.public_endpoints`, `collab.allowed_source_cidrs`, `collab.session_ttl_minutes`,
`collab.content_scan`, `collab.max_body_mb`, `collab.denied_spike_threshold`.

## Functions

Edge (ten): `collab_routes`, `collab_settings`, `collab_principal`, `collab_principal_key`, `record_collab_access`,
`emit_collab_secret_detected`, `collab_handoff_create`, `collab_handoff_consume`, `collab_session_get`,
`collab_session_revoke`. Reconciler: `ensure_collaboration_access_partition`, `purge_collab_edge_sessions`,
`record_collab_agent_key`, `remove_collab_agent_key`, `record_collab_board_key`. Helpers: `capabilities_ok`, `dns_name_ok`,
`cidr_list_ok`. Trigger functions: `agents_collaboration_guard`, `agent_templates_capability_guard`,
`team_collaboration_guard`, `agent_collaboration_guard`, `secrets_managed_guard`, `agents_collaboration_cleanup`, hold
triggers. Replaced: `team_guardrail_guard`, `secrets_managed_path`, `binding_respects_scope`,
`drop_partitions_older_than`, `instantiate_work_order_team`, `record_work_order_secret`.

## Outbox event

`collaboration.secret_detected` (aggregate `team_collaboration`), `agent.created` (swarm collaboration agent).
