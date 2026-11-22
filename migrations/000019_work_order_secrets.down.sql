-- Reverses 000019. Down migrations are for local use and tests.

DROP FUNCTION afs.record_work_order_secret(text, text, text, text, text, text, text);

-- afs.instantiate_work_order_team as 000016 defined it (payloads without the event envelope).
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
    VALUES ('pool.created', 'agent_pools', v_id, v_team, jsonb_build_object('poolId', v_id, 'teamId', v_team));
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
     jsonb_build_object('teamId', v_team, 'kind', 'ephemeral', 'workOrderId', wo.id)),
    ('work_order.assigned', 'work_orders', wo.id, v_team,
     jsonb_build_object('workOrderId', wo.id, 'teamId', v_team));
  RETURN v_team;
END $$;

DROP FUNCTION afs.event_detail(text, text, jsonb);
