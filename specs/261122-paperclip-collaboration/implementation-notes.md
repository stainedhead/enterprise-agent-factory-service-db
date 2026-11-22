# Implementation notes: paperclip-collaboration

2026-11-22. Updated as work proceeds: decisions, edge cases, deviations, lessons.

## Environment

PostgreSQL 17 could not be installed: the PGDG apt repository is blocked by the sandbox proxy (HTTP 403) and Docker is
not available. The local run used PostgreSQL 16.15 from the Ubuntu archive (`initdb` in a scratch directory, port 55432,
password `postgres`, matching the Makefile `PG_URL`). Nothing newer than PostgreSQL 16 syntax is used, which is a subset of 17. **CI's `postgres:17` is the authoritative run.**

## Technical decisions

Resolved from the PRD's DB-D1 to DB-D19 as written. Added while implementing (also in the PRD's decisions list as DB-D20 to DB-D23):

- **Edge session tables get a `deny_all` policy** for `afs_app`, and the hostname hold table gets row-level security (DB-D20). Both were found by the catalog-driven `TestEveryTeamTableHasRowLevelSecurity` and `TestCrossTeamWritesChangeNothing`.
- **Group-binding provider match** (DB-D21). Found by writing the principal test: the 000010 guard forbids a provider on a team's group bindings.
- **Partition helpers revoked from PUBLIC** (DB-D22). Found by the "afs_edge can execute only its functions" test.
- **`record_revision` key for `team_collaboration`** (DB-D23).
- **Open questions kept at their PRD defaults:** DB-OQ-10 (no worker-deletion trigger), DB-OQ-11 (`linked` while disconnected is not refused), DB-OQ-12 (swarm collaboration model from the first pool).
- **Swarm collaboration image.** The contract gives only `templateId`. The image is `collaboration.image` when present, else the first pool's repository at the template's `current_image_digest`. No pool and no image: `23514`.
- **Principal `user_id`.** A group row carries the matched `users.id` of the caller, else NULL.
- **`cidr_list_ok` is strict:** host bits are rejected, so `10.0.0.1/24` is an error, `10.0.0.0/24` is accepted.
- **ARN rotation** for a non-user secret is allowed when the path derived from the ARN is unchanged (Paperclip rotates by creating a new version with a new suffix).
- **Trigger order.** `secrets_managed_guard` must fire before `secrets_managed_path`; PostgreSQL orders same-event triggers by name, and a test asserts the order.
- **Guard triggers keying on `current_user` are SECURITY INVOKER**; the SECURITY DEFINER functions (`record_work_order_secret`, the three key functions) run as the owner and pass. In tests the owner is the superuser `postgres`.
- **`afs_edge` callable set:** the ten edge functions plus `schema_version()`. `purge_collab_edge_sessions` is the reconciler's.
- **Down migration** restores the 000019 catalog exactly (compared in `TestMigration000020`: columns, constraints, indexes, triggers, function bodies and ACLs, policies, relation and column ACLs, schema ACL, settings). It deletes the rows only 000020 can create (`managed_by <> 'user'` secrets and their bindings, `team_collaborator` bindings and keys, the `collab.*` settings) and leaves the `afs_edge` role alone (roles are cluster-level).

## Edge cases and solutions

- A `FOUND` check after `PERFORM` inside the agent guard was unreliable across the trigger's branches; the guard uses an explicit `v_has` flag.
- A missing agent in `team_collaboration` is left to the foreign key (`23503`) instead of the guard's `23514`.
- Un-deleting a team must set `state` and `deleted_at` together (`teams_check1`); the hold test does so.
- `api_keys` rows cannot be inserted already expired; the edge test inserts valid rows and rewrites the dates with user triggers disabled.
- A multi-statement `Exec` with arguments is refused by the extended protocol; tests split statements.
- Cross-team inserts under row-level security surface as `23503` or `42501` depending on visibility; tests accept any error for an insert and assert that no row changed.

## Deviations from plan

- Tests are split into `collaboration_000020_test.go`, `collaboration_secrets_000020_test.go`, `collaboration_edge_000020_test.go` and `migration_000020_test.go` (the PRD names one file).
- `TestMigration000020` carries the pre-flight, existing-row, catalog and role-idempotency checks as subtests with the PRD's names grouped by purpose.

## Root contract follow-ups

For the root repository, not changed here:

1. **Notify payloads** (contract §7.2.2, §7.2.3): the third part is empty, not `<team_id>` or `<agent_id>` (DB-D2).
2. **Revision key of `team_collaboration`** is the `team_id` (DB-D23).
3. **Swarm collaboration model and image** (§7.2.9): the contract's "template's default resources and model" has no source for either; this repository takes the first pool's model and repository. Either the swarm spec should carry `collaboration.modelId` and `image`, or the agent template should carry a model (DB-OQ-12).
4. **Edge session tables** (§7.2.8) have an explicit `deny_all` policy for `afs_app`, not "RLS with no policy" (DB-D20).
5. **`PUBLIC` execute on the partition helpers** is revoked in 000020 (DB-D22); the database contract's role section should say the edge reaches only its listed functions.
6. **Team group bindings** carry no provider (000010); §7.2.5's wording on provider-specific group bindings applies to service-level bindings only (DB-D21).

## Parked

| Item | Why | Owner |
|---|---|---|
| Run against `postgres:17` | Not available locally; CI | CI |
| Load figures (p99 targets) | Need the M3 load test and a `db.r7g.large` | `-restapi` |

## Lessons learned

- Catalog-driven tests (row-level security on every team table, revision tables announce changes, cross-team writes) found three design gaps the hand-written tests did not; keep new tables in those catalogs from the start.
- Compare catalogs, not only behaviour, to prove a down migration.
- Run the red step against the previous schema once: every new test failed on 000019.
