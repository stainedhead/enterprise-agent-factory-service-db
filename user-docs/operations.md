# Operations

## Scheduled jobs

The database holds no scheduler. The reconciler and the gateway call these functions; an operator only
needs to know they exist and what a failure looks like.

| Function | Caller | When | If it does not run |
|---|---|---|---|
| `afs.ensure_usage_partition(month)`, `afs.ensure_activity_partition(month)`, `afs.ensure_traffic_partition(month)` | reconciler | Monthly, before the month starts | Rows land in the `_default` partitions; nothing is lost, queries get slower |
| `afs.drop_partitions_older_than(13)` | reconciler | Monthly | Old monthly partitions stay; storage grows |
| `afs.release_expired_reservations()` | reconciler | Every minute | Held spend from a dead gateway is not returned until it runs |
| `afs.purge_idempotency_keys()` | reconciler | Periodically | Expired keys stay; no functional effect |
| `afs.ensure_spend_counter(budget, period_start)` | gateway, reconciler | Per call / period start | The gateway opens the period itself on the first call |

Retention keeps the current month plus 13 whole months of `usage_events`, `agent_activity` and
`external_traffic`; default partitions are never dropped. `audit_log` is never deleted.

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

## Backups and restore

Backups are RDS automated backups with point-in-time recovery, Multi-AZ, and a cross-account snapshot
copy, configured by the Terraform in `-restapi` (RPO 5 minutes, RTO 1 hour). To restore:

1. Restore the instance to a point in time (RDS console or `aws rds restore-db-instance-to-point-in-time`)
   into a new instance with the same parameter group.
2. Run `afs-migrate version` against it: it must print the version the old instance had.
3. Point the services at the new endpoint. The reconciler converges Kubernetes and AWS from the restored
   desired state; no manual SQL is needed.

A full restore drill is scheduled for milestone M4 and this section will be updated with its results.

## Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `apply 0000NN_…: … (SQLSTATE 55P03)` | The migration waited longer than the lock timeout for a table lock held by a long transaction | Find the blocker (`SELECT pid, state, query_start, query FROM pg_stat_activity WHERE state <> 'idle'`), let it finish, rerun. Raise `--lock-timeout` only if the blocking work is expected |
| `applied migration changed` | A migration file was edited after it was applied | Restore the original file; ship the change as a new migration |
| `migration versions must be contiguous` | A migration file is missing from the build | Rebuild from the tagged release |
| `permission denied` (`42501`) from a service | The LOGIN user is not in the right group role, or row-level security refused the row | Check `\du <login>`; for `afs_app`, check the session settings |
| Integration tests all skip | `AFS_TEST_DATABASE_URL` is not set | Export it in the same shell as `go test` |
