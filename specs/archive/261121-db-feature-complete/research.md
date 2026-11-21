# Research: db-feature-complete

**Date:** 2026-11-21 · **Source:** enterprise-agent-factory-service-db-PRD.md

## Research Questions

1. Which tables carry the `app_team_scope` policy, and do any team-owned tables use other `afs_app`
   policies whose cross-team UPDATE/DELETE behaviour differs (work orders, exports, idempotency keys)?
2. Does `log_destinations.secret_id` reference `secrets(team_id, id)` compositely, and is the
   `notification_channels` secret reference the same?
3. Which roles hold `SELECT` on `idempotency_keys.response_body`?
4. Does `teams_due_for_teardown` compute `expired` and `cap_reached` from data a test can seed (lifetime
   spend)?
5. What `lock_timeout` value suits a migration on RDS without hiding slow applies (OQ: default)?

## Industry Standards
- PostgreSQL `lock_timeout` (SQLSTATE `55P03 lock_not_available`) is the standard way to stop DDL
  queueing behind long transactions.

## Existing Implementations
- `migrate_test.go`, `hardening_test.go`, `templates_exports_test.go`: 160 passing (sub)tests at 000014.

## API Documentation
- pgx v5 `pgconn.PgError.Code` for SQLSTATE assertions.

## Best Practices
- Table-driven isolation tests generated from `pg_policies` so a new table is covered automatically.

## Open Questions
- See Research Questions; answers recorded below as research completes.

## References
- PRD §5, §6; `docs/data-model.md`.
