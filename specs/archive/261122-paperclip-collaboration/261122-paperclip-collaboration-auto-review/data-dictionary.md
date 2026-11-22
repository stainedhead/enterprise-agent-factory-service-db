# Data dictionary: paperclip-collaboration-auto-review
No new tables or columns. Changed behaviour only:

| Object | Change | Error |
|---|---|---|
| `afs.team_collaboration_guard()` | refuses a deleting/deleted agent | `55000` |
| `afs.record_collab_agent_key` | refuses a conflicting binding | `23505` |
| `afs.collab_handoff_create` | refuses an unknown or deleting team, or one without `team_collaboration` | `23503` |
| `afs.collab_session_get`, `collab_principal`, `collab_principal_key` | no row for a deleting/deleted team | none |
