# Enterprise Agent Factory Service — Database PRD (`-db`)

| | |
|---|---|
| **Status** | Feature complete, schema 000017 (2026-11-21): every acceptance criterion provable in this repository has a named, passing test |
| **Author** | J (Enterprise Architecture), drafted with Claude |
| **Parent** | [Root PRD](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/enterprise-agent-factory-service-initial-PRD.md) (product requirements and stories US-1..US-26) |
| **Provides** | [Database contract](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/database-contract.md) |
| **Consumes** | No service at runtime. The schema relies on jobs and infrastructure owned elsewhere (§10) |
| **Dictionary** | [docs/data-model.md](docs/data-model.md) |

## 1. Purpose

This repository is the only place the AFS schema changes. It holds all desired state, the spend ledger,
reporting tables, the audit log and the outbox in RDS PostgreSQL 17, defines the database roles each
service connects as, enforces team isolation with row-level security, and ships the migrations as a Go
module (`migrate`) plus a command (`afs-migrate`). Its job is to make the wrong thing impossible at the
data layer even if a bug in the API forgets a check. Row-level security and guards **back** the API's
authorization; they do not replace it (`afs-api` still decides every request, root ACC-3).

## 2. Users of this repository

| User | Needs |
|---|---|
| `-restapi` developers | A stable, documented schema at a release tag; clear errors; views that answer reports directly |
| `afs-api`, `afs-reconciler`, `afs-gateway`, `afs-billing` at runtime | Least-privilege roles, fast hot paths (spend reservation), safe concurrency, a change feed |
| Platform operators and DBAs | One-time bootstrap, safe forward-only migrations, backups and restore |
| Security and audit | Isolation they can test, append-only audit, no secret values anywhere |

## 3. Scope

**In:** schema `afs` and its migrations; roles and grants; RLS, including write policies on the service
catalog, settings, role bindings and users; triggers that guard invariants (guardrails and ceilings,
required tags, price decisions, secret paths, ephemeral team and pool rules, work order access, budget
exhaustion mode); functions for spend reservation (counters and held reservations), spend periods,
partitioning and retention; the desired-state change feed (`pg_notify`); reporting views; `migrate`
package; `afs-migrate` CLI; integration tests; operator docs in `user-docs/`.

**Out:** application logic (API, reconciler, gateway, billing), including the jobs that call this
schema's functions on a schedule (§10); Kubernetes and AWS resources; RDS provisioning, PITR, snapshot
copies, KMS keys and IAM database authentication (Terraform lives in `-restapi/deploy`).

## 4. Requirements owned

Each row traces a product requirement to the objects that implement it. Status: ✓ in schema at
`000016`. Scope is feature complete (root ADR-014): nothing is deferred to a later phase. Rows DB-24 to
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
| DB-40 Schema version for service roles | OPS-2 | 000017: `afs.schema_version()` (SECURITY DEFINER) for `afs_app`, `afs_reconciler`, `afs_gateway`, `afs_billing`, `afs_readonly`; proven by `TestSchemaVersionFunction` (every role reads the version; the tracking table stays `42501`) | ✓ |

## 5. User stories and acceptance criteria

Stories are implemented by migrations 000001 to 000016. Each story ends with **Proven by:**, naming the
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

## 7. Delivery

| Milestone (root PRD §9) | This repository |
|---|---|
| M0 Foundations | Schema 000001–000017, feature complete; first release tag `v0.13.0` (nothing is tagged yet, so it is the first release to contain 000011–000017) for `-restapi` to adopt |
| M3 Spend control | Load test of `reserve_spend` and `reserve_spend_held` with `-restapi` (concurrent bound, p99, RLS overhead); partition and retention jobs verified |
| M4 Production readiness | Restore drill documented in `user-docs/` |

## 8. Definition of done (every change)

- [ ] New migration, contiguous number, transactional, online-safe, lock impact in the header
- [ ] Down migration reverses it (up/down/up test)
- [ ] Rejected-case test for every new constraint and guard; isolation test for every team-owned table
- [ ] `docs/data-model.md` and, if roles, grants, functions or errors change, the database contract
- [ ] Every new acceptance criterion names its test in a **Proven by:** line
- [ ] `make gate` and `make test-db` green; release tag noted for `-restapi`

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
| Decisions | Root ADR-014 (feature-complete scope) and ADR-015 (PRD review resolutions D23–D56, recorded in root PRD §10.1; ADR-015 in the root ADR log) | Scope and the 000013 and 000014 behaviour (D49, D54) | — | — |
