# Getting started

This guide takes an operator from an empty PostgreSQL 17 database to the current AFS schema, and shows
how to check it. The schema is in `migrations/` (000001–000022); the tables, functions and roles are
described in [docs/data-model.md](../docs/data-model.md).

## 1. Prerequisites

- PostgreSQL 17. In AWS this is RDS PostgreSQL 17, provisioned by the Terraform in
  `enterprise-agent-factory-service-restapi/deploy/terraform`.
- A connection as the cluster's administrator (RDS: the master user) for the one-time role bootstrap.
- A login that is a member of `afs_owner` for migrations.
- Go 1.27 if you run `afs-migrate` from source (`go run ./cmd/afs-migrate`), or the built binary
  (`make build` writes `bin/afs-migrate`).

## 2. Create the roles (once per cluster)

```bash
psql "$ADMIN_URL" -f bootstrap/roles.sql
# or
afs-migrate --database-url "$ADMIN_URL" bootstrap-roles
```

This creates seven `NOLOGIN` group roles and is safe to run again: `afs_owner`, `afs_app`,
`afs_reconciler`, `afs_gateway`, `afs_billing`, `afs_readonly`, `afs_edge`. It sets no passwords. Give each service
its own LOGIN user (on RDS, an IAM-authenticated `rds_iam` user) and grant it exactly one group:

```sql
CREATE USER afs_api_login;      GRANT rds_iam, afs_app        TO afs_api_login;
CREATE USER afs_reconcile_login; GRANT rds_iam, afs_reconciler TO afs_reconcile_login;
CREATE USER afs_gateway_login;  GRANT rds_iam, afs_gateway    TO afs_gateway_login;
CREATE USER afs_billing_login;  GRANT rds_iam, afs_billing    TO afs_billing_login;
CREATE USER afs_migrate_login;  GRANT rds_iam, afs_owner      TO afs_migrate_login;
```

If you are upgrading an existing cluster to the release that embeds migration 000020 (Paperclip team
collaboration), **run `afs-migrate bootstrap-roles` first**: migration 000020 needs the new `afs_edge` role and
stops with `55000` (`role afs_edge does not exist`) without it, leaving the schema unchanged. The role has no
privileges on any table. The collaboration edge gets its own LOGIN user:

```sql
CREATE USER afs_edge_login; GRANT rds_iam, afs_edge TO afs_edge_login;
```

Set connection limits on those LOGIN users as described in [configuration.md](configuration.md).

## 3. Apply the migrations

```bash
export AFS_DATABASE_URL="postgres://afs_migrate_login@<host>:5432/afs?sslmode=verify-full"
afs-migrate up          # prints: applied N migration(s)
afs-migrate version     # prints the highest applied version, 20 at this release
```

`afs-api` runs the same migrations at startup through the Go package, so in a normal deployment you only
bootstrap the roles; the first API pod applies the schema:

```go
migs, err := migrate.Load(migrations.FS)
n, err := migrate.Up(ctx, conn, migs) // or migrate.Up(ctx, conn, migs, migrate.WithLockTimeout(30*time.Second))
```

Several pods can start at once: an advisory lock lets one apply the migrations while the others wait and
then find nothing to do. Each migration runs in its own transaction and is recorded in
`public.afs_schema_migrations` with a SHA-256 checksum.

## 4. Check the result

```sql
SELECT version, name, applied_at FROM public.afs_schema_migrations ORDER BY version;
SELECT count(*) FROM pg_tables WHERE schemaname = 'afs';
SELECT key, value FROM afs.service_settings ORDER BY key;   -- seeded defaults
```

## 5. Run the tests against your own database (optional)

The integration tests create and drop one scratch database per test, so point them at a server where
the login may `CREATE DATABASE`, never at a shared or production server:

```bash
export AFS_TEST_DATABASE_URL="postgres://postgres:postgres@localhost:55432/postgres?sslmode=disable"
make db-up      # postgres:17 in Docker on port 55432
make test-db    # up/down/up, constraints, row-level security, spend reservation, change feed
```

Without `AFS_TEST_DATABASE_URL` the integration tests are skipped and only the unit tests run.

Next: [configuration.md](configuration.md) for settings and limits, [operations.md](operations.md) for
the scheduled jobs, backups and troubleshooting.
