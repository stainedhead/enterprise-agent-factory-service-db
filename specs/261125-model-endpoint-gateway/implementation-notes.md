# Implementation notes

## Decisions

- **Provider derivation is the database's.** `model_endpoints.provider` is set by trigger from the base URL host
  (`afs.provider_for_host`). A team cannot choose its provider (a claimed one is overwritten). A service admin may
  name a provider only for an external host that matches no listed provider.
- **Guard ordering.** BEFORE triggers step aside when a CHECK should report (`endpoint_credentials_scope_check`,
  `model_endpoints_in_namespace_check`), so the API sees the contract's constraint name.
- **Status columns do not bump `version`.** `endpoint_credentials.status` (reconciler) and
  `endpoint_federations.status, last_error, checked_at` (gateway) use `afs.touch_row_runner_exempt`, so client ETags
  survive runner updates; revision and change-feed triggers still fire.
- **Down refuses route defaults.** `afs-migrate down 1` raises `55000` while an agent or pool has `default_route`
  set, because 000022 cannot represent it. Route usage keeps `model_id = '<route>/<model>'`; cost rows `route` become
  `gateway`, `route_capacity` become `cur_other`.
- **Makefile `VERSION` stays `dev`.** It is a build-time default overridden by the release build (`make build VERSION=v1.2.0`); 1.1.0 left it `dev` too, so the release number lives in `CHANGELOG.md` and the tag.
- **Tests ran on PostgreSQL 16.** Docker is not available here; nothing in 000023 needs 17. CI runs `postgres:17`.

## Contract notes

Where section 7.4 left room, the safest reading was taken:

1. **Corporate hosts that match a listed provider** get that provider (and its switch), not `internal`; only
   unlisted corporate hosts and in-namespace Services are `internal` (no switch).
2. **Editing an endpoint of a disabled provider** is allowed while it stays off; `provider_disabled` applies to an
   insert, to an update that leaves or turns the endpoint on, and to an update that changes the provider.
3. **`team_id` on prices and proposals.** The contract lists `team_id` on `endpoint_models`; prices and proposals
   carry it too (copied from the endpoint) so row-level security and composite keys cover them.
4. **Proposal state `superseded`** (a newer proposal or an approved price replaced it) and `afs_billing` UPDATE of
   `state` and `note` only, so billing can supersede its own proposals but approval stays with service admins.
5. **`afs_billing` reads** `endpoint_models`, `endpoint_price_proposals` and `endpoint_federations` besides the
   listed tables; it needs the model list to propose prices.
6. **Prices are written by service admins only**, also for team endpoints (the contract says "service admins
   approve"; a team-admin writing its own price directly would bypass that).
7. **`cached_input_per_mtok_usd` is nullable**: NULL bills cached input at the input price.
8. **Disabled route models** (`endpoint_models.enabled = false`) are absent from `route_admission`, like disabled
   Bedrock models; a team endpoint that is off reports `route_not_enabled_for_team`.
9. **Bedrock stays under `model_access`**: `agent_model_endpoints` never holds Bedrock; the slug `bedrock` is reserved.
10. **New teams are selected for the service default route** (trigger `teams_default_route_select`, `selected_by
    service_admin`), so the Bedrock-off rule "every live team has selected it" keeps holding.
11. **While Bedrock is off** the fallback route's provider cannot be turned off and the service default must stay a
    valid fallback (`no_fallback_model` for both).
12. **Route defaults (CD-42)** are normalized: a `default_model_id` written as `<slug>/<model>` with no
    `default_route` is split. `service_settings` `models.default_model_id` widened to 240 characters.
13. **The Bedrock switch** also applies to `effective_agent_models` and `model_admission` (reason `provider_disabled`
    first), so no path admits a Bedrock model while Bedrock is off.
14. **`cost_daily.model_id`** holds `<route>/<model>` for route rows (or the route alone for capacity).
15. **No stored credential for `none` or federated endpoints** (`endpoint_credentials_auth_kind`).
16. **In-namespace host rule**: a bare Service name or `<svc>.<team namespace>[.svc[.cluster.local]]`
    (`model_endpoints_in_namespace_host`); http allowed only there.
17. **Per-subject route limit 50** (`agent_model_endpoints_limit`, `pool_model_endpoints_limit`), like model selections.
18. **`agent_routes_team`** is raised for both agent and pool selections, as the contract names it.
19. **A service-admin selection** (terms, service-selected provider, the default route) is removed by service admins only.
20. **`provider_statements`** are visible to service admins only through `afs_app`; the gateway cannot read them.
21. **Change-feed id part** is `id`, else `endpoint_id`, else the provider (`inference_providers::bedrock`).

## Gotchas met

- SQL-standard function bodies depend on tables: drop order in the down file matters.
- `NEW.kind` in plpgsql fails on tables without that column even in an untaken branch; use `to_jsonb(NEW)->>'kind'`.
- Crockford base32 has no I, L, O, U: test ids must avoid them.

## Design review

- Migration 000023 is new, contiguous, one transaction; lock impact in the header (no table rewrite).
- `.down.sql` restores the 000022 catalog exactly (`TestMigration000023` compares catalogs) and keeps data.
- Team-owned tables have `team_id`, RLS and rows in `seedOtherTeams`. Composite `(team_id, id)` keys are used where
  both rows are team rows (`endpoint_models`, prices, proposals, agent and pool selections). Tables that may point
  from a team row to a service endpoint (`team_id` NULL there: credentials, federations, capacity costs, team
  selections) reference `model_endpoints (id)` and `endpoint_child_guard` refuses another team's endpoint
  (`<table>_endpoint_team`).
- No column can hold a secret value: credentials are ARNs checked against the expected path; federations hold
  identifiers only; the catalog test for value-like column names passes.
- `docs/data-model.md` updated.
