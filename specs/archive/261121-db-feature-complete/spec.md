# Spec: db-feature-complete

**Feature:** enterprise-agent-factory-service-db (feature-complete schema, release `v0.13.0`)
**Created:** 2026-11-21
**Source PRD:** [enterprise-agent-factory-service-db-PRD.md](../../enterprise-agent-factory-service-db-PRD.md)
(kept at the repository root as the living product PRD; snapshot copy in this directory, see
implementation-notes.md TD-1)

## Executive Summary

The schema of the Enterprise Agent Factory Service is implemented in migrations 000001–000014 and most
of its acceptance criteria are proven by integration tests. This feature closes the gap to "feature
complete": every DB-US acceptance criterion marked **pending** in the PRD gets an integration test, any
schema gap those tests reveal is fixed in a new migration 000015, the `migrate` runner gets the
`lock_timeout` the NFRs ask for, and `migrate` coverage is raised to at least 90%. The PRD's
**Proven by** lines are updated to name the real tests.

## Problem Statement

`-restapi` is about to adopt the first release tag. The PRD names 18 pending proofs, `migrate` coverage is
81.4% (target 90%), and the NFR "migrate sets a lock_timeout" is not implemented. Shipping a schema whose
isolation, guard and retention rules are only partly proven would let a regression in a later migration
go unnoticed.

## Goals / Non-Goals

**Goals**
- Prove every DB-US acceptance criterion that can be proven in this repository.
- Fix forward any defect the new tests reveal (migration 000015; 000001–000014 do not change).
- `migrate` ≥ 90% statement coverage; `lock_timeout` on every migration transaction.
- PRD, `docs/data-model.md`, docs and `user-docs/` reflect what is built.

**Non-Goals**
- Load and latency proofs (DB-US-3 p99, RLS overhead): `-restapi` M3 load test.
- Restore drill (DB-US-9): M4 with `-restapi` Terraform.
- New product behaviour beyond the PRD. Release tagging (tag pushes are blocked; the tag is noted for the maintainer).

## User Requirements — Functional Requirements

| FR | Story | Requirement (test to add) |
|---|---|---|
| FR-001 | DB-US-1 | Table-driven test over every table with an `afs_app` team-scope policy: a team-A caller updating or deleting team B's rows changes zero rows |
| FR-002 | DB-US-3 | Concurrent bound: limit 100, 99.50 spent, 50 parallel `reserve_spend(…, 0.10)` give at most 5 successes |
| FR-003 | DB-US-4 | `afs_reconciler` cannot `SELECT response_body` from `idempotency_keys` (`42501`), can read `principal`, `key`, `expires_at` |
| FR-004 | DB-US-5 | The missing-required-tag error names the key |
| FR-005 | DB-US-7 | Every migration from 000003 states its lock impact in its header |
| FR-006 | DB-US-13 | `teams_due_for_teardown` lists `expired` and `cap_reached` reasons |
| FR-007 | DB-US-14 | Cross-team handoff refused; daily views group by pool |
| FR-008 | DB-US-15 | `merged` without PR link refused; `sla_warning_hours` override changes `sla_state` |
| FR-009 | DB-US-19 | Table-driven change-feed test: every table with a revision trigger has a notify trigger, and a sample announces |
| FR-010 | DB-US-20 | `drop_partitions_older_than` drops old `agent_activity` and `external_traffic` partitions |
| FR-011 | DB-US-22 | Unpinned image refused (`23514`) |
| FR-012 | DB-US-26 | `cost_reconciliations.over_threshold` true beyond `billing.variance_alert_pct` |
| FR-013 | DB-US-27 | API key expiring more than 90 days after creation refused |
| FR-014 | DB-US-28 | `TRUNCATE audit_log` refused; audit rows can name a pool and worker pod |
| FR-015 | DB-US-34 | `log_destinations`, `notification_channels`: cross-team invisible, insert `42501`, update/delete zero rows; secret reference FK to own team (`23503`), secret in use not deletable (`23503`) |
| FR-016 | DB-US-35 | `swarm_templates`: team update/delete zero rows; team and security operator read every row |
| FR-017 | DB-US-36 | A deleted team's `usage_events`, `cost_daily`, `config_revisions`, `audit_log` stay readable by service admin and `afs_readonly` |
| FR-018 | NFR Observability | `migrate.Up`/`Down` set `lock_timeout` per migration transaction (default, overridable); a blocked DDL fails with `55P03` |
| FR-019 | NFR Quality | `migrate` ≥ 90% coverage, error paths tested |

## Non-Functional Requirements

From PRD §6. Testable here: Engine (PostgreSQL 17 features only; local run on 16, CI on 17), Online
changes (000015 additive), Security (no secret value columns, least privilege), Quality (coverage, rejected
case per constraint, isolation per policy), Observability (`lock_timeout`). Not testable here:
performance p99, RLS overhead, capacity, availability, encryption, connection limits (operator / M3 / M4).

## System Architecture

No application layers: this repository is SQL migrations plus the `migrate` Go package.
- Modified: `migrate/migrate.go` (lock timeout option).
- New: `migrate/feature_complete_test.go`, `migrate/migrate_unit_test.go` (error paths).
- New if a gap is found: `migrations/000015_*.up.sql` / `.down.sql`.

## Scope of Changes

| File | Change |
|---|---|
| `migrate/migrate.go` | `Option`, `WithLockTimeout`, `DefaultLockTimeout`; `Up`/`Down` take `...Option` (source compatible) |
| `migrate/*_test.go` | New tests per FR |
| `migrations/000015_*` | Only if a test reveals a schema gap |
| `enterprise-agent-factory-service-db-PRD.md` | Proven-by lines, status to 000015 |
| `docs/data-model.md`, `docs/technical-details.md`, ADR, `README.md`, `user-docs/` | Reflect the build |

## Breaking Changes

- API: none. `Up`/`Down` gain a variadic option; existing calls compile unchanged.
- Behaviour: migrations now fail after the lock timeout instead of waiting forever on a lock.
- Schema: only additive changes in 000015 if any.

## Success Criteria and Acceptance Criteria

- Every FR has a named, passing test; no **pending** remains in PRD §5 except items owned by M3/M4.
- `make gate` green; integration tests green against PostgreSQL; `go test -cover ./migrate/` ≥ 90%.
- Up/down/up passes with 000015; `pg_dump --schema-only` after `up` then `down 1` equals the dump at 000014.

## Edge Cases

- Nullable composite foreign keys: `(team_id, secret_id)` with `team_id NULL` (service-level notification
  channels) is not checked by PostgreSQL (MATCH SIMPLE), so a service-level channel can name any secret id.
  FR-015 tests it; a fix goes in 000015.
- Policies other than `app_team_scope` (work orders, export bundles, catalog `app_write`) need their own
  zero-row assertions; FR-001 iterates over `app_team_scope` tables and lists the others explicitly.
- Partition drop on a month boundary: tests use fixed dates relative to `date_trunc('month', now())`.
- Concurrency: FR-002 uses 50 separate connections, not goroutines on one connection.
- Lock timeout: must not apply to the advisory-lock wait (two migrators queue by design, DB-US-7).

## Open Questions

| Id | Question | Resolution path |
|---|---|---|
| SQ-1 | Should a service-level channel be able to hold a credential reference at all? | Decide in Step 3 (implementation-notes); default: refuse until a service-level secret store exists |
| SQ-2 | Default `lock_timeout` value | Decide in Step 3; 10 s proposed, overridable by `WithLockTimeout` |

## Risks and Mitigation

| Risk | Mitigation |
|---|---|
| A new test reveals a real defect | Fix forward in 000015 with TDD; document in data-model |
| Local server is PostgreSQL 16, CI is 17 | Use only features in both; CI is authoritative |
| `lock_timeout` too short for a slow apply on a busy cluster | Lock timeout bounds waiting, not statement time; default 10 s and overridable |

## Timeline and Milestones

Single run (dev-flow 14 steps), M0 release `v0.13.0`.

## References

- PRD: `enterprise-agent-factory-service-db-PRD.md` (root) and snapshot `specs/261121-db-feature-complete/enterprise-agent-factory-service-db-PRD.md`
- Root ADR-014, ADR-015 (D23–D56); root `docs/contracts/database-contract.md`
