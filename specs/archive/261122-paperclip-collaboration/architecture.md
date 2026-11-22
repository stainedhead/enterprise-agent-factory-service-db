# Architecture: paperclip-collaboration

2026-11-22. Status: Draft, then Final at the end of implementation.

## Overview

All changes live in schema `afs`. The edge never touches a table: it calls `SECURITY DEFINER` functions owned by the
migration owner with `SET search_path = pg_catalog, afs`. The reconciler gets table grants only where the contract
says, plus five functions. The API keeps its existing grants plus column grants on the two new desired-state tables.

```
afs-edge (afs_edge) --EXECUTE--> collab_routes, collab_settings, collab_principal(_key), record_collab_access,
                                 emit_collab_secret_detected, collab_handoff_*, collab_session_*  (no table privilege)
afs-api  (afs_app)  --RLS-----> team_collaboration, agent_collaboration (column grants), secrets (user|afs rows)
afs-reconciler      --grant---> secrets (paperclip rows only, guard), agent_collaboration link columns
                    --EXECUTE-> record/remove_collab_*_key, ensure_collaboration_access_partition, purge_collab_edge_sessions
```

## Component architecture and layer responsibilities

- Constraints and indexes enforce shape (`agents_role_check`, `agents_team_collaboration_uq`, secrets checks).
- BEFORE triggers enforce cross-row rules and who-may-write rules (`agents_collaboration_guard`,
  `agent_collaboration_guard`, `secrets_managed_guard`, hostname refusal) and bump `generation` (DB-D1).
- AFTER triggers do the cleanup and the hostname hold; both are `SECURITY DEFINER` so the actor's missing privileges do not matter.
- Functions are the only interface for credentials and facts.

## Data flow

Create collaboration agent (API tx): agent row, `team_collaboration`, three boot secrets. Reconcile: route table read by edge
through `collab_routes()`; link state written by reconciler; key rows through the three functions. Delete: agent
`deleting` fires cleanup, which removes the route row and disconnects links in the same transaction.

## Architectural decisions

1. **Trigger ordering.** Same-event row triggers fire in name order. `secrets_managed_guard` sorts before
   `secrets_managed_path`, so the guard runs first for every write; the replaced `secrets_managed_path` derives path
   and name for `paperclip` rows itself. On `agents`, `agents_collaboration_guard` runs before `agents_touch`. Outcomes are proven by tests.
2. **Principal is the session user.** Guards read `current_user` (as `team_guardrail_guard` does); `SECURITY DEFINER`
   functions run as the owner, which the guards treat as allowed.
3. **No policy for session tables.** RLS enabled, no policy, no grant: owner-run functions only.
4. **Facts without foreign keys.** `collaboration_access` outlives teams, like `agent_activity`.
5. All PRD decisions DB-D1 to DB-D19 apply.

## Integration points

`-restapi` `afs-edge`, `afs-reconciler`, `afs-api`; root contract §7.2; `docs/data-model.md`.
