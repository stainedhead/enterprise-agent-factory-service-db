# Paperclip collaboration (000020): code and design review fixes

| | |
|---|---|
| **Status** | Draft for implementation (2026-11-22) |
| **Source** | `/review-code` of branch `claude/project-thread-xqpqky` against `main`, spec `specs/archive/261122-paperclip-collaboration/` (archived in step 7), migration `000020_paperclip_collaboration` |
| **Parent PRD** | [`-db` PRD](enterprise-agent-factory-service-db-PRD.md) (DB-41 to DB-52, DB-US-44 to DB-US-57) and the change PRD `paperclip-collaboration-PRD.md` inside the archived spec |
| **Contract** | Root `docs/contracts/database-contract.md` section 7.2 (v1.3.1) |
| **Scope** | Fixes to the unreleased migration 000020 and its tests. Migration 000020 has not been merged or tagged, so it is corrected in place; no new migration is needed |

## 1. Executive summary

**Overall assessment: Approve with minor comments.** No finding is a blocker. The migration meets the quality bar of this repository: every constraint
and policy has a test of the rejected case, the down migration restores the 000019 catalog exactly (a catalog comparison proves it), the catalog-driven
tests found and forced three design gaps before review (RLS on the hostname hold table, a policy for the edge session tables, a PUBLIC execute
privilege), and `migrate` coverage is 96.5%. The Clean Architecture rule does not apply (SQL only); the equivalent rules do: team scoping, RLS,
least privilege, no secret values, online-safe changes, and a stated lock impact.

Review dimensions:

| Dimension | Result |
|---|---|
| Correctness | One gap: a team's collaboration settings can point at an agent that is already being deleted (FR-1) |
| Spec alignment | Every DB-US-44 to DB-US-57 criterion has a named passing test; no scope creep |
| Design and patterns | Consistent with 000013 to 000019 (definer functions with a pinned `search_path`, text plus CHECK, composite team keys). Guards that key on `current_user` are SECURITY INVOKER by design (ADR-010) |
| Security | No secret value anywhere; `afs_edge` holds no table privilege (proven by a catalog test). Two hardening gaps in the edge session functions (FR-4, FR-5) |
| Error handling | One silent no-op that should be an error (FR-3) |
| Test coverage | The pre-flight test renames a cluster-wide role outside a transaction (FR-2); the access-count batch semantics are untested in the docs (FR-6) |
| Readability | Migration is sectioned and commented; header states lock impact. Data model had a wrong `link_state` value, fixed in step 4 |

Counts: P0 0, P1 3, P2 3.

## 2. Goals and non-goals

**Goals.** Close the review findings below without changing any behaviour a consumer relies on: the contract section 7.2 function signatures, column
names and error codes of 000020 stay as they are unless a requirement says otherwise.

**Non-goals.** A new migration (000020 is unreleased); changes to `-restapi`, `-cli` or `-website`; real AWS or EKS testing (parked); new features.

## 3. Functional requirements

Priority: P0 blocker, P1 high, P2 medium. There is no P0: nothing found loses data, leaks a secret or breaks isolation.

### FR-1 (P1): `team_collaboration` must point at a live collaboration agent

**Finding.** `afs.team_collaboration_guard()` checks that the agent has `role = 'collaboration'` but not that it is live. After the cleanup trigger removes
the row for an agent that is deleting or deleted, a team caller (`afs_app` may insert its own team's row) can insert a new row naming the same dead agent.
`collab_routes()` shows it as not ready (the agent state is not `enabled`), so no traffic is routed, but the database holds a setting for an agent that
cannot serve it and the cleanup trigger will not run again.

**Requirement.** The guard refuses an insert, or an update of `agent_id`, when the agent is deleted (`deleted_at IS NOT NULL`) or its state is
`deleting` or `deleted`: `object_not_in_prerequisite_state` (`55000`), constraint-style message naming the agent.

**Acceptance criteria.**
1. Inserting `team_collaboration` for an agent in state `deleting` fails with `55000`; for `deleted` (and `deleted_at` set) fails with `55000`.
2. Inserting for an enabled or paused collaboration agent still succeeds.
3. Updating `agent_id` to a dead agent fails with `55000`; updating other columns of an existing row is unaffected.
4. After the collaboration agent is deleted, the cleanup trigger still removes the row (no regression of `TestCollaborationCleanup`).
5. `TestMigration000020` catalog comparison after `down` still equals the 000019 catalog.

### FR-2 (P1): the pre-flight test must not change cluster state outside a transaction

**Finding.** `TestMigration000020/pre-flight refuses when afs_edge is missing` renames the cluster-level role `afs_edge` and restores it in a deferred call and
a cleanup. Roles are global to the PostgreSQL cluster. If the test process is killed between the rename and the restore, every later test run (and every
other database on that cluster) loses the role and fails with `55000`. Another test that calls `bootstrap.RolesSQL` during the window would create a second
`afs_edge` and make the restore fail.

**Requirement.** Run the pre-flight check inside a transaction that is always rolled back: begin, rename the role, execute the 000020 up SQL, expect `55000`,
roll back. The role name is then never changed outside a transaction.

**Acceptance criteria.**
1. The test expects `55000` with a message naming `bootstrap-roles`, inside a transaction it rolls back.
2. After the test, `afs_edge` exists under its name even if the test is made to fail half way (checked by a following subtest).
3. No `ALTER ROLE ... RENAME` runs outside a transaction anywhere in `migrate/*_test.go`.
4. The refused migration leaves no object behind (the existing assertion moves with it).

### FR-3 (P1): `record_collab_agent_key` must not silently keep a conflicting binding

**Finding.** `record_collab_agent_key` binds the key secret to the worker with `ON CONFLICT (agent_id, target) DO NOTHING`. If the target
`PAPERCLIP_AGENT_API_KEY` is already bound on the worker to a different secret (a team bound its own secret there), the function returns success while the
agent keeps receiving the other secret. The reconciler believes the key is delivered.

**Requirement.** If the target is bound to a different secret, the function raises `unique_violation` (`23505`) naming the target and agent and writes nothing.
If it is bound to this secret, it is a no-op (idempotent).

**Acceptance criteria.**
1. A worker with `PAPERCLIP_AGENT_API_KEY` bound to a user secret: the call fails with `23505`; no secret row, binding or audit row is added.
2. A second call with the same ARN after a successful first call succeeds and adds no rows.
3. A rotation (new ARN, same path) after a successful call succeeds and updates the secret only.
4. Existing `TestCollabKeyFunctions` subtests keep passing.

### FR-4 (P2): `collab_handoff_create` validates the team

**Finding.** The function stores a handoff for any team id string, including one that does not exist or has no collaboration agent. The handoff is useless
(consume would open a session for a team nobody can route to) and the table accepts unbounded junk from a compromised edge.

**Requirement.** `collab_handoff_create` raises `foreign_key_violation` (`23503`) when the team has no `team_collaboration` row or is deleting or deleted.

**Acceptance criteria.**
1. Unknown team: `23503`. Team without `team_collaboration`: `23503`. Deleting team: `23503`.
2. A team with a collaboration agent: success, as today.
3. `TestEdgeSessions` fixtures create `team_collaboration` rows first; all existing subtests pass.

### FR-5 (P2): `collab_session_get` returns nothing for a team that is gone

**Finding.** A live session of a team that was deleted stays valid until it expires (up to `collab.session_ttl_minutes`, 24 hours at most). The edge also
checks `collab_routes()`, which omits deleted teams, so no access follows, but the session store should not vouch for a dead team.

**Requirement.** `collab_session_get` returns no row when the session's team is `deleting` or `deleted`, and `collab_principal` returns no row for such a team.

**Acceptance criteria.**
1. A session of an active team is returned as today; after the team is set `deleting` it returns no row; `collab_session_revoke` on it still returns true.
2. `collab_principal` and `collab_principal_key` for a deleting team return no row.
3. A suspended team is unchanged (it is routed with reason `team_suspended`, and its people may still see that state).

### FR-6 (P2): document and test batch atomicity of `record_collab_access`

**Finding.** One invalid row in a batch fails the whole call (the statement is one transaction), and rows for unknown teams are skipped silently. Both are
sensible, but neither is stated in `docs/data-model.md` or covered by a test that names it, so the edge developer must discover it.

**Requirement.** State both behaviours in `docs/data-model.md` and add a test: a batch with one bad row inserts nothing, and the error code is `22023` or `23514`.

**Acceptance criteria.**
1. Test: a batch of three rows with a bad second row changes no row of `collaboration_access`.
2. Test: a batch with an unknown team and a known team returns 1 and counts only the known team.
3. `docs/data-model.md` row for `record_collab_access` says both.

## 4. Non-functional requirements

| Area | Requirement |
|---|---|
| Compatibility | Function signatures, column names and public error codes of 000020 do not change except FR-3 (`23505` where it was silent) and FR-4 (`23503`), both on functions no released consumer calls yet |
| Safety | Each fix edits the unreleased 000020 in place; `down` still restores the 000019 catalog exactly; up/down/up and the checksum guard pass |
| Performance | No new table scans on the edge request path; FR-5 adds one primary-key lookup per call (`teams`) |
| Security | No secret value, token or hash appears in an error message or audit row; `afs_edge` still holds no table privilege (`TestEdgeRole`) |
| Observability | Errors name the agent, team or target, never a value |
| Quality | `migrate` coverage stays at or above 90%; `make gate` and `make test-db` pass |

## 5. How to implement the fixes

1. **Test first.** For each requirement write the failing test (Red), see it fail for the right reason, then change the migration (Green), then refactor and rerun the
   whole package. One commit per requirement or per small group.
2. **Review each fix.** After each fix do a short code and design review against the `AGENTS.md` checklist before moving on: team scoping, RLS, grants, no
   secret value, `docs/data-model.md` in step, `down` still exact.
3. **Agent teammates.** The six requirements touch two files only (`migrations/000020_paperclip_collaboration.up.sql` and its tests), so splitting is
   optional. If helpers are used, give each one requirement group (FR-1 and FR-5 are guards and edge functions; FR-3 is a reconciler function; FR-2 and FR-6 are
   tests and docs) and keep one owner for the final merge.
4. **Git worktrees.** When working in parallel, give each workstream its own worktree and branch off the working branch
   (`git worktree add ../afs-db-fr1 -b fix/fr1`), run the integration tests against a separate database name so tests do not collide (the harness creates one
   database per test), and merge the workstreams back one at a time, rerunning the package after each merge. Edits to the one migration file conflict, so
   merge them in the order FR-1, FR-3, FR-4, FR-5.
5. **Order.** P0 first (none), then P1 (FR-1, FR-2, FR-3), then P2 (FR-4, FR-5, FR-6).

## 6. Milestones

| Milestone | Content | Exit |
|---|---|---|
| R1 | FR-1 to FR-3 (P1) | Tests green, gate green, notes updated |
| R2 | FR-4 to FR-6 (P2) | Same |

## 7. Dependencies

PostgreSQL 16 locally (CI runs 17), the existing test harness, `golangci-lint` v2.15.0. No external team.

## 8. Open questions

| ID | Question | Default |
|---|---|---|
| RQ-1 | Should FR-5 also make `collab_session_get` refuse sessions of a *suspended* team? | No: the edge shows the suspended state to people; routing is refused by `collab_routes()` readiness |
| RQ-2 | Should a worker's deletion also unlink it (DB-OQ-10)? | Unchanged: no trigger; the reconciler handles it |

## 9. Findings recorded but not required

| Observation | Severity | Disposition |
|---|---|---|
| `collab_handoff_create` has no rate limit; a compromised edge could fill the table | Info | The purge removes expired rows hourly; a limit belongs in the edge. Recorded in the follow-ups |
| `collab_session_get` updates `last_seen_at` at most once a minute; the edge cannot learn the previous value | Info | As designed |
| Purge scans the tables by `expires_at` without an index | Info | Tables are small (rows live under 24 hours); revisit with the M3 load test |
| `afs_edge` has no per-role `statement_timeout` | Info | Set on the LOGIN user in Terraform (`-restapi`) |
| Positive: catalog comparison of the down migration, the catalog-driven isolation tests and the red-step check against 000019 | Observation | Keep as the pattern for later migrations |

## 10. PRD review record (step 6)

Verdict: **Ready for spec.**

| Dimension | Status | Note |
|---|---|---|
| Problem clarity | Pass | Each finding names the function, the failure and the consumer effect |
| Scope definition | Pass | Goals and non-goals explicit; 000020 is corrected in place because it is unreleased |
| Functional completeness | Pass | FR-1 to FR-6, atomic, each tied to a finding |
| NFR coverage | Pass | Compatibility, safety, performance, security, observability, quality |
| Acceptance criteria | Pass | Numbered and testable (named error codes and row counts) |
| Dependency identification | Pass | Toolchain and harness named; no external team |
| Open questions | Pass | RQ-1 and RQ-2 with defaults |
| Guidance | Pass | TDD (section 5.1), review per fix (5.2), agent teammates (5.3), git worktrees (5.4) |
| Priorities | Pass | No P0 (nothing loses data, leaks a secret or breaks isolation); P1 are real integrity, safety-of-the-test-cluster and silent-failure gaps |

Changes made in review: added this record; confirmed FR-2's criterion 3 is checkable by a grep in the test suite.
