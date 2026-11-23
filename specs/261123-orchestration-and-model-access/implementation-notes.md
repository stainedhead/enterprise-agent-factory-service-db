# Implementation notes

## Decisions (numbered; those marked **contract** differ from or add to the database contract section 7.3)

- **OM-D1 (contract) Guard triggers are split by what they need.** The contract describes one guard for the reserved role and name and one for the alias keys. `SECURITY DEFINER` hides `current_user`, so each is two functions: `agents_role_reserved_guard` and `service_settings_alias_guard` (`SECURITY INVOKER`, keyed on `afs_app`), and `agents_orchestration_guard` and `service_settings_orchestration_guard` (`SECURITY DEFINER`, read other tables, write the alias rows as the owner). Same behaviour, same constraint names (ADR-010).
- **OM-D2 (contract) The tool profile is read from constants, not from settings.** `afs.collab_tool_profile(tool)` holds Paperclip's and Buzz's profile; the CHECK on `orchestration.tools` requires the setting to repeat it exactly, so the two cannot drift and a trigger need not read a JSON setting on every write.
- **OM-D3 (contract) `agent_pools_model_id_fkey` is added.** Dropping the composite foreign key to `team_models` left pools with no foreign key to `models`; a plain foreign key replaces it.
- **OM-D4 The capabilities CHECK is kept.** `afs.capabilities_ok` is replaced and the rows rewritten, instead of dropping and re-adding the constraint (cheaper, and a 1.0.1 write of `{paperclip}` is rewritten by a trigger rather than refused).
- **OM-D5 `team_inference_profiles` is backfilled only from ARNs that match the new pattern** (`application-inference-profile/<id>`); anything else stays in `team_models.inference_profile_arn` for the reconciler to recreate.
- **OM-D6 (contract) Buzz has no boot secrets.** The contract defines none, so `record_work_order_secret` accepts Paperclip's three only; a Buzz team's agent has none to record. If Buzz gains boot secrets this function needs a new migration.
- **OM-D7 `create_orchestration_agent_impl` carries the logic without the caller check**, so `instantiate_work_order_team` (running as the owner, called by the reconciler) shares it; `create_orchestration_agent` is the `afs_app`, service-admin wrapper.
- **OM-D8 Defaults of `create_orchestration_agent`.** A null tool is the service default; null levels take the setting capped by the team limit and by what the tool supports; `p_model_ids` is ignored when access is `all`; the default model is the argument, else `models.default_model_id`, else the first selected model, else `23514`.
- **OM-D9 Trigger names carry order.** `team_collaboration_a_levels_sync` runs before `team_collaboration_b_exposure_check`; `agent_pools_a_name_reserved` runs before the pool-name uniqueness check so the reserved-name error is the one reported.
- **OM-D10 `remove_collab_agent_key` removes either tool's key** (`paperclip-agent-api-key` or `buzz-agent-private-key`), and `record_collab_agent_key` names the secret and target by the team's tool.
- **OM-D11 The down migration is lossy for what 1.0.1 cannot hold** (Buzz rows, model selections, inference profiles). It re-adds the composite foreign keys to `team_models` and validates them when the data allows, else leaves them `NOT VALID`.
- **OM-D12 Audit key renamed.** The audit row of `InstantiateWorkOrderTeam` names the agent as `orchestrationAgentId` (was `collaborationAgentId`). No document defines the old key.
- **OM-D13 Existing teams get `model_access = 'selected'`** (their `team_models` rows keep being the rule), new teams `all`; `models.service_access` is seeded `selected` when models exist, `all` otherwise.
- **OM-D14 Test fixture shim.** The 1.0.1 suites create teams and collaboration agents without the orchestration rules. `migrated()` restores that world for them (`legacyFixtureDefaults`: `orchestration_required` default false, limit and Web UI default `public`, the delete guard trigger disabled); `migratedStrict()` is the real schema and is what every 000022 test and the migration tests use.

## Found by the tests, fixed in the migration

- Renaming the role updated rows while the old CHECK was in force; the check is now dropped first, re-added `NOT VALID` after the update, then validated (found by `TestMigration000022/existing_rows_keep_their_meaning`).
- The down migration needed the constraint triggers dropped before their functions and the role check dropped before the rename back.
- The pool reserved-name trigger lost to the uniqueness check in ordering (OM-D9).

## Edge cases

- A level above a limit that was lowered later survives an unrelated update; only a changed level, or both levels after a tool change, is checked.
- `true` on a boolean under a `private` limit gives `private`, under an `off` limit `off`, and `off` for a surface the tool lacks.
- A team that is `deleting` needs no orchestration agent at commit and may lose it.
- Narrowing a team leaves `agent_models` untouched; the view and `model_admission` apply the narrower set, so widening restores access with no agent change.

## Process analysis

- The riskiest part was keeping 1.0.1 and 1.1.0 views of the same data consistent in both directions; two-way sync triggers plus a test per direction caught the ordering problems early.
- The longest feedback loop was test adaptation: many existing tests assumed teams without an orchestration agent. The fixture shim (OM-D14) kept their intent intact without weakening a single assertion.
- Real PostgreSQL 17 was not available here; PostgreSQL 16.15 ran every test. Nothing in the migration is 17-specific; CI is the proof for 17.
- Review (dev-flow `review-code` done by hand against the checklist in AGENTS.md): migration new and contiguous, transactional, online-safe with the lock impact in its header; down verified by catalog equality; team-owned tables have `team_id`, composite FKs, RLS, grants and isolation rows; no column can hold a secret value; `docs/data-model.md` updated. No open finding.
