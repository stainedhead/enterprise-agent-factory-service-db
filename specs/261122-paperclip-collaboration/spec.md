# Spec: Paperclip team collaboration (migration 000020)

Created 2026-11-22. Source PRD: `specs/261122-paperclip-collaboration/paperclip-collaboration-PRD.md` (extract of
the living `enterprise-agent-factory-service-db-PRD.md`, DB-41 to DB-52, DB-US-44 to DB-US-57).
Contract: root `docs/contracts/database-contract.md` §7.2 (v1.3.1).

## 1. Executive summary

Migration `000020_paperclip_collaboration` gives each team an optional collaboration agent (Paperclip) and the
database objects the public `afs-edge` component, `afs-api` and `afs-reconciler` need to run it: an agent role
with a one-per-team rule, two desired-state tables, a fact table of access counts, a table-less `afs_edge`
role with ten `SECURITY DEFINER` functions, server-side sessions with a single-use handoff, a managed-secrets
guard, reconciler key functions, a hostname hold and a swarm extension. It is additive, transactional and
reversible for local use.

## 2. Problem statement

The public edge must read routes, bindings and settings and write access counts with no table privilege;
Paperclip's secrets must live in the managed hierarchy without opening a bypass; and the one-collaboration-agent
rule must hold even if the API forgets it. Contract §7.2 contradicts the schema at 000019 in six places, which
the PRD resolved as DB-D1 to DB-D16.

## 3. Goals and non-goals

Goals: every object of contract §7.2 and DB-US-44 to DB-US-57, each criterion proven by a named test against
PostgreSQL. Non-goals: application logic, Kubernetes and AWS resources, creating Secrets Manager secrets,
the edge's TLS and WAF, RDS provisioning, any change to 000001 to 000019 files.

## 4. Functional requirements

| FR | Requirement | PRD |
|---|---|---|
| FR-001 | `agents.role`, one live collaboration agent per team, role immutable, collaboration guard, template `capabilities` and its guard | DB-US-44 |
| FR-002 | `team_collaboration` with generation trigger, grants, RLS, revision and change feed | DB-US-45 |
| FR-003 | `agent_collaboration` with guard trigger, link-state rules, column grants | DB-US-46 |
| FR-004 | Role `afs_edge`, `collab_routes()`, `collab_settings()`, `identity_providers.collab_client_id` and `collab_client_secret_arn` | DB-US-47 |
| FR-005 | `team_collaborator` role, `teams.may_expose_collaboration`, seven `collab.*` settings and their constraint | DB-US-48 |
| FR-006 | `secrets.managed_by`, `secrets_managed_guard`, reserved names, registered origin, binding refusal | DB-US-49 |
| FR-007 | Cleanup on collaboration agent delete | DB-US-50 |
| FR-008 | `collab_principal()` and `collab_principal_key()` | DB-US-51 |
| FR-009 | `collaboration_access`, `record_collab_access`, partition function, retention, `emit_collab_secret_detected` | DB-US-52 |
| FR-010 | `collab_hostname_holds` and triggers | DB-US-53 |
| FR-011 | One safe, reversible migration with pre-flight and lock-impact header | DB-US-54 |
| FR-012 | Edge sessions and handoff tables and four functions, purge | DB-US-55 |
| FR-013 | `record_collab_agent_key`, `remove_collab_agent_key`, `record_collab_board_key` | DB-US-56 |
| FR-014 | Swarm templates with a collaboration agent; boot secrets for it | DB-US-57 |

## 5. Non-functional requirements

PostgreSQL 17 features only; online-safe (constant defaults, `NOT VALID` then `VALIDATE`); one transaction;
`afs_edge` no table privilege; function latency targets as working figures (principal lookups p99 under 5 ms,
`collab_routes()` under 20 ms, 1000-row access batch under 100 ms), confirmed in the M3 load test; `migrate`
coverage at least 90%.

## 6. System architecture

Layer: database only (schema `afs`, roles, migration, `migrate` tests). New: 3 tables with RLS and triggers
(`team_collaboration`, `agent_collaboration`, `collab_hostname_holds`), 1 partitioned fact table
(`collaboration_access`), 2 grant-less tables (`collab_edge_sessions`, `collab_edge_handoffs`), about 20
functions. Modified: `agents`, `agent_templates`, `teams`, `secrets`, `identity_providers`, `role_bindings`,
`api_keys`, `service_settings`, `drop_partitions_older_than`, `instantiate_work_order_team`,
`record_work_order_secret`, `schema_version` grants, `binding_respects_scope`. See `architecture.md`.

## 7. Scope of changes

Create: `migrations/000020_paperclip_collaboration.up.sql` and `.down.sql`, `migrate/collaboration_000020_test.go`.
Modify: `bootstrap/roles.sql`, `migrate/feature_complete_test.go` (`seedOtherTeams`, retention test),
`migrate/service_access_test.go` and `migrate/schema_version_test.go` (role lists), `docs/data-model.md`,
`docs/*.md`, `README.md`, `AGENTS.md`, `user-docs/`. No dependency changes.

## 8. Breaking changes

None for `-restapi` at runtime: every change is additive or new. Schema: `secrets_origin_check` widens,
`role_bindings_role_check` and `api_keys_role_check` widen, `teams_guardrail_guard` is recreated with one more
column. Operators must run `afs-migrate bootstrap-roles` before 000020 (the migration refuses otherwise, `55000`).

## 9. Success and acceptance criteria

Every *Proven by* test of the PRD exists and passes against PostgreSQL; `make gate` and `make test-db` green;
up/down/up passes and the down leaves the catalog equal to 000019's; `docs/data-model.md` updated.

## 10. Risks and mitigation

| Risk | Mitigation |
|---|---|
| Local PostgreSQL is 16, CI is 17 | Use no feature newer than 17 (and none newer than 16 is needed); CI is the authoritative run; recorded in implementation-notes |
| Trigger ordering on `secrets` and `agents` | Name triggers so alphabetical order gives the intended sequence; tested |
| Down migration drift | A catalog comparison test (columns, constraints, triggers, policies, grants, functions) |
| Edge function over-exposure | Catalog-driven test: no relation privilege, exactly ten executable functions, `SECURITY DEFINER`, fixed `search_path` |
| Contract text drifting from the schema | Root contract follow-ups recorded in implementation-notes |

## 11. Timeline

All of 000020 ships in milestone C1 as one minor release. C2 to C4 only consume more of it.

## 12. References

- Source PRD: `specs/261122-paperclip-collaboration/paperclip-collaboration-PRD.md`
- Living PRD: `enterprise-agent-factory-service-db-PRD.md`
- Root contracts: https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/database-contract.md
