# AGENTS.md

Rules for AI agents and human contributors working in this repository.

## Project summary

`enterprise-agent-factory-service-db` is the database of the Enterprise Agent Factory Service: the RDS
PostgreSQL schema that holds all desired state (teams, people and role bindings, agents, identities,
secret references, models and prices, budgets and spend, usage and costs, delivery settings, work orders),
plus reconcile status, the event outbox, config revisions and the append-only audit log. It also owns the
database roles and row-level security, and ships the migrations as a Go module with a runner
(`migrate`) and a command (`afs-migrate`).

It is one child of the [enterprise-agent-factory-service](https://github.com/stainedhead/enterprise-agent-factory-service)
root (PRD and `docs/solution-design.md`). Its only code consumer is
[enterprise-agent-factory-service-restapi](https://github.com/stainedhead/enterprise-agent-factory-service-restapi),
which imports this module at a released tag and connects as the roles defined here.

Status: feature complete (migrations 000001–000018) with integration tests for up/down/up, checksums,
constraints, spend reservation, row-level security, the change feed and the service access functions; every PRD criterion provable here
names its test.

## Toolchain

| Tool | Version | Notes |
|---|---|---|
| PostgreSQL | 17 | RDS PostgreSQL 17 in AWS; `postgres:17` in CI. Do not use features newer than 17 |
| Go | 1.27.4 | Pinned by `go.mod` |
| pgx | v5.13.0 | Driver for `migrate` and tests |
| golangci-lint | v2.15.0 | `make lint` |

## Layout

```
bootstrap/roles.sql       cluster-level NOLOGIN roles, run once by a DBA before migrations
bootstrap/embed.go        exposes RolesSQL
migrations/NNNNNN_name.up.sql / .down.sql
migrations/embed.go       embeds all migrations (migrations.FS)
migrate/                  Load, Up, Down, Version; advisory lock; checksum guard
migrate/*_test.go         integration tests (need AFS_TEST_DATABASE_URL); feature_complete_test.go holds
                          the catalog-driven isolation and change-feed tests and their shared fixture
cmd/afs-migrate/          CLI: up | down N | version | bootstrap-roles
docs/data-model.md        data dictionary: every table, its purpose and its access
```

## Schema rules

- **Everything lives in schema `afs`.** The tracking table is `public.afs_schema_migrations`.
- **Migrations are append-only once merged.** Never edit a merged migration; the runner refuses a changed
  checksum. Fix forward with a new migration. Versions are contiguous six-digit numbers.
- **Forward-only in production.** Every migration still has a `.down.sql` for local use and tests.
- **Each migration runs in one transaction.** Do not use statements that cannot run in a transaction
  (`CREATE INDEX CONCURRENTLY`, `ALTER TYPE … ADD VALUE` before 12); if needed, put them in their own
  migration and document why.
- **Online-safe changes.** Add nullable columns or columns with constant defaults; backfill in batches in
  application code; add `NOT NULL` / constraints as `NOT VALID` then `VALIDATE`; never rewrite a large
  table in one step. Note lock impact in the migration header.
- **Ids** are application-generated prefixed ULIDs (`team_…`, `agt_…`) with a `CHECK (afs.ulid_ok(id, '<prefix>'))`.
- **Desired-state tables** carry `version` (bumped by `afs.touch_row()` trigger, used for `If-Match`),
  `created_at/by`, `updated_at`, and a revision trigger (`afs.record_revision()`). Spec-bearing tables also
  carry `generation`.
- **No secret values. Ever.** Secrets are Secrets Manager ARNs plus metadata. A test fails if a column
  name looks like it holds a value (`value`, `password`, `plaintext`, `secret_string`).
- **Money is `numeric`**, never float. USD only.
- **Enumerations are `text` + `CHECK`**, not PostgreSQL enums, so values can change in a transaction.
- **Team scoping.** Every team-owned table has `team_id`, and cross-table references within a team use
  composite foreign keys `(team_id, id)` so a row can never point at another team's row.
- **Row-level security.** Every team-owned table enables RLS with a policy for `afs_app` using
  `afs.caller_sees_team(team_id)`. New team-owned tables must be added to the RLS list in a migration and
  covered by the isolation test.
- **Privileges are least-privilege per role** (`afs_app`, `afs_reconciler`, `afs_gateway`, `afs_billing`,
  `afs_readonly`). Grant columns, not whole tables, where a role only updates part of a row.
- **Audit is append-only.** `afs.audit_log` rejects UPDATE, DELETE and TRUNCATE by trigger.
- Update `docs/data-model.md` in the same change as any schema change.

## TDD: Red → Green → Refactor

All three phases are mandatory. For schema work, "red" is an integration test that fails against the
current schema (missing table, constraint not enforced, role can read across teams), then the migration
that makes it pass.

- Every constraint gets a test that proves the rejected case.
- Every RLS policy gets a test that proves another team's rows are invisible and unwritable.
- `migrate` keeps ≥ 90% coverage.
- A new team-owned table must get rows in `seedOtherTeams` (`migrate/feature_complete_test.go`), or
  `TestCrossTeamWritesChangeNothing` fails.

## Quality gate

All of these must pass before every commit:

```bash
make gate        # tidy, fmt-check, vet, golangci-lint, race tests (unit), build afs-migrate
make db-up       # local postgres:17 in Docker (or point PG_URL at any PostgreSQL 17)
make test-db     # integration tests against a real database: up/down/up, constraints, RLS
```

CI runs the integration tests against a `postgres:17` service container.

## Code design review (before every commit)

- [ ] Migration is new (no edits to merged files), contiguous, transactional and online-safe
- [ ] `.down.sql` reverses it cleanly (up/down/up test passes)
- [ ] Team-owned table: `team_id`, composite FKs, RLS policy, grants per role, isolation test
- [ ] No column can hold a secret value
- [ ] `docs/data-model.md` updated
- [ ] Lock impact noted for any change to an existing large table

## Agent workflow

1. **Understand:** this repository's PRD (`enterprise-agent-factory-service-db-PRD.md`), the shared contracts in the root's `docs/contracts/`, the root PRD, solution design §8, `docs/data-model.md` and the active spec.
2. **Plan:** tables, constraints, policies and grants affected; consumers in `-restapi`.
3. **Red → Green → Refactor** with integration tests.
4. **Quality gate:** `make gate` and `make test-db`.
5. **Design review:** the checklist above.
6. **Document:** `docs/data-model.md`; tell `-restapi` the release tag to adopt.
7. **Update status:** `specs/<feature>/status.md` after every task. Mandatory.
8. **Final verify:** rerun the quality gate.

## Releases

Semver tags (`vX.Y.Z`). A new migration is a minor release. `-restapi` bumps its `go.mod` to adopt it.

## user-docs/ rule

`user-docs/` holds only files that help an operator provision and run the database: RDS setup, running
`bootstrap/roles.sql`, applying migrations, backups and restore. Not design or process material.

## Git

Clear commit messages that reference the spec directory when there is one. Never commit connection
strings with passwords, dumps or `.env` files. Work on a branch and open a pull request into `main`.

## Dev-Flow Skills

The following skills are available for the developer workflow. Invoke them with the listed slash command.

| Skill | Invocation | Purpose |
|---|---|---|
| `init-dev-flow` | `/init-dev-flow` | One-time repo setup; updates AGENTS.md |
| `create-prd` | `/create-prd [title]` | Interactive PRD authoring; writes to repo root |
| `review-prd` | `/review-prd [file]` | PRD quality review |
| `create-spec` | `/create-spec [prd-file]` | Spec creation from PRD; YYMMDD-prefixed directory |
| `review-spec` | `/review-spec [spec-dir]` | Spec quality review |
| `archive-spec` | `/archive-spec [spec-dir]` | Move completed spec to specs/archive/ |
| `implm-frm-prd` | `/implm-frm-prd [prd-file]` | Implement from PRD (11 steps) |
| `implm-frm-change-dtls` | `/implm-frm-change-dtls [ticket-or-desc]` | Implement from ticket or description (12 steps) |
| `implm-from-spec` | `/implm-from-spec [spec-dir]` | Full 11-step orchestrated implementation |
| `create-review` | `/create-review` | Code and design review artifact |
| `review-code` | `/review-code` | Code review of current branch |
| `write-flow-analys` | `/write-flow-analys [spec-dir]` | Process analysis report (final step of implm-from-spec) |

## Feature Specification Workflow

### Specs Directory Structure

All feature development uses the `specs/` directory for planning and tracking. Each feature gets its own subdirectory named `YYMMDD-<feature-name>/`.

**Directory Structure:**
```
specs/
└── YYMMDD-<feature-name>/
    ├── spec.md                  # Feature specification and requirements
    ├── status.md                # **CRITICAL**: Phase progress tracking (update after each task)
    ├── plan.md                  # Implementation plan and architecture decisions
    ├── tasks.md                 # Task breakdown and progress tracking
    ├── research.md              # Research findings, API docs, examples
    ├── data-dictionary.md       # Data structures, types, schemas
    ├── architecture.md          # System architecture and component design
    └── implementation-notes.md  # Implementation details, gotchas, decisions
```

### Progressive Documentation Build

Documents are created progressively as the feature develops:

**Phase 0: Initial Research (PRD/Feature Research)**
- Input: Product Requirement Document, RFC, or feature research
- Purpose: Understand the problem, gather requirements, identify constraints
- **Update status.md**: Mark Phase 0 as "In Progress"

**Phase 1: Specification (spec.md)**
- Define what the feature does, user requirements, acceptance criteria, goals and non-goals
- **Update status.md**: Mark Phase 0 complete, Phase 1 in progress

**Phase 2: Research & Data Modeling (research.md, data-dictionary.md)**
- Gather documentation, explore existing code, define domain entities and data structures
- **Update status.md**: Mark Phase 1 complete, Phase 2 in progress

**Phase 3: Architecture & Planning (architecture.md, plan.md)**
- Design implementation approach, identify affected layers, document component architecture
- **Update status.md**: Mark Phase 2 complete, Phase 3 in progress

**Phase 4: Task Breakdown (tasks.md)**
- Break down work into concrete, testable tasks with dependencies and estimates
- **Update status.md**: Mark Phase 3 complete, Phase 4 in progress

**Phase 5: Implementation (code + implementation-notes.md)**
- Follow TDD (Red-Green-Refactor), record decisions, document edge cases
- **Update status.md**: After EACH task completion — MANDATORY

**Phase 6: Completion & Archival**
- Update product documentation, move spec to `specs/archive/`, capture lessons learned
- **Verify status.md**: Must show 100% completion before archiving

**MANDATORY**: Update `status.md` after completing each task or phase. This file is the single source of truth for progress tracking.

### Specs Workflow Rules

- **Create the spec directory** before starting any new feature work
- **Update progressively** — specs are living documents, not written once
- **Update status.md ALWAYS** after completing each task, phase, or milestone — this is MANDATORY
- **Reference from commits** — link to the spec directory in commit messages
- **Archive completed specs** — move to `specs/archive/` when 100% complete in status.md
- **Version control** — commit specs alongside code for team visibility
