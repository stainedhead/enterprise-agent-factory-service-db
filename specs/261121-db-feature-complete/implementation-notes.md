# Implementation notes: db-feature-complete

**Date:** 2026-11-21

Purpose: decisions, edge cases and deviations, recorded as they happen. Update after each task.

## Technical Decisions

- **TD-1 PRD stays at the repository root (deviation from create-spec).** create-spec moves the PRD into the
  spec directory. This PRD is the living product PRD of the repository: `AGENTS.md`, `README.md`, the root
  repository and the sibling repositories link to `enterprise-agent-factory-service-db-PRD.md` at the root,
  and this run must update its Proven-by lines. Moving it into `specs/archive/` would break those links and
  freeze the document. Decision: copy a snapshot into the spec directory (taken at spec creation) and keep
  the canonical file at the root.
- **TD-2 No separate sub-agents.** The run was executed by a single agent working step by step (no
  sub-agent tool in this environment); every step's output is still recorded here and in the dashboard.
- **TD-3 Pre-flight skipped.** J authorized the run; the PRD was reviewed twice, so optional PRD validation
  and confirmation prompts were skipped, and archive confirmations were taken as given.
- **TD-4 Spec directory name.** `261121-db-feature-complete` (shorter than the PRD-derived
  `enterprise-agent-factory-service-db`), as requested; the dashboard keeps the PRD-derived feature name.

## Step 2 spec review (review-spec)

Verdict on first read: **Needs revision**; after fixes: **Implementation-ready**.

| Dimension | First read | After fix | Note |
|---|---|---|---|
| Acceptance criteria | Pass | Pass | FR-001–FR-019 each name the test to add |
| Technical approach | Pass | Pass | TDD, fix forward in 000015 |
| Component coverage | Pass | Pass | Files named in Scope of Changes |
| Edge case handling | Warn | Pass | Added Edge Cases (nullable composite FK, non-standard policies, month boundaries, concurrency, advisory lock vs lock timeout) |
| Open questions | Warn | Pass | Added SQ-1, SQ-2 with resolution paths |
| Out-of-scope clarity | Pass | Pass | Non-goals name M3/M4 owners |
| Status initialization | Pass | Pass | Phase 0 In Progress |

tasks.md filled with T1–T9.

## Edge Cases & Solutions

## Deviations from Plan

## Lessons Learned
