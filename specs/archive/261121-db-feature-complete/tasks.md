# Tasks: db-feature-complete

**Date:** 2026-11-21 · **Status:** Complete

## Progress Summary
10/10 tasks complete

| Id | Task | FRs | Deps | Est. | Acceptance | Status |
|---|---|---|---|---|---|---|
| T1 | `migrate` lock timeout option + error-path unit/integration tests | FR-018, FR-019 | — | 45 min | `55P03` test passes; coverage ≥ 90% | Done |
| T2 | Table-driven cross-team UPDATE/DELETE over `app_team_scope` tables | FR-001 | — | 30 min | zero rows for every table | Done |
| T3 | Log destinations and notification channels isolation and secret FK | FR-015 | — | 30 min | all DB-US-34 criteria tested | Done |
| T4 | Swarm templates reads and zero-row writes; reconciler idempotency column grant | FR-016, FR-003 | — | 20 min | tests pass | Done |
| T5 | Guards and constraints: tag message, teardown reasons, handoffs, pool grouping, merged PR, SLA override, unpinned image, over_threshold, key expiry, audit TRUNCATE and pool | FR-004, FR-006–FR-008, FR-011–FR-014 | — | 60 min | tests pass | Done |
| T6 | Change feed table-driven; retention for activity and traffic; deleted team history; concurrent reservations; lock headers | FR-002, FR-005, FR-009, FR-010, FR-017 | — | 60 min | tests pass | Done |
| T7 | Migration 000015 for gaps found by T2–T6 | — | T2–T6 | 30 min | up/down/up, pg_dump equal after down | Done |
| T8 | PRD Proven-by lines and status to 000015 | — | T1–T7 | 20 min | no repo-owned **pending** left | Done |
| T9 | Quality gate and integration run | — | all | 10 min | green | Done |
| T10 | X-DB-1..6 from `-restapi` (coordinator request): migration 000016, `migrate/service_access_test.go`, PRD DB-US-38..43 and DB-39, data model, ADR-008, root database contract | — | T9 | 90 min | red then green; pg_dump equal after down; gate green | Done |
