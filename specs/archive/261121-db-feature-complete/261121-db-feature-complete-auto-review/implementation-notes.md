# Implementation notes: db-feature-complete-auto-review

**Date:** 2026-11-21

Purpose: decisions, edge cases and deviations for the review fixes. Update after each task.

## Technical Decisions

- **F1 (R-1, P1).** `resolve` returns `ErrNegativeLockTimeout` and `Up`/`Down` return it before the
  advisory lock or any SQL (the test checks the tracking table was never created). A positive value
  below 1 ms becomes 1 ms. `afs-migrate` keeps its own clearer flag message.
- **F2 (R-2).** `cost_reconciliations_amounts_check` added to 000015 itself: 000015 is unmerged, so
  changing it is allowed and keeps one migration for the release. The down migration drops it; the schema
  after down still equals 000014 exactly (pg_dump compared after every change).
- **F6 (R-4, RQ-1 answered: now).** Only 13 fixtures used short digests, so the full-digest checks went
  into 000015 rather than a later release. Fixtures now use 64-character digests; the one test that needs
  a malformed digest keeps it. The storage-class test that used `x@sha256:a` got a full digest so it still
  fails for the storage class, not the image.
- **F4 (R-6).** `TestRunCommands` drives every `afs-migrate` command against a fresh database built from
  `AFS_TEST_DATABASE_URL` (path replaced), plus an unreachable server; command coverage 17.9% → 82.1%.
- **F3, F5.** No-op removed; data-only load guidance in `user-docs/operations.md` and the data model.

Each fix was checked against the AGENTS.md design checklist before the next: migration transactional and
online-safe (NOT VALID then VALIDATE), down reverses it, no secret column, data model updated.

## TDD log

| Test | First run | Fix |
|---|---|---|
| `TestLockTimeoutBounds` | Red: build failed (no `ErrNegativeLockTimeout`) | F1 |
| `TestPendingGuards/billed cost…` negative amounts | Red: accepted | F2 |
| `TestPendingGuards/an image is pinned to a full digest` | Red: `@sha256:abc`, uppercase and suffixed digests accepted | F6 |
| `TestRunCommands` | Green (behaviour existed, untested) | — |

## Edge Cases & Solutions

- Replacing every short digest with 64 `a`s collided with the template test's allowed digest A; legacy
  rows there use 64 `e`s so they stay outside the template's list.

## Deviations from Plan

- None. No finding was deferred.

## Lessons Learned
