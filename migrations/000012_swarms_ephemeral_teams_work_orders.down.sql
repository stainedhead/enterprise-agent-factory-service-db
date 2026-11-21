-- Reverses 000012 (local use and tests; production is forward-only).

DROP TABLE afs.cost_allocation_tag_status;

DROP VIEW afs.work_order_progress;
DROP POLICY app_scope ON afs.work_orders;
DROP POLICY app_scope ON afs.work_order_repos;
DROP POLICY app_scope ON afs.work_order_notifications;
DROP FUNCTION afs.caller_owns_work_order_repo(text);
DROP FUNCTION afs.work_order_team(text);
DROP TABLE afs.work_order_notifications;
DROP TABLE afs.work_order_repos;
CREATE POLICY app_team_scope ON afs.work_orders TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
REVOKE INSERT, UPDATE ON afs.work_orders FROM afs_reconciler;
DROP INDEX afs.work_orders_open_cve_uq;
ALTER TABLE afs.work_orders
  DROP CONSTRAINT work_orders_template_check,
  DROP CONSTRAINT work_orders_assigned_check,
  DROP CONSTRAINT work_orders_event_id_check,
  DROP CONSTRAINT work_orders_event_once,
  DROP COLUMN completed_at,
  DROP COLUMN assigned_at,
  DROP COLUMN budget_usd,
  DROP COLUMN template_id,
  DROP COLUMN source_event_id,
  DROP COLUMN source,
  DROP COLUMN severity,
  ADD COLUMN target_repos text[] NOT NULL DEFAULT '{}',
  ADD COLUMN owning_team text,
  ADD COLUMN results jsonb NOT NULL DEFAULT '{}';
DROP TABLE afs.swarm_templates;

DROP FUNCTION afs.caller_is_security_operator();
DELETE FROM afs.api_keys WHERE role = 'security_operator';
ALTER TABLE afs.api_keys
  DROP CONSTRAINT api_keys_scope_check,
  DROP CONSTRAINT api_keys_role_check,
  ADD CONSTRAINT api_keys_role_check CHECK (role IN ('team_admin', 'team_viewer')),
  ALTER COLUMN team_id SET NOT NULL;
DELETE FROM afs.role_bindings WHERE role = 'security_operator';
ALTER TABLE afs.role_bindings
  DROP CONSTRAINT role_bindings_check,
  ADD CONSTRAINT role_bindings_check CHECK ((role = 'service_admin') = (team_id IS NULL)),
  DROP CONSTRAINT role_bindings_role_check,
  ADD CONSTRAINT role_bindings_role_check CHECK (role IN ('service_admin', 'team_admin', 'team_viewer'));

REVOKE SELECT (pool_id, worker_pod) ON afs.audit_log FROM afs_readonly;
ALTER TABLE afs.audit_log
  DROP CONSTRAINT audit_log_actor_type_check,
  ADD CONSTRAINT audit_log_actor_type_check CHECK (actor_type IN ('user', 'api_key', 'system')),
  DROP COLUMN worker_pod,
  DROP COLUMN pool_id;

DROP VIEW afs.pool_workers_current;
-- Daily views back to their 000008 columns.
DROP VIEW afs.agent_activity_daily;
CREATE VIEW afs.agent_activity_daily WITH (security_invoker = true) AS
SELECT team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date AS day,
       count(*) FILTER (WHERE state = 'working') * 300 AS working_seconds,
       count(*) FILTER (WHERE state = 'idle') * 300 AS idle_seconds,
       count(*) FILTER (WHERE state IN ('paused', 'stopped')) * 300 AS off_seconds,
       count(*) FILTER (WHERE state IN ('unhealthy', 'blocked_budget')) * 300 AS impaired_seconds,
       sum(active_seconds) AS active_seconds,
       sum(model_calls) AS model_calls,
       sum(input_tokens) AS input_tokens,
       sum(output_tokens) AS output_tokens,
       sum(cost_usd) AS cost_usd,
       round(100.0 * count(*) FILTER (WHERE state = 'working')
             / nullif(count(*) FILTER (WHERE state IN ('working', 'idle')), 0), 1) AS utilization_pct
FROM afs.agent_activity
GROUP BY team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date;
DROP VIEW afs.external_traffic_daily;
CREATE VIEW afs.external_traffic_daily WITH (security_invoker = true) AS
SELECT team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date AS day, system_id,
       CASE WHEN system_id IS NULL THEN host END AS unmatched_host,
       sum(connections) FILTER (WHERE verdict = 'allowed') AS connections,
       sum(requests) FILTER (WHERE verdict = 'allowed') AS requests,
       sum(errors) FILTER (WHERE verdict = 'allowed') AS errors,
       sum(bytes_out) AS bytes_out,
       sum(bytes_in) AS bytes_in,
       coalesce(sum(connections) FILTER (WHERE verdict = 'denied'), 0) AS denied_connections,
       array_agg(DISTINCT denied_reason) FILTER (WHERE denied_reason IS NOT NULL) AS denied_reasons
FROM afs.external_traffic
GROUP BY team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date, system_id,
         CASE WHEN system_id IS NULL THEN host END;
GRANT SELECT ON afs.agent_activity_daily TO afs_app, afs_reconciler, afs_billing, afs_readonly;
GRANT SELECT ON afs.external_traffic_daily TO afs_app, afs_reconciler, afs_readonly;

DELETE FROM afs.external_traffic WHERE pool_id IS NOT NULL;
DROP INDEX afs.external_traffic_subject_uq;
ALTER TABLE afs.external_traffic
  DROP CONSTRAINT external_traffic_denied_reason_check,
  ADD CONSTRAINT external_traffic_denied_reason_check
    CHECK (denied_reason IN ('system_off_service', 'system_off_team', 'system_off_agent', 'not_in_catalog')),
  DROP CONSTRAINT external_traffic_subject_check,
  DROP COLUMN worker_pod,
  DROP COLUMN pool_id,
  ALTER COLUMN agent_id SET NOT NULL,
  ADD CONSTRAINT external_traffic_pkey PRIMARY KEY (bucket_start, agent_id, host, port, verdict);

DELETE FROM afs.agent_activity WHERE pool_id IS NOT NULL;
DROP INDEX afs.agent_activity_pool_time_idx;
DROP INDEX afs.agent_activity_subject_uq;
ALTER TABLE afs.agent_activity
  DROP CONSTRAINT agent_activity_subject_check,
  DROP COLUMN worker_pod,
  DROP COLUMN pool_id,
  ALTER COLUMN agent_id SET NOT NULL,
  ADD CONSTRAINT agent_activity_pkey PRIMARY KEY (bucket_start, agent_id);

DROP INDEX afs.cost_daily_uq;
ALTER TABLE afs.cost_daily DROP CONSTRAINT cost_daily_subject_check, DROP COLUMN pool_id;
CREATE UNIQUE INDEX cost_daily_uq
  ON afs.cost_daily (team_id, day, source, agent_id, model_id, tag_set_id) NULLS NOT DISTINCT;
ALTER TABLE afs.usage_events DROP CONSTRAINT usage_events_subject_check, DROP COLUMN worker_pod, DROP COLUMN pool_id;
DROP FUNCTION afs.worker_pod_ok(text);

DROP TABLE afs.pool_role_links;
DROP FUNCTION afs.pool_role_link_guard();

CREATE OR REPLACE VIEW afs.agent_external_access WITH (security_invoker = true) AS
SELECT a.team_id, a.id AS agent_id, s.id AS system_id, s.slug, s.name, s.category, s.endpoints,
       s.team_id IS NOT NULL AS team_declared,
       CASE
         WHEN NOT s.enabled THEN CASE WHEN s.team_id IS NULL THEN 'service' ELSE 'team' END
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.team_id = a.team_id AND o.agent_id IS NULL AND o.system_id = s.id) THEN 'team'
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.agent_id = a.id AND o.system_id = s.id) THEN 'agent'
       END AS disabled_at
FROM afs.agents a
JOIN afs.external_systems s ON s.team_id IS NULL OR s.team_id = a.team_id;
DROP VIEW afs.pool_external_access;
DELETE FROM afs.external_system_optouts WHERE pool_id IS NOT NULL;
ALTER TABLE afs.external_system_optouts
  DROP CONSTRAINT external_system_optouts_owner_system_key,
  DROP CONSTRAINT external_system_optouts_one_owner,
  DROP CONSTRAINT external_system_optouts_pool_fk,
  DROP COLUMN pool_id,
  ADD CONSTRAINT external_system_optouts_team_id_agent_id_system_id_key UNIQUE NULLS NOT DISTINCT (team_id, agent_id, system_id);

CREATE OR REPLACE FUNCTION afs.namespace_config_in_use() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF (TG_OP = 'DELETE' OR NEW.name IS DISTINCT FROM OLD.name)
     AND EXISTS (SELECT 1 FROM afs.agent_config_values a
                 WHERE a.source = 'namespace' AND a.team_id = OLD.team_id AND a.name = OLD.name)
     AND EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = OLD.team_id) THEN
    RAISE EXCEPTION 'namespace value % is used by agents; switch them to their own value first', OLD.name
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP VIEW afs.pool_config_resolved;
DROP TABLE afs.pool_config_values;
DROP TABLE afs.pool_secret_bindings;
DROP FUNCTION afs.pool_config_guard();

CREATE OR REPLACE FUNCTION afs.binding_respects_scope() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_owner text;
BEGIN
  SELECT agent_id INTO v_owner FROM afs.secrets WHERE team_id = NEW.team_id AND id = NEW.secret_id;
  IF v_owner IS NOT NULL AND v_owner <> NEW.agent_id THEN
    RAISE EXCEPTION 'secret % belongs to agent % and cannot be bound to agent %',
      NEW.secret_id, v_owner, NEW.agent_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION afs.secrets_managed_path() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.path := afs.secret_path(NEW.team_id, NEW.agent_id, NEW.name);
  ELSIF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.path IS DISTINCT FROM OLD.path
     OR NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn THEN
    RAISE EXCEPTION 'a secret''s team, scope, name, path and ARN cannot change; create a new secret'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;
DROP FUNCTION afs.secret_path(text, text, text, text);
DELETE FROM afs.secrets WHERE pool_id IS NOT NULL;
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_one_owner, DROP CONSTRAINT secrets_pool_fk, DROP COLUMN pool_id;

DELETE FROM afs.agent_identities WHERE pool_id IS NOT NULL;
DROP INDEX afs.agent_identities_kind_uq;
ALTER TABLE afs.agent_identities
  DROP CONSTRAINT agent_identities_one_owner, DROP CONSTRAINT agent_identities_pool_fk, DROP COLUMN pool_id;
CREATE UNIQUE INDEX agent_identities_kind_uq
  ON afs.agent_identities (team_id, agent_id, kind) NULLS NOT DISTINCT;

DROP TRIGGER agents_name_free_of_pools ON afs.agents;
DROP FUNCTION afs.agent_name_free_of_pools();
DROP TABLE afs.pool_handoffs;
DROP TABLE afs.agent_pools;
DROP FUNCTION afs.pool_guard();
DROP TABLE afs.swarm_stages;

DROP VIEW afs.teams_due_for_teardown;
DROP TRIGGER budgets_ephemeral_kept ON afs.budgets;
DROP TRIGGER teams_ephemeral_budget ON afs.teams;
DROP FUNCTION afs.ephemeral_budget_check();
DROP TRIGGER teams_lifecycle_guard ON afs.teams;
DROP FUNCTION afs.team_lifecycle_guard();
REVOKE UPDATE (torn_down_at, teardown_reason) ON afs.teams FROM afs_reconciler;
ALTER TABLE afs.teams
  DROP CONSTRAINT teams_teardown_ephemeral,
  DROP CONSTRAINT teams_teardown_recorded,
  DROP CONSTRAINT teams_teardown_rule_required,
  DROP COLUMN viewer_kubectl,
  DROP COLUMN teardown_reason,
  DROP COLUMN torn_down_at,
  DROP COLUMN teardown_rule;

DROP TRIGGER service_settings_work_order_channel ON afs.service_settings;
DROP FUNCTION afs.work_order_channel_guard();
DELETE FROM afs.service_settings
  WHERE key IN ('teams.ephemeral_max_days', 'work_orders.sla_warning_hours', 'billing.tag_activation_acknowledged',
                'work_orders.notification_channel_id');
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_swarm_check;
