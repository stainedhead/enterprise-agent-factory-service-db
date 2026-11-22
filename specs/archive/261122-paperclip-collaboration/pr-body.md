## Summary

Migration 000020, Paperclip team collaboration (-db PRD DB-41 to DB-52, DB-US-44 to DB-US-57; root database contract section 7.2, v1.3.1).

- **Agents and templates:** `agents.role` (worker or collaboration), one live collaboration agent per team, `agent_templates.capabilities` (`paperclip`), `team_collaborator` role for bindings and API keys.
- **Desired state:** `team_collaboration` (stored web UI and REST API choices, registration mode), `agent_collaboration` (worker links, link state), `teams.may_expose_collaboration`, seven `collab.*` settings, IdP collab client columns, cleanup trigger and 30-day hostname hold.
- **Secrets:** `secrets.managed_by`, reserved Paperclip names, registered origin, three reconciler key functions. No secret value anywhere.
- **Edge:** login-less role `afs_edge` with no table privilege and ten SECURITY DEFINER functions (routes, settings, principals, access counts, secret-detected event, sessions and one-time handoffs); `collaboration_access` (monthly partitions, 13-month retention).
- **Swarms:** `instantiate_work_order_team` and `record_work_order_secret` handle a swarm's collaboration agent.
- Down migration restores the 000019 catalog exactly (proved by a catalog comparison).

## Before you merge or release

- A DBA must run `afs-migrate bootstrap-roles` first so `afs_edge` exists; migration 000020 stops with `55000` otherwise and leaves the schema unchanged. Documented in `user-docs/`.
- `-restapi` adopts the next minor tag (chosen at release).

## Test plan

- [x] `make gate` (tidy, fmt, vet, golangci-lint 0 issues, race, build)
- [x] Full integration suite and race run against PostgreSQL 16.15 (Docker and PostgreSQL 17 were not available here); `migrate` coverage 96.5%
- [x] Every new test failed against schema 000019 first
- [ ] CI on `postgres:17` is the authoritative run

## Review

Code and design review: 0 P0, 3 P1, 3 P2, all fixed (live-agent guard, key binding conflict, dead-team handling in session, principal and handoff functions, a rolled-back pre-flight test, batch atomicity docs and test). See `specs/archive/261122-paperclip-collaboration/` (spec, review spec, notes, analysis).

## Root contract follow-ups (not changed here)

Notify payload id part is empty (DB-D2); `team_collaboration` revision key is the team id; swarm collaboration model and image have no contract source (first pool used); edge session tables carry a deny policy; PUBLIC execute revoked on the partition helpers; team group bindings carry no provider. Details in `implementation-notes.md`.

## Parked

Run on `postgres:17` (CI), load figures (M3 load test on `db.r7g.large`), real AWS and EKS behaviour.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01ScLWHEMWuWjKHYTmosrfTn
