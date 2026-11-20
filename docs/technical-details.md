# Technical details

- PostgreSQL 17 (RDS). Tested in CI against `postgres:17`.
- Migrations are embedded (`migrations.FS`) and applied by `migrate.Up` under a PostgreSQL advisory lock,
  each in its own transaction, tracked in `public.afs_schema_migrations` with a SHA-256 checksum.
- `usage_events` is range-partitioned by month with a default partition.
- Backups: RDS automated backups with PITR (35 days) and cross-region, cross-account snapshot copies
  through AWS Backup (configured in `-restapi/deploy/terraform`).
