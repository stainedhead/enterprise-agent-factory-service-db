# Spec: team orchestration agent and model access (`-db`, migration 000022)

Source: [orchestration-and-model-access-PRD.md](orchestration-and-model-access-PRD.md); contract: root `docs/contracts/database-contract.md` section 7.3.

## Goals

1. Every team has exactly one orchestration agent from the commit that creates the team (DB-US-58).
2. The Web UI and Web API of that agent are `off`, `private` or `public`, within a team limit; the tool is Paperclip or Buzz (DB-US-59).
3. `afs_edge` learns the effective level and its reasons from one function (DB-US-60).
4. Agents and pools use all, one or several models, narrowing service, team, agent (DB-US-61).
5. 1.0.1 services keep working against the new schema until 2.0.0.

## Non-goals

The API, edge, gateway, reconciler, CLI and console. Approval workflows for exposure or models (above the service and team level). Buzz's REST API (none; both Buzz surfaces N/A). Removing the 1.0.1 columns and functions (2.0.0).

## Acceptance criteria

The "Proven by" lines of the four stories in the change PRD; each names a test that passes in `make test-db`.

## Constraints

- Migration 000022 only; none of 000001 to 000021 is edited; one transaction; online-safe; lock impact stated in its header.
- No secret value in any column; `afs_edge` keeps no table privilege.
- PostgreSQL 17 features only; local runs on 16.15.
