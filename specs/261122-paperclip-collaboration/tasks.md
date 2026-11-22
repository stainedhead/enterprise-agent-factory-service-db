# Tasks: paperclip-collaboration

2026-11-22. Status: In progress. Progress: 0/18.

Each task: Red test, Green migration section, refactor. Duration S (under an hour) or M.

| ID | Task | Depends | Dur | Acceptance |
|---|---|---|---|---|
| T1 | `bootstrap/roles.sql` adds `afs_edge`; role lists in tests | none | S | roles.sql idempotent; header lists role |
| T2 | Migration 000020 skeleton, pre-flight (`55000`), header with lock impact; test file scaffold | T1 | S | `TestMigration000020/requires afs_edge 55000` |
| T3 | DB-US-44 agents role, unique index, guard, capabilities, template guard | T2 | M | `TestCollaborationAgent`, `TestAgentTemplateCapabilities` |
| T4 | DB-US-48 role checks, `may_expose_collaboration`, settings and constraint | T2 | M | `TestRoleCollaborator`, `TestTeamGuardrailMayExpose`, `TestServiceSettingRanges` |
| T5 | DB-US-47 identity provider collab client columns | T2 | S | `TestIdentityProviderCollabClient` |
| T6 | DB-US-45 `team_collaboration` | T3 | M | `TestTeamCollaboration` |
| T7 | DB-US-46 `agent_collaboration` | T6 | M | `TestAgentCollaboration` |
| T8 | DB-US-50 cleanup trigger | T7 | S | `TestCollaborationCleanup` |
| T9 | DB-US-53 hostname hold | T3 | S | `TestHostnameHold` |
| T10 | DB-US-49 managed secrets | T3 | M | `TestManagedSecrets` |
| T11 | DB-US-56 key functions | T7, T10 | M | `TestCollabKeyFunctions` |
| T12 | DB-US-47 edge role, `collab_routes`, `collab_settings` | T5, T6 | M | `TestEdgeRole` |
| T13 | DB-US-51 principals | T12 | M | `TestEdgePrincipal`, `TestEdgePrincipalKey` |
| T14 | DB-US-52 access table, functions, partitions, retention, event | T12 | M | `TestCollaborationAccess`, partitions, retention |
| T15 | DB-US-55 sessions and handoff | T12 | M | `TestEdgeSessions` |
| T16 | DB-US-57 swarm collaboration | T10, T6 | M | `TestSwarmCollaboration` |
| T17 | DB-US-54 down, catalog comparison, up/down/up, checksums, fixture, isolation tests | T3..T16 | M | `TestMigration000020`, isolation tests |
| T18 | Docs: data-model, README, AGENTS, user-docs, ADR | T17 | M | DoD checklist |
