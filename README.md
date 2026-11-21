# enterprise-agent-factory-service-db

The RDS PostgreSQL database for the Enterprise Agent Factory Service: schema and migrations for all
desired state, database roles and row-level security, real-time spend reservation functions, config
revisions and an append-only audit log. Ships as a Go module (`migrations`, `migrate`) used by the REST
API, plus the `afs-migrate` command.

Part of [enterprise-agent-factory-service](https://github.com/stainedhead/enterprise-agent-factory-service).
Data dictionary: [docs/data-model.md](docs/data-model.md).

**Status:** schema v1 — migrations `000001_core_schema`, `000002_roles_and_rls`, `000003_agent_singleton_secret_paths` and `000004_agent_persistent_storage`, with integration tests.

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
n, err := migrate.Up(ctx, conn, migs)
```

## Test

```bash
make gate       # unit tests, lint, build
make db-up      # postgres:17 in Docker on :55432
make test-db    # up/down/up, checksums, constraints, spend reservation, row-level security
```

Contributor and agent rules: [AGENTS.md](AGENTS.md). Why this repository exists: [INTENT.md](INTENT.md).
