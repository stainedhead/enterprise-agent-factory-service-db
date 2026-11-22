# Spec: paperclip-collaboration-auto-review

Source PRD: `specs/261122-paperclip-collaboration-auto-review/paperclip-collaboration-auto-review-PRD.md`. Parent spec: `specs/archive/261122-paperclip-collaboration/`.

## Executive summary
Fix six review findings (3 P1, 3 P2) in the unreleased migration 000020 and its tests. No P0.

## Problem statement
The review of 000020 found a guard gap, a test that can poison a shared cluster, a silent no-op in a reconciler function, two hardening gaps in the edge session functions and an undocumented batch behaviour.

## Goals / Non-goals
Goals: close FR-1 to FR-6 without changing signatures or column names. Non-goals: a new migration (000020 is unreleased), changes to other repositories, new features, real AWS testing.

## Functional requirements
- FR-001 (P1) `team_collaboration_guard` refuses a dead collaboration agent (`55000`).
- FR-002 (P1) The pre-flight test runs in a rolled-back transaction; no `ALTER ROLE ... RENAME` outside a transaction.
- FR-003 (P1) `record_collab_agent_key` raises `23505` when the target is bound to a different secret; idempotent otherwise.
- FR-004 (P2) `collab_handoff_create` raises `23503` for a team without `team_collaboration` or deleting/deleted.
- FR-005 (P2) `collab_session_get`, `collab_principal`, `collab_principal_key` return no row for a deleting/deleted team.
- FR-006 (P2) Test and document `record_collab_access` batch atomicity and unknown-team skipping.

## Non-functional requirements
Compatibility (signatures unchanged), safety (down restores the 000019 catalog; up/down/up), performance (one primary-key lookup added), security (no secret value; `afs_edge` keeps no table privilege), quality (coverage >= 90%, gate green).

## System architecture
SQL only. Affected: `migrations/000020_paperclip_collaboration.up.sql` (functions `team_collaboration_guard`, `record_collab_agent_key`, `collab_handoff_create`, `collab_session_get`, `collab_principal`, `collab_principal_key`), `migrate/*_000020_test.go`, `docs/data-model.md`.

## Scope of changes
Modify the up migration in place; the down migration needs no change (all are function bodies of objects it already drops). Modify tests and docs.

## Breaking changes
None for released consumers (000020 is unreleased).

## Acceptance criteria
The numbered criteria of each FR in the source PRD; `make gate`, `make test-db` green; coverage >= 90%.

## Risks and mitigation
Editing an unreleased migration changes its checksum: no environment has applied it (not merged), so no checksum conflict. Mitigation: confirm with `git log origin/main -- migrations/000020*` that main has no 000020.

## Timeline
R1 (P1) then R2 (P2), same day.

## References
Source PRD (above); `-db` PRD DB-41 to DB-52.
