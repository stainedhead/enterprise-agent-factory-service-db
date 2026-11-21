# Technical details

- PostgreSQL 17 (RDS). Tested in CI against `postgres:17`.
- Migrations are embedded (`migrations.FS`) and applied by `migrate.Up` under a PostgreSQL advisory lock,
  each in its own transaction, tracked in `public.afs_schema_migrations` with a SHA-256 checksum.
- Each migration transaction sets `lock_timeout` locally (`migrate.DefaultLockTimeout`, 10 s;
  `migrate.WithLockTimeout`; `afs-migrate --lock-timeout`), with `set_config(..., true)` so it applies to
  that transaction only and never to the advisory-lock wait (ADR-005).
- `usage_events`, `agent_activity` and `external_traffic` are range-partitioned by month with a default
  partition; the reconciler creates next month's partitions and drops those older than 13 months.
- Backups: RDS automated backups with PITR (35 days) and cross-region, cross-account snapshot copies
  through AWS Backup (configured in `-restapi/deploy/terraform`).

## Tests

| File | Covers |
|---|---|
| `migrate/runner_test.go` | `Load`, `Up`, `Down`, `Version` error paths; lock timeout |
| `migrate/migrate_test.go` | Up/down/up, checksums, constraints, RLS, per-feature behaviour (000001–000012) |
| `migrate/hardening_test.go` | 000013: guards, spend periods, change feed, retention, runtime settings |
| `migrate/templates_exports_test.go` | 000014: agent templates, export bundles, repository owners |
| `migrate/feature_complete_test.go` | Catalog-driven proofs (every team table's isolation, every revision table's feed), the 000015 fixes and the remaining PRD criteria |
| `cmd/afs-migrate/main_test.go` | Argument checks |

Integration tests need `AFS_TEST_DATABASE_URL` and create one database per test. The catalog-driven tests
(`TestCrossTeamWritesChangeNothing`, `TestEveryRevisionTableAnnouncesChanges`,
`TestEveryTeamTableHasRowLevelSecurity`, `TestEveryViewIsSecurityInvoker`) discover tables from
`pg_class`, `pg_policies` and `pg_trigger`, so a new table is covered, or fails until the shared fixture
`seedOtherTeams` gives it rows. `migrate` coverage: 96.5% (`cmd/afs-migrate` 82.1%) (`make cover` with the database URL set).
