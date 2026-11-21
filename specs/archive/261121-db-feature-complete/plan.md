# Plan: db-feature-complete

**Date:** 2026-11-21 · **Status:** Planning

## Development Approach
TDD. For every FR: write the test (red if the schema is wrong, otherwise a proof that passes first time and
is checked to fail for the right reason by a temporary mutation where practical), fix in 000015, refactor.

## Phase Breakdown
1. `migrate` lock timeout and error-path tests (FR-018, FR-019).
2. Isolation proofs (FR-001, FR-015, FR-016, FR-003).
3. Guard and constraint proofs (FR-004, FR-006–FR-008, FR-011–FR-014).
4. Feed, retention, deleted team, concurrency, lock headers (FR-002, FR-005, FR-009, FR-010, FR-017).
5. Fix-forward migration 000015 for anything found.
6. PRD Proven-by lines and docs.

## Critical Path
Phase 2 and 3 tests may reveal defects that gate 000015.

## Testing Strategy
Integration tests against PostgreSQL via `AFS_TEST_DATABASE_URL`; unit tests for `Load` with `fstest.MapFS`.

## Rollout Strategy
Release `v0.13.0` (tag by maintainer); `-restapi` bumps `go.mod`.

## Success Metrics
0 pending proofs owned by this repo; coverage ≥ 90%; gate green.
