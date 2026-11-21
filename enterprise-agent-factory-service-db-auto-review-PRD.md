# Enterprise Agent Factory Service — Database: automated review PRD

| | |
|---|---|
| **Status** | Review findings from dev-flow Step 5 (`review-code`), branch `feat/db-feature-complete` |
| **Source** | `git diff main...HEAD` (migration 000015, `migrate` lock timeout, `afs-migrate --lock-timeout`, new tests, docs) |
| **Spec** | `specs/261121-db-feature-complete/` (to be archived at `specs/archive/261121-db-feature-complete/`) |
| **Owner** | db |

## 1. Executive summary

Overall assessment: **Approve with minor comments.** No P0 (blocker) was found.

The branch proves every acceptance criterion of the database PRD that this repository can prove, fixes
four real schema gaps in a new, reversible migration (000015) and adds a per-migration lock timeout. The
dependency rule of this repository (SQL in `migrations/`, runner in `migrate/`, wiring in `cmd/`) holds;
no secret value can be stored, returned or logged; RLS backs every team-owned table, and the new
catalog-driven tests make a future table without isolation, fixture rows or a change-feed trigger fail
CI. The down migration restores the 000014 schema exactly (compared with `pg_dump --schema-only`).

The findings are one public-API correctness issue in the new lock-timeout option (P1), and five
medium items (P2): input validation that the new derived status relies on, a restore caveat the new
trigger introduces, an image check weaker than the template guard, a no-op in a test, and thin coverage
of the `afs-migrate` command.

| Dimension | Result |
|---|---|
| Correctness | One P1 (R-1) |
| Spec alignment | All FR-001–FR-019 implemented and tested; no scope creep beyond the four gap fixes, each traced to a PRD criterion |
| Design and patterns | Follows the repository's patterns (text + CHECK, NOT VALID then VALIDATE, SECURITY DEFINER with pinned `search_path`, `55000` for immutables) |
| Security | No finding. SECURITY DEFINER function reads one setting with a fixed `search_path`; EXECUTE revoked from PUBLIC |
| Error handling | Errors wrapped with migration version and name; SQLSTATEs preserved (`55P03` reaches the caller) |
| Test coverage | `migrate` 96.2%; `cmd/afs-migrate` 17.9% (R-6) |
| Readability | Migration header explains each gap, its cause and its lock impact |

## 2. How to work these fixes

- **TDD for every fix:** write the failing test first and check it fails for the right reason, make it
  pass with the least change, then refactor. Integration tests need `AFS_TEST_DATABASE_URL`.
- **Review each fix** against the AGENTS.md design checklist before starting the next (migration
  transactional and online-safe, down migration reverses it, no secret column, `docs/data-model.md`
  updated).
- **Agent teammates and git worktrees:** R-1 and R-6 (Go, `migrate/` and `cmd/`), R-2 (SQL, 000015) and
  R-3 (docs) touch disjoint files and may run as parallel workstreams, each in its own worktree on a branch
  off `feat/db-feature-complete`, merged back in priority order.
- **Migration rule:** 000015 is not merged yet, so a schema fix for this release goes into 000015 itself
  (not a 000016); 000001–000014 must not change.
- Priorities: P0 = blocks the merge; P1 = fix before the merge; P2 = fix when quick, otherwise record the
  deferral and its reason.

## 3. Functional requirements

### R-1 (P1) `WithLockTimeout` must reject negative values and must not round a small timeout to "none"

`runInTx` passes `Milliseconds()` to `lock_timeout`. A negative duration makes every migration fail inside
the transaction (`22023`, invalid value for `lock_timeout`), so a mistaken option bricks startup with an
unclear error; a duration between 0 and 1 ms becomes `0`, which disables the timeout, the opposite of
what the caller asked. `afs-migrate` checks for negative values; the library does not.

Acceptance criteria:
- `migrate.Up` and `migrate.Down` with `WithLockTimeout(d)`, `d < 0`, return an error naming the lock
  timeout before taking the advisory lock or running any SQL, and apply nothing.
- `0 < d < 1ms` sets `lock_timeout` to `1ms` (rounded up), never `0`.
- `d = 0` still disables the timeout; the default stays 10 s.
- Tests: table-driven cases for negative, sub-millisecond, zero and a normal value.

### R-2 (P2) Reconciliation amounts are not negative

The 000015 trigger derives `cost_reconciliations.status` from `gateway_usd` and `billed_usd`, but neither
column has a CHECK. A negative bill gives a meaningless variance and status.

Acceptance criteria:
- `gateway_usd >= 0` and `billed_usd >= 0`, added in 000015 as `NOT VALID` then `VALIDATE`, removed by its
  down migration.
- A negative value on insert or update is `23514`; zero stays allowed.
- `docs/data-model.md` lists the constraint.

### R-3 (P2) Document data-only loads with the new `api_keys` trigger

`api_keys_created_at_guard` sets `created_at = now()` on every insert, including a data-only restore or a
logical copy with triggers enabled, which would reset creation times and, for an old key, fail the
90-day CHECK. A full `pg_dump`/`pg_restore` is unaffected (triggers are created after the data).

Acceptance criteria:
- `user-docs/operations.md` states that data-only loads into `afs` run with
  `SET session_replication_role = replica` (or `pg_restore --disable-triggers`) as the owner, and why.
- The data-model entry of the trigger says the same in one line.

### R-4 (P2) Agent and pool images are pinned to a full digest

`agents_image_check` (and the pool equivalent) is `image LIKE '%@sha256:%'`, so `repo@sha256:abc` passes.
The template guard (000014) checks the full `sha256:<64 hex>` digest, but only for rows with a
`template_id`.

Acceptance criteria:
- An image must end in `@sha256:` plus 64 lowercase hex characters (`23514` otherwise), added `NOT VALID`
  then validated.
- Every test fixture uses full digests.
- If not done in this release, the deferral and its reason are recorded in the spec.

### R-5 (P2) Remove a no-op in `TestCrossTeamWritesChangeNothing`

`strings.Replace(others, "count(*)", "count(*)", 1)` replaces a string with itself.

Acceptance criteria: the call is removed; the test still passes and still fails when the caller is a
service admin.

### R-6 (P2) Cover `afs-migrate` beyond its argument checks

Only the argument checks of `run` are tested (17.9%).

Acceptance criteria:
- With `AFS_TEST_DATABASE_URL`, a test runs `bootstrap-roles`, `up`, `version`, `down 1`, an unknown
  command and an invalid step count against a fresh database and checks each result.
- The test skips without the URL, like the other integration tests.

## 4. Observations (no change in this repository)

- Service-level notification channels can no longer hold a secret reference (000015). A service-level
  webhook with a credential would need a service-level secret design: a question for the root solution
  design, not a defect here.
- Binding tables (`agent_secret_bindings`, `pool_secret_bindings`, `pool_handoffs`) carry no revision or
  notify trigger; the API bumps the parent agent's or pool's `generation`, which is announced. This is the
  documented design (DB-US-19).
- `-restapi`: `afs-billing` should no longer compute `cost_reconciliations.status`; the database derives
  it. The root database contract must list the 000015 objects.
- Release: tag `v0.13.0` must be pushed by a maintainer after merge (tag pushes are blocked here).
- Local integration runs used PostgreSQL 16; CI runs them on `postgres:17`.

## 5. Open questions

| Id | Question | Owner |
|---|---|---|
| RQ-1 | Should R-4 tighten the image check now (fixture churn across most tests) or in the next release? | db |
