# Plan

1. Write 000024 against contract §7.5 on a local stub of 000023; rebase onto the merged 000023 (done).
2. Integration tests per area (red first), then fixture rows in `seedOtherTeams`.
3. Adapt the 1.2.0 tests that assumed 000023 is the latest migration.
4. Data model, changelog, AGENTS.md status; gate and full `-race` integration run; PR; merge when CI is green.
