# Plan

Red then green then refactor, one area at a time; the migration grew section by section and each section had its tests written first.

1. **Helpers and capabilities.** `exposure_rank`, `collab_tool_profile`, `collab_tool_supports`, `orchestration_tools_ok`, `resources_ok`, `model_id_list_ok`; the capability vocabulary, its rewrite trigger and the in-use guard.
2. **Orchestration role.** Rename the role (check dropped, rows updated with the touch, revision and notify triggers off, check re-added), the one-per-team index, reserved name, delete guard, `teams.orchestration_required` with a deferred check, the limit column and its boolean sync.
3. **Tool and exposure.** Columns, backfill, level sync, exposure check, tool/template check, generation bump, snapshots and `collaboration_access.exposure`.
4. **Settings.** Checks, guards, aliases, notify trigger, seeds (open or closed by whether 1.0.1 had a base domain and whether models exist).
5. **Model access.** Teams, agents, pools, selection tables, insert and commit checks, inference profiles, `models` changes, the view and `model_admission`, grants and RLS.
6. **Edge.** `orchestration_routes`, `orchestration_settings`, `collab_routes` recomputed, `record_collab_access`.
7. **Creation.** `create_orchestration_agent_impl` and its wrapper, `instantiate_work_order_team`.
8. **Secrets.** Buzz reserved names and key functions.
9. **Down migration**, verified by catalog equality with 000021.
10. **Docs and release notes.**

Test adaptation: the 1.0.1 suites assumed a team without an orchestration agent. `migrated()` keeps that world with a documented fixture shim (`legacyFixtureDefaults`); `migratedStrict()` is the schema exactly as migrations leave it and is used by every 000022 test.
