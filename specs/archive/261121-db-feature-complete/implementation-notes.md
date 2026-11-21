# Implementation notes: db-feature-complete

**Date:** 2026-11-21

Purpose: decisions, edge cases and deviations, recorded as they happen. Update after each task.

## Technical Decisions

- **TD-1 PRD stays at the repository root (deviation from create-spec).** create-spec moves the PRD into the
  spec directory. This PRD is the living product PRD of the repository: `AGENTS.md`, `README.md`, the root
  repository and the sibling repositories link to `enterprise-agent-factory-service-db-PRD.md` at the root,
  and this run must update its Proven-by lines. Moving it into `specs/archive/` would break those links and
  freeze the document. Decision: copy a snapshot into the spec directory (taken at spec creation) and keep
  the canonical file at the root.
- **TD-2 No separate sub-agents.** The run was executed by a single agent working step by step (no
  sub-agent tool in this environment); every step's output is still recorded here and in the dashboard.
- **TD-3 Pre-flight skipped.** J authorized the run; the PRD was reviewed twice, so optional PRD validation
  and confirmation prompts were skipped, and archive confirmations were taken as given.
- **TD-5 Lock timeout default 10 s (SQ-2).** Long enough for a migration to take a brief ACCESS EXCLUSIVE
  lock between ordinary transactions, short enough that queued traffic recovers quickly. Set with
  `SELECT set_config('lock_timeout', $1, true)` (SET LOCAL with a bound parameter) inside each migration
  transaction, so it never applies to the advisory-lock wait between migrators and does not leak into the
  session. `Up`/`Down` take `...Option`, so `-restapi`'s existing calls compile unchanged.
- **TD-6 Service-level channels carry no secret (SQ-1).** Secrets are team-owned; a service-level secret
  store does not exist. Refusing `secret_id` on service-level channels (CHECK) is the smallest safe rule.
  A service-level webhook that needs a credential would need a service secret design first (recorded for
  the review PRD).
- **TD-7 Variance status is derived, not checked.** A CHECK cannot read a runtime setting, and refusing the
  billing job's write would make it compute the same rule. A BEFORE trigger sets `status`; the billing job
  may pass anything. Rows written before 000015 keep their status (no backfill; none exist in production).
- **TD-8 API key `created_at` reset on insert, immutable on update (55000).** Resetting rather than refusing
  on insert keeps the API's insert unchanged; 55000 on update matches the other immutable columns.
- **TD-9 Teardown view filtered, not dropped.** `CREATE OR REPLACE VIEW` keeps the columns, grants and
  `security_invoker`, so no consumer changes.
- **TD-10 Cross-team handoff is 23503, not 23514.** The composite foreign keys refuse it before any trigger;
  the PRD now says so instead of adding a redundant guard.
- **TD-11 Local server is PostgreSQL 16.** The integration tests ran against 16 here; nothing in 000015 or
  the tests needs 17, and CI runs them on `postgres:17`.
- **TD-12 Step 4 docs.** `docs/product-details.md` was not created: the product details of this repository
  are the data dictionary (`docs/data-model.md`) and the PRD, and AGENTS.md forbids duplicating them.
  `user-docs/` got getting-started, configuration and operations guides (operator material only, per the
  user-docs rule), linked from README.md.
- **TD-13 X-DB-1..6 added in a new 000016, not folded into 000015.** The coordinator relayed six schema
  access gaps from `-restapi` (its research.md §6) during Step 11. 000015 is unmerged and could have taken
  them, but its scope is "gaps found by proof"; a separate `000016_service_access_functions` keeps each
  migration's header honest and its down migration small. Stories DB-US-38 to DB-US-43, requirement DB-39.
- **TD-14 Narrow SECURITY DEFINER entry points (ADR-008).** One function per pre-scope path, pinned
  `search_path`, PUBLIC execute revoked, EXECUTE for the named roles only; the only new policies are
  INSERT-only. No policy lets `afs_app` read another team's rows.
- **TD-15 `authenticate_api_key` decides nothing.** It reports `state` (active, expired, revoked) and
  `team_state` and lets the API answer `401`; it touches `last_used_at` only for a usable key, at most
  once a minute. `principal` is the key id (the audit `actor_id`); `roles` is a one-element array so the
  shape can grow.
- **TD-16 Workload ServiceAccounts are `agent-<name>` and `pool-<name>`** in the team namespace
  (`afs-t-<slug>`), as the reconciler names them; deleted agents or pools and teams that are not `active`
  resolve to nothing.
- **TD-17 `instantiate_work_order_team` choices.** Unknown work order `P0002` (no row, not a foreign key);
  not open, no template, disabled template `55000`; slug `wo-<lowercase ulid>` (29 characters, unique by
  construction); display name `Remediation: <CVE id or title>`; ceiling equals the budget so
  `check_budget_ceiling` passes; cost center and owner email from the spec (`costCenter`, `ownerEmail`),
  else the new checked settings `work_orders.cost_center` / `work_orders.owner_email`, else `55000` (no
  invented defaults); pools name their stage by `stage` (a name, since template stages have no ids);
  handoffs and configuration values name pools by name. Template `secrets` are not created: a secret row
  needs the ARN Secrets Manager assigns, and `afs_reconciler` cannot insert `secrets`. Recorded as a
  follow-up for `-restapi` (see below).
- **TD-18 Audit and outbox insert policies.** `app_own_audit` allows any team (or none) when `actor_id =
  afs.current_actor()`; `app_operator_work_order_events` allows `work_order.*` events on `work_orders` from
  a security operator. Both are INSERT only: an `INSERT … RETURNING` outside the caller's scope still fails
  because RETURNING needs a SELECT policy; the API must not use RETURNING for these rows.
  `TestCrossTeamWritesChangeNothing` now treats a table as "scoped only" when no other SELECT or ALL policy
  exists, so INSERT-only policies keep the read check.
- **TD-19 `afs.new_id(prefix)`** generates ULIDs in SQL (48-bit milliseconds from `clock_timestamp()`, 80
  random bits from `gen_random_uuid()` with the version and variant bits skipped); owner only.
- **TD-4 Spec directory name.** `261121-db-feature-complete` (shorter than the PRD-derived
  `enterprise-agent-factory-service-db`), as requested; the dashboard keeps the PRD-derived feature name.

## Step 2 spec review (review-spec)

Verdict on first read: **Needs revision**; after fixes: **Implementation-ready**.

| Dimension | First read | After fix | Note |
|---|---|---|---|
| Acceptance criteria | Pass | Pass | FR-001–FR-019 each name the test to add |
| Technical approach | Pass | Pass | TDD, fix forward in 000015 |
| Component coverage | Pass | Pass | Files named in Scope of Changes |
| Edge case handling | Warn | Pass | Added Edge Cases (nullable composite FK, non-standard policies, month boundaries, concurrency, advisory lock vs lock timeout) |
| Open questions | Warn | Pass | Added SQ-1, SQ-2 with resolution paths |
| Out-of-scope clarity | Pass | Pass | Non-goals name M3/M4 owners |
| Status initialization | Pass | Pass | Phase 0 In Progress |

tasks.md filled with T1–T9.

## Step 3 TDD log

| Test | First run | Fix |
|---|---|---|
| `TestLogDestinationsAndNotificationChannels/a service-level channel holds no secret reference` | Red: service channel accepted team B's secret and a missing one | 000015 CHECK |
| `TestPendingGuards/teams due for teardown…` | Red: swarm B listed with reason NULL | 000015 view |
| `TestPendingGuards/billed cost beyond the variance setting…` | Red: status kept whatever was written | 000015 trigger |
| `TestPendingGuards/API keys expire within 90 days of their real creation` | Red: back-dated `created_at` accepted on insert and update | 000015 trigger |
| `TestLockTimeoutStopsBlockedMigration`, `TestLockTimeoutIsSetPerMigration` | Red: build failed (no option) | `migrate.WithLockTimeout` |
| `TestCrossTeamWritesChangeNothing` | Green; checked by mutation (service admin session) → 37 subtests fail | — |
| Other new proofs | Green first time (the schema already held) | — |

Coverage `migrate`: 81.4% → 96.2%. Tests: 160 → 280 passing (sub)tests, 1 skipped (exempt table).

T10 (000016): `TestAuthenticateAPIKey`, `TestResolveWorkload`, `TestTeamDirectory`,
`TestInstantiateWorkOrderTeam`, `TestReconcilerMarksPoolsDeleted` and `TestServiceAuditAndOutboxInserts`
written first and red against 000015 (functions missing, `42501` on the pool update and the inserts);
green with 000016; then the settings check added red→green. Tests: 284 → 327 passing (sub)tests (53
top-level), 1 skipped; coverage `migrate` 96.5%.

## Edge Cases & Solutions

- Crockford base32: fixture ids must avoid I, L, O, U (`afs.ulid_ok`).
- Payload of catalog tables without prefixed ids (`models`, `storage_classes`): the feed test compares with
  the updated row's own id and team rather than a prefix pattern.
- Concurrency test opens 50 connections; the default `max_connections` (100) is enough.

## Deviations from Plan

- PRD wording corrected where the schema was right and the text was not: cross-team handoff `23503`
  (DB-US-14); a persistent team's deletion sets `state` and `deleted_at` only (DB-US-36,
  `teams_teardown_ephemeral`).

## Follow-ups for `-restapi`

- Swarm template `secrets` are not created by `afs.instantiate_work_order_team`: the reconciler must create
  them in Secrets Manager and needs a way to record the rows (a further `SECURITY DEFINER` function or an
  INSERT grant on `secrets` / `pool_secret_bindings` for `afs_reconciler`). Not requested in X-DB-1..6.
- Do not use `INSERT … RETURNING` for audit or outbox rows written under the 000016 insert policies.

## Lessons Learned
