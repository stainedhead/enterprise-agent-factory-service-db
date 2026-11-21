-- 000016: service access the -restapi feature spec needs (its research.md §6, X-DB-1 to X-DB-6).
--
-- Row-level security hides rows until the caller's team scope is known, and the reconciler may not write
-- desired state chosen by people. Six paths need narrow, named exceptions:
--
-- 1. afs.authenticate_api_key(key_sha256) (X-DB-1, DB-US-38): afs-api finds an API key by its SHA-256
--    before it knows the caller's team (service keys have no team). Returns the key id, team, role,
--    expiry and revoked state, the team's state; never the hash. Sets last_used_at at most once a minute
--    for a usable key. afs_app only.
-- 2. afs.resolve_workload(namespace, service_account) (X-DB-2, DB-US-39): maps a workload token's
--    namespace and ServiceAccount (agent-<name> or pool-<name>) to its active team and live agent or
--    pool. afs_app and afs_gateway.
-- 3. afs.team_directory() (X-DB-3, DB-US-40): id, slug and display name of every team not deleted, for
--    service admins and security operators only (42501 otherwise). afs_app only.
-- 4. afs.instantiate_work_order_team(work_order_id) (X-DB-4, DB-US-41): creates a work order's
--    ephemeral remediation team from its swarm template (team, tags, lifetime budget, models, stages,
--    pools, handoffs, pool configuration values), assigns the work order and writes audit and outbox
--    rows; triggers write the revisions. Idempotent: a work order that has a team returns it.
--    afs_reconciler only. afs.new_id(prefix) generates the prefixed ULIDs it needs (owner only).
--    Service settings work_orders.cost_center and work_orders.owner_email (JSON strings, no default)
--    supply the team's cost center and owner when the template names none.
-- 5. afs_reconciler may update agent_pools (state, deleted_at) (X-DB-5, DB-US-42), as for agents.
-- 6. INSERT policies for afs_app (X-DB-6, DB-US-43): audit_log rows whose actor_id is the caller
--    (afs.current_actor()), whatever their team; outbox_events work order events from a security
--    operator, whatever their team. Neither makes another team's rows visible.
--
-- Lock impact: CREATE POLICY takes a brief ACCESS EXCLUSIVE lock on audit_log and outbox_events (no
-- scan, no rewrite); GRANT on agent_pools changes the catalog only. service_settings (a few dozen rows)
-- takes a brief ACCESS EXCLUSIVE lock for ADD CONSTRAINT ... NOT VALID, then VALIDATE scans it under
-- SHARE UPDATE EXCLUSIVE. New functions lock nothing.

-- Prefixed ULIDs ----------------------------------------------------------------------------------
CREATE FUNCTION afs.new_id(p_prefix text) RETURNS text
  LANGUAGE plpgsql VOLATILE
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  u    bytea := uuid_send(gen_random_uuid());
  -- 2 zero bits, 48 bits of milliseconds, 80 random bits (the uuid's version and variant bits skipped).
  bits bit varying := B'00'
    || ((extract(epoch FROM clock_timestamp()) * 1000)::bigint)::bit(48)
    || substring(('x' || encode(substring(u FROM 1 FOR 6) || substring(u FROM 11 FOR 6), 'hex'))::bit(96) FROM 1 FOR 80);
  out  text := '';
BEGIN
  FOR i IN 0..25 LOOP
    out := out || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::bit(5)::integer + 1, 1);
  END LOOP;
  RETURN p_prefix || '_' || out;
END $$;
REVOKE ALL ON FUNCTION afs.new_id(text) FROM PUBLIC;

-- 1. API keys by hash -----------------------------------------------------------------------------
CREATE FUNCTION afs.authenticate_api_key(p_key_sha256 bytea)
  RETURNS TABLE (key_id text, team_id text, principal text, role text, roles text[],
                 expires_at timestamptz, revoked_at timestamptz, state text, team_state text)
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  k afs.api_keys;
BEGIN
  SELECT * INTO k FROM afs.api_keys a WHERE a.key_sha256 = p_key_sha256;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  key_id := k.id;
  team_id := k.team_id;
  principal := k.id;
  role := k.role;
  roles := ARRAY[k.role];
  expires_at := k.expires_at;
  revoked_at := k.revoked_at;
  state := CASE WHEN k.revoked_at IS NOT NULL THEN 'revoked'
                WHEN k.expires_at <= now() THEN 'expired'
                ELSE 'active' END;
  SELECT t.state INTO team_state FROM afs.teams t WHERE t.id = k.team_id;
  IF state = 'active' AND coalesce(team_state, 'active') = 'active'
     AND (k.last_used_at IS NULL OR k.last_used_at < now() - interval '1 minute') THEN
    UPDATE afs.api_keys a SET last_used_at = now() WHERE a.id = k.id;
  END IF;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION afs.authenticate_api_key(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.authenticate_api_key(bytea) TO afs_app;

-- 2. Workloads by namespace and ServiceAccount ----------------------------------------------------
CREATE FUNCTION afs.resolve_workload(p_namespace text, p_service_account text)
  RETURNS TABLE (team_id text, agent_id text, pool_id text)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  SELECT t.id, a.id, NULL::text
    FROM afs.teams t JOIN afs.agents a ON a.team_id = t.id
   WHERE t.namespace = p_namespace AND t.state = 'active'
     AND p_service_account = 'agent-' || a.name AND a.state <> 'deleted' AND a.deleted_at IS NULL
  UNION ALL
  SELECT t.id, NULL::text, p.id
    FROM afs.teams t JOIN afs.agent_pools p ON p.team_id = t.id
   WHERE t.namespace = p_namespace AND t.state = 'active'
     AND p_service_account = 'pool-' || p.name AND p.state <> 'deleted' AND p.deleted_at IS NULL
$$;
REVOKE ALL ON FUNCTION afs.resolve_workload(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.resolve_workload(text, text) TO afs_app, afs_gateway;

-- 3. Team directory -------------------------------------------------------------------------------
CREATE FUNCTION afs.team_directory()
  RETURNS TABLE (id text, slug text, display_name text)
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NOT (afs.caller_is_service_admin() OR afs.caller_is_security_operator()) THEN
    RAISE EXCEPTION 'only service admins and security operators read the team directory'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY SELECT t.id, t.slug, t.display_name FROM afs.teams t WHERE t.state <> 'deleted' ORDER BY t.slug;
END $$;
REVOKE ALL ON FUNCTION afs.team_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.team_directory() TO afs_app;

-- 4. Remediation teams from work orders -----------------------------------------------------------
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_work_order_team_check
  CHECK ((key <> 'work_orders.cost_center'
          OR (jsonb_typeof(value) = 'string' AND length(value #>> '{}') BETWEEN 1 AND 100))
     AND (key <> 'work_orders.owner_email'
          OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') ~ '^[^@[:space:]]+@[^@[:space:]]+$'))) NOT VALID;
ALTER TABLE afs.service_settings VALIDATE CONSTRAINT service_settings_work_order_team_check;

-- The template's spec (validated by the API as SwarmTemplateSpec) is read as:
--   costCenter, ownerEmail   team fields; else service settings work_orders.cost_center and
--                            work_orders.owner_email; neither → 55000
--   tags {key: value}        team tags (required tags without a default must be here, or 23514 at commit)
--   stages [{name, position, description}]
--   pools [{name, description, stage (a stage name), template, templateId, image, persona, modelId,
--           workers, resources, scratchSizeGiB, sharedVolume}]   every modelId is enabled for the team
--   handoffs [{from, to}]    pool names
--   configValues [{pool, name, value, source}]   source defaults to literal
--   secrets                  not created here: a secret row needs the ARN Secrets Manager assigns
CREATE FUNCTION afs.instantiate_work_order_team(p_work_order_id text) RETURNS text
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
REVOKE ALL ON FUNCTION afs.instantiate_work_order_team(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.instantiate_work_order_team(text) TO afs_reconciler;

-- 5. Pool deletion by the reconciler --------------------------------------------------------------
GRANT UPDATE (state, deleted_at) ON afs.agent_pools TO afs_reconciler;

-- 6. Audit and outbox rows outside the caller's team scope ----------------------------------------
CREATE POLICY app_own_audit ON afs.audit_log FOR INSERT TO afs_app
  WITH CHECK (actor_id = afs.current_actor());
CREATE POLICY app_operator_work_order_events ON afs.outbox_events FOR INSERT TO afs_app
  WITH CHECK (afs.caller_is_security_operator() AND aggregate_kind = 'work_orders' AND event_type LIKE 'work\_order.%');
