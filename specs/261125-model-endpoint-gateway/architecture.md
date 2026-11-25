# Architecture

```
inference_providers (switch) ──provider──► model_endpoints (service | team)
                                               │
          ┌──────────────┬────────────┬────────┴─────┬──────────────┬───────────────┐
   endpoint_models  endpoint_credentials  endpoint_federations  capacity_costs  provider_statements
          │
   prices / proposals

teams ──► team_model_endpoints (opt-in to service endpoints) ──► the team's set
                                   (+ the team's own endpoints)
agents / pools ──► route_access, default_route, agent|pool_model_endpoints ⊆ team set
                                   │
                 afs.route_admission / effective_agent_routes ──► afs-gateway, afs-api, reconciler
```

- **Guards are triggers.** Rules that depend on the caller (`afs_app`, service admin) are SECURITY INVOKER
  triggers; lookups across teams (`model_endpoint_slug_taken`, `provider_for_host`, `fallback_route_ok`,
  `endpoint_child_guard`) are SECURITY DEFINER with `search_path = pg_catalog, afs`.
- **Deferred checks** (`subject_routes_check`) run at commit so an agent, its route selections and its default
  can be written in one transaction in any order.
- **Row-level security.** Per-table `app_read`/`app_write` or `app_team_scope` for `afs_app`; `service_roles_all`
  for billing, readonly and reconciler; `gateway_team_scope` (`afs.gateway_sees_team`) lets a per-namespace gateway
  that sets `afs.team_ids` read only its team plus service rows.
- **The Bedrock switch** applies to Bedrock models too: `effective_agent_models` and `model_admission` consult
  `afs.provider_enabled('bedrock')`.
