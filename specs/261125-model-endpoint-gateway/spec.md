# Spec: team model gateway (migration 000023, release 1.2.0)

Created 2026-11-25. Sources: root `model-endpoint-gateway-PRD.md` (sections 7, 7.3, 7.4, 9.4, 11, 11.1;
Appendix C.1 TC-DB-01 to TC-DB-15; Appendix D.2 MEG-DB-1 to MEG-DB-7) and the root database contract
`docs/contracts/database-contract.md` section 7.4 with decisions CD-42 and CD-43. Stories DB-US-62 to DB-US-68 in
`enterprise-agent-factory-service-db-PRD.md`.

## Problem

Agents can call Bedrock models only. Teams need OpenAI-compatible endpoints (OpenAI, OpenRouter, Nous Portal,
OpenCode, Azure, Vertex AI, corporate LLMs, vLLM in the team namespace) through the same metered, capped gateway,
and service admins need one switch per provider, Bedrock included.

## Goals

1. Hold desired state for providers, model endpoints (service and team), route models, prices, proposals, capacity
   costs, credential references, federation identifiers, provider statements and route selections (MEG-DB-1).
2. Extend teams, agents, pools, usage and cost for routes (MEG-DB-2), without changing the meaning of existing rows.
3. Decide route admission in one place, `afs.route_admission`, with fixed reasons in a fixed order (MEG-DB-3).
4. Keep every team's rows invisible and unwritable to other teams; least-privilege grants per role (MEG-DB-4).
5. Seed providers and the built-in catalog, all built-ins off (MEG-DB-5, CD-43).
6. Refuse turning Bedrock off without a usable route fallback (MEG-DB-6).
7. Announce every change on the change feed; up/down/up clean; data dictionary updated (MEG-DB-7).

## Non-goals

- Gateway, reconciler, billing or API code (`-restapi`). No secret values are stored, only ARNs and identifiers.
- Renaming or removing 1.1.0 columns; Bedrock model access (`model_access`, `agent_models`) stays as it is.

## Acceptance criteria

Each TC-DB case of the PRD Appendix C.1 is an integration test against a real PostgreSQL:

| Case | Test |
|---|---|
| TC-DB-01, 02 slugs, shapes, owner and purpose | `TestModelEndpointConstraints` |
| TC-DB-03 cross-team isolation | `TestModelGatewayPermissions`, `TestCrossTeamWritesChangeNothing` |
| TC-DB-04 team switches and terms are service-admin only | `TestModelGatewayPermissions` |
| TC-DB-05 credential paths | `TestEndpointCredentials` |
| TC-DB-06 grants per role | `TestModelGatewayGrants` |
| TC-DB-07, 08, 11, 12 admission order, opt-in kept, price rule | `TestRouteAdmission` |
| TC-DB-09 change feed | `TestModelGatewayChangeFeed`, `TestEveryRevisionTableAnnouncesChanges` |
| TC-DB-10 up/down/up | `TestMigration000023` |
| TC-DB-13 provider policy | `TestModelGatewayPermissions` |
| TC-DB-14 seeds | `TestGatewaySeeds` |
| TC-DB-15 Bedrock-off guard | `TestBedrockOffGuard` |
| CD-42 route defaults | `TestRouteDefaultModels` |

Plus: every constraint's rejected case, `migrate` coverage at least 90%, `make gate` and `make test-db` green.
