# Implementation notes: paperclip-collaboration-auto-review

## Technical decisions
- FR-001: guard now reads the whole agent row and refuses `deleting`, `deleted` or `deleted_at` set (`55000`). A missing agent is still left to the foreign key.
- FR-003: the conflict is detected by a lookup before the insert; the `ON CONFLICT DO NOTHING` stays for the same-secret case. A repeat call writes an audit row each time (as before).
- FR-002: the pre-flight test executes the migration's up SQL directly in a transaction after `ALTER ROLE ... RENAME`, then rolls back. It no longer goes through `migrate.Up` for the refused case.
- FR-004/005: one definition of "live team" everywhere: state not in (`deleting`, `deleted`) and `deleted_at IS NULL`. Suspended teams stay readable (RQ-1 default). `collab_session_revoke` is unchanged, so a session of a dead team can still be revoked.
- FR-006: only the atomicity test was missing (unknown-team skipping was already tested); the data model now states both.
- Verified: `git log origin/main -- migrations/000020*` is empty, so editing 000020 in place changes no applied checksum.

## Deferred
- Recorded Info items (no handoff rate limit, purge without an index, per-role statement timeout) are for the edge, the M3 load test and the Terraform in `-restapi`.

## Parked
| Item | Why |
|---|---|
| Run against `postgres:17` | Not available locally (PostgreSQL 16.15); CI |
