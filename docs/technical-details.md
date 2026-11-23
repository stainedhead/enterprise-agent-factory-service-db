# Technical details

- PostgreSQL 17 (RDS). Tested in CI against `postgres:17`.
- Migrations are embedded (`migrations.FS`) and applied by `migrate.Up` under a PostgreSQL advisory lock,
  each in its own transaction, tracked in `public.afs_schema_migrations` with a SHA-256 checksum.
- Each migration transaction sets `lock_timeout` locally (`migrate.DefaultLockTimeout`, 10 s;
  `migrate.WithLockTimeout`; `afs-migrate --lock-timeout`), with `set_config(..., true)` so it applies to
  that transaction only and never to the advisory-lock wait (ADR-005).
- `usage_events`, `agent_activity`, `external_traffic` and (000020) `collaboration_access` are range-partitioned by month with a default
  partition; the reconciler creates next month's partitions and drops those older than 13 months.
- The collaboration edge connects as a login that is a member of `afs_edge` (000020). The role has no table
  privilege; it calls ten `SECURITY DEFINER` functions with a pinned `search_path`, and the partition helpers
  (`ensure_*_partition`) are revoked from `PUBLIC` so it cannot reach them. Sessions and handoff codes are stored
  as SHA-256 hashes only.
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
| `migrate/work_order_secrets_000019_test.go` | 000019: `record_work_order_secret` (allowed, idempotent, refusals, grant, isolation) and the event envelope of `instantiate_work_order_team` |
| `migrate/service_access_test.go` | 000016: API key lookup, workload resolution, team directory, remediation team instantiation, pool deletion grant, audit and outbox insert policies |
| `migrate/collaboration_000020_test.go`, `collaboration_secrets_000020_test.go`, `collaboration_edge_000020_test.go`, `migration_000020_test.go` | 000020: collaboration agent and template capabilities, `team_collaborator`, guardrails and `collab.*` settings, `team_collaboration` and `agent_collaboration`, cleanup and hostname hold, managed secrets and key functions, the `afs_edge` role and its functions, access counts and partitions, sessions, swarm collaboration, row-level security, and the migration itself (pre-flight, existing rows, catalog comparison after down) |
| `migrate/orchestration_000022_test.go`, `orchestration_exposure_000022_test.go`, `model_access_000022_test.go`, `orchestration_edge_000022_test.go`, `migration_000022_test.go` | 000022: the orchestration agent and its constraints, exposure levels and limit, tool change, settings ranges and aliases, snapshots, model access at every level, inference profiles, edge routes and access counts, Buzz secrets, up/down/up with catalog equality, the upgrade of 1.0.1 data |
| `cmd/afs-migrate/main_test.go` | Argument checks |

Integration tests need `AFS_TEST_DATABASE_URL` and create one database per test. The catalog-driven tests
(`TestCrossTeamWritesChangeNothing`, `TestEveryRevisionTableAnnouncesChanges`,
`TestEveryTeamTableHasRowLevelSecurity`, `TestEveryViewIsSecurityInvoker`) discover tables from
`pg_class`, `pg_policies` and `pg_trigger`, so a new table is covered, or fails until the shared fixture
`seedOtherTeams` gives it rows. `migrate` coverage: 96.5% (`cmd/afs-migrate` 82.1%) (`make cover` with the database URL set).
