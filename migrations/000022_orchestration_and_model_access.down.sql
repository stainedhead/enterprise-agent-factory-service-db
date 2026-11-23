-- 000022 down: reverses the orchestration agent and model access migration for local use and tests.
-- Forward-only in production. Data that has no 1.0.1 shape is dropped or mapped: buzz secrets and Buzz teams'
-- templates lose their capability, agents_models rows and selected model access are discarded, and the 1.0.1
-- composite foreign keys to team_models are re-added NOT VALID (a team in all mode has no team_models rows).

-- A. Settings -----------------------------------------------------------------------------------------------
DROP TRIGGER service_settings_notify ON afs.service_settings;
DROP TRIGGER service_settings_alias_sync ON afs.service_settings;
DROP TRIGGER service_settings_alias_guard ON afs.service_settings;
DROP TRIGGER service_settings_orchestration_guard ON afs.service_settings;
DROP FUNCTION afs.notify_service_setting();
DROP FUNCTION afs.service_settings_alias_sync();
DROP FUNCTION afs.service_settings_alias_guard();
DROP FUNCTION afs.service_settings_orchestration_guard();
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_models_check;
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_orchestration_check;
DELETE FROM afs.service_settings WHERE key LIKE 'orchestration.%' OR key LIKE 'models.%';

-- B. Edge ------------------------------------------------------------------------------------------------------
DROP FUNCTION afs.collab_routes();
DROP FUNCTION afs.orchestration_routes();
DROP FUNCTION afs.orchestration_settings();

CREATE FUNCTION afs.collab_routes() RETURNS TABLE (
    team_id text, slug text, namespace text, hostname text, team_state text, agent_id text, agent_state text,
    web_ui_enabled boolean, rest_api_enabled boolean, web_ui_effective boolean, rest_api_effective boolean,
    may_expose boolean, ready boolean, not_ready_reason text, service_name text, port integer,
    provider_id text, issuer_url text, groups_claim text, collab_client_id text, collab_client_secret_arn text,
    provider_client_id text, provider_cli_client_id text)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  WITH cfg AS (
    SELECT (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'collab.base_domain' AND jsonb_typeof(s.value) = 'string') AS base_domain,
           coalesce((SELECT (s.value #>> '{}')::boolean FROM afs.service_settings s
                      WHERE s.key = 'collab.public_endpoints' AND jsonb_typeof(s.value) = 'boolean'), true) AS public_endpoints
  ), r AS (
    SELECT t.id AS tid, t.slug AS tslug, t.namespace AS tns, t.state AS tstate, t.may_expose_collaboration AS expose,
           a.id AS aid, a.state AS astate, c.web_ui_enabled AS web, c.rest_api_enabled AS rest,
           p.id AS pid, p.issuer_url AS pissuer, p.groups_claim AS pgroups, p.collab_client_id AS pclient, p.collab_client_secret_arn AS parn,
           p.client_id AS pconsole, p.cli_client_id AS pcli,
           (t.state = 'active' AND a.state = 'enabled' AND EXISTS (
              SELECT 1 FROM afs.resource_status rs
               WHERE rs.resource_kind = 'team_collaboration' AND rs.resource_id = t.id
                 AND rs.conditions @> '[{"type": "EndpointReady", "status": "True"}]'::jsonb)) AS is_ready
      FROM afs.team_collaboration c
      JOIN afs.teams t ON t.id = c.team_id
      JOIN afs.agents a ON a.team_id = c.team_id AND a.id = c.agent_id
      LEFT JOIN afs.identity_providers p
             ON p.id = coalesce(t.identity_provider_id, (SELECT d.id FROM afs.identity_providers d WHERE d.is_default))
     WHERE t.state NOT IN ('deleting', 'deleted') AND t.deleted_at IS NULL
  )
  SELECT r.tid, r.tslug, r.tns,
         CASE WHEN cfg.base_domain IS NULL THEN NULL ELSE r.tslug || '.' || cfg.base_domain END,
         r.tstate, r.aid, r.astate, r.web, r.rest,
         r.web AND r.expose AND cfg.public_endpoints AND cfg.base_domain IS NOT NULL AND r.pclient IS NOT NULL,
         r.rest AND r.expose AND cfg.public_endpoints AND cfg.base_domain IS NOT NULL,
         r.expose, r.is_ready,
         CASE WHEN r.is_ready THEN NULL
              WHEN r.tstate = 'suspended' THEN 'team_suspended'
              WHEN r.astate = 'paused' THEN 'paused'
              ELSE 'starting' END,
         'paperclip'::text, 3100, r.pid, r.pissuer, r.pgroups, r.pclient, r.parn, r.pconsole, r.pcli
    FROM r CROSS JOIN cfg
   ORDER BY r.tid
$$;

REVOKE ALL ON FUNCTION afs.collab_routes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.collab_routes() TO afs_edge;

CREATE OR REPLACE FUNCTION afs.record_collab_access(p_rows jsonb) RETURNS integer
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  e        jsonb;
  v_bucket timestamptz;
  v_team   text;
  n        integer := 0;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'rows must be a JSON array' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_array_length(p_rows) > 1000 THEN
    RAISE EXCEPTION 'at most 1000 rows per call' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_bucket := (e ->> 'bucket_start')::timestamptz;
    v_team := e ->> 'team_id';
    IF v_bucket IS NULL OR v_team IS NULL OR e ->> 'requests' IS NULL THEN
      RAISE EXCEPTION 'bucket_start, team_id and requests are required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF extract(epoch FROM v_bucket)::bigint % 300 <> 0 THEN
      RAISE EXCEPTION 'bucket_start % is not on a five-minute boundary', v_bucket USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_bucket < now() - interval '1 day' OR v_bucket > now() + interval '5 minutes' THEN
      RAISE EXCEPTION 'bucket_start % is outside the accepted window', v_bucket USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = v_team) THEN
      CONTINUE;
    END IF;
    INSERT INTO afs.collaboration_access AS c (bucket_start, team_id, surface, principal_kind, principal_id, outcome,
                                               service_admin_entry, requests, bytes)
    VALUES (v_bucket, v_team, e ->> 'surface', e ->> 'principal_kind', coalesce(e ->> 'principal_id', ''), e ->> 'outcome',
            coalesce((e ->> 'service_admin_entry')::boolean, false), (e ->> 'requests')::integer,
            coalesce((e ->> 'bytes')::bigint, 0))
    ON CONFLICT (bucket_start, team_id, surface, principal_kind, principal_id, outcome, service_admin_entry)
    DO UPDATE SET requests = c.requests + EXCLUDED.requests, bytes = c.bytes + EXCLUDED.bytes, recorded_at = now();
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- C. Work orders and secrets ------------------------------------------------------------------------------------------
DROP FUNCTION afs.create_orchestration_agent(text, text, text, text, text, text, text, text, text[], text, jsonb, integer, text);
DROP FUNCTION afs.create_orchestration_agent_impl(text, text, text, text, text, text, text, text, text[], text, jsonb, integer, text);

CREATE OR REPLACE FUNCTION afs.instantiate_work_order_team(p_work_order_id text) RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  wo       afs.work_orders;
  tpl      afs.swarm_templates;
  v_team   text;
  v_cc     text;
  v_owner  text;
  v_budget numeric;
  v_expire timestamptz;
  v_stages jsonb := '{}';
  v_pools  jsonb := '{}';
  v_id     text;
  v_from   text;
  v_to     text;
  e        jsonb;
  n        bigint;
  kv       record;
  ct       afs.agent_templates;
  v_ctpl   text;
  v_img    text;
  v_model  text;
  v_cagent text;
BEGIN
  SELECT * INTO wo FROM afs.work_orders w WHERE w.id = p_work_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no work order %', p_work_order_id USING ERRCODE = 'no_data_found';
  END IF;
  IF wo.team_id IS NOT NULL THEN
    RETURN wo.team_id;
  END IF;
  IF wo.status <> 'open' THEN
    RAISE EXCEPTION 'work order % is %, not open', wo.id, wo.status USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF wo.template_id IS NULL THEN
    RAISE EXCEPTION 'work order % has no swarm template', wo.id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  SELECT * INTO tpl FROM afs.swarm_templates s WHERE s.id = wo.template_id FOR SHARE;
  IF NOT tpl.enabled THEN
    RAISE EXCEPTION 'swarm template % is disabled', tpl.name USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF tpl.spec ? 'collaboration' THEN
    v_ctpl := tpl.spec -> 'collaboration' ->> 'templateId';
    SELECT * INTO ct FROM afs.agent_templates x WHERE x.id = v_ctpl;
    IF v_ctpl IS NULL OR NOT FOUND OR NOT ct.enabled OR NOT ('paperclip' = ANY (ct.capabilities)) THEN
      RAISE EXCEPTION 'swarm template % names collaboration template %, which is unknown, disabled or has no paperclip capability', tpl.name, coalesce(v_ctpl, '(none)')
        USING ERRCODE = 'check_violation';
    END IF;
    -- DB-D18: agent_templates has no model or repository column; take both from the swarm's first pool.
    v_model := tpl.spec -> 'pools' -> 0 ->> 'modelId';
    v_img := coalesce(tpl.spec -> 'collaboration' ->> 'image',
                      regexp_replace(tpl.spec -> 'pools' -> 0 ->> 'image', '@sha256:.*$', '') || '@' || ct.current_image_digest);
    IF v_model IS NULL OR v_img IS NULL THEN
      RAISE EXCEPTION 'swarm template % has a collaboration agent but no pool to take its model and image from', tpl.name
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  v_cc := coalesce(nullif(tpl.spec ->> 'costCenter', ''),
                   (SELECT nullif(s.value #>> '{}', '') FROM afs.service_settings s WHERE s.key = 'work_orders.cost_center'));
  v_owner := coalesce(nullif(tpl.spec ->> 'ownerEmail', ''),
                      (SELECT nullif(s.value #>> '{}', '') FROM afs.service_settings s WHERE s.key = 'work_orders.owner_email'));
  IF v_cc IS NULL OR v_owner IS NULL THEN
    RAISE EXCEPTION 'swarm template % names no costCenter or ownerEmail, and service settings work_orders.cost_center or work_orders.owner_email are not set', tpl.name
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  v_team := afs.new_id('team');
  v_budget := coalesce(wo.budget_usd, tpl.budget_usd);
  v_expire := now() + make_interval(hours => tpl.ttl_hours);

  INSERT INTO afs.teams (id, slug, display_name, description, kind, cost_center, owner_email, max_budget_usd,
                         expires_at, teardown_rule, labels)
  VALUES (v_team, 'wo-' || lower(substr(v_team, 6)), left('Remediation: ' || coalesce(wo.external_ref, wo.title), 120),
          wo.title, 'ephemeral', v_cc, v_owner, v_budget, v_expire, tpl.teardown_rule,
          jsonb_build_object('afs.work_order_id', wo.id, 'afs.swarm_template', tpl.name));
  FOR kv IN SELECT * FROM jsonb_each_text(coalesce(tpl.spec -> 'tags', '{}')) LOOP
    INSERT INTO afs.team_tags (team_id, key, value) VALUES (v_team, kv.key, kv.value);
  END LOOP;
  INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust)
  VALUES (afs.new_id('bud'), v_team, 'lifetime', v_budget, 'block');
  INSERT INTO afs.team_models (team_id, model_id)
  SELECT DISTINCT v_team, p ->> 'modelId' FROM jsonb_array_elements(coalesce(tpl.spec -> 'pools', '[]')) p;

  FOR e, n IN SELECT * FROM jsonb_array_elements(coalesce(tpl.spec -> 'stages', '[]')) WITH ORDINALITY LOOP
    v_id := afs.new_id('stg');
    INSERT INTO afs.swarm_stages (id, team_id, name, position, description)
    VALUES (v_id, v_team, e ->> 'name', coalesce((e ->> 'position')::smallint, n::smallint), coalesce(e ->> 'description', ''));
    v_stages := v_stages || jsonb_build_object(e ->> 'name', v_id);
  END LOOP;

  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(tpl.spec -> 'pools', '[]')) LOOP
    IF e ? 'stage' AND NOT v_stages ? (e ->> 'stage') THEN
      RAISE EXCEPTION 'pool % names stage %, which swarm template % does not define', e ->> 'name', e ->> 'stage', tpl.name
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    v_id := afs.new_id('pool');
    INSERT INTO afs.agent_pools (id, team_id, name, description, stage_id, template, template_id, image, persona,
                                 model_id, workers, resources, scratch_size_gib, shared_volume)
    VALUES (v_id, v_team, e ->> 'name', coalesce(e ->> 'description', ''), v_stages ->> (e ->> 'stage'),
            e ->> 'template', e ->> 'templateId', e ->> 'image', coalesce(e ->> 'persona', ''), e ->> 'modelId',
            coalesce((e ->> 'workers')::integer, 1), coalesce(e -> 'resources', '{}'),
            coalesce((e ->> 'scratchSizeGiB')::integer, 20), coalesce(e ->> 'sharedVolume', 'none'));
    v_pools := v_pools || jsonb_build_object(e ->> 'name', v_id);
    INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload)
    VALUES ('pool.created', 'agent_pools', v_id, v_team, afs.event_detail(v_team, v_id, jsonb_build_object('poolId', v_id, 'teamId', v_team)));
  END LOOP;

  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(tpl.spec -> 'handoffs', '[]')) LOOP
    v_from := v_pools ->> (e ->> 'from');
    v_to := v_pools ->> (e ->> 'to');
    IF v_from IS NULL OR v_to IS NULL THEN
      RAISE EXCEPTION 'handoff % -> % names a pool swarm template % does not define', e ->> 'from', e ->> 'to', tpl.name
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO afs.pool_handoffs (team_id, from_pool_id, to_pool_id) VALUES (v_team, v_from, v_to);
  END LOOP;

  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(tpl.spec -> 'configValues', '[]')) LOOP
    v_id := v_pools ->> (e ->> 'pool');
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'configuration value % names pool %, which swarm template % does not define', e ->> 'name', e ->> 'pool', tpl.name
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO afs.pool_config_values (id, team_id, pool_id, name, source, config_value)
    VALUES (afs.new_id('pcv'), v_team, v_id, e ->> 'name', coalesce(e ->> 'source', 'literal'), e ->> 'value');
  END LOOP;

  IF v_ctpl IS NOT NULL THEN
    v_cagent := afs.new_id('agt');
    INSERT INTO afs.agents (id, team_id, name, template, image, model_id, resources, role, template_id, iam_identity, snapshot_schedule)
    VALUES (v_cagent, v_team, 'paperclip', ct.harness, v_img, v_model, ct.default_resources, 'collaboration', ct.id, 'dedicated', 'daily');
    INSERT INTO afs.team_collaboration (team_id, agent_id) VALUES (v_team, v_cagent);
    INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload)
    VALUES ('agent.created', 'agents', v_cagent, v_team, afs.event_detail(v_team, NULL, jsonb_build_object('agentId', v_cagent, 'teamId', v_team)));
  END IF;

  UPDATE afs.work_orders w SET team_id = v_team, status = 'assigned', assigned_at = now() WHERE w.id = wo.id;

  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'InstantiateWorkOrderTeam', 'allowed', 'work_orders', wo.id, v_team,
          jsonb_build_object('teamId', v_team, 'templateId', tpl.id, 'budgetUsd', v_budget, 'expiresAt', v_expire,
                             'pools', v_pools, 'collaborationAgentId', v_cagent));
  INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES
    ('team.created', 'teams', v_team, v_team,
     afs.event_detail(v_team, NULL, jsonb_build_object('teamId', v_team, 'kind', 'ephemeral', 'workOrderId', wo.id))),
    ('work_order.assigned', 'work_orders', wo.id, v_team,
     afs.event_detail(v_team, NULL, jsonb_build_object('workOrderId', wo.id, 'teamId', v_team)));
  RETURN v_team;
END $$;

CREATE OR REPLACE FUNCTION afs.record_work_order_secret(
    p_work_order_id text, p_pool_id text, p_name text, p_description text, p_arn text, p_delivery text, p_target text)
  RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_team   text;
  v_status text;
  v_secret text;
  v_env    text;
BEGIN
  SELECT w.team_id, w.status INTO v_team, v_status FROM afs.work_orders w WHERE w.id = p_work_order_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no work order %', p_work_order_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_team IS NULL OR v_status NOT IN ('assigned', 'in_progress', 'pr_opened') THEN
    RAISE EXCEPTION 'work order % is % and has no live remediation team', p_work_order_id, v_status
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  IF p_pool_id LIKE 'agt\_%' THEN
    -- The team's collaboration agent: only its three boot secrets, AFS-managed, delivered as environment variables.
    PERFORM 1 FROM afs.agents a
     WHERE a.id = p_pool_id AND a.team_id = v_team AND a.role = 'collaboration' AND a.deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% is not the collaboration agent of team %', p_pool_id, v_team USING ERRCODE = 'check_violation';
    END IF;
    v_env := CASE p_name WHEN 'paperclip-better-auth-secret' THEN 'BETTER_AUTH_SECRET'
                         WHEN 'paperclip-tool-action-signing-secret' THEN 'PAPERCLIP_TOOL_ACTION_SIGNING_SECRET'
                         WHEN 'paperclip-secrets-master-key' THEN 'PAPERCLIP_SECRETS_MASTER_KEY' END;
    IF v_env IS NULL OR p_delivery <> 'env' OR p_target <> v_env THEN
      RAISE EXCEPTION 'a collaboration agent takes only its three boot secrets, as environment variables' USING ERRCODE = 'check_violation';
    END IF;
    SELECT s.id INTO v_secret FROM afs.secrets s WHERE s.team_id = v_team AND s.agent_id = p_pool_id AND s.name = p_name;
    IF FOUND THEN
      RETURN v_secret;
    END IF;
    v_secret := afs.new_id('sec');
    INSERT INTO afs.secrets (id, team_id, name, description, secrets_manager_arn, origin, managed_by, agent_id)
    VALUES (v_secret, v_team, p_name, coalesce(p_description, ''), p_arn, 'managed', 'afs', p_pool_id);
    INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target)
    VALUES (v_team, p_pool_id, v_secret, p_delivery, p_target);
    INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
    VALUES ('system', afs.current_actor(), 'RecordWorkOrderSecret', 'allowed', 'secrets', v_secret, v_team,
            jsonb_build_object('workOrderId', p_work_order_id, 'name', p_name, 'delivery', p_delivery, 'target', p_target,
                               'agentId', p_pool_id));
    INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload)
    VALUES ('secret.created', 'secrets', v_secret, v_team,
            afs.event_detail(v_team, NULL, jsonb_build_object('secretId', v_secret, 'name', p_name, 'scope', 'agent', 'agentId', p_pool_id)));
    RETURN v_secret;
  END IF;

  PERFORM 1 FROM afs.agent_pools p
   WHERE p.id = p_pool_id AND p.team_id = v_team AND p.state IN ('enabled', 'paused') AND p.deleted_at IS NULL FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pool % is not a live pool of team %', p_pool_id, v_team USING ERRCODE = 'foreign_key_violation';
  END IF;
  SELECT s.id INTO v_secret FROM afs.secrets s WHERE s.team_id = v_team AND s.name = p_name;
  IF FOUND THEN
    RETURN v_secret;
  END IF;
  v_secret := afs.new_id('sec');
  INSERT INTO afs.secrets (id, team_id, name, description, secrets_manager_arn, origin, pool_id)
  VALUES (v_secret, v_team, p_name, coalesce(p_description, ''), p_arn, 'managed', p_pool_id);
  INSERT INTO afs.pool_secret_bindings (team_id, pool_id, secret_id, delivery, target)
  VALUES (v_team, p_pool_id, v_secret, p_delivery, p_target);
  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, pool_id, after)
  VALUES ('system', afs.current_actor(), 'RecordWorkOrderSecret', 'allowed', 'secrets', v_secret, v_team, p_pool_id,
          jsonb_build_object('workOrderId', p_work_order_id, 'name', p_name, 'delivery', p_delivery, 'target', p_target));
  INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload)
  VALUES ('secret.created', 'secrets', v_secret, v_team,
          afs.event_detail(v_team, p_pool_id, jsonb_build_object('secretId', v_secret, 'name', p_name, 'scope', 'pool')));
  RETURN v_secret;
END $$;

DELETE FROM afs.agent_secret_bindings WHERE secret_id IN (SELECT id FROM afs.secrets WHERE managed_by = 'buzz' OR name = 'buzz-agent-private-key');
DELETE FROM afs.secrets WHERE managed_by = 'buzz' OR name = 'buzz-agent-private-key';
DROP INDEX afs.secrets_tool_name_uq;
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_registered_paperclip_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_registered_paperclip_check CHECK (origin = 'managed' OR managed_by = 'paperclip') NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_registered_paperclip_check;
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_managed_by_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_managed_by_check CHECK (managed_by IN ('user', 'afs', 'paperclip')) NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_managed_by_check;
CREATE UNIQUE INDEX secrets_paperclip_name_uq ON afs.secrets (team_id, agent_id, name) WHERE managed_by = 'paperclip';
COMMENT ON COLUMN afs.secrets.managed_by IS
  'Who creates and writes the row: user (a team), afs (AFS itself), paperclip (Paperclip, through the reconciler). Immutable.';

CREATE OR REPLACE FUNCTION afs.secrets_managed_path() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_arn_path text := substring(NEW.secrets_manager_arn FROM ':secret:(.*)-[A-Za-z0-9]{6}$');
  v_prefix   text;
  v_name     text;
  v_try      integer := 0;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.managed_by = 'paperclip' THEN
      v_prefix := afs.secret_path(NEW.team_id, NEW.agent_id, 'paperclip') || '/';
      IF v_arn_path IS NULL OR left(v_arn_path, length(v_prefix)) <> v_prefix OR length(v_arn_path) = length(v_prefix) THEN
        RAISE EXCEPTION 'a paperclip secret must live below %', v_prefix
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_paperclip_prefix';
      END IF;
      NEW.path := v_arn_path;
      v_name := left('paperclip-' || regexp_replace(lower(substr(v_arn_path, length(v_prefix) + 1)), '[^a-z0-9-]', '-', 'g'), 63);
      NEW.name := v_name;
      WHILE EXISTS (SELECT 1 FROM afs.secrets s WHERE s.team_id = NEW.team_id AND s.agent_id = NEW.agent_id
                     AND s.name = NEW.name AND s.managed_by = 'paperclip') AND v_try < 20 LOOP
        v_try := v_try + 1;
        NEW.name := left(v_name, 58) || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 4);
      END LOOP;
    ELSE
      NEW.path := afs.secret_path(NEW.team_id, NEW.agent_id, NEW.pool_id, NEW.name);
    END IF;
  ELSIF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
     OR NEW.pool_id IS DISTINCT FROM OLD.pool_id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.path IS DISTINCT FROM OLD.path
     OR NEW.managed_by IS DISTINCT FROM OLD.managed_by
     OR (NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn
         AND (OLD.managed_by = 'user' OR v_arn_path IS DISTINCT FROM OLD.path)) THEN
    RAISE EXCEPTION 'a secret''s team, scope, name, path, ARN and manager cannot change; create a new secret'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION afs.secrets_managed_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_agent  afs.agents;
  v_found  boolean := false;
  v_boot   constant text[] := ARRAY['paperclip-better-auth-secret', 'paperclip-tool-action-signing-secret',
                                    'paperclip-secrets-master-key', 'paperclip-board-api-key'];
BEGIN
  -- Who writes.
  IF current_user = 'afs_app' THEN
    IF (TG_OP = 'INSERT' AND NEW.managed_by = 'paperclip') OR (TG_OP <> 'INSERT' AND OLD.managed_by = 'paperclip') THEN
      RAISE EXCEPTION 'paperclip secrets are written by the reconciler only' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn AND OLD.managed_by = 'afs' THEN
      RAISE EXCEPTION 'the ARN of an AFS-managed secret cannot be changed through the API'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' AND OLD.managed_by = 'afs' AND OLD.name = ANY (v_boot)
       AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.team_id = OLD.team_id AND a.id = OLD.agent_id
                      AND a.role = 'collaboration' AND a.deleted_at IS NULL) THEN
      RAISE EXCEPTION 'secret % belongs to a live collaboration agent and cannot be deleted', OLD.name
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  ELSIF current_user = 'afs_reconciler' THEN
    IF (TG_OP = 'INSERT' AND NEW.managed_by <> 'paperclip') OR (TG_OP <> 'INSERT' AND OLD.managed_by <> 'paperclip') THEN
      RAISE EXCEPTION 'the reconciler writes paperclip secrets only' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  -- The reserved names, on insert (a secret's name never changes).
  IF TG_OP = 'INSERT' THEN
    IF NEW.agent_id IS NOT NULL THEN
      SELECT * INTO v_agent FROM afs.agents a WHERE a.team_id = NEW.team_id AND a.id = NEW.agent_id;
      v_found := FOUND;
    END IF;
    IF NEW.managed_by = 'paperclip' THEN
      IF NEW.origin <> 'registered' THEN
        RAISE EXCEPTION 'a paperclip secret is registered, not managed' USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_registered_paperclip_check';
      END IF;
      IF NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL OR (v_found AND (v_agent.role <> 'collaboration' OR v_agent.deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'a paperclip secret is scoped to the team''s collaboration agent'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_paperclip_scope';
      END IF;
      RETURN NEW;
    END IF;
    IF NEW.origin = 'registered' THEN
      RAISE EXCEPTION 'only paperclip secrets are registered' USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_registered_paperclip_check';
    END IF;
    IF NEW.name = 'paperclip' THEN
      RAISE EXCEPTION 'the secret name paperclip is reserved: it would sit beside the paperclip/ prefix'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
    ELSIF NEW.name = ANY (v_boot) THEN
      IF NEW.managed_by <> 'afs' OR NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL
         OR (v_found AND (v_agent.role <> 'collaboration' OR v_agent.deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'secret % is AFS-managed and belongs to the team''s live collaboration agent', NEW.name
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
      END IF;
    ELSIF NEW.name = 'paperclip-agent-api-key' THEN
      IF NEW.managed_by NOT IN ('user', 'afs') OR NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL
         OR (v_found AND (v_agent.role <> 'worker' OR v_agent.deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'secret paperclip-agent-api-key belongs to a live worker agent'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
      END IF;
    ELSIF NEW.name LIKE 'paperclip-%' THEN
      RAISE EXCEPTION 'secret names starting with paperclip- are reserved for the collaboration agent''s own secrets'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
    ELSIF NEW.managed_by <> 'user' THEN
      RAISE EXCEPTION 'secret % cannot be managed by %', NEW.name, NEW.managed_by
        USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_managed_by_name';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION afs.binding_respects_scope() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_agent text;
  v_pool  text;
  v_by    text;
BEGIN
  SELECT agent_id, pool_id, managed_by INTO v_agent, v_pool, v_by FROM afs.secrets WHERE team_id = NEW.team_id AND id = NEW.secret_id;
  IF v_by = 'paperclip' THEN
    RAISE EXCEPTION 'secret % is Paperclip''s own and cannot be bound', NEW.secret_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF TG_TABLE_NAME = 'agent_secret_bindings' THEN
    IF v_pool IS NOT NULL OR (v_agent IS NOT NULL AND v_agent <> to_jsonb(NEW) ->> 'agent_id') THEN
      RAISE EXCEPTION 'secret % belongs to another agent or a pool and cannot be bound here', NEW.secret_id
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF v_agent IS NOT NULL OR (v_pool IS NOT NULL AND v_pool <> to_jsonb(NEW) ->> 'pool_id') THEN
    RAISE EXCEPTION 'secret % belongs to an agent or another pool and cannot be bound here', NEW.secret_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION afs.record_collab_agent_key(p_team_id text, p_agent_id text, p_secret_arn text) RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  a      afs.agents;
  v_mode text;
  v_sec  text;
BEGIN
  SELECT * INTO a FROM afs.agents x WHERE x.team_id = p_team_id AND x.id = p_agent_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no agent % in team %', p_agent_id, p_team_id USING ERRCODE = 'no_data_found';
  END IF;
  IF a.role <> 'worker' OR a.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'agent % is not a live worker agent', p_agent_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  SELECT c.registration_mode INTO v_mode FROM afs.team_collaboration c WHERE c.team_id = p_team_id;
  IF v_mode IS DISTINCT FROM 'managed' THEN
    RAISE EXCEPTION 'team % does not use managed registration', p_team_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.agent_collaboration ac WHERE ac.team_id = p_team_id AND ac.agent_id = p_agent_id AND ac.connect) THEN
    RAISE EXCEPTION 'agent % is not connected to Paperclip', p_agent_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NOT afs.collab_key_arn_ok(p_team_id, p_agent_id, 'paperclip-agent-api-key', p_secret_arn) THEN
    RAISE EXCEPTION 'the ARN must be a Secrets Manager ARN at path %', afs.secret_path(p_team_id, p_agent_id, 'paperclip-agent-api-key')
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT s.id INTO v_sec FROM afs.secrets s WHERE s.team_id = p_team_id AND s.agent_id = p_agent_id AND s.name = 'paperclip-agent-api-key';
  IF FOUND THEN
    UPDATE afs.secrets s SET secrets_manager_arn = p_secret_arn, last_changed_at = now() WHERE s.id = v_sec;
  ELSE
    v_sec := afs.new_id('sec');
    INSERT INTO afs.secrets (id, team_id, name, description, secrets_manager_arn, origin, managed_by, agent_id)
    VALUES (v_sec, p_team_id, 'paperclip-agent-api-key', '', p_secret_arn, 'managed', 'afs', p_agent_id);
  END IF;
  IF EXISTS (SELECT 1 FROM afs.agent_secret_bindings b
              WHERE b.agent_id = p_agent_id AND b.target = 'PAPERCLIP_AGENT_API_KEY' AND b.secret_id <> v_sec) THEN
    RAISE EXCEPTION 'target PAPERCLIP_AGENT_API_KEY of agent % is already bound to another secret', p_agent_id
      USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target)
  VALUES (p_team_id, p_agent_id, v_sec, 'env', 'PAPERCLIP_AGENT_API_KEY')
  ON CONFLICT (agent_id, target) DO NOTHING;
  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'RecordCollabAgentKey', 'allowed', 'secrets', v_sec, p_team_id,
          jsonb_build_object('agentId', p_agent_id, 'name', 'paperclip-agent-api-key'));
  RETURN v_sec;
END $$;
CREATE OR REPLACE FUNCTION afs.remove_collab_agent_key(p_team_id text, p_agent_id text) RETURNS boolean
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_sec     text;
  v_removed boolean := false;
BEGIN
  SELECT s.id INTO v_sec FROM afs.secrets s
   WHERE s.team_id = p_team_id AND s.agent_id = p_agent_id AND s.name = 'paperclip-agent-api-key' AND s.managed_by = 'afs';
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  DELETE FROM afs.agent_secret_bindings b WHERE b.team_id = p_team_id AND b.secret_id = v_sec;
  DELETE FROM afs.secrets s WHERE s.id = v_sec;
  v_removed := true;
  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'RemoveCollabAgentKey', 'allowed', 'secrets', v_sec, p_team_id,
          jsonb_build_object('agentId', p_agent_id, 'name', 'paperclip-agent-api-key'));
  RETURN v_removed;
END $$;
CREATE OR REPLACE FUNCTION afs.record_collab_board_key(p_team_id text, p_collab_agent_id text, p_secret_arn text) RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  a     afs.agents;
  v_sec text;
BEGIN
  SELECT * INTO a FROM afs.agents x WHERE x.team_id = p_team_id AND x.id = p_collab_agent_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no agent % in team %', p_collab_agent_id, p_team_id USING ERRCODE = 'no_data_found';
  END IF;
  IF a.role <> 'collaboration' OR a.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'agent % is not a live collaboration agent', p_collab_agent_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NOT afs.collab_key_arn_ok(p_team_id, p_collab_agent_id, 'paperclip-board-api-key', p_secret_arn) THEN
    RAISE EXCEPTION 'the ARN must be a Secrets Manager ARN at path %', afs.secret_path(p_team_id, p_collab_agent_id, 'paperclip-board-api-key')
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT s.id INTO v_sec FROM afs.secrets s WHERE s.team_id = p_team_id AND s.agent_id = p_collab_agent_id AND s.name = 'paperclip-board-api-key';
  IF FOUND THEN
    UPDATE afs.secrets s SET secrets_manager_arn = p_secret_arn, last_changed_at = now() WHERE s.id = v_sec;
  ELSE
    v_sec := afs.new_id('sec');
    INSERT INTO afs.secrets (id, team_id, name, description, secrets_manager_arn, origin, managed_by, agent_id)
    VALUES (v_sec, p_team_id, 'paperclip-board-api-key', '', p_secret_arn, 'managed', 'afs', p_collab_agent_id);
  END IF;
  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'RecordCollabBoardKey', 'allowed', 'secrets', v_sec, p_team_id,
          jsonb_build_object('agentId', p_collab_agent_id, 'name', 'paperclip-board-api-key'));
  RETURN v_sec;
END $$;

-- the role names below change in section F; the functions above name 'collaboration' as 1.0.1 did

-- D. Model access ------------------------------------------------------------------------------------------------------
DROP TRIGGER model_prices_notify ON afs.model_prices;
DROP TRIGGER agents_models_check ON afs.agents;
DROP TRIGGER agent_pools_models_check ON afs.agent_pools;
DROP VIEW afs.effective_agent_models;
DROP FUNCTION afs.model_admission(text, text);
DROP TABLE afs.agent_models;
DROP TABLE afs.pool_models;
DROP TABLE afs.team_inference_profiles;
DROP FUNCTION afs.team_inference_profiles_copy();
DROP FUNCTION afs.subject_models_check();
DROP FUNCTION afs.subject_models_insert_check();
DROP FUNCTION afs.model_enabled_for_service(text);
DROP FUNCTION afs.model_allowed_for_team(text, text);
DROP TRIGGER models_enabled_guard ON afs.models;
DROP FUNCTION afs.models_enabled_guard();
REVOKE INSERT (id, provider, display_name, enabled, context_window, max_output_tokens, origin, synced_at) ON afs.models FROM afs_reconciler;
REVOKE UPDATE (synced_at) ON afs.models FROM afs_reconciler;
REVOKE SELECT (key, value) ON afs.service_settings FROM afs_gateway;
ALTER TABLE afs.models DROP COLUMN origin, DROP COLUMN synced_at;
DROP TRIGGER agents_default_model_sync ON afs.agents;
DROP TRIGGER agent_pools_default_model_sync ON afs.agent_pools;
DROP FUNCTION afs.default_model_sync();
ALTER TABLE afs.agents DROP COLUMN default_model_id, DROP COLUMN model_access;
ALTER TABLE afs.agent_pools DROP COLUMN default_model_id, DROP COLUMN model_access;
ALTER TABLE afs.agent_pools DROP CONSTRAINT agent_pools_model_id_fkey;
ALTER TABLE afs.agents ADD CONSTRAINT agents_team_id_model_id_fkey FOREIGN KEY (team_id, model_id) REFERENCES afs.team_models (team_id, model_id) NOT VALID;
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_team_id_model_id_fkey FOREIGN KEY (team_id, model_id) REFERENCES afs.team_models (team_id, model_id) NOT VALID;
-- Validate when the data allows it. Under 1.1.0 an agent may use a model its team has no team_models row for (team access
-- "all"); then the constraint stays NOT VALID, which still checks new and changed rows.
DO $$
BEGIN
  ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_team_id_model_id_fkey;
EXCEPTION WHEN foreign_key_violation THEN
  NULL;
END $$;
DO $$
BEGIN
  ALTER TABLE afs.agent_pools VALIDATE CONSTRAINT agent_pools_team_id_model_id_fkey;
EXCEPTION WHEN foreign_key_violation THEN
  NULL;
END $$;

CREATE OR REPLACE FUNCTION afs.record_revision() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  rec jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  rid text := CASE WHEN TG_TABLE_NAME = 'team_collaboration' THEN rec ->> 'team_id'
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

DROP FUNCTION afs.model_id_list_ok(jsonb);
DROP FUNCTION afs.resources_ok(jsonb);
DROP FUNCTION afs.orchestration_tools_ok(jsonb);

-- E. Tool, exposure and snapshots ------------------------------------------------------------------------------
ALTER TABLE afs.collaboration_access DROP CONSTRAINT collaboration_access_pkey;
DELETE FROM afs.collaboration_access a USING afs.collaboration_access b
 WHERE a.ctid < b.ctid AND (a.bucket_start, a.team_id, a.surface, a.principal_kind, a.principal_id, a.outcome, a.service_admin_entry)
     = (b.bucket_start, b.team_id, b.surface, b.principal_kind, b.principal_id, b.outcome, b.service_admin_entry);
ALTER TABLE afs.collaboration_access DROP COLUMN exposure;
ALTER TABLE afs.collaboration_access ADD PRIMARY KEY (bucket_start, team_id, surface, principal_kind, principal_id, outcome, service_admin_entry);

DROP POLICY app_team_scope ON afs.agent_volume_snapshots;
CREATE POLICY app_team_scope ON afs.agent_volume_snapshots TO afs_app
  USING (afs.caller_sees_team(team_id))
  WITH CHECK (afs.caller_sees_team(team_id) AND reason = 'manual');
DELETE FROM afs.agent_volume_snapshots WHERE reason = 'pre_tool_change';
ALTER TABLE afs.agent_volume_snapshots DROP CONSTRAINT agent_volume_snapshots_tool_change_check;
ALTER TABLE afs.agent_volume_snapshots DROP COLUMN tool, DROP COLUMN retain_until;
ALTER TABLE afs.agent_volume_snapshots DROP CONSTRAINT agent_volume_snapshots_reason_check;
ALTER TABLE afs.agent_volume_snapshots ADD CONSTRAINT agent_volume_snapshots_reason_check
  CHECK (reason IN ('scheduled', 'manual', 'pre_delete', 'pre_change')) NOT VALID;
ALTER TABLE afs.agent_volume_snapshots VALIDATE CONSTRAINT agent_volume_snapshots_reason_check;

REVOKE UPDATE (tool, web_ui_exposure, web_api_exposure) ON afs.team_collaboration FROM afs_app;
GRANT INSERT (team_id, agent_id, web_ui_enabled, rest_api_enabled, registration_mode) ON afs.team_collaboration TO afs_app;
DROP TRIGGER agents_tool_template ON afs.agents;
DROP TRIGGER team_collaboration_tool_template ON afs.team_collaboration;
DROP TRIGGER team_collaboration_b_exposure_check ON afs.team_collaboration;
DROP TRIGGER team_collaboration_a_levels_sync ON afs.team_collaboration;
DROP FUNCTION afs.team_collaboration_tool_template();
DROP FUNCTION afs.team_collaboration_exposure_check();
DROP FUNCTION afs.team_collaboration_levels_sync();

CREATE OR REPLACE FUNCTION afs.team_collaboration_generation() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.web_ui_enabled IS DISTINCT FROM OLD.web_ui_enabled
     OR NEW.rest_api_enabled IS DISTINCT FROM OLD.rest_api_enabled
     OR NEW.registration_mode IS DISTINCT FROM OLD.registration_mode THEN
    NEW.generation := OLD.generation + 1;
  ELSE
    NEW.generation := OLD.generation;
  END IF;
  RETURN NEW;
END $$;

ALTER TABLE afs.team_collaboration DROP COLUMN tool, DROP COLUMN web_ui_exposure, DROP COLUMN web_api_exposure;

-- F. Orchestration role --------------------------------------------------------------------------------------------
DROP TRIGGER teams_orchestration_required ON afs.teams;
DROP FUNCTION afs.teams_orchestration_required();
DROP TRIGGER teams_exposure_limit_sync ON afs.teams;
DROP FUNCTION afs.teams_exposure_limit_sync();

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
       OR NEW.may_expose_collaboration IS DISTINCT FROM OLD.may_expose_collaboration THEN
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
                   ceiling_override_usd, ceiling_override_expires_at, may_expose_collaboration ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

ALTER TABLE afs.teams DROP COLUMN orchestration_required, DROP COLUMN max_collaboration_exposure, DROP COLUMN model_access;

DROP TRIGGER agents_collaboration_cleanup ON afs.agents;
DROP TRIGGER agents_orchestration_required ON afs.agents;
DROP TRIGGER agents_role_reserved_guard ON afs.agents;
DROP TRIGGER agents_orchestration_guard ON afs.agents;
DROP TRIGGER agent_pools_a_name_reserved ON afs.agent_pools;
DROP FUNCTION afs.agent_pools_name_reserved();
DROP FUNCTION afs.agents_orchestration_required();
DROP FUNCTION afs.agents_role_reserved_guard();
DROP FUNCTION afs.agents_orchestration_guard();
DROP INDEX afs.agents_team_orchestration_uq;
ALTER TABLE afs.agents DROP CONSTRAINT agents_role_check;
ALTER TABLE afs.agents DISABLE TRIGGER agents_touch;
ALTER TABLE afs.agents DISABLE TRIGGER agents_revision;
ALTER TABLE afs.agents DISABLE TRIGGER agents_notify;
UPDATE afs.agents SET role = 'collaboration' WHERE role = 'orchestration';
ALTER TABLE afs.agents ENABLE TRIGGER agents_touch;
ALTER TABLE afs.agents ENABLE TRIGGER agents_revision;
ALTER TABLE afs.agents ENABLE TRIGGER agents_notify;
ALTER TABLE afs.agents ADD CONSTRAINT agents_role_check CHECK (role IN ('worker', 'collaboration')) NOT VALID;
ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_role_check;
COMMENT ON COLUMN afs.agents.role IS 'worker, or collaboration (Paperclip: at most one live per team). Immutable.';

CREATE UNIQUE INDEX agents_team_collaboration_uq ON afs.agents (team_id)
  WHERE role = 'collaboration' AND deleted_at IS NULL;
CREATE FUNCTION afs.agents_collaboration_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  t afs.agent_templates;
  v_has boolean := false;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'an agent''s role cannot change' USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_role_immutable';
  END IF;
  IF NEW.template_id IS NOT NULL THEN
    SELECT * INTO t FROM afs.agent_templates WHERE id = NEW.template_id;
    v_has := FOUND;
  END IF;
  IF NEW.role = 'collaboration' THEN
    IF NEW.template_id IS NULL THEN
      RAISE EXCEPTION 'a collaboration agent needs an agent template (template_id)'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_collaboration_template';
    END IF;
    IF v_has AND NOT ('paperclip' = ANY (t.capabilities)) THEN
      RAISE EXCEPTION 'agent template % does not have the paperclip capability', t.name
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_collaboration_capability';
    END IF;
    IF NEW.iam_identity <> 'dedicated' THEN
      RAISE EXCEPTION 'a collaboration agent needs a dedicated identity (iam_identity = dedicated)'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_collaboration_identity';
    END IF;
    IF NEW.snapshot_schedule = 'off' THEN
      RAISE EXCEPTION 'a collaboration agent''s snapshots cannot be turned off'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_collaboration_snapshots';
    END IF;
  ELSIF v_has AND 'paperclip' = ANY (t.capabilities) THEN
    RAISE EXCEPTION 'agent template % is a collaboration template; a worker cannot use it', t.name
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_worker_capability';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agents_collaboration_guard() FROM PUBLIC;
CREATE TRIGGER agents_collaboration_guard
  BEFORE INSERT OR UPDATE OF role, template_id, iam_identity, snapshot_schedule ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.agents_collaboration_guard();


CREATE OR REPLACE FUNCTION afs.agents_collaboration_cleanup() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.state IN ('deleting', 'deleted') THEN
    DELETE FROM afs.team_collaboration WHERE team_id = NEW.team_id;
    UPDATE afs.agent_collaboration SET connect = false WHERE team_id = NEW.team_id AND connect;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.agents_collaboration_cleanup() FROM PUBLIC;
CREATE TRIGGER agents_collaboration_cleanup AFTER UPDATE OF state, deleted_at ON afs.agents
  FOR EACH ROW WHEN (NEW.role = 'collaboration') EXECUTE FUNCTION afs.agents_collaboration_cleanup();


CREATE OR REPLACE FUNCTION afs.team_collaboration_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  a     afs.agents;
BEGIN
  SELECT * INTO a FROM afs.agents x WHERE x.team_id = NEW.team_id AND x.id = NEW.agent_id;
  IF FOUND THEN
    IF a.role <> 'collaboration' THEN
      RAISE EXCEPTION 'agent % is not a collaboration agent', NEW.agent_id
        USING ERRCODE = 'check_violation', CONSTRAINT = 'team_collaboration_agent_role';
    END IF;
    -- The cleanup trigger removes the row when the agent starts deleting; do not let it come back for a dead agent.
    IF a.deleted_at IS NOT NULL OR a.state IN ('deleting', 'deleted') THEN
      RAISE EXCEPTION 'collaboration agent % is %', NEW.agent_id, a.state
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION afs.teams_collab_hold() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL
     AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.team_id = NEW.id AND a.role = 'collaboration') THEN
    INSERT INTO afs.collab_hostname_holds (slug, team_id, held_until)
    VALUES (NEW.slug, NEW.id, now() + interval '30 days')
    ON CONFLICT (slug) DO UPDATE SET team_id = EXCLUDED.team_id, held_until = EXCLUDED.held_until;
  END IF;
  RETURN NULL;
END $$;

-- G. Capabilities ----------------------------------------------------------------------------------------------------
DROP TRIGGER agent_templates_capabilities_rewrite ON afs.agent_templates;
DROP FUNCTION afs.agent_templates_capabilities_rewrite();
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_capability_guard;
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_touch;
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_revision;
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_notify;
ALTER TABLE afs.agent_templates DROP CONSTRAINT agent_templates_capabilities_check;
UPDATE afs.agent_templates SET capabilities = CASE WHEN 'tool:paperclip' = ANY (capabilities) THEN ARRAY['paperclip'] ELSE '{}' END;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_capability_guard;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_touch;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_revision;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_notify;
CREATE OR REPLACE FUNCTION afs.capabilities_ok(p text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN p IS NOT NULL
     AND coalesce(cardinality(p), 0) <= 8
     AND NOT EXISTS (SELECT 1 FROM unnest(p) AS c WHERE c IS NULL OR c <> ALL (ARRAY['paperclip']))
     AND (SELECT count(DISTINCT c) FROM unnest(p) AS c) = coalesce(cardinality(p), 0);
ALTER TABLE afs.agent_templates ADD CONSTRAINT agent_templates_capabilities_check
  CHECK (afs.capabilities_ok(capabilities)) NOT VALID;
ALTER TABLE afs.agent_templates VALIDATE CONSTRAINT agent_templates_capabilities_check;
COMMENT ON COLUMN afs.agent_templates.capabilities IS
  'Known capabilities of the image: paperclip marks a collaboration image. Service admins write it.';

CREATE OR REPLACE FUNCTION afs.agent_templates_capability_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF 'paperclip' = ANY (OLD.capabilities) AND NOT ('paperclip' = ANY (NEW.capabilities))
     AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.template_id = OLD.id AND a.role = 'collaboration' AND a.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'a live collaboration agent uses agent template %; it keeps the paperclip capability', OLD.name
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NOT ('paperclip' = ANY (OLD.capabilities)) AND 'paperclip' = ANY (NEW.capabilities)
     AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.template_id = OLD.id AND a.role = 'worker' AND a.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'a live worker agent uses agent template %; it cannot become a collaboration template', OLD.name
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END $$;

DROP FUNCTION afs.exposure_rank(text);
DROP FUNCTION afs.collab_tool_supports(text, text);
DROP FUNCTION afs.collab_tool_profile(text);

