# Plan: db-feature-complete-auto-review

**Date:** 2026-11-21 · **Status:** Planning

## Development Approach
TDD per finding, P1 first, then P2 by effort; review each against the AGENTS.md checklist.

## Phase Breakdown
1. R-1. 2. R-2. 3. R-5, R-6. 4. R-3. 5. R-4 decision.

## Critical Path
R-1 (P1).

## Testing Strategy
Table-driven unit and integration tests; `pg_dump` comparison for 000015 down.

## Rollout Strategy
Part of `v0.13.0`.

## Success Metrics
All P1 fixed; P2 fixed or deferred with a reason.
