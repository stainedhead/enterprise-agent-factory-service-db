# Tasks: paperclip-collaboration

2026-11-22. Status: In progress. Progress: 17/18 (T18 is step 4).

Each task: Red test, Green migration section, refactor. Duration S (under an hour) or M.

| ID | Task | Depends | Dur | Acceptance | State |
|---|---|---|---|---|---|
| T1 | `bootstrap/roles.sql` adds `afs_edge`; role lists in tests | none | S | roles.sql idempotent; header lists role | Done |
| T2 | Migration 000020 skeleton, pre-flight (`55000`), header with lock impact; test file scaffold | T1 | S | `TestMigration000020/requires afs_edge 55000` | Done |
| T3 | DB-US-44 agents role, unique index, guard, capabilities, template guard | T2 | M | `TestCollaborationAgent`, `TestAgentTemplateCapabilities` | Done |
| T4 | DB-US-48 role checks, `may_expose_collaboration`, settings and constraint | T2 | M | `TestRoleCollaborator`, `TestTeamGuardrailMayExpose`, `TestServiceSettingRanges` | Done |
| T5 | DB-US-47 identity provider collab client columns | T2 | S | `TestIdentityProviderCollabClient` | Done |
| T6 | DB-US-45 `team_collaboration` | T3 | M | `TestTeamCollaboration` | Done |
| T7 | DB-US-46 `agent_collaboration` | T6 | M | `TestAgentCollaboration` | Done |
| T8 | DB-US-50 cleanup trigger | T7 | S | `TestCollaborationCleanup` | Done |
| T9 | DB-US-53 hostname hold | T3 | S | `TestHostnameHold` | Done |
| T10 | DB-US-49 managed secrets | T3 | M | `TestManagedSecrets` | Done |
| T11 | DB-US-56 key functions | T7, T10 | M | `TestCollabKeyFunctions` | Done |
| T12 | DB-US-47 edge role, `collab_routes`, `collab_settings` | T5, T6 | M | `TestEdgeRole` | Done |
| T13 | DB-US-51 principals | T12 | M | `TestEdgePrincipal`, `TestEdgePrincipalKey` | Done |
| T14 | DB-US-52 access table, functions, partitions, retention, event | T12 | M | `TestCollaborationAccess`, partitions, retention | Done |
| T15 | DB-US-55 sessions and handoff | T12 | M | `TestEdgeSessions` | Done |
| T16 | DB-US-57 swarm collaboration | T10, T6 | M | `TestSwarmCollaboration` | Done |
| T17 | DB-US-54 down, catalog comparison, up/down/up, checksums, fixture, isolation tests | T3..T16 | M | `TestMigration000020`, isolation tests | Done |
| T18 | Docs: data-model, README, AGENTS, user-docs, ADR | T17 | M | DoD checklist | Pending (step 4) |
