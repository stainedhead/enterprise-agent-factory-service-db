# Paperclip team collaboration: database change PRD (`-db`, migration 000020)

| | |
|---|---|
| **Status** | Approved for implementation (2026-11-22). Extracted from the living [`-db` PRD](enterprise-agent-factory-service-db-PRD.md) (DB-41 to DB-52, DB-US-44 to DB-US-57, DB-D1 to DB-D19, DB-OQ-9 to DB-OQ-12), which stays where it is and remains the source of truth |
| **Change** | [Paperclip team collaboration](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/paperclip-team-collaboration-PRD.md) (COL-*, SEC-7) |
| **Contracts** | [Database contract §7.2 (v1.3.1)](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/database-contract.md), [API contract](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/api-contract.md) |
| **Delivers** | One migration, `000020_paperclip_collaboration`, as one minor release for `-restapi` (milestone C1) |
| **Full PRD** | [enterprise-agent-factory-service-db-PRD.md](enterprise-agent-factory-service-db-PRD.md) |

## 1. Purpose

Each team may run one collaboration agent (Paperclip) that agents in the namespace connect to and that people
reach through a public endpoint served by `afs-edge`. For the database the problem is narrow: the public
component must read routes, role bindings and settings, and write access counts, with **no table privilege**;
Paperclip's own secrets must live in the managed hierarchy without opening a way to bypass it; and the
one-collaboration-agent-per-team rule must hold even if the API forgets it. The change adds two desired-state
tables, one fact table, one login-less role with ten functions, two session tables, and guards on existing
tables. Row-level security and guards back the API's authorization; they do not replace it.

## 2. Scope

**In:** the collaboration agent role and one-per-team rule, `team_collaboration`, `agent_collaboration`, managed
secrets and reserved names, `team_collaborator`, `afs_edge` and its functions, `collaboration_access` and its
retention, the hostname hold, edge sessions and handoff, reconciler key functions, swarm collaboration, and the
000013 guard and settings changes they need.

**Out:** application logic (API, reconciler, edge); Kubernetes and AWS resources (the Paperclip pod, network
policy, the public ALB and WAF, TLS and sessions of the edge, IAM for the `paperclip/` prefix, the credential
scanner, Paperclip's own data); creation of Secrets Manager secrets; RDS provisioning.

## 3. Requirements owned

| DB req | Product req | Objects | Status |
|---|---|---|---|
| DB-41 Collaboration agent role | COL-1, COL-2, COL-3, COL-5 | 000020: `agents.role`, `agents_team_collaboration_uq`, `agents_collaboration_guard`, `agent_templates.capabilities`, `afs.capabilities_ok`, `agent_templates_capability_guard` | Planned |
| DB-42 Collaboration settings | COL-16, COL-20, COL-23 | 000020: `team_collaboration` (stored web UI and REST API choices, registration mode), `teams.may_expose_collaboration` and its guard, the seven `collab.*` settings and `service_settings_collab_check` | Planned |
| DB-43 Agent links | COL-10, COL-12, COL-14 | 000020: `agent_collaboration` (connect flag, Paperclip agent id, link state written by the reconciler only), `afs.agent_collaboration_guard`, generation bump trigger | Planned |
| DB-44 Managed secrets | COL-7, COL-12, SEC-7 | 000020: `secrets.managed_by`, `afs.secrets_managed_guard`, reserved `paperclip` names, Paperclip-created rows written by `afs_reconciler` only, binding refusal | Planned |
| DB-45 Team collaborator role | ACC-2, PC-D6 | 000020: `team_collaborator` accepted by `role_bindings_role_check` and `api_keys_role_check`, team scope only | Planned |
| DB-46 Collaboration lifecycle | COL-8, TEAM-9 | 000020: `afs.agents_collaboration_cleanup` (collaboration agent deleting or deleted removes the route row and disconnects every agent) | Planned |
| DB-47 Edge role and read functions | COL-16 to COL-19, COL-23 | 000020: role `afs_edge` (no table privilege), `afs.collab_routes()`, `afs.collab_settings()`, `afs.collab_principal()`, `afs.collab_principal_key()`, `identity_providers.collab_client_id` and `collab_client_secret_arn` | Planned |
| DB-48 Collaboration access facts and events | COL-24, COL-30, COL-31, COL-36 | 000020: `collaboration_access` (monthly partitions, 13-month retention), `afs.record_collab_access`, `afs.ensure_collaboration_access_partition`, `afs.emit_collab_secret_detected`, `drop_partitions_older_than` extended | Planned |
| DB-49 Hostname hold | TEAM-9, PC-D9 | 000020: `collab_hostname_holds`, hold and refusal triggers on `teams` | Planned |
| DB-50 Edge sessions and handoff | COL-17, PC-D22 | 000020: `collab_edge_sessions`, `collab_edge_handoffs` (no grants), `afs.collab_handoff_create`, `collab_handoff_consume`, `collab_session_get`, `collab_session_revoke`, `afs.purge_collab_edge_sessions` | Planned |
| DB-51 Reconciler key functions | COL-12, COL-32, PC-D25, PC-D26 | 000020: `afs.record_collab_agent_key`, `afs.remove_collab_agent_key`, `afs.record_collab_board_key` | Planned |
| DB-52 Swarm collaboration | COL-9, PC-D29 | 000020: `afs.instantiate_work_order_team` and `afs.record_work_order_secret` extended | Planned |

## 4. User stories and acceptance criteria

Each story ends with **Proven by:**, naming the integration test in `migrate/collaboration_000020_test.go` (and
the extended existing tests) that proves each criterion. SQLSTATEs map to API errors through database contract
§6. The red step of TDD is each named test failing against schema 000019.

**DB-US-44 · One collaboration agent per team.** *(refines US-27; COL-1, COL-2, COL-3, COL-5)* As `afs-api`, I
want the database to refuse a second collaboration agent, a change of role, and a collaboration agent that
breaks the template or identity rules, so that the one-per-team rule holds even if the API forgets it.
- `agents.role` is `text NOT NULL DEFAULT 'worker'` with constraint `agents_role_check CHECK (role IN
  ('worker','collaboration'))`. After the migration every existing agent reads `worker`; any other value is
  `23514`. The column has a constant default, so `agents` is not rewritten.
- Given a team with a live collaboration agent (`deleted_at IS NULL`), when a second agent with `role =
  'collaboration'` is inserted, then `23505` on index `agents_team_collaboration_uq` (`UNIQUE (team_id) WHERE
  role = 'collaboration' AND deleted_at IS NULL`, the pattern of `agents_team_name_uq`). A first agent in the
  state `deleting` still counts (its `deleted_at` is NULL until the reconciler marks it `deleted`), so a
  replacement is refused with `23505` until then and accepted after (DB-D15). Another team's collaboration
  agent never conflicts. The index is a plain transactional build (a `SHARE` lock on `agents`, milliseconds for
  thousands of rows), noted in the migration header.
- Given any agent, when `role` is updated to a different value, then `23514` ("an agent's role cannot
  change"). Updates that leave `role` alone are unaffected.
- Trigger `afs.agents_collaboration_guard()` (BEFORE INSERT OR UPDATE OF `role`, `template_id`, `iam_identity`,
  `snapshot_schedule`) raises `23514`, with a message naming the failed rule, when a collaboration agent has no
  `template_id`; has a template whose `capabilities` lacks `paperclip`; has `iam_identity <> 'dedicated'`; or has
  `snapshot_schedule = 'off'` (insert, or an update that sets any of these afterwards). It also raises `23514` for
  a `worker` agent whose template has `paperclip`. A worker with no `template_id` (a legacy free-text template)
  is accepted. The default `snapshot_retain_count` stays 7 in the database; the API sets 14 for the role (DB-D16).
- `agent_templates.capabilities` is `text[] NOT NULL DEFAULT '{}'` with `CHECK (afs.capabilities_ok(capabilities))`:
  at most 8 elements, no duplicates, every element in the known list `{paperclip}`; anything else `23514`.
  `afs.capabilities_ok(text[])` is `IMMUTABLE` so a later migration can extend the list. Existing templates become
  `'{}'`. Service admins write it through the existing `app_write` policy; a team caller still cannot insert
  (`42501`) or change a row (zero rows).
- Trigger `afs.agent_templates_capability_guard()` (BEFORE UPDATE OF `capabilities`) raises `55000` when it removes
  `paperclip` while a live collaboration agent uses the template, or adds `paperclip` while a live worker agent
  uses it; with no live agent on the template, either change succeeds.
- Proven by: `TestCollaborationAgent`: `role defaults to worker and existing rows are workers`, `unknown role
  23514`, `second collaboration agent 23505`, `deleting agent still blocks, deleted agent frees the slot`, `another
  team unaffected`, `role is immutable 23514`, `template must have paperclip 23514`, `template id required
  23514`, `dedicated identity required 23514`, `snapshots cannot be turned off 23514`, `worker on a paperclip
  template 23514`, `legacy worker without template accepted`; `TestAgentTemplateCapabilities`: `check accepts
  paperclip`, `unknown value, duplicate and nine elements 23514`, `removal with a live collaboration agent
  55000`, `addition with a live worker 55000`, `change with no live agent`, `team caller cannot write`.

**DB-US-45 · Collaboration settings per team.** *(refines US-30; COL-16, COL-20)* As `afs-api`, I want one
desired-state row per team that has a collaboration agent, holding the team's stored choices, so that the
reconciler and the edge read what the team asked for.
- `team_collaboration` has `team_id` (primary key, `REFERENCES afs.teams (id) ON DELETE CASCADE`), `agent_id NOT
  NULL` with `FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id)`, `web_ui_enabled boolean NOT
  NULL DEFAULT true`, `rest_api_enabled boolean NOT NULL DEFAULT false`, `registration_mode text NOT NULL DEFAULT
  'manual' CHECK (registration_mode IN ('manual','managed'))`, `version`, `generation`, `created_at`,
  `created_by`, `updated_at`.
- Given an `agent_id` that is not a collaboration agent, when the row is inserted or its `agent_id` updated, then
  `23514` (constraint trigger). Given an agent of another team, then `23503` (the composite foreign key).
- Given an insert with no explicit values, then `web_ui_enabled = true`, `rest_api_enabled = false`,
  `registration_mode = 'manual'`, `version = 1`, `generation = 1`.
- Versioning: `afs.touch_row()` bumps `version` on every update. A new BEFORE UPDATE trigger bumps `generation`
  by 1 only when `web_ui_enabled`, `rest_api_enabled` or `registration_mode` changes, because `afs.touch_row()`
  does not touch `generation` and `afs_app` has no grant on that column (DB-D1). `afs.record_revision()` writes a
  revision under key `<team_id>` and `<table>_notify` announces the change on `afs_desired_state` with payload
  `team_collaboration:<team_id>:` (an empty id part, because the table has no `id`, DB-D2).
- Grants: `afs_app` `SELECT`, `INSERT (team_id, agent_id, web_ui_enabled, rest_api_enabled, registration_mode)` and
  `UPDATE (web_ui_enabled, rest_api_enabled, registration_mode)`; no `DELETE` (`42501`); updating `agent_id` is
  `42501`. `afs_reconciler` and `afs_readonly`: `SELECT` only (`42501` on a write). `afs_edge`, `afs_billing`,
  `afs_gateway`: no privilege (`42501`).
- RLS: enabled, policy `app_team_scope` for `afs_app` on `afs.caller_sees_team(team_id)` (all commands) and
  `service_roles_all` for the service roles, the names every team-owned table already uses (DB-D8). A caller of
  team A cannot see, insert or update team B's row; the cross-team write changes nothing.
- The database stores the team's choice and does not check guardrails: turning `teams.may_expose_collaboration`
  off, or `collab.public_endpoints` off, leaves the row, its `version` and its `generation` unchanged (COL-20).
- `resource_status` accepts rows with `resource_kind = 'team_collaboration'`, `resource_id = <team_id>` and the
  conditions `EndpointReady`, `PaperclipReady`, `RegistrationHealthy`, `UnmanagedPaperclipAgents` (written by
  `afs_reconciler`, as for other kinds; no schema change).
- `afs-api` inserts the row in the same transaction as the collaboration agent (an API rule, tested in
  `-restapi`); nothing in the database requires it.
- Proven by: `TestTeamCollaboration`: `defaults`, `agent must be a collaboration agent 23514`, `agent of another
  team 23503`, `registration mode check 23514`, `generation bumps on a spec change only`, `revision and change feed
  payload`, `app writes only the three columns`, `no delete for the API 42501`, `reconciler and readonly are
  read-only`, `guardrails leave the stored choice unchanged`, `resource status kind accepted`;
  `TestRowLevelSecurityIsolatesTeams/team_collaboration`; `TestCrossTeamWritesChangeNothing/team_collaboration`;
  `TestEveryRevisionTableAnnouncesChanges/team_collaboration` (needs a fixture row, below).

**DB-US-46 · Agent links to Paperclip.** *(refines US-28; COL-10, COL-12, COL-14)* As `afs-api` and the
reconciler, I want each worker agent's connection to Paperclip and its link state stored once, with the API
writing what the team chose and only the reconciler writing what it observed.
- `agent_collaboration` has `team_id`, `agent_id` (`PRIMARY KEY (team_id, agent_id)`, `FOREIGN KEY (team_id,
  agent_id) REFERENCES afs.agents (team_id, id)`), `connect boolean NOT NULL`, `paperclip_agent_id text` with
  `CHECK (paperclip_agent_id ~ '^[A-Za-z0-9._:-]{1,128}$')`, `link_state text NOT NULL CHECK (link_state IN
  ('pending','linked','failed','disabled'))`, `last_synced_at timestamptz`, `last_error text CHECK
  (length(last_error) <= 500)`, and `version`, `generation`, `created_at`, `created_by`, `updated_at`. After the
  migration the table is empty: no backfill, so agents that predate the collaboration agent are not connected
  (COL-10).
- Trigger `afs.agent_collaboration_guard()` (BEFORE INSERT OR UPDATE): the agent must have `role = 'worker'`
  (`23514`); `connect = true` while the team has no `team_collaboration` row is `55000`; a change of
  `paperclip_agent_id` by any role other than `afs_reconciler` while the team's `registration_mode = 'managed'` is
  `55000`; `link_state` is set by the trigger on insert (`pending` when `connect`, else `disabled`) and when
  `connect` changes (`pending` when it becomes true, `disabled` when false). Any `link_state` the caller supplies
  on insert is overwritten; thereafter only `afs_reconciler` changes `link_state`, `last_synced_at` and
  `last_error`.
- Generation: a change of `connect` bumps `generation` by 1 (trigger, DB-D1), so the reconciler rolls the agent's
  pod; a change of `paperclip_agent_id` alone also bumps it (the env var `PAPERCLIP_AGENT_ID` changes); a change
  of `last_synced_at`, `last_error` or `link_state` alone does not.
- Grants: `afs_app` `SELECT`, `INSERT (team_id, agent_id, connect, paperclip_agent_id)`, `UPDATE (connect,
  paperclip_agent_id)`, so the upsert `INSERT ... ON CONFLICT (team_id, agent_id) DO UPDATE SET connect = ...`
  works and writing `link_state`, `last_synced_at` or `last_error` is `42501`. `afs_reconciler` `SELECT` and
  `UPDATE (paperclip_agent_id, link_state, last_synced_at, last_error)`. `afs_readonly` `SELECT`. No other role.
- RLS, revision key `<team_id>/<agent_id>` (the key `afs.record_revision()` builds from `team_id` and `agent_id`
  since 000018) and change feed as DB-US-45; the notify payload is `agent_collaboration:<team_id>:` (DB-D2).
- Proven by: `TestAgentCollaboration`: `worker only 23514`, `connect needs a collaboration row 55000`, `link
  state set by trigger`, `app cannot write link columns 42501`, `reconciler writes link columns`, `managed mode
  locks paperclip_agent_id for the API 55000`, `manual mode lets the API record it`, `agent id format 23514`,
  `last error length 23514`, `upsert under column grants`, `generation bumps on connect and agent id only`,
  `no rows after migration`, `revision key and notify payload`; isolation subtests as DB-US-45 with
  `/agent_collaboration`.

**DB-US-47 · Edge read access: role, routes, settings and provider client.** *(refines US-29; COL-16, COL-17,
COL-23)* As `afs-edge`, I want to learn the route table and the service settings through two functions with no
table privilege, so that a bug or a compromise of the public component can read nothing else.
- `bootstrap/roles.sql` creates `afs_edge` (`NOLOGIN`, `IF NOT EXISTS`, listed in its header comment and its
  role array). The migration's first statement checks that the role exists and raises `55000` ("run
  afs-migrate bootstrap-roles") if not, because `afs_owner` cannot create cluster roles.
- `afs_edge` holds `USAGE` on schema `afs`, `EXECUTE` on the ten functions of DB-US-47, DB-US-51, DB-US-52 and DB-US-55
  (revoked from `PUBLIC`) and `afs.schema_version()` (000017's grant list gains it), and may `LISTEN
  afs_desired_state`. Given any table or view in schema `afs`, when `afs_edge` selects, inserts, updates or
  deletes, then `42501` (catalog-driven over every relation, so a table added later cannot slip a grant in).
- Every function is `SECURITY DEFINER`, owned by `afs_owner`, with `SET search_path = pg_catalog, afs`, and
  returns only its named columns.
- `afs.collab_routes()` returns one row per team whose `state` is not `deleting` or `deleted` and that has a
  `team_collaboration` row, with the columns of contract §7.2.5. Given those rows: `hostname` is
  `slug || '.' || collab.base_domain`, NULL when the base domain setting is JSON `null`; `web_ui_effective` and
  `rest_api_effective` are the stored choice AND `teams.may_expose_collaboration` AND `collab.public_endpoints`
  AND a base domain, and for the web UI also a provider with `collab_client_id` (so each of the five inputs
  turned off alone turns the effective flag off while the stored flag stays); `ready` is true only for an
  `active` team, an `enabled` agent and `resource_status` conditions containing `{"type": "EndpointReady",
  "status": "True"}` for `('team_collaboration', <team_id>)`; `not_ready_reason` is NULL when ready, else
  `team_suspended` (team suspended), `paused` (agent paused) or `starting` (everything else, including a deleting
  agent, a missing status row and `EndpointReady` not true); `provider_id`, `issuer_url`, `groups_claim`,
  `collab_client_id` and `collab_client_secret_arn` come from the team's `identity_provider_id` provider, else the
  default provider, and are NULL (client columns) when the provider has no collaboration client; `service_name`
  is `paperclip` and `port` 3100. A team without a collaboration row, and a deleted team, return no row.
- `afs.collab_settings()` returns `(key, value)` for the seven `collab.*` keys only, and no other setting.
- `identity_providers` gains `collab_client_id text` (nullable, `CHECK (collab_client_id ~
  '^[A-Za-z0-9._:@-]{1,255}$')`) and `collab_client_secret_arn text` (nullable, a reference, never a value; the
  same ARN pattern as `client_secret_arn`, DB-D14), with `CHECK (collab_client_secret_arn IS NULL OR
  collab_client_id IS NOT NULL)`. Service admins write them through the existing `app_write` policy; a team-admin
  cannot (zero rows or `42501` as today). The existing `identity_providers_revision` and notify triggers cover
  them.
- Proven by: `TestEdgeRole`: `no privilege on any relation 42501`, `listens to the change feed`, `schema version`,
  `routes: columns and hostname`, `routes: each guard turns the effective flag off`, `routes: ready and reasons`,
  `routes: provider selection`, `routes: deleted and unconfigured teams omitted`, `settings are collab keys only`,
  `functions revoked from public and other roles`; `TestIdentityProviderCollabClient`: `format 23514`, `secret
  without client 23514`, `arn pattern 23514`, `service admin writes, team admin cannot`.

**DB-US-48 · Collaborator role, guardrail and settings ranges.** *(refines US-30, US-33; COL-20, COL-23; ACC-2)*
As a service admin, I want the new role, the per-team guardrail and the service settings to be accepted and
validated by the database, so that bad values never reach the edge.
- `role_bindings_role_check` and `api_keys_role_check` are replaced (`NOT VALID` then `VALIDATE`) to accept
  `team_collaborator`. Given a team binding or a team API key with that role, then it is accepted; given a
  service-level binding or key (`team_id` NULL), then `23514` through `role_bindings_check` and
  `api_keys_scope_check`, which already tie service roles to a NULL team. Existing roles still work.
- `teams.may_expose_collaboration boolean NOT NULL DEFAULT true`. The trigger `teams_guardrail_guard` of 000013
  fires `BEFORE UPDATE OF` an explicit column list, so 000020 drops and recreates it with the new column in that
  list (DB-D6). Given `afs_app` with `afs.service_admin` off, when it changes the column, then `42501`; given a
  service admin, then it succeeds; the five columns guarded before still raise `42501` for a team-admin, and a
  reconciler update of `state` is unaffected.
- Seven settings are seeded with the defaults of change PRD §6.9: `collab.base_domain` = JSON `null`,
  `collab.public_endpoints` = `true`, `collab.allowed_source_cidrs` = `[]`, `collab.session_ttl_minutes` = 480,
  `collab.content_scan` = `"block"`, `collab.max_body_mb` = 25, `collab.denied_spike_threshold` = 50.
- A new constraint `service_settings_collab_check` (added `NOT VALID`, then `VALIDATE`; the 000013, 000010 and
  000012 constraints are left alone, DB-D7) rejects with `23514`: a base domain that is neither JSON `null` nor a
  DNS name (`afs.dns_name_ok`: lower-case labels of 1 to 63 characters, 4 to 253 in all, at least two labels, no
  trailing dot); a non-boolean `collab.public_endpoints`; a `collab.allowed_source_cidrs` that is not an array of
  at most 100 valid IPv4 or IPv6 CIDR strings (`afs.cidr_list_ok`); a `collab.session_ttl_minutes` not an integer
  from 15 to 1440; a `collab.content_scan` other than `"block"`, `"warn"`, `"off"`; a `collab.max_body_mb` not an
  integer from 1 to 100; a `collab.denied_spike_threshold` not an integer from 1 to 100000. Both helpers are
  `IMMUTABLE`. Other keys are unaffected.
- Proven by: `TestRoleCollaborator`: `team binding`, `team key`, `service level refused 23514`, `old roles
  still accepted`; `TestTeamGuardrailMayExpose`: `team admin 42501`, `service admin`, `earlier guarded columns
  still 42501`, `reconciler state update unaffected`; `TestServiceSettingRanges/collab.*`: one subtest per key
  with an accepted value, each boundary and each rejected value above, plus `seeded defaults`.

**DB-US-49 · Managed secrets and reserved names.** *(refines US-28, US-32; COL-7, COL-12, SEC-7)* As security, I
want no secret to sit at or beside Paperclip's reserved path except through AFS or Paperclip's own provider, and
Paperclip's own secrets listed but never bound, so that the managed hierarchy cannot be bypassed.
- `secrets.managed_by text NOT NULL DEFAULT 'user'` with `CHECK (managed_by IN ('user','afs','paperclip'))`; every
  existing row reads `user`. The value never changes after insert for any role (`55000`, the code of the
  immutability rule in `afs.secrets_managed_path`).
- Trigger `afs.secrets_managed_guard()` (BEFORE INSERT OR UPDATE OR DELETE) enforces this matrix, `23514`
  otherwise:

  | Secret name | Allowed `managed_by` | Scope |
  |---|---|---|
  | `paperclip` | none | none: it would sit beside the `paperclip/` prefix |
  | `paperclip-better-auth-secret`, `paperclip-tool-action-signing-secret`, `paperclip-secrets-master-key`, `paperclip-board-api-key` | `afs` | agent scope, the team's live collaboration agent only |
  | `paperclip-agent-api-key` | `user` or `afs` | agent scope, a `worker` agent only (PC-D11) |
  | any other `paperclip-*` | `paperclip` | agent scope, the collaboration agent |
  | every other name | `user` | as today |

  A shared (`agent_id` NULL) or pool-scoped secret with a `paperclip` name is `23514`.
- `paperclip` rows are Paperclip's own: `origin = 'registered'` (the check `secrets_origin_check` of 000003, which
  allows only `managed`, becomes `origin IN ('managed','registered')` with a new `secrets_registered_paperclip_check
  CHECK (origin = 'managed' OR managed_by = 'paperclip')`, DB-D3). For these rows the trigger `afs.secrets_managed_path`
  does not recompute `path`; it sets `path` from the ARN's secret-name part, which must start with
  `afs.secret_path(team_id, agent_id, 'paperclip') || '/'` (`23514` otherwise), so `secrets_arn_matches_path` and
  `secrets_path_key` keep holding. The trigger sets `name` to `paperclip-` plus the path suffix lower-cased with
  characters outside `[a-z0-9-]` replaced by `-`, cut to 63 characters, and with `-<4 hex>` appended when another
  row of the same agent already has that name; a partial unique index `secrets_paperclip_name_uq ON (team_id,
  agent_id, name) WHERE managed_by = 'paperclip'` backs it (`UNIQUE (team_id, name)` was dropped in 000003, so the
  uniqueness is not inherited, DB-D5).
- Writers: `afs_app` inserts `managed_by = 'user'` or `'afs'` only; an insert, update or delete of a `paperclip`
  row by `afs_app` is `42501`. `afs_reconciler` gains `INSERT, UPDATE, DELETE` on `afs.secrets` and the trigger
  raises `42501` for any write by it to a row whose `managed_by <> 'paperclip'`, instead of an RLS filter that
  would hide the refusal (DB-D4). `SECURITY DEFINER` functions (`record_work_order_secret`, 000019) run as the
  owner and are unaffected. The reconciler never inserts `afs` rows directly: `afs-api` creates the three boot secrets in the `CreateAgent`
  transaction, and the reconciler records `paperclip-agent-api-key` and `paperclip-board-api-key` through the
  `SECURITY DEFINER` functions of DB-US-56 and records the `afs`-managed key rows through the three functions of DB-US-56 (DB-D11, PC-D25).
- A live collaboration agent's four `afs`-managed secrets (three boot secrets and the board key) cannot be deleted
  by `afs_app` (`55000`); they may be updated for rotation of the metadata columns (`last_changed_at`,
  `current_version_id`) (DB-D12).
- Binding: an `agent_secret_bindings` insert or update that names a `paperclip` secret is `23514` (rule added to
  `afs.binding_respects_scope`); binding `afs`-managed secrets to their own agent works.
- Proven by: `TestManagedSecrets`: `managed_by default and immutability`, `reserved names matrix` (one row per
  line of the table, accepted and rejected), `paperclip name needs a collaboration agent`, `agent api key only on
  a worker`, `paperclip scope refused for shared and pool`, `paperclip row path from arn`, `arn outside the
  prefix 23514`, `name sanitising, cut and collision suffix`, `app cannot write paperclip rows 42501`, `reconciler
  writes paperclip rows only 42501`, `reconciler cannot write user rows`, `work order secret function still
  works for the reconciler`, `binding refused 23514`, `boot secrets cannot be deleted 55000`, `origin and
  managed_by check`, `isolation with another team's secrets`.

**DB-US-50 · A collaboration agent that goes takes its route with it.** *(refines US-27; COL-8, TEAM-9)* As the
reconciler, I want the route to disappear and the team's agents to disconnect in the same transaction that
starts the collaboration agent's deletion, so that no request reaches a dying Paperclip.
- Trigger `afs.agents_collaboration_cleanup()` (AFTER UPDATE OF `state`, `deleted_at`; `SECURITY DEFINER`, owner
  `afs_owner`, `SET search_path = pg_catalog, afs`). When a collaboration agent's `state` becomes `deleting` or
  `deleted` (from `enabled` or `paused`), it deletes the team's `team_collaboration` row and sets `connect =
  false` on every `agent_collaboration` row of the team that has `connect = true` (their `link_state` becomes
  `disabled` through DB-US-46's trigger and `generation` bumps, so the reconciler rolls them and revokes keys).
  Link rows stay.
- Given `paused` or `enabled`, then nothing is deleted (pause keeps the route record, COL-8). Given a worker
  agent's state change, then nothing happens. Given the trigger runs twice (`deleting`, then `deleted`), then the
  second run changes nothing and raises nothing.
- Given the deletes and updates, then the revision triggers write `DELETE` and `UPDATE` revisions and the notify
  triggers announce both, even though the actor was `afs_app` or `afs_reconciler`, who hold no `DELETE` on
  `team_collaboration`.
- Proven by: `TestCollaborationCleanup`: `deleting removes the route row`, `deleted after deleting is a no-op`,
  `paused and enabled keep it`, `every connected agent disconnects and rolls`, `unconnected links untouched`,
  `worker state change ignored`, `revisions and notifications written`, `works for the reconciler and the API`.

**DB-US-51 · Edge principals.** *(refines US-29, US-31; COL-18, COL-19)* As `afs-edge`, I want to learn which AFS
roles a signed-in person or an API key holds on one team, through functions that reveal nothing about other
teams, so that the edge decides with the same rules as `afs-api`.
- `afs.collab_principal(p_team_id, p_subject, p_provider_id, p_groups text[])` returns `(binding_id, role,
  subject_type, user_id)` for the `team_admin`, `team_viewer` and `team_collaborator` bindings on that team and
  the `service_admin` bindings that match the person. A user binding matches the `users` row whose
  `oidc_issuer` equals the `issuer_url` of provider `p_provider_id` and whose `oidc_subject` equals `p_subject`
  and whose `disabled_at` is NULL (DB-D9); `user_id` is NULL when no user row exists yet, which returns only group
  bindings. A group binding matches when `p_groups` contains `group_name` and its `identity_provider_id` equals
  `p_provider_id` (or is NULL and `p_provider_id` is the default provider); a service-level group binding matches
  on the provider it names. No `security_operator` row is ever returned. `p_groups` over 500 entries is `22023`.
  A binding on another team is never returned.
- `afs.collab_principal_key(p_team_id, p_key_sha256 bytea)` returns `(key_id, role, state, expires_at,
  revoked_at)`: no row for an unknown hash, for a service-level key, or for a key of another team (the answer for
  another team's key equals the answer for an unknown key); `state` is `active`, `expired` or `revoked`; for a
  usable key it sets `last_used_at` at most once a minute (as `afs.authenticate_api_key`); it never returns the
  hash or the key prefix.
- Both functions are executable by `afs_edge` only (`42501` for `afs_app`, `afs_reconciler`, `afs_gateway`,
  `afs_billing`, `afs_readonly`) and write nothing but `last_used_at`.
- Proven by: `TestEdgePrincipal`: `user binding by issuer and subject`, `disabled user matches nothing`, `user row
  missing returns group bindings only`, `group binding on the team provider`, `group binding of another provider
  ignored`, `default provider groups`, `service admin binding returned`, `security operator never returned`,
  `other team's bindings never returned`, `more than 500 groups 22023`, `team_collaborator role returned`;
  `TestEdgePrincipalKey`: `active key`, `expired`, `revoked`, `unknown hash`, `service key`, `other team's key looks
  unknown`, `last_used_at once a minute`, `no hash in the result`; `TestEdgeRole/only the edge may call`.

**DB-US-52 · Access counts and the secret-detected event.** *(refines US-29, US-32, US-33; COL-24, COL-30, COL-31,
COL-36)* As `afs-edge`, I want to record five-minute access counts and the detection of a credential in one call
each, so that reports and alerts never need a table privilege or a request body.
- `collaboration_access` is partitioned by month on `bucket_start` with a default partition, columns and checks of
  contract §7.2.5 (`bucket_start` on a five-minute boundary, `surface`, `principal_kind`, `outcome` in the listed
  sets, `principal_id` empty exactly when `anonymous`, `requests > 0`, `bytes >= 0`, `service_admin_entry`),
  primary key `(bucket_start, team_id, surface, principal_kind, principal_id, outcome, service_admin_entry)` and
  index `(team_id, bucket_start)`. It has no foreign key (facts outlive the team, like `agent_activity`) and no
  revision or notify trigger. RLS: `SELECT` policy `app_team_scope` for `afs_app`, `service_roles_all` for the
  service roles. Grants: `afs_app`, `afs_reconciler`, `afs_readonly` `SELECT`; nobody writes directly (`42501` for
  `afs_app`, `afs_reconciler`, `afs_edge`).
- `afs.record_collab_access(p_rows jsonb) -> integer` takes at most 1000 objects `{bucket_start, team_id, surface,
  principal_kind, principal_id, outcome, service_admin_entry, requests, bytes}` and adds each with `ON CONFLICT DO
  UPDATE SET requests = requests + EXCLUDED.requests, bytes = bytes + EXCLUDED.bytes`. A `bucket_start` off a
  five-minute boundary, or outside `now() - 1 day` to `now() + 5 minutes`, is `22023`; an unknown `surface`,
  `principal_kind` or `outcome`, or a non-empty `principal_id` for `anonymous`, is `23514`; a row for an unknown
  team is skipped; more than 1000 rows is `22023`. It returns the number of rows applied. Given the same batch
  sent twice, then the counts double (the function is additive, so the edge must not retry a batch that
  succeeded). The function takes no body, path or header, and a test greps its source for them.
- `afs.ensure_collaboration_access_partition(month date) -> text` creates a monthly partition like
  `ensure_activity_partition`, is `SECURITY DEFINER`, and is executable by `afs_reconciler` only.
  `afs.drop_partitions_older_than(months)` is replaced (`CREATE OR REPLACE`, same signature, same grants) to
  include `collaboration_access` in the tables it drops from, still never `audit_log`, and still leaving default
  partitions.
- `afs.emit_collab_secret_detected(p_team_id, p_surface, p_principal_kind, p_principal_id, p_pattern, p_action,
  p_count integer) -> bigint` inserts one `outbox_events` row with `event_type = 'collaboration.secret_detected'`,
  `aggregate_kind = 'team_collaboration'`, `aggregate_id = p_team_id` (DB-D13), `team_id`, and a payload built by
  `afs.event_detail` (the API contract §7 envelope, actor `system:edge`) whose `data` holds surface, principal,
  pattern, action and count only. `p_pattern` outside the eight names (`aws_access_key`, `github_token`,
  `slack_token`, `private_key`, `jwt`, `okta_client_secret`, `entra_client_secret`, `generic_assignment`) and
  `p_action` outside `blocked`, `warned` are `23514`; `p_count` below 1 is `23514`; an unknown team is `23503`.
  There is no parameter that could carry a value or fragment, and the function can write no other event type
  (PC-D16). It returns the outbox id.
- Proven by: `TestCollaborationAccess`: `columns and checks 23514`, `anonymous principal id`, `bucket alignment
  22023`, `time window 22023`, `batch limit 22023`, `additive upsert`, `unknown team skipped`, `returns applied
  count`, `no direct writes 42501`, `app reads own team only`, `reconciler and readonly read all`, `service admin
  entry kept apart`, `source has no body path or header columns`; `TestCollaborationAccessPartitions`: `ensure
  creates and is idempotent`, `reconciler only`, `default partition catches strays`;
  `TestRetentionDropsEveryFactTable` (extended: `collaboration_access` month 14 dropped, month 13 and default
  kept, `audit_log` untouched); `TestEdgeRole/emit_collab_secret_detected`: `envelope and outbox row`, `no other
  event type possible`, `pattern and action sets 23514`, `unknown team 23503`, `payload carries no value`;
  `TestRowLevelSecurityIsolatesTeams/collaboration_access` (team B rows in the fixture).

**DB-US-53 · A deleted team's hostname is held.** *(refines US-33; TEAM-9, PC-D9)* As security, I want a deleted
team's hostname held for 30 days, so that a new team with the same slug cannot take over old links.
- `collab_hostname_holds (slug text PRIMARY KEY, team_id text NOT NULL, held_until timestamptz NOT NULL, created_at
  timestamptz NOT NULL DEFAULT now())`, no foreign key. An AFTER UPDATE trigger on `teams` inserts, or extends to
  `now() + interval '30 days'`, a hold when `deleted_at` becomes set on a team that **ever had a collaboration
  agent**: any `agents` row of the team with `role = 'collaboration'`, deleted or not (DB-D10), because
  `afs.agents_collaboration_cleanup` has by then removed the team's `team_collaboration` row.
- A BEFORE INSERT trigger on `teams` refuses a slug with an unexpired hold held for a different `team_id` with
  `23505` and constraint name `collab_hostname_held`. An expired hold, or one held for the same `team_id`, does
  not refuse. `teams.slug` is `UNIQUE` across deleted rows, which already refuses reuse; the hold makes the rule
  explicit and survives a later purge of deleted team rows.
- A team that never had a collaboration agent leaves no hold. There is no early release in this release.
- Grants: `afs_app`, `afs_readonly` `SELECT`; `afs_reconciler` `SELECT, DELETE` (it purges expired holds daily);
  nobody else. No revision or notify trigger. Writes by `afs_app` or `afs_reconciler` are `42501` (the triggers are
  `SECURITY DEFINER`).
- Proven by: `TestHostnameHold`: `hold created on delete of a team that had a collaboration agent`, `deleted
  collaboration agent does not lose the hold`, `no hold for a team without one`, `reuse refused 23505
  collab_hostname_held`, `expired hold allows reuse`, `hold extended not duplicated`, `reconciler purges expired
  holds`, `direct inserts refused 42501`.

**DB-US-54 · The migration is safe to run and to reverse.** *(refines US-27; PC-D11 to PC-D18)* As an operator, I
want 000020 to be one transactional, additive migration that checks its precondition and states its lock impact,
so that adopting it is routine.
- `000020_paperclip_collaboration.up.sql` and `.down.sql` are contiguous, run in one transaction, begin with the
  `afs_edge` pre-flight (DB-US-47) and carry a header that states the lock impact of each change to an existing
  table (`TestMigrationsStateLockImpact` already requires the words *lock impact*). It uses no statement that
  cannot run in a transaction, and no statement rewrites `agents`, `secrets` or `teams`.
- Given a database at 000019 with data, when 000020 is applied, then no existing row changes except the defaults
  it adds (`role = 'worker'`, `capabilities = '{}'`, `managed_by = 'user'`, `may_expose_collaboration = true`,
  the seven settings inserted), and every existing test still passes.
- Given up, down, up: the down migration drops the new tables, functions, triggers, columns and grants,
  restores the 000013 trigger column list, `secrets_origin_check` and the role checks (deleting
  `paperclip`-origin secret rows, `team_collaborator` bindings and keys first), removes the seven settings, and
  does not drop role `afs_edge`; the second up succeeds and the checksum guard passes; the down leaves the schema
  catalog equal to 000019's (compared by a catalog query over columns, constraints, triggers, policies and grants).
- `bootstrap/roles.sql` change is idempotent and `afs-migrate bootstrap-roles` can be rerun on a cluster that has
  `afs_edge`.
- The role lists in `service_access_test.go` and `schema_version_test.go` gain `afs_edge` where a function is
  granted to every role (`afs.schema_version()`), and `seedOtherTeams` gains rows for `team_collaboration`,
  `agent_collaboration`, `collaboration_access`, an identity provider with a collaboration client and a
  collaboration agent for team B (so `TestCrossTeamWritesChangeNothing` and
  `TestEveryRevisionTableAnnouncesChanges` cover the new tables).
- Proven by: `TestMigration000020`: `requires afs_edge 55000`, `existing rows keep their meaning`, `up down up`,
  `down restores 000019 objects`, `checksum guard`, `bootstrap-roles is idempotent`;
  `TestMigrationsStateLockImpact`; `TestEveryRevisionTableAnnouncesChanges/team_collaboration` and
  `/agent_collaboration`; `TestCrossTeamWritesChangeNothing/team_collaboration`, `/agent_collaboration`.

**DB-US-55 · Edge sessions and the single-use handoff.** *(refines US-29; COL-17, PC-D22, PC-D23)* As `afs-edge`, I
want sessions and the 60-second handoff stored server-side behind functions, so that single use holds across
replicas, the cookie carries only an opaque id, and `afs_edge` still holds no table privilege.
- `collab_edge_sessions`: `id_hash bytea PRIMARY KEY CHECK (length(id_hash) = 32)`, `team_id text NOT NULL` (no
  foreign key), `issuer`, `subject`, `provider_id` (`text NOT NULL`), `groups text[] NOT NULL DEFAULT '{}' CHECK
  (cardinality(groups) <= 500)`, `created_at`, `expires_at timestamptz NOT NULL CHECK (expires_at > created_at)`,
  `last_seen_at`, `revoked_at`. `collab_edge_handoffs`: `code_hash bytea PRIMARY KEY CHECK (length(code_hash) =
  32)`, `team_id`, `host`, `issuer`, `subject`, `provider_id`, `groups` (as above), `expires_at NOT NULL`,
  `consumed_at`, `created_at`. No token, claim other than `groups`, or Paperclip content is stored; the plain
  session id and code never are (DB-D17).
- Both tables have RLS enabled with no policy for `afs_app` and **no grant to any role**, `afs_readonly` included
  (the hashes are credentials): every role's direct select, insert, update or delete is `42501`.
- `afs.collab_handoff_create(code_hash, team_id, host, issuer, subject, provider_id, groups) -> timestamptz` stores
  the identity and returns `expires_at = now() + 60 s`; an existing hash is `23505`; more than 500 groups `22023`.
- `afs.collab_handoff_consume(code_hash, host, session_id_hash) -> (team_id, expires_at)` runs one atomic `UPDATE
  ... SET consumed_at = now() WHERE code_hash = $1 AND host = $2 AND consumed_at IS NULL AND expires_at > now()
  RETURNING` and, in the same transaction, inserts a session for that identity under the hash the edge supplied,
  with `expires_at = now() + collab.session_ttl_minutes`. There is no `collab_session_create`. Given two concurrent
  calls with one code, then exactly one returns a row and exactly one session exists; given an unknown, expired,
  consumed or other-host code, then no row and no session; given a `session_id_hash` already in use, `23505`.
- `afs.collab_session_get(id_hash)` returns one row (`team_id`, `issuer`, `subject`, `provider_id`, `groups`,
  `expires_at`, `last_seen_at`) for a live session (not expired, not revoked) and no row otherwise; it sets
  `last_seen_at` at most once a minute and deletes nothing. `afs.collab_session_revoke(id_hash) -> boolean` sets
  `revoked_at` and returns true when a live session was revoked.
- `afs.purge_collab_edge_sessions() -> bigint` (`afs_reconciler` only, hourly) deletes sessions expired or revoked
  more than an hour ago and handoffs expired more than an hour ago, and returns the rows deleted; younger rows stay.
- The ten edge functions are `collab_routes`, `collab_settings`, `collab_principal`, `collab_principal_key`,
  `record_collab_access`, `emit_collab_secret_detected` and these four; `afs_edge` may execute exactly those (the
  catalog test in DB-US-47 counts ten) and all four are `SECURITY DEFINER` with `search_path = pg_catalog, afs`.
- Proven by: `TestEdgeSessions`: `handoff single use under concurrency`, `handoff expires after 60 seconds`, `handoff
  bound to its host`, `consume creates the session under the edge's hash`, `duplicate hash 23505`, `unknown code no
  row`, `session get live only`, `last_seen_at once a minute`, `revoke`, `groups limit 22023`, `session ttl follows
  collab.session_ttl_minutes`, `purge removes only old rows`, `no grant on the tables for any role 42501`, `plain
  ids never stored (columns hold 32-byte hashes)`, `only the edge may call the four, only the reconciler the purge`.

**DB-US-56 · Reconciler key functions.** *(refines US-28; COL-12, COL-32; PC-D25, PC-D26)* As the reconciler, I want
three functions to record and remove the `afs`-managed Paperclip key secrets, so that I never hold an insert on
`afs`-managed rows and the guard of DB-US-49 stays strict.
- `afs.record_collab_agent_key(team_id, agent_id, secret_arn) -> text` (`afs_reconciler` only; `afs_app` and every
  other role `42501`): for a live `worker` agent whose `agent_collaboration.connect` is true in a team with
  `registration_mode = 'managed'`, upserts the agent's secret `paperclip-agent-api-key` (`managed_by = 'afs'`,
  `origin = 'managed'`, agent scope, empty description) and its `agent_secret_bindings` row (`delivery = 'env'`,
  `target = 'PAPERCLIP_AGENT_API_KEY'`). The ARN must match the 000009 regex with a path equal to
  `afs.secret_path(team_id, agent_id, 'paperclip-agent-api-key')`. It returns the secret id and is idempotent: a
  second call with a new ARN updates the row (a rotation reuses it) and creates no second binding. It writes an audit
  row `RecordCollabAgentKey` (`actor_type` `system`, `actor_id` `afs.current_actor()`) and no outbox row. Errors:
  unknown agent `P0002`; agent not connected, not a worker, or registration `manual` `55000`; bad ARN `23514`.
- `afs.remove_collab_agent_key(team_id, agent_id) -> boolean` removes that binding and secret row and returns true
  when anything was removed (false when there was nothing); audit `RemoveCollabAgentKey`; no outbox row.
- `afs.record_collab_board_key(team_id, collab_agent_id, secret_arn) -> text` records `paperclip-board-api-key` on the
  team's live collaboration agent (`managed_by = 'afs'`, agent scope, path equal to `afs.secret_path(team_id,
  collab_agent_id, 'paperclip-board-api-key')`) and **never** a binding. It returns the secret id, is idempotent and
  audits `RecordCollabBoardKey`; `55000` when the agent is not a live collaboration agent of the team; `P0002` for an
  unknown agent; `23514` for a bad ARN.
- The functions run as the owner, so the guard of DB-US-49 allows them; no function writes a secret value (there is
  none to write).
- Proven by: `TestCollabKeyFunctions`: `record creates secret and binding`, `idempotent rotation reuses the row`,
  `manual registration 55000`, `not connected 55000`, `not a worker 55000`, `unknown agent P0002`, `arn path must
  match 23514`, `remove returns true then false`, `audit rows and no outbox rows`, `board key has no binding`,
  `board key needs a live collaboration agent 55000`, `only the reconciler may call 42501`, `afs_app still cannot
  insert afs rows for a paperclip name it may not own`.

**DB-US-57 · A swarm may rent a collaboration agent.** *(refines US-33 and the swarm stories; COL-9, PC-D29; P1,
shipped in 000020, used in C4)* As the reconciler, I want `instantiate_work_order_team` to create the collaboration
agent when the swarm template asks for one, so that a swarm's people can watch it.
- A swarm template `spec` may carry `collaboration: {"templateId": "tpl_..."}`. When it does,
  `afs.instantiate_work_order_team` (000016, replaced by `CREATE OR REPLACE`; 000019's envelope payloads kept) also
  inserts, in the same transaction, the team's collaboration agent (`role = 'collaboration'`, that template and its
  `current_image_digest`, `iam_identity = 'dedicated'`, `snapshot_schedule = 'daily'`, the template's default
  resources, name `paperclip`) and its `team_collaboration` row (web UI on, REST API off, `manual`), and writes an
  outbox event `agent.created` with the API contract §7 envelope beside the existing ones. Its model is the model
  of the swarm's first pool in spec order (DB-D18: `agent_templates` has no model column).
- Given an unknown, disabled or non-`paperclip` template, then `23514` and nothing is created (the team, pools and
  work order are unchanged); given a spec without `collaboration`, then behaviour is exactly as 000019; given a
  second call, then it returns the same team and creates no second agent.
- `afs.record_work_order_secret` (000019) accepts the id of the work order team's collaboration agent (`agt_...`) in its
  pool argument. It then records an agent-scope secret with `managed_by = 'afs'` and its binding, only for the three
  boot secret names and their environment variables (`BETTER_AUTH_SECRET`, `PAPERCLIP_TOOL_ACTION_SIGNING_SECRET`,
  `PAPERCLIP_SECRETS_MASTER_KEY`); another name, or an `agt_` id that is not the team's collaboration agent, is `23514`;
  other rules (audit, `secret.created` outbox event, idempotency on team and name) as for a pool secret.
- Proven by: `TestSwarmCollaboration`: `agent and team_collaboration created with defaults`, `agent.created event with
  envelope`, `model from the first pool`, `invalid template refused and nothing created 23514`, `no collaboration
  entry unchanged`, `second call idempotent`, `boot secret recorded for the collaboration agent`, `other names and
  other agents refused 23514`, `pool secrets still work`; the existing `TestInstantiateWorkOrderTeam` and
  `TestRecordWorkOrderSecret` subtests stay green.

## 5. Non-functional requirements

| Area | Requirement |
|---|---|
| Engine | PostgreSQL 17 features only; tested on `postgres:17` in CI |
| Online changes | Additive columns with constant defaults; constraints `NOT VALID` then `VALIDATE`; one transaction; lock impact stated in the migration header |
| Collaboration (000020) | The functions the edge calls on the request path are indexed lookups: `collab_principal` and `collab_principal_key` p99 < 5 ms at 200 teams and 50 000 role bindings; `collab_routes()` p99 < 20 ms for 200 teams (the edge calls it at most every 30 seconds per replica and on a change notification); `record_collab_access` applies a 1000-row batch in under 100 ms p99. `collaboration_access` is bounded by team, person or key, outcome and five-minute bucket: at most about 8.6 M rows a day at the extreme (200 teams, 50 people, 3 outcomes, 288 buckets) and far fewer in practice; monthly partitions, primary key plus one `(team_id, bucket_start)` index per partition, retention 13 whole months like the other fact tables. Working figures, confirmed in the M3 load test (DB-OQ-3). `afs_edge` holds no table privilege and every function returns only its named columns, so a compromise of the public component reads no table |
| Security | `afs_edge` holds no table privilege; every edge function is `SECURITY DEFINER` with `search_path = pg_catalog, afs` and returns only its named columns; no secret value, token, request body or path is stored |
| Quality | Every constraint has a rejected-case test; every new team-owned table has an isolation test and a row in `seedOtherTeams`; `migrate` stays at or above 90% coverage |

## 6. Milestones

| Milestone | This repository |
|---|---|
| C1 Collaboration agent (change PRD §10) | All of migration 000020 (DB-US-44 to DB-US-57; swarm collaboration is P1 and used in C4), as one minor release for `-restapi` to adopt (tag chosen at release; it follows the first tag that contains 000011 to 000019). Exit: every story's *Proven by* test passes against `postgres:17`, `make gate` and `make test-db` are green, the contract §7.2 and `docs/data-model.md` are corrected, `-restapi` has built against the tag. Roles bootstrap (`afs_edge`) runs in dev first |
| C2 Public web UI | No migration. `-restapi` `afs-edge` uses `collab_routes()`, `collab_settings()`, `collab_principal*()`, `record_collab_access()`; this repository supports with fixes and a load check of the principal functions in the dev environment |
| C3 REST API and managed mode | No migration. `emit_collab_secret_detected()`, `paperclip` secret rows and link-state writes are exercised by `-restapi`; gaps found become a minor migration (000021) |
| C4 People and reports | No migration expected. `collaboration_access` read by the collaboration report; retention verified with the monthly job |

## 7. Definition of done

- [ ] New migration, contiguous number, transactional, online-safe, lock impact in the header
- [ ] Down migration reverses it (up/down/up test, catalog comparison with 000019)
- [ ] Rejected-case test for every new constraint and guard; isolation test for every team-owned table
- [ ] `bootstrap/roles.sql` and its header list `afs_edge`; `seedOtherTeams` and the role lists in tests extended
- [ ] `docs/data-model.md` gains the new tables, columns and the `afs_edge` role; `user-docs/` says to run `afs-migrate bootstrap-roles` first
- [ ] `make gate` and `make test-db` green; release tag noted for `-restapi`

## 8. Decisions

| # | Question | Decision |
|---|---|---|
| DB-D1 | Contract §7.2.2 and §7.2.3 say `generation` bumps, but `afs.touch_row()` bumps only `version` and the application bumps `generation` elsewhere; `afs_app` has no column grant on it | A BEFORE UPDATE trigger on each new table bumps `generation` when a spec column changes (`web_ui_enabled`, `rest_api_enabled`, `registration_mode`; `connect`, `paperclip_agent_id`, because `PAPERCLIP_AGENT_ID` is an env var of the pod). The database guarantees the roll of the pod, not the API |
| DB-D2 | Contract §7.2.2 and §7.2.3 give the notify payloads `team_collaboration:<team_id>:<team_id>` and `agent_collaboration:<team_id>:<agent_id>`, but `afs.notify_desired_state()` (000013) uses `to_jsonb(row)->>'id'` for the third part and `TestEveryRevisionTableAnnouncesChanges` asserts that | Keep the function and the test unchanged. Payloads are `team_collaboration:<team_id>:` and `agent_collaboration:<team_id>:` (the id part empty, like `agent_secret_bindings`); the reconciler re-reads the team. The contract text is corrected |
| DB-D3 | Contract §7.2.4 says Paperclip's rows use `origin = 'registered'`, but `secrets_origin_check` (000003) allows only `managed` and `afs.secrets_managed_path` recomputes `path` from the name on every insert, which would not match an ARN under `paperclip/` | Follow the contract's `registered`: widen `secrets_origin_check` and add `secrets_registered_paperclip_check`; for `paperclip` rows the trigger derives `path` from the ARN instead of recomputing it |
| DB-D4 | Contract §7.2.6 limits the reconciler's secret writes to `paperclip` rows "by policy and column grant" and expects `42501`; the existing `service_roles_all` policy is `USING (true)`, and a restrictive policy would silently filter an UPDATE or DELETE | Table grant plus trigger `afs.secrets_managed_guard()`, which raises `42501` for `afs_reconciler` writes to rows that are not `managed_by = 'paperclip'` and for `afs_app` writes to `paperclip` rows |
| DB-D5 | Contract §7.2.4 relies on "the existing `UNIQUE (team_id, name)`", which 000003 dropped (a secret's identity is its `path`) | The trigger computes `name` for `paperclip` rows (sanitised path suffix, 63 characters, `-<4 hex>` on collision); a partial unique index `secrets_paperclip_name_uq` on `(team_id, agent_id, name) WHERE managed_by = 'paperclip'` backs it so T4 shows stable names |
| DB-D6 | Contract §7.2.1 says the 000013 guard "lists" `may_expose_collaboration`, but `teams_guardrail_guard` is `BEFORE UPDATE OF <column list>` | 000020 drops and recreates the trigger with the column added; the function is replaced with the extra condition |
| DB-D7 | Contract §7.2.1 says the 000013 range check is replaced; the settings checks are four separate constraints (`service_settings_pricing_check`, `_idempotency_check`, `_swarm_check`, `_runtime_check`, plus `_work_order_team_check`) | Add one new `service_settings_collab_check` (`NOT VALID` then `VALIDATE`) with `IMMUTABLE` helpers `afs.dns_name_ok(jsonb)` and `afs.cidr_list_ok(jsonb)`; touch no existing constraint. Two bounds are chosen here because the contract gives none: at most 100 CIDRs (the WAF IP set allows more; raise it by migration) and a base domain of at least two labels |
| DB-D8 | Contract §7.2.2 names the RLS policy `app_team`; every existing team-owned table uses `app_team_scope` | Use `app_team_scope` and `service_roles_all` |
| DB-D9 | Contract §7.2.5 matches a user on "`sub` and provider"; `users` has `oidc_issuer`, `oidc_subject` and `disabled_at`, and no provider id | Match `users.oidc_issuer = identity_providers.issuer_url` of `p_provider_id` and `oidc_subject = p_subject`, and exclude users with `disabled_at` set |
| DB-D10 | Contract §7.2.5 creates the hostname hold when a team with a `team_collaboration` row is deleted, but the cleanup trigger removes that row when the collaboration agent is deleted, which happens before the team's `deleted_at` is set | Create the hold when the team has ever had a collaboration agent (any `agents` row with `role = 'collaboration'`, including deleted) |
| DB-D11 | Which role inserts `afs`-managed rows for the board key and per-agent keys in `managed` mode | Resolved by PC-D25: neither `afs_app` nor a direct reconciler insert; three `SECURITY DEFINER` functions for `afs_reconciler` (DB-US-56). `afs_app` inserts only the boot secrets |
| DB-D12 | May a team-admin delete the boot secrets of a live collaboration agent? Not stated | No: `55000` for `afs_app`; rotation of metadata is allowed. The API's rotate rules (COL-7) stay in `-restapi` |
| DB-D13 | `aggregate_kind` and `aggregate_id` of `collaboration.secret_detected` are not stated | `team_collaboration` and the team id |
| DB-D14 | Contract §7.2.1 checks `collab_client_secret_arn` with a loose `LIKE`; `client_secret_arn` uses the stricter regex of 000009 | Use the 000009 regex for both, so one parser serves both |
| DB-D15 | After the collaboration agent starts deleting, the unique index (on `deleted_at IS NULL`) still blocks a replacement while the team's route row is already gone | Accept: a new collaboration agent is refused with `23505` until the reconciler marks the old one `deleted`; the API returns `409` meanwhile. No second index |
| DB-D16 | COL-5 says daily snapshots with 14 kept; the column default is 7 | The database keeps its default and enforces only "not off"; `afs-api` sets 14 for the role |
| DB-D17 | Sessions and handoffs (PC-D22, contract §7.2.8) | Only SHA-256 hashes are stored; the edge generates the session id hash and passes it to `collab_handoff_consume`, so the handoff row carries the identity and there is no `collab_session_create`; tables carry no grant to any role and RLS is enabled, with only a deny policy for `afs_app` (DB-D20) |
| DB-D18 | Which model does a swarm's collaboration agent use? Contract §7.2.9 says "the template's default resources and model"; `agent_templates` has no model column | The first pool's model in spec order (an enabled team model by construction); DB-OQ-12 |
| DB-D19 | Do the key functions emit events? | No outbox rows, only audit (PC-D25); the board key is never bound |
| DB-D20 | `TestEveryTeamTableHasRowLevelSecurity` requires a policy for `afs_app` on every table with row-level security, and every table with a `team_id` to have it. DB-D17 said "RLS enabled, no policy" for the edge session tables | Edge session and handoff tables carry an explicit `deny_all` policy for `afs_app` (`USING (false)`), still with no grant to any role; `collab_hostname_holds` (it has a `team_id`) gets row-level security with the standard `app_team_scope` (SELECT) and `service_roles_all` policies. Its two trigger functions are `SECURITY DEFINER`, so a new team's insert still sees every hold |
| DB-D21 | `collab_principal` as first written matched a team's group bindings (which name no provider since 000010) only when the caller's provider was the default | A team's group bindings match when the caller's provider is the team's provider (`teams.identity_provider_id`, else the default); a service-level group binding matches its named provider, else the default |
| DB-D22 | `afs_edge` must not reach `SECURITY DEFINER` helpers through the default `PUBLIC` execute privilege | 000020 revokes `EXECUTE` on `ensure_usage_partition`, `ensure_activity_partition` and `ensure_traffic_partition` from `PUBLIC` (the reconciler keeps its explicit grants); `down` grants them back |
| DB-D23 | `afs.record_revision()` would have keyed `team_collaboration` revisions by `team_id/agent_id` | The function is replaced so a `team_collaboration` revision's key is the `team_id` (one row per team), restored by `down` |

## 9. Open questions

| Id | Question | Owner | Status |
|---|---|---|---|
| DB-OQ-9 | Who inserts the `afs`-managed key rows in `managed` registration? | restapi, db | Resolved by PC-D25: three reconciler functions (DB-US-56); `afs-api` inserts only the boot secrets |
| DB-OQ-10 | Should a worker agent's deletion also set its `agent_collaboration.connect = false`, as the collaboration agent's does for the team? The contract says only the collaboration agent's cleanup does; the reconciler revokes keys for deleted workers by observing `agents.state` | restapi, db | Open; default: no trigger, the reconciler handles it |
| DB-OQ-12 | Swarm collaboration agent's model: `agent_templates` has no model column, so DB-D18 takes the first pool's model. Should the swarm template spec carry `collaboration.modelId` instead (a contract change to database contract §7.2.9)? | restapi, db | Open; default: first pool's model |
| DB-OQ-11 | Is the database to refuse an `agent_collaboration.link_state = 'linked'` while `connect = false`? Not in the contract; the trigger sets `disabled` on disconnect and the reconciler could race it | restapi | Open; default: not refused |

## 10. Dependencies

| Dependency | Who | Calls or provides | When |
|---|---|---|---|
| Database contract §7.2 | Root `docs/contracts/database-contract.md` | Migration 000020; corrected to the decisions of §9.1 when 000020 lands | With 000020 |
| Collaboration role bootstrap | Platform DBA | `afs-migrate bootstrap-roles` creates `afs_edge` (NOLOGIN) before 000020; the `afs-edge` LOGIN user is a member of `afs_edge` with IAM authentication, created with the other service users | Before `-restapi` adopts 000020 |
| Edge | `-restapi` `afs-edge` | `collab_routes()` (30 s and on notify), `collab_settings()`, `collab_principal()`, `collab_principal_key()`, `record_collab_access()` every 5 minutes, `emit_collab_secret_detected()`, `collab_handoff_create/consume`, `collab_session_get/revoke` (sessions are server-side, PC-D22); `LISTEN afs_desired_state` | Continuously |
| Collaboration reconciliation | `afs-reconciler` | Calls `record_collab_agent_key`, `remove_collab_agent_key`, `record_collab_board_key` and `purge_collab_edge_sessions` (hourly); writes `agent_collaboration` link columns and `paperclip` secret rows, `resource_status` for `team_collaboration`; reads `collaboration_access` every minute for `collaboration.denied_spike`; `ensure_collaboration_access_partition` monthly; purges expired `collab_hostname_holds` daily; `drop_partitions_older_than(13)` now also covers `collaboration_access` | Continuously |
| Collaboration API | `afs-api` | Inserts `team_collaboration` with the collaboration agent and the four `afs` boot and board secrets in one transaction; upserts `agent_collaboration`; reads `collaboration_access` for T16 and the collaboration report (reads only, RLS applies) | Per request |
