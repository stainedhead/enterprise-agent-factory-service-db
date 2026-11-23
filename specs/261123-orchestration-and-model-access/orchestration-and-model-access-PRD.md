# Change PRD: team orchestration agent and model access (`-db`, migration 000022)

| | |
|---|---|
| **Status** | Implemented in `-db` on branch `claude/project-thread-68nbc5`; release 1.1.0 (lockstep with `-restapi`), not yet tagged |
| **Owner** | J (product owner) |
| **Source of truth** | Root `team-orchestration-agent-PRD.md` (ORC-1 to ORC-32, MOD-1 to MOD-8, DB-US-58 to DB-US-61) and the root `docs/contracts/database-contract.md` section 7.3 (v1.4.0, decisions CD-13 to CD-25). Where they differ the contract wins |
| **Refines** | `enterprise-agent-factory-service-db-PRD.md`: stories DB-US-58 to DB-US-61 continue its numbering after DB-US-57 |
| **Spec** | `specs/261123-orchestration-and-model-access/` |

## 1. Problem

In 1.0.1 a team may have one Paperclip collaboration agent, exposed publicly or not at all, and an agent has one model. J asked for
three changes that the database must make true on its own, not by trusting the API:

1. Every team gets one **orchestration agent**, created with the team, running Paperclip or Buzz.
2. Its Web UI and Web API are **off, private or public**, within a limit that only a service admin raises.
3. An agent or pool uses **all, one or several models**, a subset of what the team and the service allow, with defaults open.

## 2. Scope

In: migration 000022 and its down migration; the tests; `docs/data-model.md`, README, `user-docs/`, CHANGELOG; the release number 1.1.0.
Out: the API, the edge, the gateway and the reconciler (`-restapi`); the CLI and console; approvals of exposure or models (above team and service level, by decision of J); Buzz's own REST (none: both Buzz surfaces are N/A).

## 3. Stories

### DB-US-58 · Orchestration role and the one-per-team rule

As the platform, I want the database to refuse a team with no orchestration agent or with two, so that no client can leave a team without one.

- Given a database at 000021 with agents of role `collaboration`, when 000022 runs, then they are `orchestration` and their `version` is unchanged.
- Given a team created with `orchestration_required`, when its transaction commits without a live orchestration agent, then the commit fails `23514` (`teams_orchestration_required`); a team already `deleting` needs none.
- Given a team with an orchestration agent, when a second is inserted, then `23505` (`agents_team_orchestration_uq`).
- Given `afs_app`, when it inserts role `orchestration` or the name `orchestrator` (agent or pool), then `23514` (`agents_role_reserved`, `agents_name_reserved`, `agent_pools_name_reserved`).
- Given a live team, when its orchestration agent moves to `deleting` or `deleted`, then `23514` (`agents_orchestration_required`); when the team is `deleting`, it is allowed and the route row goes with it.
- Given `afs.create_orchestration_agent` called by a service admin, then the agent, its `team_collaboration` row, its `agent_models`, audit and the events `agent.created` and `orchestration.created` are written in the caller's transaction; a caller who is not a service admin gets `42501`, a disabled tool `23514`, an unset runtime `55000`.
- Given a work order team, then it gets an orchestration agent with its volume deleted with the team.
- Proven by: `TestOrchestrationAgent`, `TestCreateOrchestrationAgent`, `TestWorkOrderTeamHasOrchestrationAgent`, `TestMigration000022/existing_rows_keep_their_meaning`.

### DB-US-59 · Exposure levels, limit and tool

As a team admin I want to choose off, private or public for the Web UI and Web API within the limit my service admin gave my team, and the tool my agent runs, so that exposure is my decision inside a boundary.

- Given the 1.0.1 booleans, then `web_ui_exposure` and `web_api_exposure` are backfilled (`true` is `public`) and stay in step with the booleans both ways; `true` under a private limit gives `private`, under an off limit `off`.
- Given a level above the team's limit, when it is set, then `23514` (`team_collaboration_exposure_limit`); a level that is not changed survives a later lowering of the limit.
- Given the tool Buzz, then both surfaces are refused above `off` (`team_collaboration_surface_supported`) and manual registration is refused (`team_collaboration_registration_supported`).
- Given a tool change, then both surfaces are re-checked, and at commit the agent's template carries the tool's capability (`team_collaboration_tool_template`); a template in use keeps its capability (`55000`).
- Given a tool change, then `afs_app` may record a `pre_tool_change` snapshot with the tool and a retention, and no other reason.
- Given the `orchestration.*` settings, then every range and the single default tool are checked, default levels are not above the default limit, and `collab.base_domain` and `collab.public_endpoints` are read-only aliases for `afs_app`.
- Proven by: `TestCollaborationExposure`, `TestToolChangeSnapshot`, `TestOrchestrationSettings` (the contract's `TestServiceSettingRanges/orchestration.*`), `TestOrchestrationCapabilities`, `TestBuzzManagedSecrets`, `TestCrossTeamWritesChangeNothing`.

### DB-US-60 · Edge routes by exposure

As `afs-edge` I want one function that says, per surface, which level is effective and why, so that I serve the right host and never guess.

- Given a team, then `afs.orchestration_routes()` returns two rows (`web_ui`, `web_api`) with `effective`, `reasons` in a fixed order (`tool_not_supported`, `team_limit`, `service_switch_public`, `service_switch_private`, `base_domain_unset`, `provider_without_collab_client`), the public and private hostnames and readiness; a deleting team has none.
- Given `afs_edge`, then it still holds no table privilege and gains `EXECUTE` on `orchestration_routes` and `orchestration_settings` only; `collab_routes()` stays, recomputed, until 2.0.0.
- Given access counts, then `exposure` is public or private (default public), part of the key, and `web_api` is stored as `rest_api`.
- Proven by: `TestOrchestrationRoutes` (the contract's `TestEdgeRole/orchestration_routes`), `TestRecordAccessExposure`, `TestEdgeRole`, `TestEdgeRoutes`.

### DB-US-61 · Model access levels

As a team admin I want an agent to use all models, one, or several of what my team may use, so that I can narrow one agent without changing the team.

- Given the service, then `models.service_access` is `all` (every model usable, `enabled` fixed) or `selected` (only `enabled` models); it is seeded `selected` on an upgraded database with models and `all` on a new one.
- Given a team, then `model_access` is `all` or `selected` (the `team_models` rows); existing teams are `selected`.
- Given an agent or pool, then `model_access` is `all` or `selected` with `agent_models` or `pool_models`; a selected agent has at least one model (`agents_models_selection_nonempty`), its default is among them (`agents_default_model_allowed`), and each is enabled for the service (`agent_models_service`), allowed for the team (`agent_models_team`), at most 50 (`agent_models_limit`). Narrowing the team leaves the agent's rows unchanged.
- Given a model, then it is callable only with a price in force; `afs.model_admission` names the first failing level and `effective_agent_models` lists what is callable.
- Given the gateway role, then it reads the view, the function and the `models.*` settings it needs and nothing else of `service_settings`.
- Given `team_inference_profiles`, then the reconciler writes one row per (team, model) and `afs_app` reads its team's only.
- Proven by: `TestModelAccess`, `TestTeamInferenceProfiles`, `TestCrossTeamWritesChangeNothing`, `TestRowLevelSecurityIsolatesTeams`.

## 4. Non-functional

- Up/down/up and the down migration restoring the 000021 catalog: `TestMigration000022/down_restores_the_000021_catalog_and_keeps_the_data`.
- Online-safe: constant defaults, NOT VALID then VALIDATE, backfills with triggers disabled; the one blocking step is the `collaboration_access` primary key (lock impact in the migration header and `user-docs/operations.md`).
- 1.0.1 services keep working until 2.0.0: the old columns and functions stay in step.
- No secret value in any column; no new role.
- Local runs used PostgreSQL 16.15 (17 is not available here); CI runs `postgres:17`.
