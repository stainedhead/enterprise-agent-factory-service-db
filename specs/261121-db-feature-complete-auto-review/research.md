# Research: db-feature-complete-auto-review

**Date:** 2026-11-21 · **Source:** review PRD in this directory

## Research Questions
1. What does PostgreSQL do with `lock_timeout = '-1'`? (expected: `22023`, out of range)
2. How many fixtures use a short `@sha256:` digest (effort for R-4)?
3. Does `session_replication_role = replica` skip ordinary BEFORE triggers on COPY? (expected: yes)

## Industry Standards
- `pg_restore --disable-triggers` for data-only restores.

## Existing Implementations
- `afs-migrate` already refuses a negative `--lock-timeout`.

## API Documentation
- PostgreSQL `lock_timeout`: integer milliseconds, 0 disables, range 0..INT_MAX.

## Best Practices
- Validate options before taking locks or opening transactions.

## Open Questions
- RQ-1 answered: now (13 fixtures).

## Answers
1. `22023` (invalid value): hence the early check.
2. 13 fixtures.
3. Yes: ordinary triggers do not fire in `replica` mode.

## References
- Review PRD §3.
