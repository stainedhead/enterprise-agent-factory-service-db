# Data dictionary (000023)

The authoritative dictionary is `docs/data-model.md`, section "Team model gateway (000023)". This file lists the
shapes the tests rely on.

| Object | Key | Team scoped | Writers |
|---|---|---|---|
| `inference_providers` | `provider` | no | service admins (`afs_app`, column grants) |
| `model_endpoints` | `id` (`mep_`) | `team_id` NULL or set | service admins; team-admins of teams with `may_add_model_endpoints` |
| `endpoint_models` | `(endpoint_id, model_name)` | `team_id` copied | as the endpoint |
| `endpoint_model_prices` | `(endpoint_id, model_name, effective_from)` | `team_id` copied | service admins; append-only |
| `endpoint_price_proposals` | `id` (`epp_`) | `team_id` copied | `afs_billing` inserts; service admins decide |
| `endpoint_capacity_costs` | `(endpoint_id, team_id, effective_from)` | yes | service admins |
| `endpoint_credentials` | `(endpoint_id, scope)` | `team_id` or `_shared` | team-admins (own team), service admins (shared); reconciler `status` |
| `endpoint_federations` | `(endpoint_id, team_id)` | yes | service admins; gateway status columns |
| `provider_statements` | `id` (`pst_`) | no (rows name teams) | service admins |
| `team_model_endpoints` | `(team_id, endpoint_id)` | yes | team-admins, service admins (terms, service-selected providers) |
| `agent_model_endpoints`, `pool_model_endpoints` | `(team_id, agent_id|pool_id, endpoint_id)` | yes | team-admins |

Route model reference: `<slug>/<model>`; the slug matches `^[a-z][a-z0-9-]{1,30}$` and is never `bedrock`.

Admission reasons, in order: `provider_disabled`, `route_not_enabled_for_service`, `route_not_enabled_for_team`,
`route_not_enabled_for_agent`, `model_not_priced`.

Change-feed payload: `<table>:<team_id>:<id>` with id = `id`, else `endpoint_id`, else the provider.
