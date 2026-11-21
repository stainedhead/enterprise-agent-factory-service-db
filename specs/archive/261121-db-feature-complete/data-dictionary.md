# Data dictionary: db-feature-complete

**Purpose:** the data structures this feature touches. The full dictionary is `docs/data-model.md`.

## Entities
- Tables under test: `log_destinations`, `notification_channels`, `swarm_templates`, `idempotency_keys`,
  `teams`, `usage_events`, `agent_activity`, `external_traffic`, `cost_daily`, `cost_reconciliations`,
  `api_keys`, `audit_log`, `pool_handoffs`, `work_order_repos`, `config_revisions`.

## Value objects
- SQLSTATE codes: `42501`, `23514`, `23503`, `23505`, `55000`, `22023`, `55P03`.

## Interfaces
- `migrate.Option`, `migrate.WithLockTimeout(time.Duration)`, `migrate.DefaultLockTimeout`.

## Enumerations
- Teardown reasons: `expired`, `cap_reached`, `work_complete`.

## API request/response types
- None (no HTTP surface in this repository).
