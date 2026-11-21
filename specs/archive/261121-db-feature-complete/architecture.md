# Architecture: db-feature-complete

**Date:** 2026-11-21 · **Status:** Draft

## Architecture Overview
Schema in `migrations/`, applied by `migrate` (Go) under an advisory lock, one transaction per migration.

## Component Architecture
- `migrate`: Load, Up, Down, Version. This feature adds per-transaction `SET LOCAL lock_timeout`.
- `migrations/000015_*`: fix-forward for gaps found by tests (if any).

## Layer Responsibilities
- SQL: invariants, RLS, grants. Go: ordering, locking, checksum guard, lock timeout.

## Data Flow
`afs-api` / `afs-migrate` → `migrate.Up` → `pg_advisory_lock` → per migration: `BEGIN; SET LOCAL lock_timeout; <up>; INSERT tracking; COMMIT`.

## Sequence Diagrams
Not needed beyond the data flow above.

## Integration Points
`-restapi` imports `migrate` at a tag; the variadic option keeps its call compiling.

## Architectural Decisions
- See implementation-notes.md (TD-*) and ADR-005 in `docs/architectural-decision-record.md` once written.
