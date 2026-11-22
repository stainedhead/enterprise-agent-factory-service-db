-- Reverses 000020. Down migrations are for local use and tests. Role afs_edge is cluster-level and stays.

-- Swarm collaboration: the 000019 functions.
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

  UPDATE afs.work_orders w SET team_id = v_team, status = 'assigned', assigned_at = now() WHERE w.id = wo.id;

  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'InstantiateWorkOrderTeam', 'allowed', 'work_orders', wo.id, v_team,
          jsonb_build_object('teamId', v_team, 'templateId', tpl.id, 'budgetUsd', v_budget, 'expiresAt', v_expire,
                             'pools', v_pools));
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
BEGIN
  SELECT w.team_id, w.status INTO v_team, v_status FROM afs.work_orders w WHERE w.id = p_work_order_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no work order %', p_work_order_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_team IS NULL OR v_status NOT IN ('assigned', 'in_progress', 'pr_opened') THEN
    RAISE EXCEPTION 'work order % is % and has no live remediation team', p_work_order_id, v_status
      USING ERRCODE = 'object_not_in_prerequisite_state';
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

-- Rows only 000020 could create (local use: a team's collaboration agents become ordinary agents).
DELETE FROM afs.agent_secret_bindings b USING afs.secrets s
 WHERE b.team_id = s.team_id AND b.secret_id = s.id AND s.managed_by <> 'user';
DELETE FROM afs.secrets WHERE managed_by <> 'user';
DELETE FROM afs.role_bindings WHERE role = 'team_collaborator';
DELETE FROM afs.api_keys WHERE role = 'team_collaborator';
DELETE FROM afs.service_settings WHERE key LIKE 'collab.%';

-- Edge role objects.
REVOKE EXECUTE ON FUNCTION afs.schema_version() FROM afs_edge;
REVOKE USAGE ON SCHEMA afs FROM afs_edge;
DROP FUNCTION afs.emit_collab_secret_detected(text, text, text, text, text, text, integer);
DROP FUNCTION afs.record_collab_access(jsonb);
DROP FUNCTION afs.collab_principal_key(text, bytea);
DROP FUNCTION afs.collab_principal(text, text, text, text[]);
DROP FUNCTION afs.collab_routes();
DROP FUNCTION afs.collab_settings();
DROP FUNCTION afs.purge_collab_edge_sessions();
DROP FUNCTION afs.collab_session_revoke(bytea);
DROP FUNCTION afs.collab_session_get(bytea);
DROP FUNCTION afs.collab_handoff_consume(bytea, text, bytea);
DROP FUNCTION afs.collab_handoff_create(bytea, text, text, text, text, text, text[]);
DROP TABLE afs.collab_edge_handoffs;
DROP TABLE afs.collab_edge_sessions;

-- Retention, as 000013 defined it.
CREATE OR REPLACE FUNCTION afs.drop_partitions_older_than(p_months integer) RETURNS SETOF text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  r record;
  v_cutoff date := (date_trunc('month', now()) - make_interval(months => p_months))::date;
BEGIN
  IF p_months < 1 THEN
    RAISE EXCEPTION 'keep at least one month' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  FOR r IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace n ON n.oid = p.relnamespace
     WHERE n.nspname = 'afs' AND p.relname IN ('usage_events', 'agent_activity', 'external_traffic')
       AND c.relname ~ '_[0-9]{6}$'
       AND to_date(right(c.relname, 6), 'YYYYMM') < v_cutoff
     ORDER BY 1
  LOOP
    EXECUTE format('DROP TABLE afs.%I', r.relname);
    RETURN NEXT r.relname;
  END LOOP;
END $$;
DROP FUNCTION afs.ensure_collaboration_access_partition(date);
DROP TABLE afs.collaboration_access;

-- Key functions, secrets.
DROP FUNCTION afs.record_collab_board_key(text, text, text);
DROP FUNCTION afs.remove_collab_agent_key(text, text);
DROP FUNCTION afs.record_collab_agent_key(text, text, text);
DROP FUNCTION afs.collab_key_arn_ok(text, text, text, text);

CREATE OR REPLACE FUNCTION afs.binding_respects_scope() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_agent text;
  v_pool  text;
BEGIN
  SELECT agent_id, pool_id INTO v_agent, v_pool FROM afs.secrets WHERE team_id = NEW.team_id AND id = NEW.secret_id;
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

REVOKE INSERT, UPDATE, DELETE ON afs.secrets FROM afs_reconciler;
DROP TRIGGER secrets_managed_guard ON afs.secrets;
DROP FUNCTION afs.secrets_managed_guard();
CREATE OR REPLACE FUNCTION afs.secrets_managed_path() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.path := afs.secret_path(NEW.team_id, NEW.agent_id, NEW.pool_id, NEW.name);
  ELSIF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
     OR NEW.pool_id IS DISTINCT FROM OLD.pool_id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.path IS DISTINCT FROM OLD.path
     OR NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn THEN
    RAISE EXCEPTION 'a secret''s team, scope, name, path and ARN cannot change; create a new secret'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;
DROP INDEX afs.secrets_paperclip_name_uq;
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_registered_paperclip_check;
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_origin_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_origin_check CHECK (origin = 'managed');
ALTER TABLE afs.secrets DROP COLUMN managed_by;

-- Hostname hold, links, collaboration rows, cleanup.
DROP TRIGGER teams_collab_hold_refuse ON afs.teams;
DROP TRIGGER teams_collab_hold ON afs.teams;
DROP FUNCTION afs.teams_collab_hold_refuse();
DROP FUNCTION afs.teams_collab_hold();
DROP TABLE afs.collab_hostname_holds;
DROP TRIGGER agents_collaboration_cleanup ON afs.agents;
DROP FUNCTION afs.agents_collaboration_cleanup();
DROP TABLE afs.agent_collaboration;
DROP FUNCTION afs.agent_collaboration_guard();
DROP FUNCTION afs.agent_collaboration_generation();
DROP TABLE afs.team_collaboration;
DROP FUNCTION afs.team_collaboration_guard();
DROP FUNCTION afs.team_collaboration_generation();
CREATE OR REPLACE FUNCTION afs.record_revision() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  rec jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  rid text := coalesce(rec ->> 'id',
                       concat_ws('/', rec ->> 'team_id', rec ->> 'model_id', rec ->> 'key', rec ->> 'agent_id', rec ->> 'target'));
BEGIN
  INSERT INTO afs.config_revisions (resource_kind, resource_id, team_id, operation, version, snapshot, changed_by)
  VALUES (TG_TABLE_NAME, rid,
          CASE WHEN TG_TABLE_NAME = 'teams' THEN rec ->> 'id' ELSE rec ->> 'team_id' END,
          TG_OP, (rec ->> 'version')::bigint, rec, afs.current_actor());
  RETURN NULL;
END
$$;

-- Settings, provider client, guardrail, roles.
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_collab_check;
DROP FUNCTION afs.cidr_list_ok(jsonb);
DROP FUNCTION afs.dns_name_ok(jsonb);
ALTER TABLE afs.identity_providers
  DROP COLUMN collab_client_secret_arn,
  DROP COLUMN collab_client_id;

DROP TRIGGER teams_guardrail_guard ON afs.teams;
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
       OR NEW.may_manage_aws_accounts IS DISTINCT FROM OLD.may_manage_aws_accounts THEN
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
CREATE TRIGGER teams_guardrail_guard
  BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems, may_manage_aws_accounts, max_budget_usd, quotas,
                   ceiling_override_usd, ceiling_override_expires_at ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();
ALTER TABLE afs.teams DROP COLUMN may_expose_collaboration;

ALTER TABLE afs.api_keys DROP CONSTRAINT api_keys_role_check;
ALTER TABLE afs.api_keys ADD CONSTRAINT api_keys_role_check CHECK (role IN ('team_admin', 'team_viewer', 'security_operator'));
ALTER TABLE afs.role_bindings DROP CONSTRAINT role_bindings_role_check;
ALTER TABLE afs.role_bindings ADD CONSTRAINT role_bindings_role_check
  CHECK (role IN ('service_admin', 'security_operator', 'team_admin', 'team_viewer'));

-- Collaboration agent role and templates.
DROP TRIGGER agent_templates_capability_guard ON afs.agent_templates;
DROP FUNCTION afs.agent_templates_capability_guard();
DROP TRIGGER agents_collaboration_guard ON afs.agents;
DROP FUNCTION afs.agents_collaboration_guard();
DROP INDEX afs.agents_team_collaboration_uq;
ALTER TABLE afs.agents DROP COLUMN role;
ALTER TABLE afs.agent_templates DROP COLUMN capabilities;
DROP FUNCTION afs.capabilities_ok(text[]);
