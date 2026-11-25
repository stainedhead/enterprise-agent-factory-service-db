-- Reverses 000023 (local use and tests only; production is forward-only). Refuses when an agent or pool has a route
-- default model, since 000022 has no way to hold one. Route usage rows keep their model as <route>/<model> in model_id;
-- route cost rows become gateway (route) and cur_other (route_capacity) rows. The service default model is reset to
-- null when it is a route model.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM afs.agents WHERE default_route IS NOT NULL)
     OR EXISTS (SELECT 1 FROM afs.agent_pools WHERE default_route IS NOT NULL) THEN
    RAISE EXCEPTION 'agents or pools have a route default model; give them a Bedrock default before migrating down'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END $$;

-- 10. Change feed, revisions, grants and policies go with the tables; restore the shared functions.
CREATE OR REPLACE FUNCTION afs.notify_desired_state() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
DECLARE
  j jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
BEGIN
  PERFORM pg_notify('afs_desired_state',
    TG_TABLE_NAME || ':' || coalesce(CASE WHEN TG_TABLE_NAME = 'teams' THEN j->>'id' ELSE j->>'team_id' END, '')
                  || ':' || coalesce(j->>'id', ''));
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION afs.record_revision() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  rec jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  rid text := CASE TG_TABLE_NAME
                WHEN 'team_collaboration' THEN rec ->> 'team_id'
                WHEN 'agent_models' THEN concat_ws('/', rec ->> 'team_id', rec ->> 'agent_id', rec ->> 'model_id')
                WHEN 'pool_models' THEN concat_ws('/', rec ->> 'team_id', rec ->> 'pool_id', rec ->> 'model_id')
                ELSE coalesce(rec ->> 'id',
                              concat_ws('/', rec ->> 'team_id', rec ->> 'model_id', rec ->> 'key', rec ->> 'agent_id', rec ->> 'target'))
              END;
BEGIN
  INSERT INTO afs.config_revisions (resource_kind, resource_id, team_id, operation, version, snapshot, changed_by)
  VALUES (TG_TABLE_NAME, rid,
          CASE WHEN TG_TABLE_NAME = 'teams' THEN rec ->> 'id' ELSE rec ->> 'team_id' END,
          TG_OP, (rec ->> 'version')::bigint, rec, afs.current_actor());
  RETURN NULL;
END
$$;

-- 9. Usage and cost.
ALTER TABLE afs.usage_events DROP CONSTRAINT usage_events_route_check;
UPDATE afs.usage_events u SET model_id = coalesce((SELECT e.slug FROM afs.model_endpoints e WHERE e.id = u.endpoint_id), 'route') || '/' || coalesce(u.model_name, '')
 WHERE u.model_id IS NULL;
ALTER TABLE afs.usage_events ALTER COLUMN model_id SET NOT NULL;
ALTER TABLE afs.usage_events
  DROP COLUMN endpoint_id,
  DROP COLUMN model_name,
  DROP COLUMN usage_source,
  DROP COLUMN reasoning_tokens,
  DROP COLUMN ttft_ms,
  DROP COLUMN upstream_ms,
  DROP COLUMN gateway_ms,
  DROP COLUMN http_status;
UPDATE afs.cost_daily SET source = CASE source WHEN 'route' THEN 'gateway' ELSE 'cur_other' END WHERE source IN ('route', 'route_capacity');
ALTER TABLE afs.cost_daily DROP CONSTRAINT cost_daily_source_check;
ALTER TABLE afs.cost_daily ADD CONSTRAINT cost_daily_source_check
  CHECK (source IN ('gateway', 'cur_bedrock', 'cur_eks', 'cur_other'));
COMMENT ON COLUMN afs.cost_daily.model_id IS NULL;

-- 8. Settings.
CREATE OR REPLACE FUNCTION afs.service_settings_orchestration_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  k       text;
  v_tpl   text;
  v_limit text;
  v_ui    text;
  v_api   text;
  m       text;
BEGIN
  IF NEW.key = 'orchestration.tools' THEN
    FOREACH k IN ARRAY ARRAY['paperclip', 'buzz'] LOOP
      v_tpl := NEW.value -> k ->> 'templateId';
      IF v_tpl IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM afs.agent_templates t
            WHERE t.id = v_tpl AND 'orchestration' = ANY (t.capabilities) AND 'tool:' || k = ANY (t.capabilities)) THEN
        RAISE EXCEPTION 'agent template % for tool % does not exist or lacks the orchestration and tool:% capabilities', v_tpl, k, k
          USING ERRCODE = 'check_violation', CONSTRAINT = 'orchestration_tools_template';
      END IF;
    END LOOP;
  ELSIF NEW.key IN ('orchestration.default_limit', 'orchestration.default_web_ui_exposure', 'orchestration.default_web_api_exposure') THEN
    v_limit := CASE WHEN NEW.key = 'orchestration.default_limit' THEN NEW.value #>> '{}'
                    ELSE (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'orchestration.default_limit') END;
    v_ui := CASE WHEN NEW.key = 'orchestration.default_web_ui_exposure' THEN NEW.value #>> '{}'
                 ELSE (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'orchestration.default_web_ui_exposure') END;
    v_api := CASE WHEN NEW.key = 'orchestration.default_web_api_exposure' THEN NEW.value #>> '{}'
                  ELSE (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'orchestration.default_web_api_exposure') END;
    IF afs.exposure_rank(v_ui) > afs.exposure_rank(v_limit) OR afs.exposure_rank(v_api) > afs.exposure_rank(v_limit) THEN
      RAISE EXCEPTION 'the default Web UI and Web API exposure (% and %) cannot be above the default limit (%)', v_ui, v_api, v_limit
        USING ERRCODE = 'check_violation', CONSTRAINT = 'service_settings_orchestration_check';
    END IF;
  ELSIF NEW.key = 'models.default_team_models' AND afs.model_id_list_ok(NEW.value) THEN
    FOR m IN SELECT jsonb_array_elements_text(NEW.value) LOOP
      IF NOT EXISTS (SELECT 1 FROM afs.models x WHERE x.id = m) THEN
        RAISE EXCEPTION 'model % does not exist', m USING ERRCODE = 'check_violation', CONSTRAINT = 'service_settings_models_check';
      END IF;
    END LOOP;
  ELSIF NEW.key = 'models.default_model_id' AND jsonb_typeof(NEW.value) = 'string' THEN
    IF NOT EXISTS (SELECT 1 FROM afs.models x WHERE x.id = NEW.value #>> '{}') THEN
      RAISE EXCEPTION 'model % does not exist', NEW.value #>> '{}'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'service_settings_models_check';
    END IF;
  END IF;
  RETURN NEW;
END $$;
UPDATE afs.service_settings SET value = 'null'
 WHERE key = 'models.default_model_id' AND jsonb_typeof(value) = 'string'
   AND NOT EXISTS (SELECT 1 FROM afs.models m WHERE m.id = value #>> '{}');
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_models_check;
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_models_check CHECK (
  (key NOT IN ('models.service_access', 'models.default_team_access')
   OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') IN ('all', 'selected')))
  AND (key <> 'models.default_team_models' OR afs.model_id_list_ok(value))
  AND (key <> 'models.default_model_id' OR jsonb_typeof(value) = 'null'
       OR (jsonb_typeof(value) = 'string' AND length(value #>> '{}') BETWEEN 1 AND 200))
);

-- 7. Effective routes and admission; the Bedrock set without the provider switch.
DROP TRIGGER agents_routes_check ON afs.agents;
DROP TRIGGER agent_pools_routes_check ON afs.agent_pools;
DROP FUNCTION afs.route_admission(text, text);
DROP VIEW afs.effective_agent_routes;
CREATE OR REPLACE VIEW afs.effective_agent_models WITH (security_invoker = true) AS
WITH cfg AS (
  SELECT coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'models.service_access'), 'all') AS service_access
), svc AS (
  SELECT m.id FROM afs.models m CROSS JOIN cfg WHERE cfg.service_access = 'all' OR m.enabled
), subjects AS (
  SELECT a.team_id, 'agent'::text AS subject_kind, a.id AS subject_id, a.model_access, a.default_model_id
    FROM afs.agents a WHERE a.deleted_at IS NULL AND a.state <> 'deleted'
  UNION ALL
  SELECT p.team_id, 'pool', p.id, p.model_access, p.default_model_id
    FROM afs.agent_pools p WHERE p.deleted_at IS NULL AND p.state <> 'deleted'
)
SELECT s.team_id, s.subject_kind, s.subject_id, m.id AS model_id, (m.id = s.default_model_id) AS is_default
  FROM subjects s
  JOIN afs.teams t ON t.id = s.team_id AND t.state <> 'deleted'
  CROSS JOIN svc m
 WHERE (t.model_access = 'all' OR EXISTS (SELECT 1 FROM afs.team_models tm WHERE tm.team_id = t.id AND tm.model_id = m.id))
   AND (s.model_access = 'all'
        OR (s.subject_kind = 'agent' AND EXISTS (SELECT 1 FROM afs.agent_models x WHERE x.team_id = s.team_id AND x.agent_id = s.subject_id AND x.model_id = m.id))
        OR (s.subject_kind = 'pool' AND EXISTS (SELECT 1 FROM afs.pool_models x WHERE x.team_id = s.team_id AND x.pool_id = s.subject_id AND x.model_id = m.id)))
   AND EXISTS (SELECT 1 FROM afs.model_prices pr WHERE pr.model_id = m.id AND pr.effective_from <= now());
CREATE OR REPLACE FUNCTION afs.model_admission(p_subject_kind text, p_subject_id text) RETURNS TABLE (model_id text, reason text)
  LANGUAGE sql STABLE
  SET search_path = pg_catalog, afs
AS $$
  WITH cfg AS (
    SELECT coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'models.service_access'), 'all') AS service_access
  ), subj AS (
    SELECT a.team_id, a.id AS subject_id, a.model_access FROM afs.agents a
     WHERE p_subject_kind = 'agent' AND a.id = p_subject_id AND a.deleted_at IS NULL
    UNION ALL
    SELECT p.team_id, p.id, p.model_access FROM afs.agent_pools p
     WHERE p_subject_kind = 'pool' AND p.id = p_subject_id AND p.deleted_at IS NULL
  )
  SELECT m.id,
         CASE WHEN NOT (cfg.service_access = 'all' OR m.enabled) THEN 'model_not_enabled_for_service'
              WHEN NOT (t.model_access = 'all'
                        OR EXISTS (SELECT 1 FROM afs.team_models tm WHERE tm.team_id = t.id AND tm.model_id = m.id))
                   THEN 'model_not_enabled_for_team'
              WHEN NOT (s.model_access = 'all'
                        OR (p_subject_kind = 'agent' AND EXISTS (SELECT 1 FROM afs.agent_models x WHERE x.team_id = s.team_id AND x.agent_id = s.subject_id AND x.model_id = m.id))
                        OR (p_subject_kind = 'pool' AND EXISTS (SELECT 1 FROM afs.pool_models x WHERE x.team_id = s.team_id AND x.pool_id = s.subject_id AND x.model_id = m.id)))
                   THEN 'model_not_enabled_for_agent'
              WHEN NOT EXISTS (SELECT 1 FROM afs.model_prices pr WHERE pr.model_id = m.id AND pr.effective_from <= now())
                   THEN 'model_not_priced'
         END
    FROM subj s
    JOIN afs.teams t ON t.id = s.team_id
    CROSS JOIN cfg
    CROSS JOIN afs.models m
   ORDER BY m.id
$$;

-- 6. Default models: back to the foreign keys of 000022.
DROP TRIGGER models_in_use_guard ON afs.models;
DROP FUNCTION afs.models_in_use_guard();
DROP TRIGGER agents_default_route_ref ON afs.agents;
DROP TRIGGER agent_pools_default_route_ref ON afs.agent_pools;
DROP FUNCTION afs.default_model_ref();
DROP TRIGGER agents_models_check ON afs.agents;
DROP TRIGGER agent_pools_models_check ON afs.agent_pools;
CREATE OR REPLACE FUNCTION afs.subject_models_check() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_rec     jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  v_is_pool boolean := TG_TABLE_NAME IN ('agent_pools', 'pool_models');
  v_id      text := CASE TG_TABLE_NAME WHEN 'agent_models' THEN v_rec ->> 'agent_id' WHEN 'pool_models' THEN v_rec ->> 'pool_id'
                                       ELSE v_rec ->> 'id' END;
  v_team    text := v_rec ->> 'team_id';
  v_access  text;
  v_default text;
  n         integer;
  v_in      boolean;
BEGIN
  IF v_is_pool THEN
    SELECT p.model_access, p.default_model_id INTO v_access, v_default
      FROM afs.agent_pools p WHERE p.team_id = v_team AND p.id = v_id AND p.deleted_at IS NULL;
  ELSE
    SELECT a.model_access, a.default_model_id INTO v_access, v_default
      FROM afs.agents a WHERE a.team_id = v_team AND a.id = v_id AND a.deleted_at IS NULL;
  END IF;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_access = 'selected' THEN
    IF v_is_pool THEN
      SELECT count(*), coalesce(bool_or(x.model_id = v_default), false) INTO n, v_in
        FROM afs.pool_models x WHERE x.team_id = v_team AND x.pool_id = v_id;
    ELSE
      SELECT count(*), coalesce(bool_or(x.model_id = v_default), false) INTO n, v_in
        FROM afs.agent_models x WHERE x.team_id = v_team AND x.agent_id = v_id;
    END IF;
    IF n = 0 THEN
      RAISE EXCEPTION '% % is in selected model access but has no models', CASE WHEN v_is_pool THEN 'pool' ELSE 'agent' END, v_id
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_models_selection_nonempty';
    END IF;
    IF NOT v_in THEN
      RAISE EXCEPTION 'default model % is not in the selection of %', v_default, v_id
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_default_model_allowed';
    END IF;
  END IF;
  IF NOT afs.model_enabled_for_service(v_default) OR NOT afs.model_allowed_for_team(v_team, v_default) THEN
    RAISE EXCEPTION 'default model % is not enabled for the service or not allowed for team %', v_default, v_team
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_default_model_allowed';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER agents_models_check AFTER INSERT OR UPDATE OF model_access, default_model_id ON afs.agents
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();
CREATE CONSTRAINT TRIGGER agent_pools_models_check AFTER INSERT OR UPDATE OF model_access, default_model_id ON afs.agent_pools
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();
ALTER TABLE afs.agents ADD CONSTRAINT agents_model_id_fkey FOREIGN KEY (model_id) REFERENCES afs.models (id);
ALTER TABLE afs.agents ADD CONSTRAINT agents_default_model_id_fkey FOREIGN KEY (default_model_id) REFERENCES afs.models (id);
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_model_id_fkey FOREIGN KEY (model_id) REFERENCES afs.models (id);
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_default_model_id_fkey FOREIGN KEY (default_model_id) REFERENCES afs.models (id);

-- 5 and 4. Guards, selections, teams.
DROP TRIGGER teams_default_route_select ON afs.teams;
DROP FUNCTION afs.teams_default_route_select();
CREATE OR REPLACE FUNCTION afs.team_guardrail_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_budget numeric;
  v_ceiling numeric;
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin() THEN
    IF NEW.may_add_external_systems IS DISTINCT FROM OLD.may_add_external_systems
       OR NEW.may_manage_aws_accounts IS DISTINCT FROM OLD.may_manage_aws_accounts
       OR NEW.may_expose_collaboration IS DISTINCT FROM OLD.may_expose_collaboration
       OR NEW.max_collaboration_exposure IS DISTINCT FROM OLD.max_collaboration_exposure
       OR NEW.model_access IS DISTINCT FROM OLD.model_access
       OR NEW.orchestration_required IS DISTINCT FROM OLD.orchestration_required THEN
      RAISE EXCEPTION 'only service admins decide what a team may manage itself'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.allowed_aws_accounts IS DISTINCT FROM OLD.allowed_aws_accounts AND NOT OLD.may_manage_aws_accounts THEN
      RAISE EXCEPTION 'this team''s allowed AWS accounts are managed by service admins'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.max_budget_usd IS DISTINCT FROM OLD.max_budget_usd
       OR NEW.quotas IS DISTINCT FROM OLD.quotas
       OR NEW.ceiling_override_usd IS DISTINCT FROM OLD.ceiling_override_usd
       OR NEW.ceiling_override_expires_at IS DISTINCT FROM OLD.ceiling_override_expires_at THEN
      RAISE EXCEPTION 'only service admins set a team''s ceiling and quotas'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  -- Whoever changes it, the ceiling in force may not fall below the team's budget.
  SELECT amount_usd INTO v_budget FROM afs.budgets WHERE team_id = NEW.id;
  v_ceiling := CASE WHEN NEW.ceiling_override_usd IS NOT NULL AND NEW.ceiling_override_expires_at > now()
                    THEN NEW.ceiling_override_usd ELSE NEW.max_budget_usd END;
  IF v_budget IS NOT NULL AND v_ceiling < v_budget THEN
    RAISE EXCEPTION 'ceiling % USD is below the team''s budget % USD; lower the budget first', v_ceiling, v_budget
      USING ERRCODE = 'check_violation', CONSTRAINT = 'teams_ceiling_covers_budget';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER teams_guardrail_guard ON afs.teams;
CREATE TRIGGER teams_guardrail_guard
  BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems, may_manage_aws_accounts, max_budget_usd, quotas,
                   ceiling_override_usd, ceiling_override_expires_at, may_expose_collaboration,
                   max_collaboration_exposure, model_access, orchestration_required ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

DROP TABLE afs.agent_model_endpoints;
DROP TABLE afs.pool_model_endpoints;
DROP FUNCTION afs.endpoint_in_team_set(text, text);
DROP TABLE afs.team_model_endpoints;
DROP FUNCTION afs.subject_routes_check();
DROP FUNCTION afs.subject_routes_insert_check();
DROP FUNCTION afs.team_model_endpoint_guard();

ALTER TABLE afs.agents DROP COLUMN route_access, DROP COLUMN default_route;
ALTER TABLE afs.agent_pools DROP COLUMN route_access, DROP COLUMN default_route;
ALTER TABLE afs.teams DROP COLUMN may_add_model_endpoints, DROP COLUMN gateway_deployment;

-- 3. Credentials, federation and statements.
DROP TABLE afs.provider_statements;
DROP FUNCTION afs.statement_rows_ok(jsonb);
DROP TABLE afs.endpoint_federations;
DROP TABLE afs.endpoint_credentials;
CREATE OR REPLACE FUNCTION afs.secret_path(p_team_id text, p_agent_id text, p_name text) RETURNS text
  LANGUAGE plpgsql STABLE
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_prefix text;
  v_ns     text;
  v_agent  text;
BEGIN
  SELECT value #>> '{}' INTO v_prefix FROM afs.service_settings WHERE key = 'secrets.path_prefix';
  v_prefix := coalesce(v_prefix, 'afs');

  SELECT namespace INTO v_ns FROM afs.teams WHERE id = p_team_id;
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'team % not found', p_team_id USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF p_agent_id IS NULL THEN
    v_agent := '_shared';  -- cannot collide: agent names start with a letter
  ELSE
    SELECT name INTO v_agent FROM afs.agents WHERE team_id = p_team_id AND id = p_agent_id;
    IF v_agent IS NULL THEN
      RAISE EXCEPTION 'agent % not found in team %', p_agent_id, p_team_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN v_prefix || '/' || v_ns || '/' || v_agent || '/' || p_name;
END;
$$;

-- 2. Endpoints, models and prices.
DROP TABLE afs.endpoint_capacity_costs;
DROP TABLE afs.endpoint_price_proposals;
DROP TABLE afs.endpoint_model_prices;
DROP TABLE afs.endpoint_models;
DROP FUNCTION afs.model_endpoint_slug_taken(text, text, text);
DROP TABLE afs.model_endpoints;
DROP FUNCTION afs.endpoint_price_proposal_apply();
DROP FUNCTION afs.endpoint_price_proposal_guard();
DROP FUNCTION afs.endpoint_model_prices_append_only();
DROP FUNCTION afs.endpoint_child_guard();
DROP FUNCTION afs.model_endpoint_guard();
DROP FUNCTION afs.endpoint_protocols_ok(text[]);

-- 1. Providers.
DROP FUNCTION afs.fallback_route_ok(text, text);
DROP FUNCTION afs.provider_for_host(text);
DROP FUNCTION afs.provider_enabled(text);
DROP TABLE afs.inference_providers;
DROP FUNCTION afs.inference_provider_guard();

-- 0. Helpers.
DROP FUNCTION afs.gateway_sees_team(text);
DROP FUNCTION afs.route_model_name(text);
DROP FUNCTION afs.route_model_slug(text);
DROP FUNCTION afs.url_host(text);
DROP FUNCTION afs.host_matches(text, text);
DROP FUNCTION afs.host_globs_ok(text[]);
