# Research: paperclip-collaboration-auto-review
- `agents.state` values include `deleting` and `deleted`; `deleted_at` is set when deleted.
- A role rename is transactional in PostgreSQL (`ALTER ROLE ... RENAME` inside `BEGIN ... ROLLBACK`).
- `afs.agent_secret_bindings` has a unique key `(agent_id, target)`.
- `afs.teams.state`: active, suspended, deleting, deleted.
- Verified: `collab_handoff_create` accepts a non-existent team id on the current branch.
