-- 000002 privileges and row-level security.
--
-- Requires the roles from bootstrap/roles.sql. RLS is defense in depth behind the API's own
-- authorization: afs-api runs as afs_app and sets, per transaction,
--   SET LOCAL afs.actor          = '<principal id>';
--   SET LOCAL afs.service_admin  = 'on' | 'off';
--   SET LOCAL afs.team_ids       = '<comma-separated team ids the caller is bound to>';
-- A bug that forgets a WHERE team_id = ... still cannot read another team's rows.

GRANT USAGE ON SCHEMA afs TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;

-- afs_app: desired state read/write; audit and outbox insert-only; no access to spend internals
-- beyond reading them.
GRANT SELECT, INSERT, UPDATE, DELETE ON
  afs.service_settings, afs.users, afs.teams, afs.api_keys, afs.role_bindings, afs.models,
  afs.model_prices, afs.team_models, afs.secrets, afs.agents, afs.agent_secret_bindings,
  afs.agent_identities, afs.team_egress_rules, afs.budgets, afs.log_destinations,
  afs.notification_channels, afs.work_orders, afs.export_bundles
  TO afs_app;
GRANT SELECT ON afs.spend_counters, afs.budget_threshold_events, afs.usage_events,
  afs.cost_daily, afs.cost_reconciliations, afs.resource_status, afs.config_revisions
  TO afs_app;
GRANT SELECT, INSERT ON afs.audit_log, afs.outbox_events TO afs_app;

-- afs_reconciler: reads everything, writes status, inference profile ARNs, identity status,
-- lifecycle state, partitions and outbox publication marks; appends audit (drift corrections).
GRANT SELECT ON ALL TABLES IN SCHEMA afs TO afs_reconciler;
GRANT INSERT, UPDATE, DELETE ON afs.resource_status TO afs_reconciler;
GRANT UPDATE (inference_profile_arn) ON afs.team_models TO afs_reconciler;
GRANT UPDATE (status, external_ref) ON afs.agent_identities TO afs_reconciler;
GRANT UPDATE (state, deleted_at) ON afs.teams, afs.agents TO afs_reconciler;
GRANT UPDATE (published_at, attempts) ON afs.outbox_events TO afs_reconciler;
GRANT INSERT ON afs.audit_log, afs.outbox_events, afs.spend_counters TO afs_reconciler;
GRANT UPDATE (limit_usd) ON afs.spend_counters TO afs_reconciler;
GRANT EXECUTE ON FUNCTION afs.ensure_usage_partition(date) TO afs_reconciler;

-- afs_gateway: the minimum to authorize, reserve, settle and meter a model call.
GRANT SELECT ON afs.teams, afs.agents, afs.models, afs.model_prices, afs.team_models, afs.budgets
  TO afs_gateway;
GRANT SELECT, UPDATE (spent_usd, reserved_usd, updated_at) ON afs.spend_counters TO afs_gateway;
GRANT INSERT ON afs.usage_events, afs.budget_threshold_events, afs.outbox_events TO afs_gateway;
GRANT USAGE ON SEQUENCE afs.usage_events_id_seq TO afs_gateway;
GRANT EXECUTE ON FUNCTION afs.reserve_spend(text, timestamptz, numeric),
                          afs.settle_spend(text, timestamptz, numeric, numeric) TO afs_gateway;

-- afs_billing: daily rollups and reconciliation.
GRANT SELECT ON afs.teams, afs.agents, afs.models, afs.usage_events TO afs_billing;
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.cost_daily, afs.cost_reconciliations TO afs_billing;
GRANT INSERT ON afs.outbox_events TO afs_billing;

-- afs_readonly: reporting. Audit payloads (before/after) are excluded.
GRANT SELECT ON ALL TABLES IN SCHEMA afs TO afs_readonly;
REVOKE SELECT ON afs.audit_log FROM afs_readonly;
GRANT SELECT (id, occurred_at, actor_type, actor_id, action, outcome, resource_kind, resource_id,
              team_id, request_id) ON afs.audit_log TO afs_readonly;
REVOKE SELECT ON afs.api_keys FROM afs_readonly;

-- Nobody but the owner may change or remove audit history (the trigger blocks the owner too).
REVOKE UPDATE, DELETE, TRUNCATE ON afs.audit_log FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------
-- Row-level security for afs_app
-- ---------------------------------------------------------------------------------------------

CREATE FUNCTION afs.caller_is_service_admin() RETURNS boolean
  LANGUAGE sql STABLE
  RETURN coalesce(current_setting('afs.service_admin', true), 'off') = 'on';

CREATE FUNCTION afs.caller_sees_team(p_team_id text) RETURNS boolean
  LANGUAGE sql STABLE
  RETURN afs.caller_is_service_admin()
      OR (p_team_id IS NOT NULL
          AND p_team_id = ANY (string_to_array(coalesce(current_setting('afs.team_ids', true), ''), ',')));

DO $$
DECLARE
  t text;
BEGIN
  -- Tables keyed by team_id.
  FOREACH t IN ARRAY ARRAY[
    'api_keys', 'team_models', 'secrets', 'agents', 'agent_secret_bindings', 'agent_identities',
    'team_egress_rules', 'budgets', 'log_destinations', 'notification_channels', 'work_orders',
    'usage_events', 'cost_daily', 'cost_reconciliations', 'resource_status', 'config_revisions',
    'audit_log', 'outbox_events']
  LOOP
    EXECUTE format('ALTER TABLE afs.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY app_team_scope ON afs.%I TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id))', t);
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_reconciler, afs_gateway, afs_billing, afs_readonly USING (true) WITH CHECK (true)', t);
  END LOOP;
END
$$;

-- teams: keyed by id. Creating a team is a service-admin action.
ALTER TABLE afs.teams ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.teams TO afs_app
  USING (afs.caller_sees_team(id))
  WITH CHECK (afs.caller_sees_team(id));
CREATE POLICY service_roles_all ON afs.teams TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

-- Budget/spend internals hang off budgets; scope through the budget's team.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['spend_counters', 'budget_threshold_events']
  LOOP
    EXECUTE format('ALTER TABLE afs.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY app_team_scope ON afs.%I TO afs_app
                     USING (EXISTS (SELECT 1 FROM afs.budgets b WHERE b.id = budget_id))$p$, t);
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_reconciler, afs_gateway, afs_billing, afs_readonly USING (true) WITH CHECK (true)', t);
  END LOOP;
END
$$;
