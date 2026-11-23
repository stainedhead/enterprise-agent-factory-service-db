# Enterprise Agent Factory Service — Database PRD (`-db`)

| | |
|---|---|
| **Status** | Feature complete through schema 000019 for the original scope (every acceptance criterion provable here has a named, passing test; 000018 and 000019 are not yet traced in §4 and §5, DB-OQ-8). **2026-11-22:** extended for the Paperclip team collaboration change: migration 000020 is specified in DB-41 to DB-52 and DB-US-44 to DB-US-57 and implemented (milestone C1, spec `specs/archive/261122-paperclip-collaboration/`; verified locally on PostgreSQL 16, CI's `postgres:17` is the authoritative run; release tag chosen at release), and the PRD review record is §11 |
| **Change** | [Paperclip team collaboration](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/paperclip-team-collaboration-PRD.md) (COL-*, SEC-7; DB-US-44 to DB-US-47 of its §7.2, split and refined here) |
| **Author** | J (Enterprise Architecture), drafted with Claude |
| **Parent** | [Root PRD](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/enterprise-agent-factory-service-initial-PRD.md) (product requirements and stories US-1..US-26) |
| **Provides** | [Database contract](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/database-contract.md) (§7.2 for 000020; where the existing schema contradicts it, §9.1 here records the decision and the contract is corrected) |
| **Consumes** | No service at runtime. The schema relies on jobs and infrastructure owned elsewhere (§10) |
| **Dictionary** | [docs/data-model.md](docs/data-model.md) |

## 1. Purpose

This repository is the only place the AFS schema changes. It holds all desired state, the spend ledger,
reporting tables, the audit log and the outbox in RDS PostgreSQL 17, defines the database roles each
service connects as, enforces team isolation with row-level security, and ships the migrations as a Go
module (`migrate`) plus a command (`afs-migrate`). Its job is to make the wrong thing impossible at the
data layer even if a bug in the API forgets a check. Row-level security and guards **back** the API's
authorization; they do not replace it (`afs-api` still decides every request, root ACC-3).

**Paperclip collaboration (000020).** Each team may run one collaboration agent (Paperclip) that agents in the
namespace connect to and that people reach through a public endpoint served by `afs-edge`. The problem for this
repository is narrow: the public component must read routes, role bindings and settings, and write access counts,
with **no table privilege**; Paperclip's own secrets must live in the managed hierarchy without opening a way to
bypass it; and the one-collaboration-agent-per-team rule must hold even if the API forgets it. The change adds
two desired-state tables, one fact table, one login-less role with ten functions, two session tables, and guards on existing tables.

## 2. Users of this repository

| User | Needs |
|---|---|
| `-restapi` developers | A stable, documented schema at a release tag; clear errors; views that answer reports directly |
| `afs-api`, `afs-reconciler`, `afs-gateway`, `afs-billing` at runtime | Least-privilege roles, fast hot paths (spend reservation), safe concurrency, a change feed |
| Platform operators and DBAs | One-time bootstrap, safe forward-only migrations, backups and restore |
| Security and audit | Isolation they can test, append-only audit, no secret values anywhere, and a public edge role that can read nothing but what its functions return |
| `afs-edge` at runtime (000020) | A role with no table privilege and ten functions: routes, settings, principals, access counts, one event, sessions and the single-use handoff |

## 3. Scope

**In:** schema `afs` and its migrations; roles and grants; RLS, including write policies on the service
catalog, settings, role bindings and users; triggers that guard invariants (guardrails and ceilings,
required tags, price decisions, secret paths, ephemeral team and pool rules, work order access, budget
exhaustion mode); functions for spend reservation (counters and held reservations), spend periods,
partitioning and retention; the desired-state change feed (`pg_notify`); reporting views; `migrate`
package; `afs-migrate` CLI; integration tests; operator docs in `user-docs/`.

**Paperclip change (000020), in:** the collaboration agent role and one-per-team rule, `team_collaboration`, `agent_collaboration`, managed secrets and reserved names, `team_collaborator`, `afs_edge` and its functions, `collaboration_access` and its retention, the hostname hold, and the 000013 guard and settings changes they need.

**Out:** application logic (API, reconciler, gateway, billing), including the jobs that call this
schema's functions on a schedule (§10); Kubernetes and AWS resources (the Paperclip pod, Service and network policy, the public ALB and WAF, the edge's TLS and sessions, IAM for the `paperclip/` prefix, the credential-pattern scanner, Paperclip's own data, none of which the database stores); the creation of Secrets Manager secrets; RDS provisioning, PITR, snapshot
copies, KMS keys and IAM database authentication (Terraform lives in `-restapi/deploy`).

## 4. Requirements owned

Each row traces a product requirement to the objects that implement it. Status: ✓ in schema at
`000019` (rows DB-41 to DB-52 are planned for 000020; 000018 and 000019 are not traced here, DB-OQ-8). Scope is feature complete (root ADR-014): nothing is deferred to a later phase. Rows DB-24 to
DB-34 come from the PRD review (root D28, D30, D31, D33–D36, D45); DB-35 and DB-36 close the two gaps left
open at 000013 (root D54, D49); DB-37 adds owner resolution for work orders (root D38); DB-38 closes the
gaps the 000015 proofs revealed; DB-39 adds the service access paths `-restapi` needs (its X-DB-1 to X-DB-6).

| DB req | Product req | Objects | Status |
|---|---|---|---|
| DB-1 Teams and lifecycle | TEAM-1, TEAM-2 (namespace only), TEAM-5, TEAM-7 | `teams` (`namespace` derived from `slug`, kind, state, expiry, `teardown_rule`, `torn_down_at`, `teardown_reason`), `kind` immutable (`23514`), lifetime-budget triggers, `teams_due_for_teardown`, `resource_status`. Pod Security, ResourceQuota and LimitRange of TEAM-2 are not in the database | ✓ |
| DB-2 Isolation tier | TEAM-6 | `teams.isolation_tier`, `team_isolation_guard` | ✓ |
| DB-3 Allowed AWS accounts | TEAM-8, D6 | `org_aws_accounts`, `teams.allowed_aws_accounts`, `may_manage_aws_accounts`, `afs.account_allowed`, `team_guardrail_guard` | ✓ |
| DB-4 Agents, one identity one pod | AGT-1, AGT-2, AGT-7 | `agents` (no replica column), digest-pinned image check | ✓ |
| DB-5 Agent identity and role links | AGT-3, AGT-5, AGT-6, AGT-10 | `agents.iam_identity`, `agent_identities`, `agent_role_links` | ✓ |
| DB-6 Agent storage | AGT-9 | `storage_classes`, agent volume columns, `agent_volume_snapshots` | ✓ |
| DB-7 Secrets as references | SEC-1, SEC-2, SEC-3, SEC-5, EXT-7 | `secrets` (ARN, managed path via `afs.secret_path`), `agent_secret_bindings`; `idempotency_keys` refuses a stored `secretKey` | ✓ |
| DB-8 Configuration values | CFG-7 | `namespace_config_values`, `agent_config_values`, `agent_config_resolved` | ✓ |
| DB-9 Budgets and spend | BUD-1, BUD-2, BUD-4, BUD-5, BUD-8 | `budgets`, `spend_counters`, `reserve_spend`, `settle_spend`, `budget_threshold_events`, `usage_events`. BUD-3 (IAM deny) has no database object | ✓ |
| DB-10 Costs, reconciliation, prices | BUD-6, BUD-7, BUD-9 | `cost_daily`, `cost_reconciliations`, `model_prices`, `model_price_proposals`, pricing settings | ✓ |
| DB-11 People and access | ACC-1, ACC-2, ACC-4, ACC-5 | `users`, `role_bindings` and `api_keys` (incl. service-level `security_operator`), `identity_providers`, `teams.identity_provider_id`, `teams.viewer_kubectl` | ✓ |
| DB-12 Desired state, revisions, audit, outbox | CFG-1, CFG-3, CFG-6, OPS-2 | `version`/`generation`, `touch_row`, `record_revision`, `config_revisions`, `audit_log`, `outbox_events` | ✓ |
| DB-13 Export and import | CFG-5 | `export_bundles` (nullable `s3_uri` and `sha256`, `download_url`, `download_expires_at`, `size_bytes` from 000014: see DB-36) | ✓ |
| DB-14 External systems | EXT-1 to EXT-7 | `external_systems`, `external_system_optouts`, `agent_external_access` | ✓ |
| DB-15 Reporting | RPT-1 to RPT-7, RPT-9 | `agent_activity`, `external_traffic` (with `pool_id`, `worker_pod`), daily and current views, `team_budget_position`, `*_by_tag` views; settings `reports.idle_cpu_millicores`, `egress.denied_spike_threshold` | ✓ |
| DB-16 Scheduled reports | RPT-8 | `report_schedules` (team's own channels only) | ✓ |
| DB-17 Cost allocation tags | TAG-1 to TAG-7 | `service_tags`, `team_tags`, `team_effective_tags`, `agent_effective_tags`, `tag_sets` snapshots on every fact row, `cost_allocation_tag_status` | ✓ |
| DB-18 Idempotency keys | IF-1, API contract §1 | `idempotency_keys` (no stored `secretKey`; reconciler reads `principal`, `key`, `expires_at` only), `purge_idempotency_keys`, setting `api.idempotency_key_ttl_seconds` | ✓ |
| DB-19 Agent sign-in events | OPS-4, D17 | None by design: sign-ins go to team log delivery only | ✓ (no table) |
| DB-20 Work orders | WO-1 to WO-6 | `work_orders`, `work_order_repos` (teams read; assigned team updates progress columns only, `work_order_repo_progress_guard`), `work_order_notifications`, `work_order_progress`, `swarm_templates`, settings `work_orders.sla_warning_hours` and `work_orders.notification_channel_id` | ✓ |
| DB-21 Swarm pools | AGT-8, BUD-8 | `swarm_stages`, `agent_pools`, `pool_handoffs`, pool secrets, bindings, configuration, opt-outs, `pool_role_links`, `pool_external_access`, `pool_config_resolved`, `pool_workers_current`; pools share the team's lifetime budget | ✓ |
| DB-22 Roles and RLS | G2, ACC-3 | `afs_app`, `afs_reconciler`, `afs_gateway`, `afs_billing`, `afs_readonly`; `app_team_scope` and `service_roles_all` policies; work order read and write policies | ✓ |
| DB-23 Migrations runner and CLI | CFG-2 (desired state from a known schema) | `migrate` (Load, Up, Down, Version, advisory lock, checksum guard), `afs-migrate`. CFG-4 (PITR) is RDS configuration, traced to DB-US-9 and §10 | ✓ |
| DB-24 Log and notification configuration | OPS-1, OPS-3 | `log_destinations`, `notification_channels` (configuration only; delivery and EventBridge rules are not in the database) | ✓ |
| DB-25 Ceiling and quotas guarded | BUD-1, G3, D35 | `team_guardrail_guard` extended to `max_budget_usd`, `quotas` and the ceiling override; `teams_ceiling_covers_budget` (a ceiling never below the budget) | ✓ |
| DB-26 Service catalog and settings writes | BUD-9, AGT-9, D35 | `app_read` / `app_write` policies on `service_settings`, `models`, `model_prices`, `storage_classes`; restrictive `app_admin_*` policies on `team_models` | ✓ |
| DB-27 Bindings and users writes | ACC-2, ACC-3, D35 | RLS on `role_bindings` (reads open; service-level roles by service admins, team roles on the caller's teams) and `users` (reads open; own row or service admin) | ✓ |
| DB-28 Temporary ceiling raise | BUD-1, D5, D34 | `teams.ceiling_override_usd`, `teams.ceiling_override_expires_at`, `teams_ceiling_override_check`, `afs.team_ceiling`, `check_budget_ceiling`, reconciler column grants | ✓ |
| DB-29 Budget exhaustion mode | G3, BUD-10, D33 | `budget_exhaust_guard` (`budgets_exhaust_guard` trigger) | ✓ |
| DB-30 Spend periods and held reservations | BUD-2, BUD-4, D31 | `afs.ensure_spend_counter`, `spend_reservations`, `afs.reserve_spend_held`, `afs.settle_reservation`, `afs.release_expired_reservations`, setting `gateway.reservation_ttl_seconds` | ✓ |
| DB-31 Change feed | CFG-2, D30 | `afs.notify_desired_state`, `<table>_notify` triggers on every table with a revision trigger, channel `afs_desired_state` | ✓ |
| DB-32 Retention | RPT-1, D36 | `afs.drop_partitions_older_than`; partition functions `SECURITY DEFINER` for the reconciler | ✓ |
| DB-33 Runtime settings | IF-1, RPT-5, RPT-6, BUD-2, D45 | `service_settings_runtime_check`; seeded `reports.idle_cpu_millicores` (50), `egress.denied_spike_threshold` (20), `gateway.reservation_ttl_seconds` (900), `api.cors_origins` (`[]`) | ✓ |
| DB-34 Model output limit | BUD-2, D28 | `models.max_output_tokens` (worst case when a request has no max tokens) | ✓ |
| DB-35 Agent template catalog | AGT-2, AGT-11, D54 | `agent_templates` (allowed and current image digests, `enabled`; service-admin writes, `agent_templates_notify`), `agents.template_id` and `agent_pools.template_id`, `afs.image_digests_ok`, `afs.template_use_guard` (`agents_template_guard`, `agent_pools_template_guard`); the free-text `template` columns stay | ✓ |
| DB-36 Export and import transport | CFG-5, D49 | `export_bundles`: nullable `s3_uri` and `sha256`, `download_url`, `download_expires_at`, `size_bytes`, `export_bundles_succeeded_check`, `export_bundles_export_succeeded_check`, reconciler column grants | ✓ |
| DB-37 Repository owner resolution | WO-1, D38 | `afs.resolve_repo_owners(host, repo)` (000014, `SECURITY DEFINER`, executable by `afs_app` and `afs_reconciler` only), reading namespace config value `AFS_OWNED_REPOS` | ✓ |
| DB-38 Gaps closed by proof | SEC-1, BUD-6, TEAM-7, ACC-4 | 000015: `notification_channels_service_no_secret`, `teams_due_for_teardown` lists only teams due, `cost_reconciliation_status` (derived `status`) and `cost_reconciliations_amounts_check`, `api_key_created_at_guard`, `agents_image_digest_check` and `agent_pools_image_digest_check`; `migrate` sets `lock_timeout` per migration (`DefaultLockTimeout`, `WithLockTimeout`, `afs-migrate --lock-timeout`) | ✓ |
| DB-39 Service access paths | ACC-2, ACC-3, ACC-4, AGT-7, AGT-8, WO-1, WO-2, CFG-3 | 000016: `afs.authenticate_api_key(key_sha256)` (`afs_app`), `afs.resolve_workload(namespace, service_account)` (`afs_app`, `afs_gateway`), `afs.team_directory()` (`afs_app`; service admins and security operators), `afs.instantiate_work_order_team(work_order_id)` (`afs_reconciler`), all `SECURITY DEFINER`; `afs.new_id(prefix)` (owner only); settings `work_orders.cost_center` and `work_orders.owner_email` (`service_settings_work_order_team_check`); `UPDATE (state, deleted_at)` on `agent_pools` for `afs_reconciler`; INSERT policies `app_own_audit` (audit_log) and `app_operator_work_order_events` (outbox_events) for `afs_app` | ✓ |
| DB-40 Schema version and CLI client id | OPS-2, ACC-1, D48 | 000017: `identity_providers.cli_client_id` (public CLI client, optional; `TestIdentityProviderCLIClientID`); `afs.schema_version()` (SECURITY DEFINER) for `afs_app`, `afs_reconciler`, `afs_gateway`, `afs_billing`, `afs_readonly`; proven by `TestSchemaVersionFunction` (every role reads the version; the tracking table stays `42501`) | ✓ |
| DB-41 Collaboration agent role | COL-1, COL-2, COL-3, COL-5 | 000020: `agents.role`, `agents_team_collaboration_uq`, `agents_collaboration_guard`, `agent_templates.capabilities`, `afs.capabilities_ok`, `agent_templates_capability_guard` | Implemented in 000020 (C1) |
| DB-42 Collaboration settings | COL-16, COL-20, COL-23 | 000020: `team_collaboration` (stored web UI and REST API choices, registration mode), `teams.may_expose_collaboration` and its guard, the seven `collab.*` settings and `service_settings_collab_check` | Implemented in 000020 (C1) |
| DB-43 Agent links | COL-10, COL-12, COL-14 | 000020: `agent_collaboration` (connect flag, Paperclip agent id, link state written by the reconciler only), `afs.agent_collaboration_guard`, generation bump trigger | Implemented in 000020 (C1) |
| DB-44 Managed secrets | COL-7, COL-12, SEC-7 | 000020: `secrets.managed_by`, `afs.secrets_managed_guard`, reserved `paperclip` names, Paperclip-created rows written by `afs_reconciler` only, binding refusal | Implemented in 000020 (C1) |
| DB-45 Team collaborator role | ACC-2, PC-D6 | 000020: `team_collaborator` accepted by `role_bindings_role_check` and `api_keys_role_check`, team scope only | Implemented in 000020 (C1) |
| DB-46 Collaboration lifecycle | COL-8, TEAM-9 | 000020: `afs.agents_collaboration_cleanup` (collaboration agent deleting or deleted removes the route row and disconnects every agent) | Implemented in 000020 (C1) |
| DB-47 Edge role and read functions | COL-16 to COL-19, COL-23 | 000020: role `afs_edge` (no table privilege), `afs.collab_routes()`, `afs.collab_settings()`, `afs.collab_principal()`, `afs.collab_principal_key()`, `identity_providers.collab_client_id` and `collab_client_secret_arn` | Implemented in 000020 (C1, used from C2) |
| DB-48 Collaboration access facts and events | COL-24, COL-30, COL-31, COL-36 | 000020: `collaboration_access` (monthly partitions, 13-month retention), `afs.record_collab_access`, `afs.ensure_collaboration_access_partition`, `afs.emit_collab_secret_detected`, `drop_partitions_older_than` extended | Implemented in 000020 (C1, used from C2) |
| DB-49 Hostname hold | TEAM-9, PC-D9 | 000020: `collab_hostname_holds`, hold and refusal triggers on `teams` | Implemented in 000020 (C1) |
| DB-50 Edge sessions and handoff | COL-17, PC-D22 | 000020: `collab_edge_sessions`, `collab_edge_handoffs` (no grants), `afs.collab_handoff_create`, `collab_handoff_consume`, `collab_session_get`, `collab_session_revoke`, `afs.purge_collab_edge_sessions` | Implemented in 000020 (C1, used from C2) |
| DB-51 Reconciler key functions | COL-12, COL-32, PC-D25, PC-D26 | 000020: `afs.record_collab_agent_key`, `afs.remove_collab_agent_key`, `afs.record_collab_board_key` | Implemented in 000020 (C1, used from C3) |
| DB-52 Swarm collaboration | COL-9, PC-D29 | 000020: `afs.instantiate_work_order_team` and `afs.record_work_order_secret` extended | Implemented in 000020 (C1, used from C4) |

## 5. User stories and acceptance criteria

Stories DB-US-1 to DB-US-43 are implemented by migrations 000001 to 000017 (000018 and 000019 are not yet traced, DB-OQ-8); DB-US-44 to DB-US-57 are planned for 000020 (see their subsection). Each story ends with **Proven by:**, naming the
integration test (`migrate/migrate_test.go`, `migrate/hardening_test.go` for 000013,
`migrate/templates_exports_test.go` for 000014, `migrate/feature_complete_test.go` for the proofs and
fixes of 000015, `migrate/service_access_test.go` for 000016, `migrate/runner_test.go` for the runner) that proves each criterion, written
`TestName/subtest`. Where a criterion cannot be proven in this repository it names the milestone and
owner. No criterion is **pending**. All named tests pass against `postgres:17`.

SQLSTATEs map to API errors through database contract §6: `42501` → `AccessDenied`, `23514` →
`ValidationError`, `23503` → `ValidationError` on insert or update and `Conflict` on delete, `23505` and
`55000` → `Conflict`.

**DB-US-1 · Isolation that survives an API bug.** *(refines US-3)* As security, I want the database to
refuse cross-team reads and writes for `afs_app` regardless of the query, so that a missing `WHERE`
cannot leak data.
- Given a transaction as `afs_app` with `afs.team_ids = team A`, when it selects from any team-owned
  table or view without a filter, then it sees only team A's rows.
- When it updates or deletes team B's rows by id, then zero rows change; when it inserts a row for
  team B, then `42501`.
- Given a transaction that sets no session settings, then it sees no team rows (fail closed).
- Every table with a `team_id` column has row-level security, and every table with row-level security
  has a policy for `afs_app`; a new table without them fails CI.
- Named exceptions, readable by every `afs_app` caller: `role_bindings` (read before team scope
  exists), `users` (names on member and audit pages), and the service catalog (`models`, `model_prices`,
  `storage_classes`, `service_settings`, `agent_templates`, `identity_providers`, service-level `external_systems`). Their
  writes are restricted (DB-US-17).

Proven by: `TestRowLevelSecurityIsolatesTeams` (team A sees 1 of 2 teams and secrets; no settings sees
0; cross-team insert `42501`); `TestEveryTeamTableHasRowLevelSecurity` (RLS on every `team_id` table and
an `afs_app` policy on every RLS table); per-feature isolation subtests (`TestConfigurationValues/other
team cannot see config`, `TestCrossAccountRoleLinks/other team cannot see links`,
`TestAgentActivityReporting/another team cannot see activity or write it`,
`TestExternalTrafficReporting/another team cannot see traffic`). Cross-team UPDATE and DELETE:
`TestCrossTeamWritesChangeNothing` (one subtest per RLS table with a team column, found from the
catalog: a team-A caller's update and delete of every other team's and every service-level row change
zero rows, and on team-scoped tables it sees none; a new team table without fixture rows fails;
`idempotency_keys` is scoped by principal and proven in DB-US-12).

**DB-US-2 · Guardrails only service admins change.** *(refines US-1, US-7)* As a service admin, I want
budget ceilings, quotas, the temporary ceiling override, `may_*` rights and (when the team does not
manage it) the allowed-accounts filter protected in the database.
- Given an `afs_app` caller who is not a service admin, when it changes `max_budget_usd`, `quotas`,
  `ceiling_override_usd`, `ceiling_override_expires_at`, `may_add_external_systems` or
  `may_manage_aws_accounts`, then `42501`.
- Given `may_manage_aws_accounts` is off, when a team caller changes `allowed_aws_accounts`, then
  `42501`; when it is on, the change succeeds.
- When a budget above the ceiling in force is written by anyone, then `23514`.
- When anyone sets a ceiling (base or override in force) below the team's current budget, then `23514`
  (`teams_ceiling_covers_budget`): lower the budget first.

Proven by: `TestHardeningSpendPeriodsAndChangeFeed/only service admins set the ceiling, quotas and
override`; `TestIdentityProvidersAndTeamGuardrails/team admins set the account filter only when
allowed`; `TestExternalSystems/teams declare their own systems only when allowed`;
`TestConstraints/budget above ceiling rejected`.

**DB-US-3 · Spend reservation that cannot reserve past the limit.** *(refines US-9)* As the gateway, I
want an atomic reserve and settle, so that concurrent calls cannot reserve past the limit.
- `reserve_spend` returns true only when `spent + reserved + amount ≤ limit`, checked and applied in one
  `UPDATE` of the counter row, so concurrent reservations serialize on that row.
- `settle_spend` releases the reservation and adds the actual cost in one statement. The actual cost may
  exceed the estimate (actual-versus-estimate rounding, such as the input-token estimate), so `spent`
  may pass the limit by that overage; this is the bound of root G3 (one in-flight request per agent or
  pool worker) and the database does not refuse it.
- Sequentially, on a limit of 100: a reservation of 60 fits, a further 50 is refused, settling the 60
  to 12.5 lets the 50 fit.
- Concurrently, given a limit of 100 with 99.50 spent, 50 parallel `reserve_spend(…, 0.10)` calls give at
  most 5 successes.
- `reserve_spend` p99 under 5 ms at 500 calls per second on the reference instance `db.r7g.large`.

Proven by: `TestSpendReservation` (sequential case); `TestConcurrentReservationsNeverOverbook` (50
connections as `afs_gateway`: exactly 5 granted, spent plus reserved equals the limit). p99: gateway
load test in `-restapi`, milestone M3.

**DB-US-4 · Secrets cannot leak through the schema.** *(refines US-6)* As security, I want no column
able to hold a secret value.
- A test fails if any column outside the documented, non-secret configuration and tag tables matches
  `value|password|plaintext|secret_string`. `service_settings.value` is exempt because settings are
  service configuration (prefixes, thresholds, ids, origins), written only by service admins (DB-US-17)
  and, for the keys listed in `docs/data-model.md`, typed by CHECK constraints; no key holds a
  credential. A credential-like key check for settings is open (§9).
- A secret row whose ARN does not match `afs.secret_path(team, agent, name)` (or the 4-argument pool form
  `afs.secret_path(team, agent, pool, name)`) is refused (`23514`).
- Configuration names and tag keys that look like credentials are refused (`23514`).
- A stored idempotent response that contains `secretKey` anywhere in its body is refused (`23514`); the API
  stores `CreateApiKey` and `CreateServiceApiKey` responses with `secretKey` removed (D52), so a replay
  returns the key's metadata without it, and the CHECK refuses any body that still contains it; the
  reconciler can read only `principal`, `key` and `expires_at`.

Proven by: `TestConstraints/no secret value column exists`; `TestSecretPathsAreManaged/ARN outside the
managed path rejected`; `TestSwarmsEphemeralTeamsAndWorkOrders/pool secrets have their own path and bind
only to their pool`; `TestConfigurationValues/credential-like and malformed names rejected`;
`TestCostAllocationTags/service admins define fixed and required keys`;
`TestReportSchedulesIsolationTierAndIdempotencyKeys/idempotency keys belong to their caller and expire`
(the `secretKey` case); `TestReconcilerCannotReadIdempotentResponses` (reconciler `SELECT
response_body` and request columns `42501`; `principal`, `key`, `expires_at` readable).

**DB-US-5 · Required tags at team creation.** *(refines US-12)* As a service admin, I want a team to be
impossible to create without required tags.
- Given a required key without a default, when a transaction inserts a team without a value, then the
  commit fails with `23514` naming the key; with the value in the same transaction, it commits.
- When a team removes a required value later, then the commit fails.
- `team_effective_tags` always includes `afs-team-id`; `agent_effective_tags` always includes
  `afs-agent-id`; neither can be set or overridden through `team_tags`.

Proven by: `TestCostAllocationTags/new teams must give required tags without a default`,
`TestCostAllocationTags/system tags team and agent id are always there`; `TestPendingGuards/a missing
required tag is named in the error`.

**DB-US-6 · Price decisions with a trail.** *(refines US-10)* As a service admin, I want only service
admins to approve prices, and approvals never to backdate a price.
- `afs_billing` can propose and supersede, never approve (`42501`); a team caller cannot approve
  (`42501`); a decided proposal cannot be decided again (`55000`).
- An approved proposal with a past `effective_from` writes a `model_prices` row effective at approval.
- A team caller cannot insert a `model_prices` row directly (`42501`), so prices change only through a
  decision or a service admin.

Proven by: `TestModelPriceProposals/only service admins decide`, `TestModelPriceProposals/a late
approval takes effect from now, not the past`; `TestHardeningSpendPeriodsAndChangeFeed/the service
catalog, settings and enabled models are service admin writes`.

**DB-US-7 · Safe, repeatable migrations.** *(refines US-13)* As an operator, I want migrations to apply
once, in order, under a lock, and to refuse tampering.
- Two `Up` runs at once: one applies every migration, the other waits on the advisory lock, then finds
  nothing to do.
- A changed checksum of an applied migration stops the run with a clear error.
- `up`, `down` to zero and `up` again succeed in CI on `postgres:17` (local and test use only).
- Each migration from 000003 on states its lock impact in its header; 000001 and 000002 create the
  schema from nothing and are exempt. None rewrites a large table in one step.

- Each migration transaction sets `lock_timeout` (default 10 s, `WithLockTimeout`, `afs-migrate
  --lock-timeout`), so a DDL blocked by live traffic fails with `55P03` instead of queueing it; a
  negative timeout is refused before any SQL runs, and one below 1 ms is rounded up, never to "none".

Proven by: `TestConcurrentUpAppliesOnce`; `TestChecksumMismatchIsRefused`; `TestUpDownUp`;
`TestLoadRejectsGaps` and `TestLoadErrors` (order, names, missing up script); `TestUpAndDownErrors`;
`TestMigrationsStateLockImpact` (lock impact in every header from 000003);
`TestLockTimeoutStopsBlockedMigration`, `TestLockTimeoutIsSetPerMigration`, `TestLockTimeoutBounds`;
`TestRunCommands` (`afs-migrate` commands against a fresh database).

**DB-US-8 · Reports from views.** *(refines US-11, US-12)* As an `-restapi` developer, I want daily and
current views that answer the report API without application-side aggregation.
- `agent_activity_daily.utilization_pct` = working ÷ (working + idle); `agent_activity_current.idle_since`
  = end of the last working window.
- `cost_daily_by_tag` groups by tag key and value with `NULL` for untagged; system keys are excluded.
- Every view is `security_invoker`, so a team caller sees only its own teams through it.

Proven by: `TestAgentActivityReporting/daily rollup gives time in state and utilization`,
`TestAgentActivityReporting/current state shows how long an idle agent has been idle`,
`TestCostAllocationTags/cost, activity and traffic roll up by tag`, `TestEveryViewIsSecurityInvoker`.

**DB-US-9 · Recover from a backup.** *(refines US-13; CFG-4)* As an operator, I want to restore the
database to a point in time and have the services converge from it.
- `user-docs/` describes PITR restore and cross-account snapshot copy; a restored database passes
  `afs-migrate version` and the reconciler converges without manual SQL.

Proven by: restore drill, milestone M4 (with `-restapi`, which owns the RDS Terraform).

**DB-US-10 · Spend attributed to the tags of its time.** *(refines US-12, TAG-6)* As finance, I want
rollups by tag to use the tags a team had when the spend happened.
- Every `usage_events`, `agent_activity`, `external_traffic` and `cost_daily` row carries a `tag_set_id`
  for its own team (another team's set → `23503`).
- A tag set is immutable (update → `55000`) and its id is derived from its content, so the same tags give
  the same id; system tags are not stored in it.
- Given spend before and after a tag change, `cost_daily_by_tag` shows each under the value in effect at
  the time; a currently required key missing from an old set reads as `NULL`.

Proven by: `TestCostAllocationTags/tag sets are per team and immutable`, `TestCostAllocationTags/spend
keeps the tags in effect when it happened`.

**DB-US-11 · Scheduled reports go only to the team.** *(refines US-11, RPT-8)* As a team-admin, I want
report schedules that can only target my team's channels.
- A schedule whose channel belongs to another team or to the service is refused (`23503`).
- `afs_billing` can update only the run columns (`42501` otherwise); another team's schedules are
  invisible to `afs_app`, and scheduling for another team is `42501`.

Proven by: `TestReportSchedulesIsolationTierAndIdempotencyKeys/scheduled reports go only to the team's
own channels`.

**DB-US-12 · Retries are safe for one hour.** *(refines IF-1)* As a client, I want a retried create with the
same key to be recognised.
- `(principal, key)` is unique (`23505`); a caller sees only its own keys, and writing a key as someone
  else is `42501` (RLS on `afs.current_actor()`).
- `afs.purge_idempotency_keys()` removes keys past `expires_at`; the TTL setting accepts 60 to 604800
  (default 3600).

Proven by: `TestReportSchedulesIsolationTierAndIdempotencyKeys/idempotency keys belong to their caller
and expire`.

**DB-US-13 · Ephemeral teams cannot outlive their cap.** *(refines US-15, TEAM-7, BUD-8)* As a service
admin, I want an ephemeral team to always have an expiry, a teardown rule and a blocking lifetime budget.
- Without any of them, or with expiry beyond `teams.ephemeral_max_days`, the commit fails (`23514`);
  removing the lifetime budget fails (`23514`); changing `kind` fails (`23514`, `ValidationError` as
  root US-15 requires).
- `teams_due_for_teardown` lists a team when its rule fires (expired, cap reached, work order complete),
  and only then.

Proven by: `TestSwarmsEphemeralTeamsAndWorkOrders/an ephemeral team needs a blocking lifetime budget and
a bounded expiry`, `TestSwarmsEphemeralTeamsAndWorkOrders/teams due for teardown` (`work_complete`);
`TestPendingGuards/teams due for teardown: expired, cap reached, and nothing else` (a team whose rule has
not fired is not listed, 000015).

**DB-US-14 · Pools only where they belong.** *(refines US-17, AGT-8)* As a team-admin, I want pools that
behave like agents without breaking the one-agent-one-pod rule.
- A pool in a persistent team is refused (`23514`); a pool and an agent with the same name in one team
  conflict (`23505`); a pool cannot be renamed (`55000`).
- Pool secrets use the managed path `<prefix>/<namespace>/<pool>/<name>`; a pool role link outside the
  team's allowed accounts is refused (`23514`).
- Handoffs only join pools of the same team (`23503`, composite foreign keys) and never a pool to itself
  (`23514`); workers 0 to 200;
  usage, activity and traffic rows may carry `pool_id` and `worker_pod`, and their daily views group by
  pool.

Proven by: `TestSwarmsEphemeralTeamsAndWorkOrders/pools live only in swarms and share the agent name
space`, `…/pool secrets have their own path and bind only to their pool`, `…/a pool uses one shared role
name in allowed accounts`, `…/usage and activity are attributed to the pool and the worker pod`;
`TestPendingGuards/handoffs only join pools of the same team`, `TestPendingGuards/daily activity and
traffic group by pool`.

**DB-US-15 · Work orders visible to the right people.** *(refines US-16, WO-1 to WO-6)* As a security
operator, I want to manage all work orders, and owning teams to see theirs read-only.
- With `afs.security_operator = on` (or as a service admin), `afs_app` reads and writes every work order
  and repository row; without it, a team sees a work order only when it is assigned or owns one of its
  repositories.
- A team caller cannot create, change or delete a work order: an insert for another team is `42501`, and
  an owning or assigned team's `UPDATE` or `DELETE` of `work_orders` changes zero rows.
- The assigned team may update only the progress columns of its work order's repositories (`status`,
  `pr_url`, `pr_number`, `detail`, `merged_at`); changing a repository's work order, host,
  repo or owner is `42501`, and adding a repository is `42501`. An owning team cannot change progress
  (zero rows).
- One open work order per CVE (`23505`); an EventBridge event id is accepted once (`23505`); each
  repository needs an owner, team or email (`23514`); `pr_opened` and `merged` need a PR link (`23514`).
- A notification of a kind is recorded once per recipient and repository (`23505`).
- `work_order_progress.sla_state` is `due_soon` within `work_orders.sla_warning_hours` of the due time.
- `work_orders.notification_channel_id` accepts only null or a service-level email channel.

Proven by: `TestSwarmsEphemeralTeamsAndWorkOrders/work orders are visible to security, the assigned team
and owning teams only`, `…/teams only read work orders and report progress on their own`, `…/work orders
track repositories and notify owners once`; `TestWorkOrderOutsideContactChannel`;
`TestPendingGuards/a merged repository needs a PR link`, `TestPendingGuards/the SLA warning window
follows its setting`.

**DB-US-16 · Who may grant cluster and node access.** *(refines US-18; ACC-5, TEAM-6)* As a service
admin, I want viewer kubectl and the isolation tier to be mine to set.
- An `afs_app` caller who is not a service admin changing `viewer_kubectl` or `isolation_tier` gets
  `42501`.

Proven by: `TestReportSchedulesIsolationTierAndIdempotencyKeys/only service admins set the isolation
tier`; `TestSwarmsEphemeralTeamsAndWorkOrders/an ephemeral team needs a blocking lifetime budget and a
bounded expiry` (the `viewer_kubectl` case).

**DB-US-17 · Service catalog, settings and bindings change only by the right people.** *(refines US-1,
US-2, US-10; D35)* As a service admin, I want the catalog, settings, enabled models, role bindings and
user rows to be writable only by those allowed to change them.
- Given an `afs_app` caller who is not a service admin, when it inserts into `model_prices`, `models`,
  `storage_classes` or `team_models`, then `42501`; when it updates a `service_settings` row, zero rows
  change. It still reads every model (and every setting, price and storage class).
- A service admin can enable a model for a team (`team_models` insert).
- `role_bindings`: a team-admin inserting a `service_admin` binding (`team_id` null) gets `42501`; a
  binding on a team it is not bound to gets `42501`; a binding on its own team succeeds; a service admin
  can grant `security_operator`. Every `afs_app` caller reads every binding.
- `users`: a caller updating another person's row changes zero rows; updating its own row (matched on
  `afs.actor`) changes it. Every `afs_app` caller reads every user.

Proven by: `TestHardeningSpendPeriodsAndChangeFeed/the service catalog, settings and enabled models are
service admin writes`, `…/bindings: service roles by service admins, team roles in your own team`, `…/a
person changes only their own user row`.

**DB-US-18 · Spend periods and stuck reservations.** *(refines US-9; BUD-2, BUD-4; D31)* As the gateway
and reconciler, I want a new period to open on demand and a dead gateway's reservations to be returned.
- `afs.ensure_spend_counter(budget, period_start)` (`afs_gateway`, `afs_reconciler`) opens the period with
  the budget's amount as its limit and returns the limit; a second call is a no-op returning the same
  limit; an unknown budget is `23503`.
- `afs.reserve_spend_held(budget, period_start, amount, holder)` (`afs_gateway`) returns a reservation id
  when it fits and `NULL` when it does not; the hold expires after setting
  `gateway.reservation_ttl_seconds` (default 900, accepts 60 to 3600).
- `afs.release_expired_reservations()` (`afs_reconciler`) releases every hold past `expires_at`, returns
  how many, and leaves `reserved` back at its value before the hold, with `spent` unchanged.
- `afs.settle_reservation(id, budget, period_start, actual)` (`afs_gateway`) on a live hold releases it,
  adds the actual cost and returns `true`; on a hold already released it returns `false` and still adds
  the actual cost, so a call that outlives the TTL still counts; a budget or period that does not match
  the hold is `22023`.

Proven by: `TestHardeningSpendPeriodsAndChangeFeed/spend periods open on demand and stuck reservations
are released`, `…/runtime settings are checked` (TTL bounds).

**DB-US-19 · Change feed.** *(refines US-13; CFG-2; D30)* As the reconciler, I want to hear about a
desired-state change as soon as it commits.
- Given a session listening on `afs_desired_state`, when a row of any table with a revision trigger is
  inserted, updated or deleted, then after commit it receives `<table>:<team_id>:<id>` (for `teams`, the
  team's own id in both places). The payload carries ids only, never values.
- `users` and `service_settings` carry no revision trigger and send nothing. The 30-second poll on
  `generation <> observed_generation` and the 10-minute resync belong to the reconciler.

Proven by: `TestHardeningSpendPeriodsAndChangeFeed/desired-state changes are announced` (`teams`);
`TestEveryRevisionTableAnnouncesChanges` (one subtest per table with a revision trigger, found from the
catalog: a row-level notify trigger for insert, update and delete, and an update of one row sends exactly
`<table>:<team_id>:<id>`).

**DB-US-20 · Retention.** *(refines US-11; D36)* As an operator, I want old fact partitions removed on a
schedule without owner rights.
- `afs.drop_partitions_older_than(13)` as `afs_reconciler` drops the monthly partitions of
  `usage_events`, `agent_activity` and `external_traffic` whose month starts before the first day of the
  month 13 months ago, and returns their names; the current month, the 13 whole months before it and the
  default partitions are kept.
- Keeping fewer than one month is `22023`.
- `afs_reconciler` can create partitions (`ensure_usage_partition`, `ensure_activity_partition`,
  `ensure_traffic_partition`, now `SECURITY DEFINER`).
- `audit_log` is never deleted (append-only trigger); see OQ-4.

Proven by: `TestHardeningSpendPeriodsAndChangeFeed/old monthly partitions are dropped by the reconciler`
(`usage_events`); `TestRetentionDropsEveryFactTable` (all three tables: the month 14 months back is
dropped; 13 months back, the current month and the default partitions stay).

**DB-US-21 · Temporary ceiling raise and notify-only budgets.** *(refines US-1, US-9, US-24; BUD-1, BUD-10,
G3; D5, D33, D34)* As a service admin, I want to raise a ceiling for a limited time and, for a persistent team
only, choose notify-only.
- `ceiling_override_usd` and `ceiling_override_expires_at` are set together and the override is above
  `max_budget_usd`; otherwise `23514`. Only service admins set them (DB-US-2).
- While the override is unexpired it is the ceiling in force (`afs.team_ceiling`): a budget up to it is
  accepted. Clearing the override while the budget exceeds the base ceiling is `23514`.
- At expiry the reconciler lowers the budget to the base ceiling, then clears the override; it holds the
  column grants for both.
- A team-admin setting `on_exhaust = 'notify'` gets `42501`; a service admin can for a persistent team; a
  budget of an ephemeral team that notifies is `23514`.

Proven by: `TestHardeningSpendPeriodsAndChangeFeed/a temporary override raises the ceiling until it
expires`, `…/notify-only budgets are a service admin choice for persistent teams`.

**DB-US-22 · One agent, one pod, a pinned image.** *(refines US-4; DB-4)* As a team-admin, I want an
agent that cannot be scaled sideways or run an unpinned image.
- `agents` has no replica column.
- An image that does not end in `@sha256:` and 64 lowercase hex characters is refused (`23514`; the
  full digest from 000015), for agents and pools.

Proven by: `TestAgentsHaveNoReplicaCount`; `TestPendingGuards/an image is pinned to a full digest`
(insert and update, agents and pools; tag, missing, short, uppercase and suffixed digests refused).

**DB-US-23 · Agent identities and cross-account links.** *(refines US-7; DB-5)* As a team-admin, I want
an agent's role links limited to the accounts my team may use.
- An agent on the team-shared role cannot link (`23514`); an account outside the filter, suspended or
  unknown is refused (`23514`); the role ARN must be in the linked account (`23514`).
- Role and external ID are immutable (`55000`); an agent with links cannot return to the team role
  (`55000`); another team cannot see the links.

Proven by: `TestCrossAccountRoleLinks` (all subtests).

**DB-US-24 · Agent storage.** *(refines US-4; DB-6)* As a team-admin, I want each agent's volume to be
safe to change.
- Agents get a default volume; a volume grows and never shrinks (`55000`); the storage class is immutable
  (`55000`); a disabled class is refused for new agents (`23514`).
- `afs_app` may request only manual snapshots and only for its own team (`42501`).

Proven by: `TestAgentPersistentStorage` (all subtests).

**DB-US-25 · Configuration values.** *(refines US-5; DB-8)* As an agent author, I want non-secret
configuration that resolves predictably.
- A namespace link needs a namespace value of that name in the same team (`23503`); a linked namespace
  value cannot be deleted or renamed (`23503`); a configuration name cannot shadow a secret environment
  variable or the reverse (`23505`); another team cannot see the values.

Proven by: `TestConfigurationValues` (all subtests).

**DB-US-26 · Billed cost against the estimate.** *(refines US-10, US-11; DB-10)* As finance, I want the
gateway's estimate compared with the bill.
- `cost_reconciliations.variance_pct` is generated, and `status` is derived on every write (000015):
  `over_threshold` when the estimate is more than setting `billing.variance_alert_pct` (default 5, 0 to
  100) percent above or below the bill, `missing_billing` when nothing was billed for a metered day, else
  `ok`. Both amounts are zero or more (`23514`).

Proven by: `TestModelPriceProposals/pricing settings are typed` (setting bounds); `TestPendingGuards/billed
cost beyond the variance setting is over threshold` (including negative amounts `23514`).

**DB-US-27 · People, keys and sign-in providers.** *(refines US-2; DB-11)* As a team-admin, I want
bindings, keys and providers that cannot be misused.
- A team-scoped `security_operator` binding is refused (`23514`); a service-level key may only have the
  `security_operator` role (`23514`); keys expire within 90 days of creation (`23514`), and the creation
  time is the database's own (`now()` on insert; changing it is `55000`, 000015).
- One default provider, unique HTTPS issuers, supported kinds only; the default cannot be disabled; a
  provider in use cannot be disabled (`55000`); team callers read every provider and cannot add one
  (`42501`); team bindings never name a provider (`23514`).

Proven by: `TestSwarmsEphemeralTeamsAndWorkOrders/security operators are a service-level role`;
`TestIdentityProvidersAndTeamGuardrails` (provider subtests); DB-US-17 for binding writes;
`TestPendingGuards/API keys expire within 90 days of their real creation`.

**DB-US-28 · History and audit.** *(refines US-13, US-14, US-20; DB-12)* As an auditor, I want every change
versioned and every audit row permanent.
- An update bumps `version`; every desired-state change writes a `config_revisions` row.
- `audit_log` rejects `UPDATE`, `DELETE` and `TRUNCATE`; audit rows can name a pool and worker pod.

Proven by: `TestConstraints/version bumps on update`, `TestConstraints/revisions recorded`,
`TestConstraints/audit log is append-only` (UPDATE and DELETE); `TestPendingGuards/audit rows are
permanent and can name a pool and worker pod` (`TRUNCATE` refused; pool rows hidden from other teams).

**DB-US-29 · Export bundle checksum.** *(refines US-13; DB-13)* As an operator, I want each export recorded
with a verifiable checksum.
- `export_bundles.sha256`, when present, is 64 lowercase hex characters.

Proven by: `TestExportBundles/size and checksum are checked`. The rest of the `export_bundles` rules
(nullable `s3_uri`, download link, size, reconciler grants, service-admin-only access) are DB-US-33.

**DB-US-30 · Outside services by catalog.** *(refines US-8; DB-14)* As a service admin, I want a catalog
that each level can only narrow.
- Built-ins are on except non-Bedrock model providers; team and agent opt-outs only narrow (duplicate
  `23505`); team-admins cannot change the service catalog; built-ins cannot be deleted (`55000`); a team
  declares its own system only when allowed (`42501`), never shadowing a catalog slug (`23505`) and with
  owner and purpose (`23514`); endpoints are validated (`23514`); another team's systems are invisible
  and cannot be referenced (`23503`).

Proven by: `TestExternalSystems` (all subtests), `TestEgressRulesBecomeTeamSystems`.

**DB-US-31 · Sign-ins stay out of the database.** *(refines US-14; DB-19, D17)* As security, I want
agent sign-in events only in the team's log delivery.
- No table or column records agent sign-ins to external systems.

Proven by: design review (nothing to test; a future table would need a PRD change).

**DB-US-32 · Agent template catalog.** *(refines US-4, US-21; AGT-2, AGT-11; D54)* As a service admin, I
want to curate the templates teams may use and the image digests each allows, so that a team cannot start
an agent or pool from a retired template or an unapproved image.
- Given a template, then its name is unique kebab-case, `allowed_image_digests` has at least one entry,
  each `sha256:` plus 64 lowercase hex, and `current_image_digest` is on that list; otherwise `23514`
  (`23505` for a duplicate name).
- Given a team-admin caller (`afs_app`, not a service admin), when it inserts a template, then `42501`;
  when it updates or deletes one, then zero rows change; every `afs_app` caller reads the catalog.
- Given an agent or pool with `template_id`, when it is inserted, or its `template_id` or `image` changes,
  to a disabled template or an image digest not on the template's allowed list, then `23514`; an unknown
  template is `23503`.
- Given templates are disabled or a digest is removed, then existing agents and pools are not changed and
  their unrelated updates still succeed (the reconciler flags them `TemplateRetired`); re-enabling reopens
  creation.
- A template used by an agent or pool cannot be deleted (`23503`, `Conflict`: disable it instead).
- Agents and pools without `template_id` (all rows before 000014) are not guarded; their free-text
  `template` column stays.
- A change to a template is announced on `afs_desired_state` as `agent_templates::<id>`.

Proven by: `TestAgentTemplates/columns are checked`, `TestAgentTemplates/only service admins write
templates; everyone signed in reads them`, `TestAgentTemplates/a new agent or pool needs an enabled
template and an allowed digest`, `TestAgentTemplates/a changed template or image is checked, an unrelated
update is not`, `TestAgentTemplates/disabling a template or removing a digest blocks new use and leaves
existing rows alone`, `TestAgentTemplates/agents and pools without a template are not guarded`,
`TestAgentTemplates/a template in use cannot be deleted`, `TestAgentTemplates/template changes are
announced without a team`.

**DB-US-33 · Export and import without an S3 object.** *(refines US-13; CFG-5; D49)* As the reconciler
and `afs-api`, I want export and import runs recorded without forcing an S3 location, so that an import
applied from the request body and an export still being built both fit.
- An import row has no `s3_uri`; a pending, running or failed export has neither `s3_uri` nor `sha256`
  until the reconciler has built the bundle.
- A `succeeded` row without `sha256`, and a `succeeded` export without `s3_uri`, are refused (`23514`).
- `size_bytes` is not negative (`23514`); `download_url` and `download_expires_at` hold the pre-signed
  link (not a secret value).
- The reconciler may update `status`, `summary`, `finished_at`, `s3_uri`, `sha256`, `download_url`,
  `download_expires_at` and `size_bytes` of an export, and nothing else (`42501`); it cannot insert or delete.
- Given a team caller (`afs_app` with `afs.team_ids` set, not a service admin), when it selects from or
  writes to `export_bundles`, then it sees no rows and a write is `42501`; only service admins (and the
  service roles) read and write bundles, because export and import are `admin:export` and `admin:import`.
  Given a service admin, then it records exports and imports as `afs_app`.

Proven by: `TestExportBundles` (all subtests), including `TestExportBundles/team callers cannot see or write
bundles` and `TestExportBundles/the API creates exports and imports as afs_app`.

**DB-US-34 · Log destinations and notification channels belong to the team.** *(refines US-19; DB-24)* As a
team-admin, I want my team's log destinations and notification channels to hold configuration and secret
references only, and to be invisible to other teams.
- Given a `log_destinations` row, then its credentials are a reference to a team secret (`secret_id`, a
  composite foreign key on `(team_id, id)`), never a value; `config` holds non-secret settings only. A
  reference to another team's secret is `23503`, and a secret in use by a destination cannot be deleted
  (`23503`, `Conflict`).
- Given a transaction as `afs_app` with `afs.team_ids = team A`, when it selects from `log_destinations` or
  `notification_channels`, then it sees only team A's rows (the standard `app_team_scope` policy); inserting a row for team B
  is `42501`; updating or deleting team B's rows changes zero rows.
- Given a channel used by a report schedule, then deleting it is `23503`.
- Given a service-level channel (`team_id` null), then it holds no secret reference (`23514`, 000015):
  the composite foreign key is not checked when `team_id` is null, and secrets are always team-owned.

Proven by: `TestEveryTeamTableHasRowLevelSecurity` (RLS and an `afs_app` policy on both tables);
`TestReportSchedulesIsolationTierAndIdempotencyKeys/scheduled reports go only to the team's own channels`
(channel references and delete restriction); `TestLogDestinationsAndNotificationChannels` (all subtests:
team callers see only their own, a row for another team or the service is refused, another team's rows
cannot be changed or removed, credentials are a reference to the team's own secret, a secret in use
cannot be deleted, a service-level channel holds no secret reference, a channel used by a report schedule
cannot be deleted).

**DB-US-35 · Swarm templates: service admins write, everyone reads.** *(refines US-22; WO-2)* As a service
admin, I want the swarm template catalog to be writable only by service admins and readable by every
signed-in caller, so that a team cannot define its own remediation shape.
- Given an `afs_app` caller that is not a service admin (a team caller), when it inserts a
  `swarm_templates` row, then `42501`; when it updates or deletes one, then zero rows change; every
  `afs_app` caller (including security operators) reads every template.
- Given a service admin, when it inserts a template with a name, kind, spec, budget and time to live, then
  it is stored; `enabled = false` keeps the row and its revisions (US-22: a work order naming a disabled
  template is refused by the API with `ValidationError`).

Proven by: `TestSwarmsEphemeralTeamsAndWorkOrders/work orders track repositories and notify owners once`
(service admin creates a template; a team's insert is `42501`); `TestSwarmTemplatesCatalog` (all
subtests: zero-row update and delete by a team, reads by a team caller, a security operator and a caller
with no team, disabling keeps the row and its revisions).

**DB-US-36 · A deleted team keeps its rows and history.** *(refines US-23; TEAM-9, D53)* As a service admin,
I want a deleted team to stay as a row with `state = 'deleted'` and its usage, cost, revisions and audit
to stay readable, so that nothing is lost when its resources go.
- Given the reconciler records a deletion, when it sets `state = 'deleted'` and `deleted_at` (and, for an
  ephemeral team, `torn_down_at` and `teardown_reason`), then the team row and every row that references
  it remain; nothing is deleted by cascade.
- Given a deleted team, then a service admin (or `afs_readonly`) can still read its `usage_events`,
  `cost_daily`, `config_revisions` and `audit_log` rows.
- `torn_down_at` on a persistent team, or without a `teardown_reason`, is `23514`.

Proven by: `TestSwarmsEphemeralTeamsAndWorkOrders/teams due for teardown` (reconciler records
`state = 'deleted'`; teardown time on a persistent team `23514`); `TestDeletedTeamKeepsItsHistory` (a
persistent and an ephemeral team marked deleted keep every referencing row; a service admin and
`afs_readonly` read their usage, cost, revisions and audit).


**DB-US-37 · Repository owners resolved from team configuration.** *(refines US-16; WO-1; D38)* As `afs-api`,
I want to ask the database which team owns a repository that a work order names without an owner, so that a
CVE reaches the right team without the caller knowing it.
- A team lists the repositories it owns in its namespace config value `AFS_OWNED_REPOS`, entries
  `host/owner/repo` or `host/owner/*` separated by commas or whitespace; matching ignores case.
- `afs.resolve_repo_owners(host, repo)` returns the ids of the teams at the best match. Given team A with
  `github.com/acme/*` and team B with `github.com/acme/payments-api`, then `acme/payments-api` resolves to
  team B only (an exact entry beats a wildcard).
- Given two teams that both list the same wildcard, then it returns both ids, so the API can refuse the
  ambiguity (`400`, `details.ambiguousRepos`); given no entry, then it returns no row (`details.unownedRepos`).
- The host must match: an entry for `ghe.example.com/pay/*` does not match `github.com/pay/ledger`.
- Given a team whose `state` is `deleting` or `deleted`, then its entries are ignored.
- Given `afs_gateway` (or any role other than `afs_app` and `afs_reconciler`), when it calls the function,
  then `42501`.

Proven by: `TestResolveRepoOwners` in `migrate/templates_exports_test.go`: `exact entry beats a wildcard`,
`matching ignores case`, `two wildcards are ambiguous`, `host must match`, `no owner`, `deleted teams own
nothing`, `only the API and reconciler may call it` (gateway `42501`).

**DB-US-38 · API keys found by hash before the team is known.** *(refines US-2; ACC-4; X-DB-1)* As `afs-api`,
I want to look up an API key by its SHA-256 before I know the caller's team, so that team keys and
service-level keys (no team) authenticate under row-level security.
- `afs.authenticate_api_key(key_sha256)` returns, for a matching key, `key_id`, `team_id` (NULL for a
  service-level key), `principal` (the key id, the audit `actor_id`), `role` and `roles`, `expires_at`,
  `revoked_at`, `state` (`active`, `expired` or `revoked`) and `team_state`; no row for an unknown hash.
  It never returns the hash or any secret.
- Given an active key of an active team (or a service key), then `last_used_at` is set, at most once a
  minute; an expired or revoked key's is not.
- Given a caller with no `afs.team_ids` and no service admin setting, then the lookup still works.
- Given any role other than `afs_app` (or PUBLIC), when it calls the function, then `42501`.

Proven by: `TestAuthenticateAPIKey` in `migrate/service_access_test.go`: `team key found without team
scope`, `last_used_at at most once a minute`, `service key has no team`, `expired and revoked keys are
reported, not used`, `suspended team is reported`, `unknown key`, `no hash or secret in the result`, `only
the API may call it` (catalog check of every role; gateway `42501`).

**DB-US-39 · Workloads resolved from namespace and ServiceAccount.** *(refines US-16; AGT-7, AGT-8; X-DB-2)* As
`afs-api` and `afs-gateway`, I want to map a workload token's namespace and ServiceAccount to its team and
agent or pool, so that a workload principal gets its scope before any team row is visible.
- `afs.resolve_workload(namespace, service_account)` returns `(team_id, agent_id, NULL)` for
  ServiceAccount `agent-<name>` and `(team_id, NULL, pool_id)` for `pool-<name>`, in the team whose
  namespace it is.
- Given another team's namespace, a name without the kind prefix, `default`, a pool name asked as an agent,
  or a namespace that is not a team's, then no row.
- Given a team that is not `active`, or an agent or pool that is `deleted`, then no row.
- Only `afs_app` and `afs_gateway` may call it.

Proven by: `TestResolveWorkload` in `migrate/service_access_test.go`: `agent`, `pool, for the gateway
too`, `no match`, `only active teams and live workloads`, `only the API and gateway may call it`.

**DB-US-40 · Team directory for service admins and security operators.** *(refines US-22; ACC-2, WO-1; X-DB-3)*
As a security operator, I want the id, slug and display name of every team, so that I can address a work
order without being able to read any team's rows.
- `afs.team_directory()` returns `id`, `slug`, `display_name` of every team whose `state` is not
  `deleted`, ordered by slug, when `afs.service_admin` or `afs.security_operator` is on.
- Given a team member or a caller with neither setting, then `42501`.
- Only `afs_app` may call it.

Proven by: `TestTeamDirectory` in `migrate/service_access_test.go`: `security operator sees every team
not deleted`, `service admin sees every team not deleted`, `team member is refused`, `no role is refused`,
`only the API may call it`.

**DB-US-41 · Remediation teams created from work orders.** *(refines US-22; WO-2; RC-12; X-DB-4)* As the
reconciler, I want one call that creates a work order's ephemeral remediation team from its swarm
template, so that I need no write access to desired state chosen by people.
- `afs.instantiate_work_order_team(work_order_id)` creates an ephemeral team (`slug` `wo-<ulid>`,
  teardown rule and expiry from the template's `teardown_rule` and `ttl_hours`, cost center and owner email
  from the template spec or service settings `work_orders.cost_center` / `work_orders.owner_email`,
  ceiling equal to the budget), its tags, a lifetime budget that blocks at the cap
  (`work_orders.budget_usd`, else the template's `budget_usd`), the pools' models, stages, pools (stage by
  name), handoffs and literal pool configuration values; sets the work order's `team_id`, `status =
  assigned` and `assigned_at`; writes an audit row (`InstantiateWorkOrderTeam`) and outbox events
  `team.created`, `pool.created` per pool and `work_order.assigned`; triggers write the revisions. It
  returns the team id.
- Given a work order that already has a team, then it returns that team and writes nothing; two
  concurrent calls create one team.
- Given an unknown work order `P0002`; one that is not open, has no template, or whose template is
  disabled, or no cost center or owner email anywhere, `55000`; a pool model that does not exist `23503`;
  a refused call leaves nothing behind.
- Settings `work_orders.cost_center` (a string of 1–100 characters) and `work_orders.owner_email` (a string
  `local@domain`) are checked: any other value is `23514`.
- Template secrets are not created: a secret row needs the ARN Secrets Manager assigns.
- Only `afs_reconciler` may call it (`afs_app` `42501`).

Proven by: `TestInstantiateWorkOrderTeam` in `migrate/service_access_test.go`: `creates the team from the
template`, `assigns the work order`, `writes audit, outbox and revisions`, `a second call returns the same
team`, `concurrent calls create one team`, `budget from the template, owner from service settings` (and the settings' rejected values `23514`),
`refused/*` (unknown, no template, cancelled, template disabled, model not in models), `only the
reconciler may call it`.

**DB-US-42 · The reconciler completes pool deletion.** *(refines US-22; AGT-8; RC-17; X-DB-5)* As the
reconciler, I want to mark a pool `deleted` once its resources are gone, as I do for agents and teams.
- `afs_reconciler` may update `agent_pools.state` and `deleted_at`, and no other pool column (`42501`).

Proven by: `TestReconcilerMarksPoolsDeleted`.

**DB-US-43 · Audit and outbox rows outside the caller's team scope.** *(refines US-14; ACC-3, CFG-3; X-DB-6)* As
`afs-api`, I want to record a denied request on a service route or on a team the caller does not see, and
a security operator's work order events on any team, so that every decision is audited.
- `afs_app` may insert an `audit_log` row whose `actor_id` is `afs.current_actor()`, whatever its
  `team_id`; a row naming another actor outside the caller's scope is `42501`. The caller still sees only
  its own teams' rows.
- With `afs.security_operator` on, `afs_app` may insert `outbox_events` with `aggregate_kind =
  'work_orders'` and an event type `work_order.*`, whatever the team; any other event outside the caller's
  scope is `42501`.

Proven by: `TestServiceAuditAndOutboxInserts` in `migrate/service_access_test.go`: `own denied request with
no team`, `own denied request on a team the caller does not see`, `another actor's row is refused`, `the
rows stay invisible to the caller`, `security operator work order events on any team`, `other events are
refused`; `TestCrossTeamWritesChangeNothing/audit_log` and `/outbox_events` (still no update, delete or
read across teams).

### Paperclip team collaboration (migration 000020, change PRD `paperclip-team-collaboration-PRD.md`)

Stories DB-US-44 to DB-US-57 implement database contract §7.2 for the
[Paperclip change PRD](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/paperclip-team-collaboration-PRD.md)
(COL-*, SEC-7). DB-US-44 to DB-US-47 are the ids that PRD §7.2 assigns; they are split here into smaller
stories (DB-US-48 to DB-US-54 take the parts that were bundled; DB-US-55 to DB-US-57 were added when contract v1.3.1 answered PC-D20 to PC-D31). All of 000020 ships in milestone C1 (it is
additive and `-restapi` adopts it once); C2 to C4 only consume more of it. Integration tests live in
`migrate/collaboration_000020_test.go` and are **not written yet**: each *Proven by* line names the test the
change adds, written `TestName/subtest`, and the red step of TDD is that test failing against schema 000019.
Where this PRD differs from the contract's wording because the existing schema forces it, the story says so and
the decision is logged as DB-D1 to DB-D19 in §9.1; the contract was corrected to match in v1.3.1 (PC-D20) and this PRD is aligned to it.
SQLSTATE to API error mapping is unchanged (contract §6).

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

### 5.x Orchestration agent and model access (migration 000022, release 1.1.0)

Specified in [specs/261123-orchestration-and-model-access/orchestration-and-model-access-PRD.md](specs/261123-orchestration-and-model-access/orchestration-and-model-access-PRD.md); the stories continue this document's numbering and refine root stories US-34 and US-37 to US-41.

**DB-US-58 · Orchestration role and the one-per-team rule.** Exactly one live orchestration agent per team from the commit that creates the team; role, reserved name and delete guard. Proven by `TestOrchestrationAgent`, `TestCreateOrchestrationAgent`, `TestWorkOrderTeamHasOrchestrationAgent`.

**DB-US-59 · Exposure levels, limit and tool.** `off`, `private`, `public` per surface within the team limit; Paperclip or Buzz; settings and aliases; snapshots on a tool change. Proven by `TestCollaborationExposure`, `TestToolChangeSnapshot`, `TestOrchestrationSettings`, `TestOrchestrationCapabilities`, `TestBuzzManagedSecrets`.

**DB-US-60 · Edge routes by exposure.** `orchestration_routes()` with effective level and reasons; access counts by exposure. Proven by `TestOrchestrationRoutes`, `TestRecordAccessExposure`.

**DB-US-61 · Model access levels.** All, one or several models at team, agent and pool level; price rule; `model_admission`. Proven by `TestModelAccess`, `TestTeamInferenceProfiles`.

## 6. Non-functional requirements

| Area | Requirement |
|---|---|
| Engine | PostgreSQL 17 features only; tested on `postgres:17` in CI |
| Online changes | Additive columns with constant defaults; constraints `NOT VALID` then `VALIDATE`; batched backfills in application code |
| Performance | Hot paths indexed (`spend_counters` by budget and period, `usage_events` by team and time, partitions by month); report views read monthly partitions only for the range asked. `reserve_spend` p99 < 5 ms at 500 calls/s on `db.r7g.large` (DB-US-3) |
| RLS overhead | Policy functions (`caller_sees_team`, `caller_is_service_admin`) are `STABLE` and read session settings only; a report view queried as a team caller is no more than 20% slower at p95 than the same query as `afs_readonly`, measured in the M3 load test (working budget, DB-OQ-3) |
| Capacity | Initial scale (root §7): 200 teams, 2,000 agents, 500 gateway requests/s. That is about 43 M `usage_events` rows a day, about 1.3 B a month and about 17 B over 13 months of retention. Partitions stay monthly; each `usage_events` partition carries the primary key and one `(team_id, occurred_at)` index only (index budget: two per partition). A partition past 500 GB is a signal to move to weekly partitions in a new migration |
| Retention | `usage_events`, `agent_activity`, `external_traffic`: the current month plus 13 whole months, older partitions dropped by `afs.drop_partitions_older_than(13)` run monthly by the reconciler (D36). `audit_log`: kept online with no deletion (root asks 400 days online, then archived); partitioning and archiving it is OQ-4, reviewed at 12 months or 50 GB. `idempotency_keys`: purged after their TTL. `spend_reservations`: released after `gateway.reservation_ttl_seconds` |
| Availability and recovery | RPO 5 minutes and RTO 1 hour (root §7) through RDS automated backups with point-in-time recovery, Multi-AZ, and cross-account snapshot copy; configured by `-restapi` Terraform, proven by the M4 restore drill (DB-US-9) |
| Encryption | At rest: RDS storage encrypted with a customer-managed KMS key. In transit: TLS required (`rds.force_ssl = 1`); clients verify the RDS CA |
| Authentication | Each service logs in as its own LOGIN user, a member of one NOLOGIN role from `bootstrap/roles.sql`, with IAM database authentication (`rds_iam`); no static passwords |
| Connections | Per-service connection limits (`ALTER ROLE … CONNECTION LIMIT` on the LOGIN users, set by operators): `afs-api` 100, `afs-gateway` 100, `afs-reconciler` 20, `afs-billing` 10, `afs-migrate` 2, `afs_readonly` users 10 (working values, confirmed by the M3 load test, DB-OQ-3); their sum stays below 80% of `max_connections` of the reference instance |
| Observability | `pg_stat_statements` on; `log_min_duration_statement` 500 ms (parameter group, `-restapi` Terraform); `afs-migrate version` reports the applied version; `migrate` sets `lock_timeout` in each migration transaction (default 10 s, `WithLockTimeout`, `afs-migrate --lock-timeout`) so a blocked DDL fails with `55P03` instead of queueing traffic behind it (`TestLockTimeoutStopsBlockedMigration`) |
| Security | No secret values; least-privilege grants per role, column grants where a role updates part of a row; audit append-only by trigger; RLS backs the API's checks |
| Quality | `migrate` ≥ 90% coverage (96.5% at 000016, `make cover` with `AFS_TEST_DATABASE_URL`); every constraint has a rejected-case test; every RLS policy has an isolation test (`TestCrossTeamWritesChangeNothing`) |
| Collaboration (000020) | The functions the edge calls on the request path are indexed lookups: `collab_principal` and `collab_principal_key` p99 < 5 ms at 200 teams and 50 000 role bindings; `collab_routes()` p99 < 20 ms for 200 teams (the edge calls it at most every 30 seconds per replica and on a change notification); `record_collab_access` applies a 1000-row batch in under 100 ms p99. `collaboration_access` is bounded by team, person or key, outcome and five-minute bucket: at most about 8.6 M rows a day at the extreme (200 teams, 50 people, 3 outcomes, 288 buckets) and far fewer in practice; monthly partitions, primary key plus one `(team_id, bucket_start)` index per partition, retention 13 whole months like the other fact tables. Working figures, confirmed in the M3 load test (DB-OQ-3). `afs_edge` holds no table privilege and every function returns only its named columns, so a compromise of the public component reads no table |

## 7. Delivery

| Milestone (root PRD §9) | This repository |
|---|---|
| M0 Foundations | Schema 000001–000017, feature complete; first release tag `v0.13.0` (nothing is tagged yet, so it is the first release to contain 000011–000017) for `-restapi` to adopt |
| M3 Spend control | Load test of `reserve_spend` and `reserve_spend_held` with `-restapi` (concurrent bound, p99, RLS overhead); partition and retention jobs verified |
| M4 Production readiness | Restore drill documented in `user-docs/` |
| C1 Collaboration agent (change PRD §10) | All of migration 000020 (DB-US-44 to DB-US-57; swarm collaboration is P1 and used in C4), as one minor release for `-restapi` to adopt (tag chosen at release; it follows the first tag that contains 000011 to 000019). Exit: every story's *Proven by* test passes against `postgres:17`, `make gate` and `make test-db` are green, the contract §7.2 and `docs/data-model.md` are corrected, `-restapi` has built against the tag. Roles bootstrap (`afs_edge`) runs in dev first |
| C2 Public web UI | No migration. `-restapi` `afs-edge` uses `collab_routes()`, `collab_settings()`, `collab_principal*()`, `record_collab_access()`; this repository supports with fixes and a load check of the principal functions in the dev environment |
| C3 REST API and managed mode | No migration. `emit_collab_secret_detected()`, `paperclip` secret rows and link-state writes are exercised by `-restapi`; gaps found become a minor migration (000021) |
| C4 People and reports | No migration expected. `collaboration_access` read by the collaboration report; retention verified with the monthly job |

## 8. Definition of done (every change)

- [ ] New migration, contiguous number, transactional, online-safe, lock impact in the header
- [ ] Down migration reverses it (up/down/up test)
- [ ] Rejected-case test for every new constraint and guard; isolation test for every team-owned table
- [ ] `docs/data-model.md` and, if roles, grants, functions or errors change, the database contract
- [ ] Every new acceptance criterion names its test in a **Proven by:** line
- [ ] `make gate` and `make test-db` green; release tag noted for `-restapi`
- [ ] Paperclip change (000020), in addition: `bootstrap/roles.sql` (and its header comment) lists `afs_edge`; database contract §7.2 (corrected in v1.3.1) and this PRD still agree on every name when 000020 lands; `seedOtherTeams` and the role lists in tests are extended (DB-US-54); `docs/data-model.md` gains `team_collaboration`, `agent_collaboration`, `collaboration_access`, `collab_hostname_holds`, `collab_edge_sessions`, `collab_edge_handoffs`, the new columns and the `afs_edge` role; `user-docs/` mentions running `afs-migrate bootstrap-roles` before a `-restapi` release that embeds 000020; the release tag is noted for `-restapi`

## 9. Open questions

| Id | Question | Owner | Status |
|---|---|---|---|
| OQ-4 | When to partition `audit_log` and archive beyond 400 days (the append-only trigger blocks deletion today) | db | Review at 12 months or 50 GB |
| DB-OQ-1 | RLS backs but does not replace the API's checks. Service-level tables are now guarded (DB-US-17); which remaining service-level rules the API alone enforces (for example work order creation from a template) should be listed in the database contract | db, restapi | Open |
| DB-OQ-2 | Retention ownership: the reconciler runs `drop_partitions_older_than` monthly; who owns the audit archive target (S3 bucket, Object Lock) | J / platform | Open |
| DB-OQ-3 | Reference instance: `db.r7g.large` is the working assumption for DB-US-3 and the connection limits; confirm after the M3 load test | restapi | Open |
| DB-OQ-4 | `afs.settle_reservation` on an already released hold did not add the actual cost. Resolved: it now takes the budget and period and records the cost on a late settle | db | Resolved (Claude, for J's review) |
| DB-OQ-5 | A credential-like key check, or a key allowlist, for `service_settings` | db | Open |
| DB-OQ-6 | `tag_sets` ids are md5 of their content: collision risk accepted? | db | Open |
| DB-OQ-7 | D18 (security operators, service-level keys), D19 (who switches on viewer kubectl) and D22 (swarm and work order plumbing) are accepted working decisions pending J's review | J | Pending review |
| DB-OQ-8 | The PRD predates migrations 000018 (report rollups, `agent_secret_bindings` revisions, billing reads) and 000019 (work order secrets, `afs.event_detail`): they have no requirement rows or stories in §4 and §5, though their tests exist. Add them in a catch-up change | db | Open |
| DB-OQ-9 | Who inserts the `afs`-managed key rows in `managed` registration? | restapi, db | Resolved by PC-D25: three reconciler functions (DB-US-56); `afs-api` inserts only the boot secrets |
| DB-OQ-10 | Should a worker agent's deletion also set its `agent_collaboration.connect = false`, as the collaboration agent's does for the team? The contract says only the collaboration agent's cleanup does; the reconciler revokes keys for deleted workers by observing `agents.state` | restapi, db | Open; default: no trigger, the reconciler handles it |
| DB-OQ-12 | Swarm collaboration agent's model: `agent_templates` has no model column, so DB-D18 takes the first pool's model. Should the swarm template spec carry `collaboration.modelId` instead (a contract change to database contract §7.2.9)? | restapi, db | Open; default: first pool's model |
| DB-OQ-11 | Is the database to refuse an `agent_collaboration.link_state = 'linked'` while `connect = false`? Not in the contract; the trigger sets `disabled` on disconnect and the reconciler could race it | restapi | Open; default: not refused |

### 9.1 Decisions (Claude, for J's review)

Made while specifying 000020 against the schema as it stands at 000019. Each is reflected in the stories above; the
first column of each row is what the database contract §7.2 says or leaves open, and the contract is corrected to
match (DoD, §8).

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

**Contract corrections:** all of DB-D1 to DB-D16 were applied to `docs/contracts/database-contract.md` §7.2 in API contract v1.3.1 (PC-D20), and the change PRD's DB-US-44 to DB-US-47 are superseded for `-db` by this PRD. DB-D17 to DB-D19 restate PC-D22, PC-D25 and the open model question.

## 10. Dependencies

| Dependency | Who | Calls or provides | When | Milestone |
|---|---|---|---|---|
| Partition creation | `afs-reconciler` | `ensure_usage_partition`, `ensure_activity_partition`, `ensure_traffic_partition` for next month | Monthly, before the month starts | M0 |
| Retention | `afs-reconciler` | `drop_partitions_older_than(13)` | Monthly | M3 |
| Spend periods | `afs-gateway`, `afs-reconciler` | `ensure_spend_counter` (gateway before reserving; reconciler at period start, then emits `budget.reset`) | Per call; period start | M3 |
| Spend | `afs-gateway` | `reserve_spend_held` / `settle_reservation(id, budget, period, actual)` (or `reserve_spend` / `settle_spend`) | Every model call | M3 |
| Stuck reservations | `afs-reconciler` | `release_expired_reservations` | Every minute | M3 |
| Idempotency keys | `afs-reconciler` | `purge_idempotency_keys` | Periodically | M1 |
| Change feed | `afs-reconciler` | `LISTEN afs_desired_state`, plus 30 s generation poll and 10 min resync | Always | M1 |
| Teardown | `afs-reconciler` | Reads `teams_due_for_teardown`, records `torn_down_at` and `teardown_reason` | Continuously | M0 (D18) |
| Ceiling override expiry | `afs-reconciler` | Lowers `budgets.amount_usd`, clears the override, emits `budget.ceiling_override_expired` | At expiry | M3 |
| Work order intake | `afs-reconciler` | Inserts work orders from EventBridge (via SQS), unique `source_event_id` | Continuously | M0 (D18) |
| Billing | `afs-billing` | Writes `cost_daily`, `cost_reconciliations`, `cost_allocation_tag_status`, price proposals; runs report schedules | Daily | M4 |
| RDS, PITR, snapshot copy, KMS, IAM authentication, parameter group | `-restapi` Terraform (`deploy/terraform`) | RDS PostgreSQL 17 Multi-AZ, PITR, cross-account snapshot copy, `rds.force_ssl`, `rds_iam` LOGIN users, connection limits | Before M1 | M0–M4 |
| Load test | `-restapi` | Concurrent `reserve_spend` bound, p99, RLS overhead | — | M3 |
| CI | This repository | `postgres:17` service container for `make test-db` | Every PR | M0 |
| Database contract | Root `docs/contracts/database-contract.md` | Roles, settings, functions, error mapping; must list 000013, 000014, 000015 and 000016 objects and the 4-argument `afs.secret_path(team, agent, pool, name)` in §4.2 | With `v0.13.0` | M0 |
| Database contract §7.2 | Root `docs/contracts/database-contract.md` | Migration 000020; corrected to the decisions of §9.1 when 000020 lands | With 000020 | C1 |
| Decisions | Root ADR-014 (feature-complete scope) and ADR-015 (PRD review resolutions D23–D56, recorded in root PRD §10.1; ADR-015 in the root ADR log) | Scope and the 000013 and 000014 behaviour (D49, D54) | — | — |
| Collaboration role bootstrap | Platform DBA | `afs-migrate bootstrap-roles` creates `afs_edge` (NOLOGIN) before 000020; the `afs-edge` LOGIN user is a member of `afs_edge` with IAM authentication, created with the other service users | Before `-restapi` adopts 000020 | C1 |
| Edge | `-restapi` `afs-edge` | `collab_routes()` (30 s and on notify), `collab_settings()`, `collab_principal()`, `collab_principal_key()`, `record_collab_access()` every 5 minutes, `emit_collab_secret_detected()`, `collab_handoff_create/consume`, `collab_session_get/revoke` (sessions are server-side, PC-D22); `LISTEN afs_desired_state` | Continuously | C2 |
| Collaboration reconciliation | `afs-reconciler` | Calls `record_collab_agent_key`, `remove_collab_agent_key`, `record_collab_board_key` and `purge_collab_edge_sessions` (hourly); writes `agent_collaboration` link columns and `paperclip` secret rows, `resource_status` for `team_collaboration`; reads `collaboration_access` every minute for `collaboration.denied_spike`; `ensure_collaboration_access_partition` monthly; purges expired `collab_hostname_holds` daily; `drop_partitions_older_than(13)` now also covers `collaboration_access` | Continuously | C1 to C3 |
| Collaboration API | `afs-api` | Inserts `team_collaboration` with the collaboration agent and the four `afs` boot and board secrets in one transaction; upserts `agent_collaboration`; reads `collaboration_access` for T16 and the collaboration report (reads only, RLS applies) | Per request | C1, C4 |
| Pinned contract extracts | Root contracts | This repository keeps no pinned snapshot of a root contract (it provides the database contract). When 000020 lands, `docs/data-model.md` and the database contract §7.2 must be resynced in the same change (DoD); `-restapi`, `-cli` and `-website` resync their own pinned API snapshots from `-restapi` | With 000020 | C1 |
| Paperclip change PRD | Root `paperclip-team-collaboration-PRD.md` (COL-*, SEC-7, PC-D1 to PC-D19, PC-OQ-1 to PC-OQ-8) | Requirements and decisions refined by DB-41 to DB-49 | — | C1 to C4 |

## 11. Review record

`review-prd` pass by hand (dev-flow), 2026-11-22, on the Paperclip extension of this PRD (DB-41 to DB-52,
DB-US-44 to DB-US-57, §9.1), checked against migrations 000001 to 000019 and `bootstrap/roles.sql`. The earlier
content (DB-1 to DB-40, DB-US-1 to DB-US-43) was not re-reviewed. Verdict after fixes: **Ready for spec**.

| Dimension | Status | Note |
|---|---|---|
| Problem clarity | ✅ Pass | §1 names the Paperclip problem for the database: a public role with no table access, a bounded secrets exception, a one-per-team rule that survives an API bug |
| Scope definition | ✅ Pass | §3 lists what 000020 includes and what stays out (pod, network, ALB, WAF, scanning, Secrets Manager writes, Paperclip data) |
| Functional completeness | ✅ Pass | DB-41 to DB-49 trace COL-1, 2, 3, 5, 7, 10, 12, 14, 16 to 20, 23, 24, 30, 31, 36, SEC-7, ACC-2 and TEAM-9 to objects; every object of contract §7.2 appears in a story |
| NFR coverage | ✅ Pass | New row for function latency, fact-table capacity and retention, least privilege; existing rows (online changes, security, quality) apply unchanged |
| Acceptance criteria | ✅ Pass | Each story has Given/When/Then style criteria with exact object names, SQLSTATEs and named subtests; none is pending, though none is implemented (stated) |
| Dependency identification | ✅ Pass | Role bootstrap order, edge, reconciler and API duties, contract resync and the change PRD are named |
| Open questions | ✅ Pass | DB-OQ-8 to DB-OQ-11 with owners; DB-D1 to DB-D16 record decisions |

Findings and fixes in this pass:

- **Fail then fixed, Acceptance criteria and Open questions:** the contract's §7.2 could not be implemented as written
  in six places because the schema at 000019 contradicts it: Paperclip secrets with `origin = 'registered'` against
  `secrets_origin_check` and the path trigger (DB-D3), a `UNIQUE (team_id, name)` that 000003 dropped (DB-D5), a
  guard trigger whose `UPDATE OF` list must be rebuilt (DB-D6), notify payloads and `generation` behaviour that
  `afs.notify_desired_state()` and `afs.touch_row()` do not give (DB-D1, DB-D2), a hostname hold keyed to a row
  that the cleanup trigger deletes first (DB-D10), and the user match on columns `users` does not have (DB-D9).
  Each now has a decision and a contract correction.
- **Warning then fixed, Functional completeness:** the change PRD bundled the edge's functions, the principal
  lookups and the access facts in one story; split into DB-US-47, DB-US-51 and DB-US-52, and the cleanup, role,
  hostname and upgrade criteria into DB-US-48, DB-US-50, DB-US-53 and DB-US-54.
- **Warning then fixed, Acceptance criteria:** "only `afs_reconciler` writes `paperclip` rows" and "`42501` for
  other secret writes" would have been a silent RLS filter; now a guard trigger (DB-D4) with named subtests.
- **Warning then fixed, Dependencies:** no writer existed for `afs`-managed rows in `managed` mode; recorded as
  DB-D11 and DB-OQ-9 for `-restapi` to confirm.
- **Warning then fixed, NFR coverage:** function latency and `collaboration_access` growth had no figures; added as
  working values to be confirmed in the load test.
- **Not fixed, left open on purpose:** 000018 and 000019 have no requirement rows or stories (DB-OQ-8); the
  worker-deletion and `linked`-while-disconnected questions (DB-OQ-10, DB-OQ-11). None blocks 000020.

**Aligned to v1.3.1** (2026-11-22, after the contracts corrections round, PC-D20 to PC-D31): DB-US-55 (sessions and handoffs, PC-D22), DB-US-56 (reconciler key functions and purge, PC-D25, PC-D26) and DB-US-57 (swarm collaboration, PC-D29) added; the edge now has ten functions (DB-US-47, DB-US-55); DB-OQ-9 closed and DB-D11 resolved by PC-D25; DB-D17 to DB-D19 added; contract corrections confirmed applied. Remaining inconsistency: contract §7.2.9 names a template "model" that `agent_templates` lacks (DB-D18, DB-OQ-12).
