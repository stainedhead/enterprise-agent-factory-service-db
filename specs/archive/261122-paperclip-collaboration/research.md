# Research: paperclip-collaboration

2026-11-22. Source PRD: `paperclip-collaboration-PRD.md` (this directory).

## Research questions

1. Which existing objects does 000020 replace, and what do they look like at 000019 (`team_guardrail_guard`, `drop_partitions_older_than`, `binding_respects_scope`, `secrets_managed_path`, `instantiate_work_order_team`, `record_work_order_secret`)? Answered below from the catalog.
2. How do trigger names order on `secrets` and `agents`, so the new guards run where they must (before the path trigger, before touch)?
3. What does `afs_edge` need so `LISTEN` works, given NOTIFY needs no privilege in PostgreSQL?
4. Can `INSERT ... ON CONFLICT DO UPDATE` work under column grants (needs `INSERT` and `UPDATE` on every column in the SET list and the conflict target)?
5. What breaks when a table in `afs` with `team_id` and RLS and no grant is added (`TestCrossTeamWritesChangeNothing` demands a fixture row)?
6. What is the exact ARN regex of 000009 and how do `secrets_arn_matches_path` and the path trigger interact for `registered` rows?

## Findings

- Q1: the existing function bodies are read from the live catalog in the implementation (`pg_get_functiondef`), then replaced with `CREATE OR REPLACE` plus the extra condition. `drop_partitions_older_than` filters parents by `relname IN (...)`; add `collaboration_access`.
- Q2: PostgreSQL fires same-event row triggers in name order. Guards on `secrets` are named `secrets_a_managed_guard` style where order matters; `secrets_managed_path` already exists. Decision recorded in architecture.md.
- Q3: `LISTEN` and `pg_notify` need no privilege. `afs_edge` can LISTEN with only a login; the test proves a notification arrives.
- Q4: Column grants apply to the `ON CONFLICT` target (needs `SELECT` on the key) and the SET list needs `UPDATE (col)`; PRD grants satisfy it.
- Q5: RLS tables with a `team_id` column are enumerated by that test; the new tables need seed rows for team B. `collab_edge_*` have RLS enabled and no grant, so a team caller gets `42501`, which the test accepts.
- Q6: 000009 ARN pattern: `^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$` (identity_providers). `secrets` checks a looser LIKE plus `secrets_arn_matches_path`.

## Industry standards, existing implementations, API documentation, best practices

PostgreSQL documentation: `SECURITY DEFINER` with a fixed `search_path`, `REVOKE ... FROM PUBLIC` on functions, partitioned tables with a default partition, `pg_notify`. The repository's own earlier migrations (000013 for guards and the change feed, 000016 for service access functions, 000019 for event envelopes) are the pattern to follow.

## Open questions

DB-OQ-10, DB-OQ-11, DB-OQ-12: decided in `implementation-notes.md` (defaults of the PRD).

## References

Root `docs/contracts/database-contract.md` §7.2; `docs/data-model.md`; migrations 000003, 000009, 000012, 000013, 000016, 000019.
