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
| `work_orders.cost_center` | unset | string, 1–100 characters; cost center of a remediation team whose swarm template names none |
| `work_orders.owner_email` | unset | string `local@domain`; owner of a remediation team whose swarm template names none |
| `secrets.path_prefix` | `afs` | managed Secrets Manager path prefix |
| `collab.base_domain` | null | Read-only alias of `orchestration.public_base_domain` until 2.0.0 (000020, 000022) |
| `collab.public_endpoints` | true | Read-only alias of `orchestration.public_endpoints` until 2.0.0 |
| `collab.allowed_source_cidrs` | `[]` | up to 100 CIDRs (no host bits) |
| `collab.session_ttl_minutes` | 480 | 15–1440 |
| `collab.content_scan` | `block` | `block`, `warn` or `off` |
| `collab.max_body_mb` | 25 | 1–100 |
| `collab.denied_spike_threshold` | 50 | 1–100000 |

Orchestration and model access (000022). A service admin writes them through the API; the database checks every value.

| Key | Default | Range |
|---|---|---|
| `orchestration.tools` | Paperclip enabled and default, Buzz disabled | object per tool: `enabled`, `default` (exactly one enabled default), `templateId` (an agent template with the `orchestration` and `tool:<tool>` capabilities), `imageRepository`, and the tool's fixed profile. A tool is unusable until its template and repository are set |
| `orchestration.public_base_domain` | the old `collab.base_domain` (null on a new database) | null or a DNS name; public hostnames are `<slug>.<domain>` |
| `orchestration.private_base_domain` | null | null or a DNS name reachable only from the private network |
| `orchestration.public_endpoints`, `orchestration.private_endpoints` | true | boolean master switches |
| `orchestration.default_limit` | `public` if a base domain was set, else `private` | `off`, `private`, `public`; the limit of a new team |
| `orchestration.default_web_ui_exposure`, `orchestration.default_web_api_exposure` | the default limit, `off` | `off`, `private`, `public`; not above the default limit |
| `orchestration.default_resources` | `{"cpu": "1", "memory": "4Gi"}` | object with string `cpu` and `memory` |
| `orchestration.default_volume_gib` | 20 | whole number 10–1000 |
| `models.service_access` | `all` on a new database; `selected` when models already exist | `all` or `selected` (only models with `enabled = true`) |
| `models.default_team_access` | `all` | `all` or `selected` |
| `models.default_team_models` | `[]` | up to 100 existing model ids |
| `models.default_model_id` | null | null or an existing model id |

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
