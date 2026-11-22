# enterprise-agent-factory-service-db

The RDS PostgreSQL database for the Enterprise Agent Factory Service: schema and migrations for all
desired state, database roles and row-level security, real-time spend reservation functions, config
revisions and an append-only audit log. Ships as a Go module (`migrations`, `migrate`) used by the REST
API, plus the `afs-migrate` command.

Part of [enterprise-agent-factory-service](https://github.com/stainedhead/enterprise-agent-factory-service).
Data dictionary: [docs/data-model.md](docs/data-model.md).

**Status:** feature complete (schema 000019) — migrations `000001_core_schema`, `000002_roles_and_rls`, `000003_agent_singleton_secret_paths`, `000004_agent_persistent_storage`, `000005_configuration_values`, `000006_cross_account_roles`, `000007_external_systems`, `000008_reporting_activity`, `000009_identity_providers_team_guardrails`, `000010_cost_tags_team_idp_price_sync`, `000011_tag_snapshots_reports_isolation_idempotency`, `000012_swarms_ephemeral_teams_work_orders`, `000013_hardening_spend_periods_change_feed`, `000014_agent_templates_export_bundles`, `000015_feature_complete_gaps` and `000016_service_access_functions`, `000017_schema_version_cli_client_id`, `000018_report_rollups_followups` and `000019_work_order_secrets`, with integration tests that prove every acceptance criterion of the [PRD](enterprise-agent-factory-service-db-PRD.md) this repository can prove.

## Use

```bash
# once per cluster, as the RDS master user
psql "$ADMIN_URL" -f bootstrap/roles.sql       # or: afs-migrate --database-url "$ADMIN_URL" bootstrap-roles

# apply migrations, as a member of afs_owner
go run ./cmd/afs-migrate --database-url "$AFS_DATABASE_URL" up
```

From Go (as `afs-api` does at startup):

```go
migs, _ := migrate.Load(migrations.FS)
n, err := migrate.Up(ctx, conn, migs) // each migration waits at most 10 s for a lock (migrate.WithLockTimeout)
```

## Operator guides

- [Getting started](user-docs/getting-started.md): roles, migrations, checks, tests
- [Configuration reference](user-docs/configuration.md): `afs-migrate` options, session and runtime settings, limits
- [Operations](user-docs/operations.md): scheduled jobs, releases, backups and restore, troubleshooting

## Test

```bash
make gate       # unit tests, lint, build
make db-up      # postgres:17 in Docker on :55432
make test-db    # up/down/up, checksums, constraints, spend reservation, row-level security, change feed
make cover      # migrate coverage (set AFS_TEST_DATABASE_URL for the integration tests)
```

Contributor and agent rules: [AGENTS.md](AGENTS.md). Why this repository exists: [INTENT.md](INTENT.md).
