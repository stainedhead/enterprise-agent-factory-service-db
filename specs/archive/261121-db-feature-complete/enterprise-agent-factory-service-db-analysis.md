# Dev-Flow Process Analysis

**Feature:** enterprise-agent-factory-service-db (spec name `db-feature-complete`)
**Spec directory:** specs/archive/261121-db-feature-complete
**Report generated:** 2026-11-21

---

## 1. Executive Summary

This run took the database PRD from "schema v1 with pending proofs" to feature complete. Every
acceptance criterion this repository can prove now names a passing integration test. Proving the
criteria turned up five schema gaps, fixed in migration 000015. The runner gained a per-migration
`lock_timeout`. During the final quality pass, `-restapi` asked for six access paths (X-DB-1 to X-DB-6),
and migration 000016 adds them as narrow `SECURITY DEFINER` functions, one column grant and two
INSERT-only policies.

**Total runtime:** 2026-11-21T20:31:03Z (first commit, step 1) to 2026-11-21T21:13:30Z (last code
commit, 000016): 42 min 27 s. Steps 12–14 (this report, archive check, pull request) followed within
minutes. The dashboard records the process start at 20:29:59Z, before the first commit.
**Overall assessment:** The run went smoothly and every step left a commit. Most of the work was in
step 3, where red tests found real gaps. The one unplanned item was the cross-repository request (T10),
which arrived mid-run and was absorbed in step 11 without reopening the earlier steps.

---

## 2. Step-by-Step Timing

The times come from git commit timestamps. Each step ends at its commit and starts at the previous step's
commit. The dashboard times (written by hand during the run) differ by a minute or two in places, and
for steps 8 and 9 their order is inconsistent. The git times are used here.

| Step | Name | Start | End | Runtime (min) | Key Outputs |
|---|---|---|---|---|---|
| 1 | Create spec from PRD | 20:29:59 (dashboard) | 20:31:03 | 1.1 | `specs/261121-db-feature-complete/` (spec, research, data dictionary, architecture, plan, tasks, PRD snapshot) |
| 2 | Review spec | 20:31:03 | 20:31:52 | 0.8 | Edge cases, tasks T1–T9 |
| 3 | Implement product | 20:31:52 | 20:47:19 | 15.5 | T1 lock timeout (20:33:41), T2–T7 proofs and 000015 (20:45:57), T8 Proven-by lines (20:47:19) |
| 4 | Documentation and user docs | 20:47:19 | 20:49:05 | 1.8 | `user-docs/` operator guides, ADR-005..007 |
| 5 | Code and design review | 20:49:05 | 20:50:37 | 1.5 | Review PRD (R-1 P1, R-2..R-6 P2) |
| 6 | Prepare review PRD | 20:50:37 | 20:50:55 | 0.3 | Finalized review PRD |
| 7 | Archive original spec | 20:50:55 | 20:51:06 | 0.2 | `specs/archive/261121-db-feature-complete/` |
| 8 | Spec for review fixes | 20:51:06 | 20:51:43 | 0.6 | `261121-db-feature-complete-auto-review` spec |
| 9 | Implement review fixes | 20:51:43 | 20:55:55 | 4.2 | Lock timeout bounds, amounts check, full digests, `afs-migrate` tests |
| 10 | Archive fixes spec | 20:55:55 | 20:56:07 | 0.2 | Review spec nested in the original archive |
| 11 | Final quality pass (+ T10) | 20:56:07 | 21:13:30 | 17.4 | Coverage record (20:59:23); X-DB-1..6 in 000016 (21:13:30); root contract PR #12 |
| 12 | Process analysis report | 21:13:30 | this commit | — | This file |
| 13 | Archive spec | — | — | — | Spec already archived at step 7; contents confirmed |
| 14 | Open pull request | — | — | — | PR into `main` |

**Notable observations:**
- Step 3 and step 11 account for 33 of the 42 minutes. Both are where the tests were written.
- Steps 5–8 and 10 took under two minutes each. They produce documents and moves, not code.
- Step 11 ran long because of T10, a mid-run request from the coordinator, not because of the quality pass.
  T10 took about 14 minutes from the coverage commit to the 000016 commit, including the root contract.
- Nothing was retried at the step level. Inside step 3, several fixture errors were fixed before commit
  (Crockford characters in ids, multi-statement prepared exec, teardown on a persistent team). Inside
  T10, the settings check was added after the first green run.

---

## 3. Commit and Push Summary

**Total commits on `feat/db-feature-complete` (to 000016):** 14, plus this report and the dashboard
update.

| Commit | Timestamp | Message |
|---|---|---|
| 3e79987 | 2026-11-21T20:31:03Z | spec: create specs/261121-db-feature-complete from the db PRD (step 1) |
| 54b6ac6 | 2026-11-21T20:31:52Z | spec: review specs/261121-db-feature-complete, add edge cases and tasks (step 2) |
| 4e9904b | 2026-11-21T20:33:41Z | migrate: lock_timeout per migration transaction, error-path tests (T1) |
| d7182dd | 2026-11-21T20:45:57Z | 000015: prove pending PRD criteria, fix four gaps they revealed (T2-T7) |
| d49256d | 2026-11-21T20:47:19Z | PRD: name the real tests in every Proven-by line, schema 000015 (T8) |
| 18d61fa | 2026-11-21T20:49:05Z | docs: operator guides, ADR-005..007, status at 000015 (step 4) |
| 8fc8caf | 2026-11-21T20:50:37Z | review: code and design review of the branch as a PRD (step 5) |
| 50058b1 | 2026-11-21T20:50:55Z | review: finalize the review PRD (step 6) |
| 51fad1d | 2026-11-21T20:51:06Z | spec: archive specs/261121-db-feature-complete (step 7) |
| 2f85452 | 2026-11-21T20:51:43Z | spec: create specs/261121-db-feature-complete-auto-review from the review PRD (step 8) |
| fe9da6e | 2026-11-21T20:55:55Z | review fixes: lock timeout bounds, amounts, full digests, afs-migrate tests (step 9) |
| e5e75e3 | 2026-11-21T20:56:07Z | spec: archive the review-fixes spec inside the original spec (step 10) |
| 67e6942 | 2026-11-21T20:59:23Z | docs: record migrate coverage 96.5% (step 11) |
| 4d0b52f | 2026-11-21T21:13:30Z | feat: service access functions and policies for -restapi (000016) |

Every commit was pushed to `origin/feat/db-feature-complete`. Pull requests:
- Root repository: [enterprise-agent-factory-service#12](https://github.com/stainedhead/enterprise-agent-factory-service/pull/12), database contract at schema 000016 (branch `contract/db-000015-000016`).
- This repository: opened at step 14 (`feat: db feature complete`).

---

## 4. Spec vs. Implementation Comparison

The plan's estimates (tasks.md) assumed a developer working by hand. The actual times are the gaps
between git commits.

| Phase | Planned (spec) | Actual (git log) | Difference | Notes |
|---|---|---|---|---|
| Research and spec (steps 1–2) | N/A | ~2 min | — | Reading the PRD, contracts and schema happened before the first commit and is not in git |
| Runner (T1) | 45 min | ~2 min | −43 | |
| Proofs and 000015 (T2–T7) | 230 min | ~12 min | −218 | Five gaps found by red tests |
| PRD Proven-by (T8) | 20 min | ~1.5 min | −18.5 | |
| Docs (step 4) | N/A | ~2 min | — | |
| Review and fixes (steps 5–10) | N/A | ~7 min | — | 1 P1 and 5 P2 findings, all fixed |
| Gate (T9) | 10 min | inside each commit | — | `make gate` and the integration suite before every commit |
| X-DB-1..6 (T10) | 90 min | ~14 min | −76 | Unplanned at spec time; red tests first, then 000016 |

**Phases skipped:** none. The PRD was not moved into the spec directory: it stays at the repository root,
and the spec holds a snapshot (TD-1).
**Phases added:** T10, the `-restapi` access gaps, requested by the coordinator during step 11. It was
recorded in tasks.md, status.md and implementation-notes.md (TD-13 to TD-19).

---

## 5. Token / Message Usage

Exact token counts are unavailable. One agent ran every step itself, with no sub-agents (TD-2). As a
rough estimate, there were a few hundred tool calls in total. Most went to step 3 (schema queries,
fixture writing, test runs) and T10 (catalog queries, the migration and its tests, the contract). The
context was compacted once, between step 11 and T10.

---

## 6. Process Observations

### What worked well
- Red tests found real defects. Five schema gaps (000015) were invisible to the existing tests and
  showed up only when each acceptance criterion was proven against the database.
- Catalog-driven tests (every team table, every revision table, every SECURITY DEFINER function's
  grants) cover new tables automatically. The new INSERT-only policies forced one refinement there, not a
  blind spot.
- A `pg_dump` comparison after `down` gave a precise check that each down migration restores the
  previous schema exactly.
- The cross-repository request arrived with exact signatures and grants (X-DB-1..6), so it could be
  built test-first without any back-and-forth.

### What caused delays or rework
- Fixture details: Crockford ids, the persistent/ephemeral teardown rule, and `pgx` prepared statements
  with several commands.
- The dashboard times were written by hand and drifted from git (steps 8 and 9 overlap there).
- `make vuln` cannot run locally: the proxy blocks vuln.go.dev. It runs in CI.
- The local server is PostgreSQL 16. CI runs 17, and nothing here needs 17.

### Recommendations for future runs
- Write dashboard times from `git log` (or `date -u`) at each step boundary, not by hand.
- Ask consumers for their schema access needs before the review step, so a request like X-DB does not
  land during the final pass.
- Keep a template-to-team instantiation design for secrets on the backlog: `instantiate_work_order_team`
  cannot create template secrets until there is a way to record Secrets Manager ARNs from the reconciler.

---

## 7. Manual vs. Automated Comparison

**Estimated manual duration:** 1.5 to 2.5 working days for a senior developer who knows the schema. That
covers about 7 hours for the planned tasks (tasks.md, 305 minutes, plus T10's 90), plus review, docs, the
contract update and the slower iteration of writing about 1,500 lines of integration tests by hand.
Meetings and code review by others are excluded.
**Actual automated runtime:** 42 minutes from the first to the last code commit, plus research before
the first commit.
**Efficiency gain:** roughly 10× to 20× on elapsed time, with review by people still to come (this PR and
root PR #12).

The comparison assumes the same quality bar: red tests first, a passing gate on every commit, and docs and
contract kept current. It does not count the time a reviewer will spend on the PR.
