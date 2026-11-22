# Plan: paperclip-collaboration

2026-11-22. Status: Planning.

## Development approach

One migration file in one transaction, developed test first. The test file `migrate/collaboration_000020_test.go` is written
group by group (Red), the matching section of the migration added (Green), then refactored. A migration is append-only once
merged but not yet merged here, so the file grows during development; the checksum guard only matters from the merge.

## Phase breakdown

| Phase | Content | Stories |
|---|---|---|
| A | Role bootstrap, migration skeleton with pre-flight, test scaffolding, role lists | DB-US-54 (part), DB-US-47 (role) |
| B | Existing-table changes: agents role and guards, capabilities, teams guardrail, role checks, settings, provider client | DB-US-44, 48, 47 (client) |
| C | New desired-state tables, cleanup, hostname hold | DB-US-45, 46, 50, 53 |
| D | Secrets guard, key functions | DB-US-49, 56 |
| E | Edge functions, access facts, sessions | DB-US-47, 51, 52, 55 |
| F | Swarm collaboration | DB-US-57 |
| G | Down migration, catalog comparison, up/down/up, fixture extension, docs | DB-US-54 |

## Critical path

A, then B (the agents role and capabilities underpin C), then C, D; E depends on C and B; F depends on C and D; G last.

## Testing strategy

Integration tests against PostgreSQL (`AFS_TEST_DATABASE_URL`), subtests named as in the PRD's *Proven by* lines.
Catalog-driven tests for the edge role. A catalog snapshot comparison for the down migration. Existing tests stay green.

## Rollout strategy

Operators run `afs-migrate bootstrap-roles`, then `afs-migrate up`. One minor release tag for `-restapi`.

## Success metrics

All PRD tests pass; `make gate` and `make test-db` green; coverage of `migrate` at least 90%.
