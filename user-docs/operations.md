# Operations

## Scheduled jobs

The database holds no scheduler. The reconciler and the gateway call these functions; an operator only
needs to know they exist and what a failure looks like.

| Function | Caller | When | If it does not run |
|---|---|---|---|
| `afs.ensure_usage_partition(month)`, `afs.ensure_activity_partition(month)`, `afs.ensure_traffic_partition(month)` | reconciler | Monthly, before the month starts | Rows land in the `_default` partitions; nothing is lost, queries get slower |
| `afs.ensure_collaboration_access_partition(month)` | reconciler | Monthly, before the month starts (000020) | Counts land in the default partition; nothing is lost |
| `afs.purge_collab_edge_sessions()` | reconciler | Every few minutes (000020) | Expired collaboration sessions and handoff codes stay; they are never honored |
| `afs.drop_partitions_older_than(13)` | reconciler | Monthly | Old monthly partitions stay; storage grows |
| `afs.rollup_reports_recent(2)` | reconciler | Every 5 to 15 minutes (7 days nightly for late samples) | Service-wide and 90-day activity and traffic reports read the daily rollups; they go stale, the five-minute tables stay correct |
| `afs.release_expired_reservations()` | reconciler | Every minute | Held spend from a dead gateway is not returned until it runs |
| `afs.purge_idempotency_keys()` | reconciler | Periodically | Expired keys stay; no functional effect |
| `afs.ensure_spend_counter(budget, period_start)` | gateway, reconciler | Per call / period start | The gateway opens the period itself on the first call |

Retention keeps the current month plus 13 whole months of `usage_events`, `agent_activity`,
`external_traffic` and `collaboration_access`; default partitions are never dropped. `audit_log` is never deleted.

To run a job by hand, connect as the reconciler login:

```sql
SELECT afs.ensure_usage_partition(date_trunc('month', now() + interval '1 month')::date);
SELECT afs.drop_partitions_older_than(13);   -- returns the names of the dropped partitions
```

## Applying a new release

1. Read the release notes and the new migration's header: it states its lock impact.
2. Apply in a quiet period, or let `afs-api` apply it on rollout. Each migration waits at most the lock
   timeout (10 s by default) for its locks.
3. Check `afs-migrate version`.

Migrations are forward-only in production. Fix a problem with a new migration, not with `down`.

### Upgrading to 1.1.0 (migration 000022)

Release 1.1.0 embeds migration 000022 (team orchestration agent and model access). `-restapi` 1.1.0 applies it at startup;
run `afs-migrate up` first if you prefer to apply it yourself.

- **Upgrade window.** Run it when the edge sees little traffic. The one blocking step is rebuilding the primary key of
  `afs.collaboration_access` (it gains the `exposure` column), which holds an `ACCESS EXCLUSIVE` lock on that table
  for the length of a scan of at most weeks of request counts. While it runs, `afs-edge` cannot record counts (it
  retries) and nothing else is blocked. Every other statement takes row locks or brief metadata locks.
- **No new role.** 000022 needs no `bootstrap-roles` run; the `afs_edge` role from 000020 is enough.
- **Version skew.** 1.0.1 services keep working against the 000022 schema: the old columns (`web_ui_enabled`,
  `rest_api_enabled`, `may_expose_collaboration`, `agents.model_id`, `team_models.inference_profile_arn`) and the
  functions `collab_routes()` and `collab_settings()` stay in step until 2.0.0. A 1.0.1 `-restapi` cannot create a
  team's orchestration agent or an orchestration-tool change; roll `-restapi` forward to 1.1.0 soon after.
- **Existing data.** Agents with role `collaboration` become `orchestration` (versions unchanged). Existing teams get
  model access `selected` (their `team_models` rows stay the rule) and a limit of `public` or `off` from
  `may_expose_collaboration`. Existing teams are not required to have an orchestration agent; new ones are.
- **After the upgrade.** Set `orchestration.tools` (the Paperclip template and image repository are filled in when
  exactly one template had the `paperclip` capability; Buzz needs both set by hand) and, for private endpoints,
  `orchestration.private_base_domain`.
- **Down.** `afs-migrate down 1` is for local use. It renames the role back and drops the new tables; Buzz rows,
  model selections and inference-profile rows made under 1.1.0 are lost.

## Backups and restore

Backups are RDS automated backups with point-in-time recovery, Multi-AZ, and a cross-account snapshot
copy, configured by the Terraform in `-restapi` (RPO 5 minutes, RTO 1 hour). To restore:

1. Restore the instance to a point in time (RDS console or `aws rds restore-db-instance-to-point-in-time`)
   into a new instance with the same parameter group.
2. Run `afs-migrate version` against it: it must print the version the old instance had.
3. Point the services at the new endpoint. The reconciler converges Kubernetes and AWS from the restored
   desired state; no manual SQL is needed.

### Data-only loads

A full `pg_dump` / `pg_restore` creates triggers after it loads the data, so nothing changes. A
**data-only** load (`pg_restore --data-only`, `COPY`, a logical copy) fires the schema's triggers on every
row: `api_keys` would get a new `created_at` and old keys would fail the 90-day check, and derived values
such as `cost_reconciliations.status` would be recomputed. Run data-only loads as the schema owner with
triggers off:

```bash
pg_restore --data-only --disable-triggers --schema=afs -d "$AFS_OWNER_URL" afs.dump
# or, in psql before COPY:  SET session_replication_role = replica;
```

A full restore drill is scheduled for milestone M4 and this section will be updated with its results.

## Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `apply 0000NN_…: … (SQLSTATE 55P03)` | The migration waited longer than the lock timeout for a table lock held by a long transaction | Find the blocker (`SELECT pid, state, query_start, query FROM pg_stat_activity WHERE state <> 'idle'`), let it finish, rerun. Raise `--lock-timeout` only if the blocking work is expected |
| `applied migration changed` | A migration file was edited after it was applied | Restore the original file; ship the change as a new migration |
| `migration versions must be contiguous` | A migration file is missing from the build | Rebuild from the tagged release |
| `role afs_edge does not exist` (`55000`) applying 000020 | `bootstrap-roles` was not run for this release | Run `afs-migrate bootstrap-roles` as the administrator, then `afs-migrate up`; nothing was applied |
| `permission denied` (`42501`) from a service | The LOGIN user is not in the right group role, or row-level security refused the row | Check `\du <login>`; for `afs_app`, check the session settings |
| Integration tests all skip | `AFS_TEST_DATABASE_URL` is not set | Export it in the same shell as `go test` |
