# Configuration reference

## `afs-migrate`

```
afs-migrate [--database-url URL] [--lock-timeout 10s] up | down N | version | bootstrap-roles
```

| Option | Default | Meaning |
|---|---|---|
| `--database-url` | `AFS_DATABASE_URL` | PostgreSQL URL. Use `sslmode=verify-full` against RDS |
| `--lock-timeout` | `10s` | How long each migration may wait for a table lock before it fails with SQLSTATE `55P03`. `0` waits forever. It does not limit statement time or the wait for another migrator |

| Command | Does |
|---|---|
| `up` | Applies every pending migration in order |
| `down N` | Reverts the last `N` migrations. For local use and tests only: production is forward-only |
| `version` | Prints the highest applied version (0 when none) |
| `bootstrap-roles` | Runs `bootstrap/roles.sql` |

Exit status is 1 on any error; the message is printed to stderr.

From Go, `migrate.Up` and `migrate.Down` take the same option: `migrate.WithLockTimeout(d)`
(`migrate.DefaultLockTimeout` is 10 s).

## Session settings the services set

`afs-api` connects as a member of `afs_app` and sets, with `SET LOCAL` inside every transaction:

| Setting | Value | Effect |
|---|---|---|
| `afs.actor` | principal id (`usr_…`, `key_…`) | Written to `created_by`, revisions and audit; scopes idempotency keys |
| `afs.service_admin` | `on` / `off` | Service admins see and write every team |
| `afs.team_ids` | comma-separated team ids | The teams the caller may see; unset means none (fail closed) |
| `afs.security_operator` | `on` / unset | Security operators read and write every work order |

A transaction that sets nothing sees no team data.

## Runtime settings (`afs.service_settings`)

Service admins change these through the API. Values are JSON and checked by the database:

| Key | Default | Allowed |
|---|---|---|
| `api.idempotency_key_ttl_seconds` | 3600 | 60–604800 |
| `api.cors_origins` | `[]` | array of `https://host[:port]` |
| `billing.variance_alert_pct` | 5 | 0–100; drives `cost_reconciliations.status` |
| `gateway.reservation_ttl_seconds` | 900 | 60–3600 |
| `reports.idle_cpu_millicores` | 50 | 1–4000 |
| `egress.denied_spike_threshold` | 20 | 1–100000 |
| `teams.ephemeral_max_days` | 90 | 1–365 |
| `work_orders.sla_warning_hours` | 48 | 1–720 |
| `work_orders.notification_channel_id` | null | null or a service-level email channel |
| `secrets.path_prefix` | `afs` | managed Secrets Manager path prefix |

The full list, with the remaining keys, is in [docs/data-model.md](../docs/data-model.md).

## Database parameters and limits

Set in the RDS parameter group and on the LOGIN users (Terraform in `-restapi`):

| Item | Value |
|---|---|
| `rds.force_ssl` | `1` |
| `shared_preload_libraries` | includes `pg_stat_statements` |
| `log_min_duration_statement` | `500` (ms) |
| Connection limit, `afs-api` login | 100 |
| Connection limit, `afs-gateway` login | 100 |
| Connection limit, `afs-reconciler` login | 20 |
| Connection limit, `afs-billing` login | 10 |
| Connection limit, `afs-migrate` login | 2 |
| Connection limit, each `afs_readonly` login | 10 |

```sql
ALTER ROLE afs_api_login CONNECTION LIMIT 100;
```

Keep the sum below 80% of `max_connections`. These are working values until the M3 load test confirms
them.
