# Spec: db-feature-complete-auto-review

**Created:** 2026-11-21 · **Source PRD:** `specs/261121-db-feature-complete-auto-review/enterprise-agent-factory-service-db-auto-review-PRD.md`

## Executive Summary
Fix the findings of the Step 5 code review of `feat/db-feature-complete`: one P1 (lock-timeout option
bounds) and five P2 items, before the branch merges.

## Problem Statement
The new `WithLockTimeout` option misbehaves for negative and sub-millisecond values; the derived
reconciliation status trusts unchecked amounts; the new `api_keys` trigger affects data-only loads; the
image check is weaker than the template guard; a test has a no-op; `afs-migrate` is barely covered.

## Goals / Non-Goals
Goals: R-1 to R-6 per the review PRD. Non-goals: changes to 000001–000014, new product behaviour.

## Functional Requirements

| FR | Finding | Requirement |
|---|---|---|
| FR-001 | R-1 (P1) | Negative lock timeout → error before any SQL; 0 < d < 1 ms → 1 ms; 0 disables |
| FR-002 | R-2 (P2) | `cost_reconciliations` amounts ≥ 0 (`23514`), in 000015, NOT VALID then VALIDATE |
| FR-003 | R-3 (P2) | Operations guide and data model document data-only loads with the trigger |
| FR-004 | R-4 (P2) | Images pinned to a full `sha256:<64 hex>` digest, or deferral recorded |
| FR-005 | R-5 (P2) | No-op removed from `TestCrossTeamWritesChangeNothing` |
| FR-006 | R-6 (P2) | `afs-migrate` integration test of every command |

## Non-Functional Requirements
As the review PRD §3 NFR table: gate green, coverage ≥ 90%, online-safe, reversible, no secrets.

## System Architecture
`migrate/migrate.go`, `cmd/afs-migrate/`, `migrations/000015_*`, `user-docs/operations.md`,
`docs/data-model.md`, `migrate/feature_complete_test.go`.

## Scope of Changes
As above. 000015 is unmerged and may change; nothing else in `migrations/` changes.

## Breaking Changes
`Up`/`Down` return an error for a negative lock timeout (previously failed inside the transaction).

## Success Criteria and Acceptance Criteria
Each FR has a passing test (FR-003 is docs); `make gate` and the integration tests green; 000015 down
restores 000014 exactly.

## Risks and Mitigation
R-4 touches fixtures across most test files: decide by effort (RQ-1), defer with a reason if large.

## Timeline and Milestones
Same run, before Step 11.

## References
Review PRD in this directory; original spec `specs/archive/261121-db-feature-complete/`.
