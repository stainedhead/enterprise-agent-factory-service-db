-- 000019: work order secrets (RC-12 known gap, requested by -restapi M6) and the event envelope on
-- work order team instantiation.
--
-- 1. afs.event_detail(team_id, pool_id, data) builds the outbox payload the API contract (section 7)
--    defines: {id, occurredAt, teamId, poolId?, actor, data}. Owner only; called by the functions below.
-- 2. afs.record_work_order_secret(work_order_id, pool_id, name, description, arn, delivery, target)
--    records one secret a swarm template declares for a live work order's remediation team. The reconciler
--    creates the secret empty in Secrets Manager (the team puts the value there; no value reaches the
--    database) and passes the ARN it was given. The function inserts a managed secrets row scoped to one
--    of the team's live pools, its pool_secret_bindings row, the audit record and a secret.created
--    outbox event in the caller's transaction. Idempotent on (team, name): an existing secret returns
--    its id and writes nothing. The secrets triggers compute the managed path and the check
--    secrets_arn_matches_path rejects an ARN that does not end in it. afs_reconciler only.
--      P0002 unknown work order; 55000 work order not assigned, in_progress or pr_opened, or without a
--      team; 23503 the pool is not an enabled or paused pool of that team; 23514 ARN or binding value
--      rejected by a constraint; 23505 the pool already has a binding for that target.
-- 3. afs.instantiate_work_order_team is replaced (CREATE OR REPLACE): its team.created, pool.created and
--    work_order.assigned outbox payloads now carry the envelope. The former top-level keys (teamId,
--    poolId, kind, workOrderId) move into data; behaviour is otherwise unchanged. Rows already in the
--    outbox keep their old payload.
--
-- Lock impact: none on existing tables; CREATE OR REPLACE FUNCTION and the new functions take no table
-- locks. The function inserts into secrets and pool_secret_bindings with row locks only.

CREATE FUNCTION afs.event_detail(p_team_id text, p_pool_id text, p_data jsonb) RETURNS jsonb
  LANGUAGE sql VOLATILE
  SET search_path = pg_catalog, afs
  RETURN jsonb_strip_nulls(jsonb_build_object(
    'id', afs.new_id('evt'),
    'occurredAt', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'teamId', p_team_id, 'poolId', p_pool_id, 'actor', afs.current_actor(),
    'data', coalesce(p_data, '{}'::jsonb)));
REVOKE ALL ON FUNCTION afs.event_detail(text, text, jsonb) FROM PUBLIC;


CREATE FUNCTION afs.record_work_order_secret(
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
REVOKE ALL ON FUNCTION afs.record_work_order_secret(text, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.record_work_order_secret(text, text, text, text, text, text, text) TO afs_reconciler;

-- Instantiation, with enveloped event payloads.
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
