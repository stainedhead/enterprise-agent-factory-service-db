# Research

- **PostgreSQL 17 versus the local 16.15.** Nothing used is newer than 16. CI proves 17.
- **Trigger ordering.** BEFORE triggers fire by name; the level sync and the exposure check must see each other's results, so they are named `team_collaboration_a_levels_sync` and `team_collaboration_b_exposure_check`; the pool reserved-name check sorts before the name-uniqueness check so its error is the one reported.
- **`SECURITY DEFINER` hides `current_user`.** A guard that keys on `afs_app` must be `SECURITY INVOKER` (ADR-010); a guard that also reads tables `afs_app` cannot see is a second, definer, function.
- **A `WHEN` clause cannot reference `NEW` on a `DELETE` trigger**, so the settings notify trigger filters keys inside its function.
- **Deferred constraint triggers** give "at least one orchestration agent per new team" and "selected models are non-empty and contain the default" without ordering the API's inserts.
- **`pg_notify` payloads** for `service_settings` are `service_settings::<key>` for `models.*` and `orchestration.*` only, so the reconciler and gateway re-read just what they use.
- **Column grants.** `afs_gateway` gets `SELECT (key, value)` on `service_settings`; descriptions stay hidden.
