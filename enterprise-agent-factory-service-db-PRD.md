# Enterprise Agent Factory Service — Database PRD (`-db`)

| | |
|---|---|
| **Status** | Draft for review (2026-11-21) |
| **Author** | J (Enterprise Architecture), drafted with Claude |
| **Parent** | [Root PRD](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/enterprise-agent-factory-service-initial-PRD.md) (product requirements and stories US-1..US-16) |
| **Provides** | [Database contract](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/database-contract.md) |
| **Consumes** | Nothing at runtime. Bootstrap roles from operators |
| **Dictionary** | [docs/data-model.md](docs/data-model.md) |

## 1. Purpose

This repository is the only place the AFS schema changes. It holds all desired state, the spend ledger,
reporting tables, the audit log and the outbox in RDS PostgreSQL 17, defines the database roles each
service connects as, enforces team isolation with row-level security, and ships the migrations as a Go
module (`migrate`) plus a command (`afs-migrate`). Its job is to make the wrong thing impossible at the
data layer even if a bug in the API forgets a check.

## 2. Users of this repository

| User | Needs |
|---|---|
| `-restapi` developers | A stable, documented schema at a release tag; clear errors; views that answer reports directly |
| `afs-api`, `afs-reconciler`, `afs-gateway`, `afs-billing` at runtime | Least-privilege roles, fast hot paths (spend reservation), safe concurrency |
| Platform operators and DBAs | One-time bootstrap, safe forward-only migrations, backups and restore |
| Security and audit | Isolation they can test, append-only audit, no secret values anywhere |

## 3. Scope

**In:** schema `afs` and its migrations; roles and grants; RLS; triggers that guard invariants
(guardrails, required tags, price decisions, secret paths); functions for spend reservation and
partitioning; reporting views; `migrate` package; `afs-migrate` CLI; integration tests; operator docs in
`user-docs/`.

**Out:** application logic (API, reconciler, gateway, billing); Kubernetes and AWS resources; RDS
provisioning (Terraform lives in `-restapi/deploy`).

## 4. Requirements owned

Each row traces a product requirement to the objects that implement it. Status: ✓ in schema at
`000010`; ◐ partly; ○ planned.

| DB req | Product req | Objects | Status |
|---|---|---|---|
| DB-1 Teams and lifecycle | TEAM-1, TEAM-5, TEAM-7 | `teams` (kind, state, expiry), `resource_status` | ✓ |
| DB-2 Isolation tier | TEAM-6 | `teams.isolation_tier` | ○ |
| DB-3 Allowed AWS accounts | TEAM-8, D6 | `org_aws_accounts`, `teams.allowed_aws_accounts`, `may_manage_aws_accounts`, `afs.account_allowed`, `team_guardrail_guard` | ✓ |
| DB-4 Agents, one identity one pod | AGT-1, AGT-2, AGT-7 | `agents` (no replica column), digest-pinned image check | ✓ |
| DB-5 Agent identity and role links | AGT-3, AGT-5, AGT-6, AGT-10 | `agents.iam_identity`, `agent_identities`, `agent_role_links` | ✓ |
| DB-6 Agent storage | AGT-9 | `storage_classes`, agent volume columns, `agent_volume_snapshots` | ✓ |
| DB-7 Secrets as references | SEC-1, SEC-2, SEC-3, SEC-5, EXT-7 | `secrets` (ARN, managed path via `afs.secret_path`), `agent_secret_bindings` | ✓ |
| DB-8 Configuration values | CFG-7 | `namespace_config_values`, `agent_config_values`, `agent_config_resolved` | ✓ |
| DB-9 Budgets and spend | BUD-1 to BUD-5, BUD-8 | `budgets`, `spend_counters`, `reserve_spend`, `settle_spend`, `budget_threshold_events`, `usage_events` | ✓ |
| DB-10 Costs, reconciliation, prices | BUD-6, BUD-7, BUD-9 | `cost_daily`, `cost_reconciliations`, `model_prices`, `model_price_proposals`, pricing settings | ✓ |
| DB-11 People and access | ACC-1, ACC-2, ACC-4 | `users`, `role_bindings`, `api_keys`, `identity_providers`, `teams.identity_provider_id` | ✓ |
| DB-12 Desired state, revisions, audit, outbox | CFG-1, CFG-3, CFG-6, OPS-2 | `version`/`generation`, `touch_row`, `record_revision`, `config_revisions`, `audit_log`, `outbox_events` | ✓ |
| DB-13 Export and import | CFG-5 | `export_bundles` | ✓ |
| DB-14 External systems | EXT-1 to EXT-7 | `external_systems`, `external_system_optouts`, `agent_external_access` | ✓ |
| DB-15 Reporting | RPT-1 to RPT-7, RPT-9 | `agent_activity`, `external_traffic`, daily and current views, `team_budget_position`, `*_by_tag` views | ✓ |
| DB-16 Scheduled reports | RPT-8 | `report_schedules` | ○ |
| DB-17 Cost allocation tags | TAG-1 to TAG-6 | `service_tags`, `team_tags`, `team_effective_tags`, `agent_effective_tags` | ✓ |
| DB-18 Idempotency keys | API contract §1 | `idempotency_keys` | ○ |
| DB-19 Agent sign-in events | OPS-4 | `agent_login_events` (or a flag on `external_traffic`) | ○ |
| DB-20 Work orders | WO-1, WO-2 | `work_orders` | ◐ (table only) |
| DB-21 Swarm pools | AGT-8 | `agent_pools` and pool budgets | ○ (phase 2) |
| DB-22 Roles and RLS | G2, ACC-3 | `afs_app`, `afs_reconciler`, `afs_gateway`, `afs_billing`, `afs_readonly`; `app_team_scope` and `service_roles_all` policies | ✓ |
| DB-23 Migrations runner and CLI | CFG-2, CFG-4 | `migrate` (Load, Up, Down, Version, advisory lock, checksum guard), `afs-migrate` | ✓ |

## 5. User stories and acceptance criteria

**DB-US-1 · Isolation that survives an API bug.** *(refines US-3)* As security, I want the database to
refuse cross-team reads and writes for `afs_app` regardless of the query, so that a missing `WHERE`
cannot leak data.
- Given a transaction as `afs_app` with `afs.team_ids = team A`, when it selects from any team-owned
  table or view without a filter, then it sees only team A's rows.
- When it updates or deletes team B's rows by id, then zero rows change; when it inserts a row for
  team B, then `42501` or an RLS violation is raised.
- Given a transaction that sets no session settings, then it sees no team rows (fail closed).
- Every new team-owned table is added to the isolation test in the migration's PR; CI fails otherwise.

**DB-US-2 · Guardrails only service admins change.** *(refines US-1, US-7)* As a service admin, I want
budget ceilings, quotas, `may_*` rights and (when the team does not manage it) the allowed-accounts filter
protected in the database.
- Given an `afs_app` caller who is not a service admin, when it changes `max_budget_usd`,
  `may_add_external_systems` or `may_manage_aws_accounts`, then `42501`.
- Given `may_manage_aws_accounts` is off, when a team caller changes `allowed_aws_accounts`, then
  `42501`; when it is on, the change succeeds.
- When a budget above the ceiling is written by anyone, then `23514`.

**DB-US-3 · Spend reservation that never overspends.** *(refines US-9)* As the gateway, I want an
atomic reserve and settle, so that concurrent calls cannot spend past the limit.
- Given a limit of 100 with 99.50 spent, when 50 concurrent `reserve_spend(…, 0.10)` calls run, then at
  most 5 return true and `spent + reserved ≤ limit` holds at every commit.
- When `settle_spend` runs, then the reservation is released and the actual cost added in one statement.
- `reserve_spend` p99 under 5 ms at 500 calls per second on the reference instance (load test in
  `-restapi`).

**DB-US-4 · Secrets cannot leak through the schema.** *(refines US-6)* As security, I want no column
able to hold a secret value.
- A test fails if any column outside the documented, non-secret configuration and tag tables matches
  `value|password|plaintext|secret_string`.
- A secret row whose ARN does not match `afs.secret_path(team, agent, name)` is refused (`23514`).
- Configuration names and tag keys that look like credentials are refused.

**DB-US-5 · Required tags at team creation.** *(refines US-12)* As a service admin, I want a team to be
impossible to create without required tags.
- Given a required key without a default, when a transaction inserts a team without a value, then the
  commit fails with `23514` naming the key; with the value in the same transaction, it commits.
- When a team removes a required value later, then the commit fails.
- `team_effective_tags` always includes `afs-team-id`; `agent_effective_tags` always includes
  `afs-agent-id`; neither can be set or overridden through `team_tags`.

**DB-US-6 · Price decisions with a trail.** *(refines US-10)* As a service admin, I want only service
admins to approve prices, and approvals never to backdate a price.
- `afs_billing` can propose and supersede, never approve (`42501`); a team caller cannot approve
  (`42501`); a decided proposal cannot be decided again (`55000`).
- An approved proposal with a past `effective_from` writes a `model_prices` row effective at approval.

**DB-US-7 · Safe, repeatable migrations.** *(refines US-13)* As an operator, I want migrations to apply
once, in order, under a lock, and to refuse tampering.
- Two `afs-migrate up` runs at once: one applies, the other waits, then finds nothing to do.
- A changed checksum of an applied migration stops the run with a clear error.
- `up`, `down` to zero and `up` again succeed in CI on `postgres:17` (local and test use only).
- Each migration states its lock impact; none rewrites a large table in one step.

**DB-US-8 · Reports from views.** *(refines US-11, US-12)* As an `-restapi` developer, I want daily and
current views that answer the report API without application-side aggregation.
- `agent_activity_daily.utilization_pct` = working ÷ (working + idle); `agent_activity_current.idle_since`
  = end of the last working window.
- `cost_daily_by_tag` groups by tag key and value with `NULL` for untagged; system keys are excluded.
- Every view is `security_invoker`, so a team caller sees only its own teams through it.

**DB-US-9 · Recover from a backup.** *(refines US-13)* As an operator, I want to restore the database to a
point in time and have the services converge from it.
- `user-docs/` describes PITR restore and cross-account snapshot copy; a restored database passes
  `afs-migrate version` and the reconciler converges without manual SQL.

## 6. Non-functional requirements

| Area | Requirement |
|---|---|
| Engine | PostgreSQL 17 features only; tested on `postgres:17` in CI |
| Online changes | Additive columns with constant defaults; constraints `NOT VALID` then `VALIDATE`; batched backfills in application code |
| Performance | Hot paths indexed (`spend_counters` by budget and period, `usage_events` by team and time, partitions by month); report views read monthly partitions only for the range asked |
| Retention | `usage_events`, `agent_activity`, `external_traffic` partitions kept 13 months; audit 400 days online |
| Security | No secret values; least-privilege grants per role, column grants where a role updates part of a row; audit append-only by trigger |
| Quality | `migrate` ≥ 90% coverage; every constraint has a rejected-case test; every RLS policy has an isolation test |

## 7. Delivery

| Milestone (root PRD §9) | This repository |
|---|---|
| M0 Foundations | Schema v1 (000001–000010) ✓; tag `v0.10.0` for `-restapi` to adopt |
| M1 Teams & access | DB-2 isolation tier; DB-18 idempotency keys |
| M3 Spend control | Load test of `reserve_spend` with `-restapi`; partition maintenance job verified |
| M4 Production readiness | DB-16 report schedules; DB-19 sign-in events; restore drill documented in `user-docs/` |
| Phase 2 / 3 | DB-21 swarm pools; DB-20 work order details |

## 8. Definition of done (every change)

- [ ] New migration, contiguous number, transactional, online-safe, lock impact in the header
- [ ] Down migration reverses it (up/down/up test)
- [ ] Rejected-case test for every new constraint and guard; isolation test for every team-owned table
- [ ] `docs/data-model.md` and, if roles, grants, functions or errors change, the database contract
- [ ] `make gate` and `make test-db` green; release tag noted for `-restapi`
