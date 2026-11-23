-- 000022: team orchestration agent and model access (change PRD orchestration-and-model-access-PRD.md; root PRD
-- team-orchestration-agent-PRD.md DB-US-58 to DB-US-61; database contract section 7.3, v1.4.0; spec
-- 261123-orchestration-and-model-access). Release 1.1.0, lockstep with -restapi.
--
--   1. Capabilities orchestration, tool:paperclip, tool:buzz (replacing paperclip), rewrite of existing rows and
--      of a 1.0.1 write; the guard that keeps a template in use.
--   2. agents.role collaboration -> orchestration, one live orchestration agent per team, reserved name
--      orchestrator, delete guard, teams.orchestration_required with its deferred check.
--   3. team_collaboration.tool and the two exposure levels (off, private, public) kept in step with the 1.0.1
--      booleans, teams.max_collaboration_exposure kept in step with may_expose_collaboration, the exposure check,
--      the tool/template check, tool-change snapshots, collaboration_access.exposure.
--   4. orchestration.* and models.* service settings, their checks and seeds, and the collab.* aliases.
--   5. Model access: teams, agents and pools gain all/selected, agents and pools gain default_model_id,
--      agent_models, pool_models, team_inference_profiles, the view effective_agent_models and the function
--      model_admission; the composite foreign keys to team_models are dropped.
--   6. Edge: orchestration_routes(), orchestration_settings(), collab_routes() recomputed, record_collab_access
--      with exposure.
--   7. create_orchestration_agent; instantiate_work_order_team and record_work_order_secret replaced.
--   8. Reserved secret names for Buzz.
--
-- Pre-flight: none beyond 000021 (no new role). One transaction. Decisions CD-13 to CD-25 of the database contract
-- and the decisions in specs/261123-orchestration-and-model-access/implementation-notes.md apply.
--
-- Lock impact (existing tables):
--   agents, agent_pools: ADD COLUMN with constant defaults (no rewrite, brief ACCESS EXCLUSIVE); the default_model_id
--     backfill updates every row in one statement with the touch, revision and notify triggers disabled
--     (thousands of rows, row locks only); CHECKs and the new foreign keys are added NOT VALID then VALIDATEd
--     (SHARE UPDATE EXCLUSIVE / SHARE ROW EXCLUSIVE); one plain unique index (SHARE lock for milliseconds); the two
--     composite foreign keys to team_models are dropped (instant).
--   agent_templates: capabilities rewritten for tens of rows with triggers disabled.
--   teams: three constant-default columns; the limit backfill updates every row (hundreds) with triggers disabled.
--   team_collaboration: three columns; backfill of at most one row per team with triggers disabled.
--   collaboration_access: the primary key is dropped and rebuilt with exposure under ACCESS EXCLUSIVE on the
--     partitioned table; the table holds at most weeks of 1.0.1 counts. Run in the upgrade window.
--   agent_volume_snapshots, models: two nullable columns, one constant default.
--   service_settings: two CHECKs NOT VALID then VALIDATE, rows inserted.
--   secrets: one CHECK and one index replaced (small table).
--   Functions and views: CREATE OR REPLACE, no table locks.

-- 0. Helpers ---------------------------------------------------------------------------------------------------
CREATE FUNCTION afs.exposure_rank(p text) RETURNS integer
  LANGUAGE sql IMMUTABLE
  RETURN CASE p WHEN 'off' THEN 0 WHEN 'private' THEN 1 WHEN 'public' THEN 2 END;

-- The fixed capability profile of each tool (CD-17). orchestration.tools carries the same members and its CHECK keeps
-- them equal, so the database reads the profile from here.
CREATE FUNCTION afs.collab_tool_profile(p_tool text) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
  RETURN CASE p_tool
    WHEN 'paperclip' THEN '{"webUi": true, "webApi": true, "registration": ["manual", "managed"], "inNamespacePort": 3100}'::jsonb
    WHEN 'buzz' THEN '{"webUi": false, "webApi": false, "registration": ["managed"], "inNamespacePort": 3000}'::jsonb
  END;

CREATE FUNCTION afs.collab_tool_supports(p_tool text, p_surface text) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN coalesce((afs.collab_tool_profile(p_tool) ->> CASE p_surface WHEN 'web_ui' THEN 'webUi' ELSE 'webApi' END)::boolean, false);

CREATE FUNCTION afs.orchestration_tools_ok(p jsonb) RETURNS boolean
  LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  k         text;
  v         jsonb;
  n_default integer := 0;
BEGIN
  IF jsonb_typeof(p) <> 'object'
     OR (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(p) AS x) IS DISTINCT FROM ARRAY['buzz', 'paperclip'] THEN
    RETURN false;
  END IF;
  FOREACH k IN ARRAY ARRAY['paperclip', 'buzz'] LOOP
    v := p -> k;
    IF jsonb_typeof(v) <> 'object'
       OR (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(v) AS x)
          IS DISTINCT FROM ARRAY['default', 'enabled', 'imageRepository', 'inNamespacePort', 'registration', 'templateId', 'webApi', 'webUi'] THEN
      RETURN false;
    END IF;
    IF jsonb_typeof(v -> 'enabled') <> 'boolean' OR jsonb_typeof(v -> 'default') <> 'boolean' THEN
      RETURN false;
    END IF;
    IF (v - 'enabled' - 'default' - 'templateId' - 'imageRepository') IS DISTINCT FROM afs.collab_tool_profile(k) THEN
      RETURN false;
    END IF;
    IF NOT (jsonb_typeof(v -> 'templateId') = 'null'
            OR (jsonb_typeof(v -> 'templateId') = 'string' AND afs.ulid_ok(v ->> 'templateId', 'tpl'))) THEN
      RETURN false;
    END IF;
    IF NOT (jsonb_typeof(v -> 'imageRepository') = 'null'
            OR (jsonb_typeof(v -> 'imageRepository') = 'string'
                AND (v ->> 'imageRepository') ~ '^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$')) THEN
      RETURN false;
    END IF;
    IF (v ->> 'default')::boolean THEN
      n_default := n_default + 1;
      IF NOT (v ->> 'enabled')::boolean THEN
        RETURN false;
      END IF;
    END IF;
  END LOOP;
  RETURN n_default = 1;
END $$;

CREATE FUNCTION afs.resources_ok(p jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN jsonb_typeof(p) = 'object' AND jsonb_typeof(p -> 'cpu') = 'string' AND jsonb_typeof(p -> 'memory') = 'string';

CREATE FUNCTION afs.model_id_list_ok(p jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN jsonb_typeof(p) = 'array'
     AND jsonb_array_length(p) <= 100
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p) AS e WHERE jsonb_typeof(e) <> 'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 200)
     AND (SELECT count(DISTINCT e) FROM jsonb_array_elements(p) AS e) = jsonb_array_length(p);

REVOKE ALL ON FUNCTION afs.exposure_rank(text), afs.collab_tool_profile(text), afs.collab_tool_supports(text, text),
  afs.orchestration_tools_ok(jsonb), afs.resources_ok(jsonb), afs.model_id_list_ok(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.exposure_rank(text), afs.collab_tool_profile(text), afs.collab_tool_supports(text, text),
  afs.orchestration_tools_ok(jsonb), afs.resources_ok(jsonb), afs.model_id_list_ok(jsonb)
  TO afs_app, afs_reconciler, afs_readonly;

-- 1. Capabilities (DB-US-59, CD-24) ---------------------------------------------------------------------------
-- Known values orchestration, tool:paperclip, tool:buzz; a template with orchestration has exactly one tool:* value
-- and a tool:* value needs orchestration. Replacing the function leaves the CHECK in place; the rewrite below makes
-- every stored row valid under it.
CREATE OR REPLACE FUNCTION afs.capabilities_ok(p text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN p IS NOT NULL
     AND coalesce(cardinality(p), 0) <= 8
     AND NOT EXISTS (SELECT 1 FROM unnest(p) AS c WHERE c IS NULL OR c <> ALL (ARRAY['orchestration', 'tool:paperclip', 'tool:buzz']))
     AND (SELECT count(DISTINCT c) FROM unnest(p) AS c) = coalesce(cardinality(p), 0)
     AND (('orchestration' = ANY (p) AND (SELECT count(*) FROM unnest(p) AS c WHERE c LIKE 'tool:%') = 1)
          OR (NOT ('orchestration' = ANY (p)) AND (SELECT count(*) FROM unnest(p) AS c WHERE c LIKE 'tool:%') = 0));

-- A written paperclip becomes orchestration + tool:paperclip (until 2.0.0). It sorts before the capability guard.
CREATE FUNCTION afs.agent_templates_capabilities_rewrite() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF 'paperclip' = ANY (NEW.capabilities) THEN
    NEW.capabilities := array_remove(NEW.capabilities, 'paperclip');
    IF NOT ('orchestration' = ANY (NEW.capabilities)) THEN
      NEW.capabilities := array_append(NEW.capabilities, 'orchestration');
    END IF;
    IF NOT ('tool:paperclip' = ANY (NEW.capabilities)) THEN
      NEW.capabilities := array_append(NEW.capabilities, 'tool:paperclip');
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agent_templates_capabilities_rewrite() FROM PUBLIC;

ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_capability_guard;
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_touch;
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_revision;
ALTER TABLE afs.agent_templates DISABLE TRIGGER agent_templates_notify;
UPDATE afs.agent_templates SET capabilities = ARRAY['orchestration', 'tool:paperclip'] WHERE capabilities = ARRAY['paperclip'];
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_capability_guard;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_touch;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_revision;
ALTER TABLE afs.agent_templates ENABLE TRIGGER agent_templates_notify;

CREATE TRIGGER agent_templates_capabilities_rewrite
  BEFORE INSERT OR UPDATE OF capabilities ON afs.agent_templates
  FOR EACH ROW EXECUTE FUNCTION afs.agent_templates_capabilities_rewrite();
COMMENT ON COLUMN afs.agent_templates.capabilities IS
  'Known capabilities of the image: orchestration marks an orchestration-agent image, tool:paperclip and tool:buzz name its collaboration tool (exactly one). Service admins write it.';

CREATE OR REPLACE FUNCTION afs.agent_templates_capability_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  c text;
  k text;
  v_tools jsonb := (SELECT s.value FROM afs.service_settings s WHERE s.key = 'orchestration.tools');
BEGIN
  FOREACH c IN ARRAY OLD.capabilities LOOP
    IF (c = 'orchestration' OR c LIKE 'tool:%') AND NOT (c = ANY (NEW.capabilities)) THEN
      IF EXISTS (SELECT 1 FROM afs.agents a WHERE a.template_id = OLD.id AND a.role = 'orchestration' AND a.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'a live orchestration agent uses agent template %; it keeps the % capability', OLD.name, c
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END IF;
      FOREACH k IN ARRAY ARRAY['paperclip', 'buzz'] LOOP
        IF v_tools -> k ->> 'templateId' = OLD.id AND (c = 'orchestration' OR c = 'tool:' || k) THEN
          RAISE EXCEPTION 'orchestration.tools names agent template % for %; it keeps the % capability', OLD.name, k, c
            USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
      END LOOP;
    END IF;
  END LOOP;
  IF NOT ('orchestration' = ANY (OLD.capabilities)) AND 'orchestration' = ANY (NEW.capabilities)
     AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.template_id = OLD.id AND a.role = 'worker' AND a.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'a live worker agent uses agent template %; it cannot become an orchestration template', OLD.name
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END $$;

-- 2. Orchestration role (DB-US-58) -----------------------------------------------------------------------------
DROP TRIGGER agents_collaboration_guard ON afs.agents;
DROP TRIGGER agents_collaboration_cleanup ON afs.agents;
DROP INDEX afs.agents_team_collaboration_uq;

ALTER TABLE afs.agents DROP CONSTRAINT agents_role_check;
ALTER TABLE afs.agents DISABLE TRIGGER agents_touch;
ALTER TABLE afs.agents DISABLE TRIGGER agents_revision;
ALTER TABLE afs.agents DISABLE TRIGGER agents_notify;
UPDATE afs.agents SET role = 'orchestration' WHERE role = 'collaboration';
ALTER TABLE afs.agents ENABLE TRIGGER agents_touch;
ALTER TABLE afs.agents ENABLE TRIGGER agents_revision;
ALTER TABLE afs.agents ENABLE TRIGGER agents_notify;
ALTER TABLE afs.agents ADD CONSTRAINT agents_role_check CHECK (role IN ('worker', 'orchestration')) NOT VALID;
ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_role_check;
COMMENT ON COLUMN afs.agents.role IS 'worker, or orchestration (the team''s one orchestration agent, at most one live per team). Immutable.';

CREATE UNIQUE INDEX agents_team_orchestration_uq ON afs.agents (team_id)
  WHERE role = 'orchestration' AND deleted_at IS NULL;

DROP FUNCTION afs.agents_collaboration_guard();
CREATE FUNCTION afs.agents_orchestration_guard() RETURNS trigger
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
  IF TG_OP = 'INSERT' AND NEW.name = 'orchestrator' AND NEW.role <> 'orchestration' THEN
    RAISE EXCEPTION 'the name orchestrator is reserved for the team''s orchestration agent'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_name_reserved';
  END IF;
  IF NEW.template_id IS NOT NULL THEN
    SELECT * INTO t FROM afs.agent_templates WHERE id = NEW.template_id;
    v_has := FOUND;
  END IF;
  IF NEW.role = 'orchestration' THEN
    IF NEW.template_id IS NULL THEN
      RAISE EXCEPTION 'an orchestration agent needs an agent template (template_id)'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_orchestration_template';
    END IF;
    IF v_has AND NOT ('orchestration' = ANY (t.capabilities)) THEN
      RAISE EXCEPTION 'agent template % does not have the orchestration capability', t.name
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_orchestration_capability';
    END IF;
    IF NEW.iam_identity <> 'dedicated' THEN
      RAISE EXCEPTION 'an orchestration agent needs a dedicated identity (iam_identity = dedicated)'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_orchestration_identity';
    END IF;
    IF NEW.snapshot_schedule = 'off' THEN
      RAISE EXCEPTION 'an orchestration agent''s snapshots cannot be turned off'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_orchestration_snapshots';
    END IF;
  ELSIF v_has AND 'orchestration' = ANY (t.capabilities) THEN
    RAISE EXCEPTION 'agent template % is an orchestration template; a worker cannot use it', t.name
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_worker_capability';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agents_orchestration_guard() FROM PUBLIC;
CREATE TRIGGER agents_orchestration_guard
  BEFORE INSERT OR UPDATE OF role, name, template_id, iam_identity, snapshot_schedule ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.agents_orchestration_guard();

-- SECURITY INVOKER on purpose: it keys on current_user, so the SECURITY DEFINER functions that create the
-- orchestration agent pass as the owner and afs_app does not.
CREATE FUNCTION afs.agents_role_reserved_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.role = 'orchestration' AND current_user = 'afs_app' THEN
    RAISE EXCEPTION 'the orchestration role is reserved: the orchestration agent is created with the team'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_role_reserved';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agents_role_reserved_guard() FROM PUBLIC;
CREATE TRIGGER agents_role_reserved_guard BEFORE INSERT ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.agents_role_reserved_guard();

-- Agent and pool names share a namespace, so a pool may not take the reserved name either (insert only; CD-19).
CREATE FUNCTION afs.agent_pools_name_reserved() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.name = 'orchestrator' THEN
    RAISE EXCEPTION 'the name orchestrator is reserved for the team''s orchestration agent'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agent_pools_name_reserved';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agent_pools_name_reserved() FROM PUBLIC;
CREATE TRIGGER agent_pools_a_name_reserved BEFORE INSERT ON afs.agent_pools
  FOR EACH ROW EXECUTE FUNCTION afs.agent_pools_name_reserved();

-- The orchestration agent leaves only with its team.
CREATE FUNCTION afs.agents_orchestration_required() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_state text;
BEGIN
  IF NEW.role = 'orchestration'
     AND ((NEW.state IN ('deleting', 'deleted') AND OLD.state NOT IN ('deleting', 'deleted'))
          OR (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)) THEN
    SELECT t.state INTO v_state FROM afs.teams t WHERE t.id = NEW.team_id;
    IF v_state IS NOT NULL AND v_state NOT IN ('deleting', 'deleted') THEN
      RAISE EXCEPTION 'the orchestration agent of a live team cannot be deleted; delete the team'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_orchestration_required';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agents_orchestration_required() FROM PUBLIC;
CREATE TRIGGER agents_orchestration_required BEFORE UPDATE OF state, deleted_at ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.agents_orchestration_required();

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
CREATE TRIGGER agents_collaboration_cleanup AFTER UPDATE OF state, deleted_at ON afs.agents
  FOR EACH ROW WHEN (NEW.role = 'orchestration') EXECUTE FUNCTION afs.agents_collaboration_cleanup();

CREATE OR REPLACE FUNCTION afs.team_collaboration_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  a     afs.agents;
BEGIN
  SELECT * INTO a FROM afs.agents x WHERE x.team_id = NEW.team_id AND x.id = NEW.agent_id;
  IF FOUND THEN
    IF a.role <> 'orchestration' THEN
      RAISE EXCEPTION 'agent % is not an orchestration agent', NEW.agent_id
        USING ERRCODE = 'check_violation', CONSTRAINT = 'team_collaboration_agent_role';
    END IF;
    IF a.deleted_at IS NOT NULL OR a.state IN ('deleting', 'deleted') THEN
      RAISE EXCEPTION 'orchestration agent % is %', NEW.agent_id, a.state
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
     AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.team_id = NEW.id AND a.role = 'orchestration') THEN
    INSERT INTO afs.collab_hostname_holds (slug, team_id, held_until)
    VALUES (NEW.slug, NEW.id, now() + interval '30 days')
    ON CONFLICT (slug) DO UPDATE SET team_id = EXCLUDED.team_id, held_until = EXCLUDED.held_until;
  END IF;
  RETURN NULL;
END $$;

-- 2b. teams: orchestration_required, limit, model access (DB-US-58, 59, 61) ---------------------------------------
ALTER TABLE afs.teams ADD COLUMN orchestration_required boolean NOT NULL DEFAULT false;
ALTER TABLE afs.teams ALTER COLUMN orchestration_required SET DEFAULT true;
ALTER TABLE afs.teams ADD COLUMN max_collaboration_exposure text NOT NULL DEFAULT 'off'
  CHECK (max_collaboration_exposure IN ('off', 'private', 'public'));
ALTER TABLE afs.teams ADD COLUMN model_access text NOT NULL DEFAULT 'selected'
  CHECK (model_access IN ('all', 'selected'));
ALTER TABLE afs.teams ALTER COLUMN model_access SET DEFAULT 'all';
COMMENT ON COLUMN afs.teams.orchestration_required IS
  'True for teams created with an orchestration agent: at commit such a team must have a live one. Existing teams false. Service admins and the orchestration functions only.';
COMMENT ON COLUMN afs.teams.max_collaboration_exposure IS
  'Guardrail: the highest exposure (off, private, public) a team may give its orchestration endpoints. Service admins only.';
COMMENT ON COLUMN afs.teams.model_access IS
  'all: every model the service allows; selected: the models in team_models. Service admins only.';

ALTER TABLE afs.teams DISABLE TRIGGER teams_touch;
ALTER TABLE afs.teams DISABLE TRIGGER teams_revision;
ALTER TABLE afs.teams DISABLE TRIGGER teams_notify;
UPDATE afs.teams SET max_collaboration_exposure = CASE WHEN may_expose_collaboration THEN 'public' ELSE 'off' END;
ALTER TABLE afs.teams ENABLE TRIGGER teams_touch;
ALTER TABLE afs.teams ENABLE TRIGGER teams_revision;
ALTER TABLE afs.teams ENABLE TRIGGER teams_notify;

CREATE FUNCTION afs.teams_exposure_limit_sync() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.may_expose_collaboration := NEW.max_collaboration_exposure <> 'off';
  ELSIF NEW.max_collaboration_exposure IS DISTINCT FROM OLD.max_collaboration_exposure THEN
    NEW.may_expose_collaboration := NEW.max_collaboration_exposure <> 'off';
  ELSIF NEW.may_expose_collaboration IS DISTINCT FROM OLD.may_expose_collaboration THEN
    NEW.max_collaboration_exposure := CASE WHEN NEW.may_expose_collaboration THEN 'public' ELSE 'off' END;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.teams_exposure_limit_sync() FROM PUBLIC;
CREATE TRIGGER teams_exposure_limit_sync BEFORE INSERT OR UPDATE ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.teams_exposure_limit_sync();

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

CREATE FUNCTION afs.teams_orchestration_required() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  t afs.teams;
BEGIN
  SELECT * INTO t FROM afs.teams x WHERE x.id = NEW.id;
  IF FOUND AND t.orchestration_required AND t.state NOT IN ('deleting', 'deleted')
     AND NOT EXISTS (SELECT 1 FROM afs.agents a WHERE a.team_id = t.id AND a.role = 'orchestration' AND a.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'team % needs an orchestration agent', t.id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'teams_orchestration_required';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.teams_orchestration_required() FROM PUBLIC;
CREATE CONSTRAINT TRIGGER teams_orchestration_required AFTER INSERT OR UPDATE OF orchestration_required ON afs.teams
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.teams_orchestration_required();

-- 3. Tool, exposure levels, snapshots (DB-US-59) -----------------------------------------------------------------
ALTER TABLE afs.team_collaboration
  ADD COLUMN tool text NOT NULL DEFAULT 'paperclip' CHECK (tool IN ('paperclip', 'buzz')),
  ADD COLUMN web_ui_exposure text NOT NULL DEFAULT 'off' CHECK (web_ui_exposure IN ('off', 'private', 'public')),
  ADD COLUMN web_api_exposure text NOT NULL DEFAULT 'off' CHECK (web_api_exposure IN ('off', 'private', 'public'));
COMMENT ON COLUMN afs.team_collaboration.tool IS 'The collaboration tool the orchestration agent runs: paperclip or buzz.';
COMMENT ON COLUMN afs.team_collaboration.web_ui_exposure IS
  'The team''s stored choice for the Web UI: off, private or public. web_ui_enabled is kept in step until 2.0.0.';
COMMENT ON COLUMN afs.team_collaboration.web_api_exposure IS
  'The team''s stored choice for the Web API: off, private or public. rest_api_enabled is kept in step until 2.0.0.';

ALTER TABLE afs.team_collaboration DISABLE TRIGGER team_collaboration_touch;
ALTER TABLE afs.team_collaboration DISABLE TRIGGER team_collaboration_revision;
ALTER TABLE afs.team_collaboration DISABLE TRIGGER team_collaboration_notify;
ALTER TABLE afs.team_collaboration DISABLE TRIGGER team_collaboration_generation;
UPDATE afs.team_collaboration
   SET web_ui_exposure = CASE WHEN web_ui_enabled THEN 'public' ELSE 'off' END,
       web_api_exposure = CASE WHEN rest_api_enabled THEN 'public' ELSE 'off' END;
ALTER TABLE afs.team_collaboration ENABLE TRIGGER team_collaboration_touch;
ALTER TABLE afs.team_collaboration ENABLE TRIGGER team_collaboration_revision;
ALTER TABLE afs.team_collaboration ENABLE TRIGGER team_collaboration_notify;
ALTER TABLE afs.team_collaboration ENABLE TRIGGER team_collaboration_generation;

-- Booleans and levels in step (CD-16). Named so it sorts first: the exposure check and the generation bump see
-- the final levels.
CREATE FUNCTION afs.team_collaboration_levels_sync() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_limit text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.web_ui_enabled := NEW.web_ui_exposure <> 'off';
    NEW.rest_api_enabled := NEW.web_api_exposure <> 'off';
    RETURN NEW;
  END IF;
  SELECT t.max_collaboration_exposure INTO v_limit FROM afs.teams t WHERE t.id = NEW.team_id;
  IF NEW.web_ui_exposure IS DISTINCT FROM OLD.web_ui_exposure THEN
    NEW.web_ui_enabled := NEW.web_ui_exposure <> 'off';
  ELSIF NEW.web_ui_enabled IS DISTINCT FROM OLD.web_ui_enabled THEN
    NEW.web_ui_exposure := CASE WHEN NEW.web_ui_enabled AND afs.collab_tool_supports(NEW.tool, 'web_ui')
                                THEN coalesce(v_limit, 'off') ELSE 'off' END;
    NEW.web_ui_enabled := NEW.web_ui_exposure <> 'off';
  END IF;
  IF NEW.web_api_exposure IS DISTINCT FROM OLD.web_api_exposure THEN
    NEW.rest_api_enabled := NEW.web_api_exposure <> 'off';
  ELSIF NEW.rest_api_enabled IS DISTINCT FROM OLD.rest_api_enabled THEN
    NEW.web_api_exposure := CASE WHEN NEW.rest_api_enabled AND afs.collab_tool_supports(NEW.tool, 'web_api')
                                 THEN coalesce(v_limit, 'off') ELSE 'off' END;
    NEW.rest_api_enabled := NEW.web_api_exposure <> 'off';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.team_collaboration_levels_sync() FROM PUBLIC;
CREATE TRIGGER team_collaboration_a_levels_sync BEFORE INSERT OR UPDATE ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.team_collaboration_levels_sync();

-- The limit and the tool's profile (CD-15): only a level that is new or changed, or both after a tool change.
CREATE FUNCTION afs.team_collaboration_exposure_check() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_limit        text;
  v_prof         jsonb := afs.collab_tool_profile(NEW.tool);
  v_tool_changed boolean := TG_OP = 'UPDATE' AND NEW.tool IS DISTINCT FROM OLD.tool;
  v_surface      text;
  v_level        text;
  v_changed      boolean;
BEGIN
  SELECT t.max_collaboration_exposure INTO v_limit FROM afs.teams t WHERE t.id = NEW.team_id;
  FOREACH v_surface IN ARRAY ARRAY['web_ui', 'web_api'] LOOP
    v_level := CASE v_surface WHEN 'web_ui' THEN NEW.web_ui_exposure ELSE NEW.web_api_exposure END;
    v_changed := TG_OP = 'INSERT' OR v_tool_changed
                 OR v_level IS DISTINCT FROM CASE v_surface WHEN 'web_ui' THEN OLD.web_ui_exposure ELSE OLD.web_api_exposure END;
    IF v_changed THEN
      IF afs.exposure_rank(v_level) > afs.exposure_rank(coalesce(v_limit, 'off')) THEN
        RAISE EXCEPTION '% exposure % is above the team''s limit %', v_surface, v_level, coalesce(v_limit, 'off')
          USING ERRCODE = 'check_violation', CONSTRAINT = 'team_collaboration_exposure_limit';
      END IF;
      IF v_level <> 'off' AND NOT afs.collab_tool_supports(NEW.tool, v_surface) THEN
        RAISE EXCEPTION 'tool % does not support the % surface', NEW.tool, v_surface
          USING ERRCODE = 'check_violation', CONSTRAINT = 'team_collaboration_surface_supported';
      END IF;
    END IF;
  END LOOP;
  IF (TG_OP = 'INSERT' OR v_tool_changed OR NEW.registration_mode IS DISTINCT FROM OLD.registration_mode)
     AND NOT (NEW.registration_mode = ANY (ARRAY(SELECT jsonb_array_elements_text(v_prof -> 'registration')))) THEN
    RAISE EXCEPTION 'tool % does not support registration mode %', NEW.tool, NEW.registration_mode
      USING ERRCODE = 'check_violation', CONSTRAINT = 'team_collaboration_registration_supported';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.team_collaboration_exposure_check() FROM PUBLIC;
CREATE TRIGGER team_collaboration_b_exposure_check
  BEFORE INSERT OR UPDATE OF web_ui_exposure, web_api_exposure, tool, registration_mode ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.team_collaboration_exposure_check();

-- At commit the orchestration agent's template must carry the tool's capability, so a tool change may update the
-- row and the agent in either order.
CREATE FUNCTION afs.team_collaboration_tool_template() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_tool text;
  v_tpl  text;
  v_caps text[];
BEGIN
  SELECT c.tool, a.template_id INTO v_tool, v_tpl
    FROM afs.team_collaboration c
    JOIN afs.agents a ON a.team_id = c.team_id AND a.id = c.agent_id
   WHERE c.team_id = NEW.team_id AND a.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT t.capabilities INTO v_caps FROM afs.agent_templates t WHERE t.id = v_tpl;
  IF NOT FOUND OR NOT ('tool:' || v_tool = ANY (v_caps)) THEN
    RAISE EXCEPTION 'the orchestration agent of team % runs tool %, but its agent template does not have the tool:% capability',
      NEW.team_id, v_tool, v_tool
      USING ERRCODE = 'check_violation', CONSTRAINT = 'team_collaboration_tool_template';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.team_collaboration_tool_template() FROM PUBLIC;
CREATE CONSTRAINT TRIGGER team_collaboration_tool_template AFTER INSERT OR UPDATE OF tool, agent_id ON afs.team_collaboration
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.team_collaboration_tool_template();
CREATE CONSTRAINT TRIGGER agents_tool_template AFTER UPDATE OF template_id ON afs.agents
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.role = 'orchestration')
  EXECUTE FUNCTION afs.team_collaboration_tool_template();

CREATE OR REPLACE FUNCTION afs.team_collaboration_generation() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.web_ui_enabled IS DISTINCT FROM OLD.web_ui_enabled
     OR NEW.rest_api_enabled IS DISTINCT FROM OLD.rest_api_enabled
     OR NEW.registration_mode IS DISTINCT FROM OLD.registration_mode
     OR NEW.tool IS DISTINCT FROM OLD.tool
     OR NEW.web_ui_exposure IS DISTINCT FROM OLD.web_ui_exposure
     OR NEW.web_api_exposure IS DISTINCT FROM OLD.web_api_exposure THEN
    NEW.generation := OLD.generation + 1;
  ELSE
    NEW.generation := OLD.generation;
  END IF;
  RETURN NEW;
END $$;

-- The row is created only by create_orchestration_agent (section 7); afs_app updates the choices.
REVOKE INSERT (team_id, agent_id, web_ui_enabled, rest_api_enabled, registration_mode) ON afs.team_collaboration FROM afs_app;
GRANT UPDATE (tool, web_ui_exposure, web_api_exposure) ON afs.team_collaboration TO afs_app;

-- A tool change snapshots the volume first and keeps the snapshot 90 days (CD-23).
ALTER TABLE afs.agent_volume_snapshots DROP CONSTRAINT agent_volume_snapshots_reason_check;
ALTER TABLE afs.agent_volume_snapshots ADD CONSTRAINT agent_volume_snapshots_reason_check
  CHECK (reason IN ('scheduled', 'manual', 'pre_delete', 'pre_change', 'pre_tool_change')) NOT VALID;
ALTER TABLE afs.agent_volume_snapshots VALIDATE CONSTRAINT agent_volume_snapshots_reason_check;
ALTER TABLE afs.agent_volume_snapshots
  ADD COLUMN tool text CHECK (tool IN ('paperclip', 'buzz')),
  ADD COLUMN retain_until timestamptz;
ALTER TABLE afs.agent_volume_snapshots ADD CONSTRAINT agent_volume_snapshots_tool_change_check
  CHECK (reason <> 'pre_tool_change' OR (tool IS NOT NULL AND retain_until IS NOT NULL)) NOT VALID;
ALTER TABLE afs.agent_volume_snapshots VALIDATE CONSTRAINT agent_volume_snapshots_tool_change_check;
COMMENT ON COLUMN afs.agent_volume_snapshots.tool IS 'The tool the volume held, set for reason pre_tool_change.';
COMMENT ON COLUMN afs.agent_volume_snapshots.retain_until IS 'The reconciler never prunes the snapshot before this time.';
DROP POLICY app_team_scope ON afs.agent_volume_snapshots;
CREATE POLICY app_team_scope ON afs.agent_volume_snapshots TO afs_app
  USING (afs.caller_sees_team(team_id))
  WITH CHECK (afs.caller_sees_team(team_id) AND reason IN ('manual', 'pre_tool_change'));
GRANT SELECT (tool, retain_until) ON afs.agent_volume_snapshots TO afs_app, afs_readonly, afs_reconciler;
GRANT INSERT (tool, retain_until) ON afs.agent_volume_snapshots TO afs_app;

-- Access counts say which endpoint (public or private) was used (ORC-31).
ALTER TABLE afs.collaboration_access
  ADD COLUMN exposure text NOT NULL DEFAULT 'public' CHECK (exposure IN ('public', 'private'));
ALTER TABLE afs.collaboration_access DROP CONSTRAINT collaboration_access_pkey;
ALTER TABLE afs.collaboration_access ADD PRIMARY KEY
  (bucket_start, team_id, surface, exposure, principal_kind, principal_id, outcome, service_admin_entry);

-- 4. Settings (DB-US-59, DB-US-61) --------------------------------------------------------------------------------
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_orchestration_check CHECK (
  (key <> 'orchestration.tools' OR afs.orchestration_tools_ok(value))
  AND (key NOT IN ('orchestration.public_base_domain', 'orchestration.private_base_domain')
       OR jsonb_typeof(value) = 'null' OR afs.dns_name_ok(value))
  AND (key NOT IN ('orchestration.public_endpoints', 'orchestration.private_endpoints') OR jsonb_typeof(value) = 'boolean')
  AND (key NOT IN ('orchestration.default_limit', 'orchestration.default_web_ui_exposure', 'orchestration.default_web_api_exposure')
       OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') IN ('off', 'private', 'public')))
  AND (key <> 'orchestration.default_resources' OR afs.resources_ok(value))
  AND (key <> 'orchestration.default_volume_gib' OR CASE WHEN jsonb_typeof(value) = 'number'
         THEN (value #>> '{}')::numeric = trunc((value #>> '{}')::numeric)
              AND (value #>> '{}')::numeric BETWEEN 10 AND 1000 ELSE false END)
) NOT VALID;
ALTER TABLE afs.service_settings VALIDATE CONSTRAINT service_settings_orchestration_check;

ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_models_check CHECK (
  (key NOT IN ('models.service_access', 'models.default_team_access')
   OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') IN ('all', 'selected')))
  AND (key <> 'models.default_team_models' OR afs.model_id_list_ok(value))
  AND (key <> 'models.default_model_id' OR jsonb_typeof(value) = 'null'
       OR (jsonb_typeof(value) = 'string' AND length(value #>> '{}') BETWEEN 1 AND 200))
) NOT VALID;
ALTER TABLE afs.service_settings VALIDATE CONSTRAINT service_settings_models_check;

-- Checks that read other tables (CD-17, CD-25). SECURITY DEFINER so it can write the alias keys as the owner.
CREATE FUNCTION afs.service_settings_orchestration_guard() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.service_settings_orchestration_guard() FROM PUBLIC;
CREATE TRIGGER service_settings_orchestration_guard BEFORE INSERT OR UPDATE ON afs.service_settings
  FOR EACH ROW EXECUTE FUNCTION afs.service_settings_orchestration_guard();

-- collab.base_domain and collab.public_endpoints become read-only aliases of the new keys until 2.0.0 (CD-25).
-- SECURITY INVOKER: it keys on current_user, and the alias trigger below writes them as the owner.
CREATE FUNCTION afs.service_settings_alias_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.key IN ('collab.base_domain', 'collab.public_endpoints') AND current_user = 'afs_app' THEN
    RAISE EXCEPTION 'setting % was renamed: write % instead', NEW.key,
      CASE NEW.key WHEN 'collab.base_domain' THEN 'orchestration.public_base_domain' ELSE 'orchestration.public_endpoints' END
      USING ERRCODE = 'check_violation', CONSTRAINT = 'service_settings_alias_read_only';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.service_settings_alias_guard() FROM PUBLIC;
CREATE TRIGGER service_settings_alias_guard BEFORE INSERT OR UPDATE ON afs.service_settings
  FOR EACH ROW EXECUTE FUNCTION afs.service_settings_alias_guard();

CREATE FUNCTION afs.service_settings_alias_sync() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  INSERT INTO afs.service_settings (key, value, description)
  VALUES (CASE NEW.key WHEN 'orchestration.public_base_domain' THEN 'collab.base_domain' ELSE 'collab.public_endpoints' END,
          NEW.value, 'Alias of ' || NEW.key || ' until 2.0.0; write the new key.')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value WHERE afs.service_settings.value IS DISTINCT FROM EXCLUDED.value;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.service_settings_alias_sync() FROM PUBLIC;
CREATE TRIGGER service_settings_alias_sync AFTER INSERT OR UPDATE ON afs.service_settings
  FOR EACH ROW WHEN (NEW.key IN ('orchestration.public_base_domain', 'orchestration.public_endpoints'))
  EXECUTE FUNCTION afs.service_settings_alias_sync();

-- The change feed fires for the keys a service reads (payload service_settings::<key>).
CREATE FUNCTION afs.notify_service_setting() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_key text := CASE WHEN TG_OP = 'DELETE' THEN OLD.key ELSE NEW.key END;
BEGIN
  IF v_key LIKE 'models.%' OR v_key LIKE 'orchestration.%' THEN
    PERFORM pg_notify('afs_desired_state', 'service_settings::' || v_key);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.notify_service_setting() FROM PUBLIC;
CREATE TRIGGER service_settings_notify AFTER INSERT OR UPDATE OR DELETE ON afs.service_settings
  FOR EACH ROW EXECUTE FUNCTION afs.notify_service_setting();

-- Seeds. orchestration.default_limit first: the guard compares the two default levels with it.
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('orchestration.default_limit',
   CASE WHEN (SELECT jsonb_typeof(s.value) FROM afs.service_settings s WHERE s.key = 'collab.base_domain') = 'string'
        THEN '"public"' ELSE '"private"' END::jsonb,
   'Highest exposure a new team may give its orchestration endpoints: off, private or public.')
ON CONFLICT (key) DO NOTHING;
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('orchestration.default_web_ui_exposure',
   (SELECT s.value FROM afs.service_settings s WHERE s.key = 'orchestration.default_limit'),
   'Web UI exposure a new team starts with; not above the default limit.'),
  ('orchestration.default_web_api_exposure', '"off"', 'Web API exposure a new team starts with; not above the default limit.'),
  ('orchestration.public_base_domain', coalesce((SELECT s.value FROM afs.service_settings s WHERE s.key = 'collab.base_domain'), 'null'),
   'DNS name under which public orchestration hostnames are served (<slug>.<base domain>). null: none.'),
  ('orchestration.private_base_domain', 'null',
   'DNS name under which private orchestration hostnames are served, reachable from the private network only. null: none.'),
  ('orchestration.public_endpoints', coalesce((SELECT s.value FROM afs.service_settings s WHERE s.key = 'collab.public_endpoints'), 'true'),
   'Master switch for public orchestration endpoints.'),
  ('orchestration.private_endpoints', 'true', 'Master switch for private orchestration endpoints.'),
  ('orchestration.default_resources', '{"cpu": "1", "memory": "4Gi"}', 'Resources of a new team''s orchestration agent.'),
  ('orchestration.default_volume_gib', '20', 'Volume size in GiB of a new team''s orchestration agent (10 to 1000).'),
  ('models.service_access',
   CASE WHEN EXISTS (SELECT 1 FROM afs.models) THEN '"selected"' ELSE '"all"' END::jsonb,
   'all: every model in the catalog is usable; selected: only models with enabled = true.'),
  ('models.default_team_access', '"all"', 'Model access of a new team: all or selected.'),
  ('models.default_team_models', '[]', 'Models a new team in selected mode starts with (at most 100 model ids).'),
  ('models.default_model_id', 'null', 'Default model of a new agent when the request names none; null: the API falls back.')
ON CONFLICT (key) DO NOTHING;

-- orchestration.tools: the template of Paperclip is the one enabled template that had the paperclip capability.
INSERT INTO afs.service_settings (key, value, description)
SELECT 'orchestration.tools',
       jsonb_build_object(
         'paperclip', jsonb_build_object(
             'enabled', true, 'default', true,
             'templateId', (SELECT CASE WHEN count(*) = 1 THEN to_jsonb(min(t.id)) ELSE 'null'::jsonb END
                              FROM afs.agent_templates t WHERE t.enabled AND 'tool:paperclip' = ANY (t.capabilities)),
             'imageRepository', (SELECT CASE WHEN r ~ '^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$' THEN to_jsonb(r) ELSE 'null'::jsonb END
                                   FROM (SELECT regexp_replace(a.image, '@sha256:.*$', '') AS r
                                           FROM afs.agents a WHERE a.role = 'orchestration' AND a.deleted_at IS NULL
                                          ORDER BY a.created_at DESC LIMIT 1) latest),
             'webUi', true, 'webApi', true, 'registration', '["manual", "managed"]'::jsonb, 'inNamespacePort', 3100),
         'buzz', jsonb_build_object(
             'enabled', false, 'default', false, 'templateId', NULL, 'imageRepository', NULL,
             'webUi', false, 'webApi', false, 'registration', '["managed"]'::jsonb, 'inNamespacePort', 3000)),
       'Orchestration tools: which are enabled, the service default, each tool''s agent template, image repository and fixed capability profile.'
ON CONFLICT (key) DO NOTHING;

-- 5. Model access (DB-US-61) ----------------------------------------------------------------------------------------
ALTER TABLE afs.agents DROP CONSTRAINT agents_team_id_model_id_fkey;
ALTER TABLE afs.agent_pools DROP CONSTRAINT agent_pools_team_id_model_id_fkey;
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_model_id_fkey FOREIGN KEY (model_id) REFERENCES afs.models (id) NOT VALID;
ALTER TABLE afs.agent_pools VALIDATE CONSTRAINT agent_pools_model_id_fkey;

ALTER TABLE afs.agents ADD COLUMN model_access text NOT NULL DEFAULT 'all' CHECK (model_access IN ('all', 'selected'));
ALTER TABLE afs.agent_pools ADD COLUMN model_access text NOT NULL DEFAULT 'all' CHECK (model_access IN ('all', 'selected'));
ALTER TABLE afs.agents ADD COLUMN default_model_id text REFERENCES afs.models (id);
ALTER TABLE afs.agent_pools ADD COLUMN default_model_id text REFERENCES afs.models (id);
COMMENT ON COLUMN afs.agents.model_access IS 'all: every model the service and team allow; selected: the models in agent_models.';
COMMENT ON COLUMN afs.agents.default_model_id IS 'The model used when a call names none. model_id is kept in step until 2.0.0.';
COMMENT ON COLUMN afs.agent_pools.model_access IS 'all: every model the service and team allow; selected: the models in pool_models.';
COMMENT ON COLUMN afs.agent_pools.default_model_id IS 'The model used when a call names none. model_id is kept in step until 2.0.0.';

ALTER TABLE afs.agents DISABLE TRIGGER agents_touch;
ALTER TABLE afs.agents DISABLE TRIGGER agents_revision;
ALTER TABLE afs.agents DISABLE TRIGGER agents_notify;
ALTER TABLE afs.agent_pools DISABLE TRIGGER agent_pools_touch;
ALTER TABLE afs.agent_pools DISABLE TRIGGER agent_pools_revision;
ALTER TABLE afs.agent_pools DISABLE TRIGGER agent_pools_notify;
UPDATE afs.agents SET default_model_id = model_id;
UPDATE afs.agent_pools SET default_model_id = model_id;
ALTER TABLE afs.agents ENABLE TRIGGER agents_touch;
ALTER TABLE afs.agents ENABLE TRIGGER agents_revision;
ALTER TABLE afs.agents ENABLE TRIGGER agents_notify;
ALTER TABLE afs.agent_pools ENABLE TRIGGER agent_pools_touch;
ALTER TABLE afs.agent_pools ENABLE TRIGGER agent_pools_revision;
ALTER TABLE afs.agent_pools ENABLE TRIGGER agent_pools_notify;
ALTER TABLE afs.agents ADD CONSTRAINT agents_default_model_check CHECK (default_model_id IS NOT NULL) NOT VALID;
ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_default_model_check;
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_default_model_check CHECK (default_model_id IS NOT NULL) NOT VALID;
ALTER TABLE afs.agent_pools VALIDATE CONSTRAINT agent_pools_default_model_check;

CREATE FUNCTION afs.default_model_sync() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.default_model_id := coalesce(NEW.default_model_id, NEW.model_id);
    NEW.model_id := NEW.default_model_id;
  ELSIF NEW.default_model_id IS DISTINCT FROM OLD.default_model_id THEN
    NEW.model_id := NEW.default_model_id;
  ELSIF NEW.model_id IS DISTINCT FROM OLD.model_id THEN
    NEW.default_model_id := NEW.model_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.default_model_sync() FROM PUBLIC;
CREATE TRIGGER agents_default_model_sync BEFORE INSERT OR UPDATE ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.default_model_sync();
CREATE TRIGGER agent_pools_default_model_sync BEFORE INSERT OR UPDATE ON afs.agent_pools
  FOR EACH ROW EXECUTE FUNCTION afs.default_model_sync();

CREATE TABLE afs.agent_models (
  team_id    text NOT NULL,
  agent_id   text NOT NULL,
  model_id   text NOT NULL REFERENCES afs.models (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, agent_id, model_id),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE
);
CREATE TABLE afs.pool_models (
  team_id    text NOT NULL,
  pool_id    text NOT NULL,
  model_id   text NOT NULL REFERENCES afs.models (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, pool_id, model_id),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);
COMMENT ON TABLE afs.agent_models IS 'The models an agent in model_access = selected may call. Narrows the team''s set; read only while selected.';
COMMENT ON TABLE afs.pool_models IS 'The models a pool in model_access = selected may call. Narrows the team''s set; read only while selected.';

CREATE FUNCTION afs.model_enabled_for_service(p_model text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN EXISTS (SELECT 1 FROM afs.models m
                  WHERE m.id = p_model
                    AND (m.enabled OR coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s
                                                 WHERE s.key = 'models.service_access'), 'all') = 'all'));

CREATE FUNCTION afs.model_allowed_for_team(p_team text, p_model text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN EXISTS (SELECT 1 FROM afs.teams t
                  WHERE t.id = p_team
                    AND (t.model_access = 'all'
                         OR EXISTS (SELECT 1 FROM afs.team_models tm WHERE tm.team_id = t.id AND tm.model_id = p_model)));
REVOKE ALL ON FUNCTION afs.model_enabled_for_service(text), afs.model_allowed_for_team(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.model_enabled_for_service(text), afs.model_allowed_for_team(text, text)
  TO afs_app, afs_reconciler, afs_gateway, afs_readonly;

-- At write time: the model must be enabled for the service and allowed for the team; at most 50 per subject.
CREATE FUNCTION afs.subject_models_insert_check() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_subject text := to_jsonb(NEW) ->> CASE TG_TABLE_NAME WHEN 'agent_models' THEN 'agent_id' ELSE 'pool_id' END;
  n         integer;
BEGIN
  IF NOT afs.model_enabled_for_service(NEW.model_id) THEN
    RAISE EXCEPTION 'model % is not enabled for the service', NEW.model_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agent_models_service';
  END IF;
  IF NOT afs.model_allowed_for_team(NEW.team_id, NEW.model_id) THEN
    RAISE EXCEPTION 'model % is not allowed for team %', NEW.model_id, NEW.team_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agent_models_team';
  END IF;
  IF TG_TABLE_NAME = 'agent_models' THEN
    SELECT count(*) INTO n FROM afs.agent_models x WHERE x.team_id = NEW.team_id AND x.agent_id = v_subject;
  ELSE
    SELECT count(*) INTO n FROM afs.pool_models x WHERE x.team_id = NEW.team_id AND x.pool_id = v_subject;
  END IF;
  IF n >= 50 THEN
    RAISE EXCEPTION 'at most 50 models per agent or pool' USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_limit';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.subject_models_insert_check() FROM PUBLIC;
CREATE TRIGGER agent_models_insert_check BEFORE INSERT ON afs.agent_models
  FOR EACH ROW EXECUTE FUNCTION afs.subject_models_insert_check();
CREATE TRIGGER pool_models_insert_check BEFORE INSERT ON afs.pool_models
  FOR EACH ROW EXECUTE FUNCTION afs.subject_models_insert_check();

-- At commit, for each agent or pool whose model fields changed in the transaction (CD-14).
CREATE FUNCTION afs.subject_models_check() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.subject_models_check() FROM PUBLIC;
CREATE CONSTRAINT TRIGGER agents_models_check AFTER INSERT OR UPDATE OF model_access, default_model_id ON afs.agents
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();
CREATE CONSTRAINT TRIGGER agent_models_check AFTER INSERT OR DELETE ON afs.agent_models
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();
CREATE CONSTRAINT TRIGGER agent_pools_models_check AFTER INSERT OR UPDATE OF model_access, default_model_id ON afs.agent_pools
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();
CREATE CONSTRAINT TRIGGER pool_models_check AFTER INSERT OR DELETE ON afs.pool_models
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();

-- Inference profiles move out of team_models (CD-13): one row per model callable for the team.
CREATE TABLE afs.team_inference_profiles (
  team_id               text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  model_id              text NOT NULL REFERENCES afs.models (id),
  inference_profile_arn text CHECK (inference_profile_arn ~ '^arn:aws[a-z-]*:bedrock:[a-z0-9-]+:[0-9]{12}:application-inference-profile/[a-z0-9]+$'),
  state                 text NOT NULL DEFAULT 'creating' CHECK (state IN ('creating', 'active', 'retiring')),
  retire_after          timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, model_id),
  CHECK ((state = 'retiring') = (retire_after IS NOT NULL))
);
COMMENT ON TABLE afs.team_inference_profiles IS
  'Bedrock application inference profile per model callable for a team, written by the reconciler; retiring for 7 days after a model stops being callable.';
INSERT INTO afs.team_inference_profiles (team_id, model_id, inference_profile_arn, state)
SELECT tm.team_id, tm.model_id, tm.inference_profile_arn, 'active'
  FROM afs.team_models tm
 WHERE tm.inference_profile_arn ~ '^arn:aws[a-z-]*:bedrock:[a-z0-9-]+:[0-9]{12}:application-inference-profile/[a-z0-9]+$';

-- 1.0.1 readers keep reading team_models.inference_profile_arn until 2.0.0.
CREATE FUNCTION afs.team_inference_profiles_copy() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE afs.team_models SET inference_profile_arn = NULL
     WHERE team_id = OLD.team_id AND model_id = OLD.model_id AND inference_profile_arn IS NOT NULL;
  ELSE
    UPDATE afs.team_models SET inference_profile_arn = NEW.inference_profile_arn
     WHERE team_id = NEW.team_id AND model_id = NEW.model_id AND inference_profile_arn IS DISTINCT FROM NEW.inference_profile_arn;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.team_inference_profiles_copy() FROM PUBLIC;
CREATE TRIGGER team_inference_profiles_copy AFTER INSERT OR UPDATE OF inference_profile_arn OR DELETE ON afs.team_inference_profiles
  FOR EACH ROW EXECUTE FUNCTION afs.team_inference_profiles_copy();

-- models: origin of the row, and the enabled flag is fixed while every model is usable.
ALTER TABLE afs.models
  ADD COLUMN origin text NOT NULL DEFAULT 'manual' CHECK (origin IN ('manual', 'bedrock_sync')),
  ADD COLUMN synced_at timestamptz;
COMMENT ON COLUMN afs.models.origin IS 'manual, or bedrock_sync for a model the reconciler''s daily sync found (inserted disabled).';
CREATE FUNCTION afs.models_enabled_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NEW.enabled IS DISTINCT FROM OLD.enabled
     AND coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'models.service_access'), 'all') = 'all' THEN
    RAISE EXCEPTION 'models.service_access is all: every model is usable and the enabled flag cannot change'
      USING ERRCODE = 'object_not_in_prerequisite_state', CONSTRAINT = 'models_enabled_fixed';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.models_enabled_guard() FROM PUBLIC;
CREATE TRIGGER models_enabled_guard BEFORE UPDATE OF enabled ON afs.models
  FOR EACH ROW EXECUTE FUNCTION afs.models_enabled_guard();

-- The effective set per subject: service, team, subject and callable (a price in force).
CREATE VIEW afs.effective_agent_models WITH (security_invoker = true) AS
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
COMMENT ON VIEW afs.effective_agent_models IS
  'The models each live agent and pool may call: service, team, agent or pool, and priced. Runs with the caller''s rights.';

-- Why a model is refused for one subject: the first failing level, in a fixed order (the gateway caches it).
CREATE FUNCTION afs.model_admission(p_subject_kind text, p_subject_id text) RETURNS TABLE (model_id text, reason text)
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
REVOKE ALL ON FUNCTION afs.model_admission(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.model_admission(text, text) TO afs_app, afs_reconciler, afs_gateway, afs_readonly;

-- Grants, row-level security, change feed and revisions.
ALTER TABLE afs.agent_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.pool_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.team_inference_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.agent_models TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY app_team_scope ON afs.pool_models TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY app_team_scope ON afs.team_inference_profiles FOR SELECT TO afs_app USING (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.agent_models TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);
CREATE POLICY service_roles_all ON afs.pool_models TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);
CREATE POLICY service_roles_all ON afs.team_inference_profiles TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, DELETE ON afs.agent_models, afs.pool_models TO afs_app;
GRANT SELECT ON afs.agent_models, afs.pool_models TO afs_reconciler, afs_gateway, afs_readonly;
GRANT SELECT ON afs.team_inference_profiles TO afs_app, afs_gateway, afs_billing, afs_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.team_inference_profiles TO afs_reconciler;
GRANT SELECT ON afs.effective_agent_models TO afs_app, afs_reconciler, afs_gateway, afs_readonly;
GRANT SELECT (key, value) ON afs.service_settings TO afs_gateway;
GRANT INSERT (id, provider, display_name, enabled, context_window, max_output_tokens, origin, synced_at) ON afs.models TO afs_reconciler;
GRANT UPDATE (synced_at) ON afs.models TO afs_reconciler;

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
CREATE TRIGGER agent_models_revision AFTER INSERT OR UPDATE OR DELETE ON afs.agent_models
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER pool_models_revision AFTER INSERT OR UPDATE OR DELETE ON afs.pool_models
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER agent_models_notify AFTER INSERT OR UPDATE OR DELETE ON afs.agent_models
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();
CREATE TRIGGER pool_models_notify AFTER INSERT OR UPDATE OR DELETE ON afs.pool_models
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();
CREATE TRIGGER team_inference_profiles_notify AFTER INSERT OR UPDATE OR DELETE ON afs.team_inference_profiles
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();
CREATE TRIGGER model_prices_notify AFTER INSERT OR UPDATE OR DELETE ON afs.model_prices
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();

-- 6. Edge functions (DB-US-60) ---------------------------------------------------------------------------------------
CREATE FUNCTION afs.orchestration_settings() RETURNS TABLE (key text, value jsonb)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  SELECT s.key, s.value FROM afs.service_settings s
   WHERE s.key IN ('orchestration.public_base_domain', 'orchestration.private_base_domain',
                   'orchestration.public_endpoints', 'orchestration.private_endpoints')
   ORDER BY s.key
$$;

CREATE FUNCTION afs.orchestration_routes() RETURNS TABLE (
    team_id text, slug text, namespace text, team_state text, agent_id text, agent_state text, tool text,
    service_name text, port integer, surface text, supported boolean, exposure text, limit_exposure text,
    effective text, reasons text[], public_hostname text, private_hostname text, hostname text,
    ready boolean, not_ready_reason text, provider_id text, issuer_url text, groups_claim text,
    collab_client_id text, collab_client_secret_arn text, provider_client_id text, provider_cli_client_id text)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  WITH cfg AS (
    SELECT (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'orchestration.public_base_domain' AND jsonb_typeof(s.value) = 'string') AS pub_domain,
           (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'orchestration.private_base_domain' AND jsonb_typeof(s.value) = 'string') AS priv_domain,
           coalesce((SELECT (s.value #>> '{}')::boolean FROM afs.service_settings s
                      WHERE s.key = 'orchestration.public_endpoints' AND jsonb_typeof(s.value) = 'boolean'), true) AS pub_on,
           coalesce((SELECT (s.value #>> '{}')::boolean FROM afs.service_settings s
                      WHERE s.key = 'orchestration.private_endpoints' AND jsonb_typeof(s.value) = 'boolean'), true) AS priv_on
  ), r AS (
    SELECT t.id AS tid, t.slug AS tslug, t.namespace AS tns, t.state AS tstate, t.max_collaboration_exposure AS lim,
           a.id AS aid, a.state AS astate, c.tool AS ctool, c.web_ui_exposure AS ui, c.web_api_exposure AS api,
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
  ), s AS (
    SELECT r.*, v.surface AS surf, v.exposure AS expo, afs.collab_tool_supports(r.ctool, v.surface) AS sup
      FROM r CROSS JOIN LATERAL (VALUES ('web_ui', r.ui), ('web_api', r.api)) AS v (surface, exposure)
  ), l AS (
    SELECT s.*,
           CASE WHEN s.sup THEN s.expo ELSE 'off' END AS l0
      FROM s
  ), m AS (
    SELECT l.*,
           CASE WHEN afs.exposure_rank(l.l0) <= afs.exposure_rank(l.lim) THEN l.l0 ELSE l.lim END AS l1
      FROM l
  ), z AS (
    SELECT m.*,
           (m.l1 = 'public' AND NOT cfg.pub_on) AS kill_pub,
           (m.l1 = 'private' AND NOT cfg.priv_on) AS kill_priv,
           ((m.l1 = 'public' AND cfg.pub_domain IS NULL) OR (m.l1 = 'private' AND cfg.priv_domain IS NULL)) AS no_domain,
           (m.surf = 'web_ui' AND m.l1 <> 'off' AND m.pclient IS NULL) AS no_client,
           cfg.pub_domain, cfg.priv_domain
      FROM m CROSS JOIN cfg
  )
  SELECT z.tid, z.tslug, z.tns, z.tstate, z.aid, z.astate, z.ctool,
         z.ctool, (afs.collab_tool_profile(z.ctool) ->> 'inNamespacePort')::integer, z.surf, z.sup, z.expo, z.lim,
         CASE WHEN z.kill_pub OR z.kill_priv OR z.no_domain OR z.no_client THEN 'off' ELSE z.l1 END,
         array_remove(ARRAY[
           CASE WHEN z.expo <> 'off' AND NOT z.sup THEN 'tool_not_supported' END,
           CASE WHEN z.l0 <> 'off' AND afs.exposure_rank(z.l0) > afs.exposure_rank(z.lim) THEN 'team_limit' END,
           CASE WHEN z.kill_pub THEN 'service_switch_public' END,
           CASE WHEN z.kill_priv THEN 'service_switch_private' END,
           CASE WHEN z.no_domain THEN 'base_domain_unset' END,
           CASE WHEN z.no_client THEN 'provider_without_collab_client' END], NULL),
         CASE WHEN z.pub_domain IS NULL THEN NULL ELSE z.tslug || '.' || z.pub_domain END,
         CASE WHEN z.priv_domain IS NULL THEN NULL ELSE z.tslug || '.' || z.priv_domain END,
         CASE WHEN z.kill_pub OR z.kill_priv OR z.no_domain OR z.no_client THEN NULL
              WHEN z.l1 = 'public' THEN z.tslug || '.' || z.pub_domain
              WHEN z.l1 = 'private' THEN z.tslug || '.' || z.priv_domain END,
         z.is_ready,
         CASE WHEN z.is_ready THEN NULL
              WHEN z.tstate = 'suspended' THEN 'team_suspended'
              WHEN z.astate = 'paused' THEN 'paused'
              ELSE 'starting' END,
         z.pid, z.pissuer, z.pgroups, z.pclient, z.parn, z.pconsole, z.pcli
    FROM z
   ORDER BY z.tid, z.surf
$$;

-- The 1.0.1 view of the same data, for an edge that has not been upgraded yet (dropped in 2.0.0).
DROP FUNCTION afs.collab_routes();
CREATE FUNCTION afs.collab_routes() RETURNS TABLE (
    team_id text, slug text, namespace text, hostname text, team_state text, agent_id text, agent_state text,
    web_ui_enabled boolean, rest_api_enabled boolean, web_ui_effective boolean, rest_api_effective boolean,
    may_expose boolean, ready boolean, not_ready_reason text, service_name text, port integer,
    provider_id text, issuer_url text, groups_claim text, collab_client_id text, collab_client_secret_arn text,
    provider_client_id text, provider_cli_client_id text)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  SELECT ui.team_id, ui.slug, ui.namespace, ui.public_hostname, ui.team_state, ui.agent_id, ui.agent_state,
         c.web_ui_enabled, c.rest_api_enabled, ui.effective = 'public', api.effective = 'public',
         ui.limit_exposure <> 'off', ui.ready, ui.not_ready_reason, ui.service_name, ui.port,
         ui.provider_id, ui.issuer_url, ui.groups_claim, ui.collab_client_id, ui.collab_client_secret_arn,
         ui.provider_client_id, ui.provider_cli_client_id
    FROM afs.orchestration_routes() ui
    JOIN afs.orchestration_routes() api ON api.team_id = ui.team_id AND api.surface = 'web_api'
    JOIN afs.team_collaboration c ON c.team_id = ui.team_id
   WHERE ui.surface = 'web_ui'
   ORDER BY ui.team_id
$$;

CREATE OR REPLACE FUNCTION afs.record_collab_access(p_rows jsonb) RETURNS integer
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  e         jsonb;
  v_bucket  timestamptz;
  v_team    text;
  v_surface text;
  v_exp     text;
  n         integer := 0;
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
    v_exp := coalesce(e ->> 'exposure', 'public');
    IF v_exp NOT IN ('public', 'private') THEN
      RAISE EXCEPTION 'exposure must be public or private' USING ERRCODE = 'check_violation';
    END IF;
    v_surface := CASE e ->> 'surface' WHEN 'web_api' THEN 'rest_api' ELSE e ->> 'surface' END;
    IF NOT EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = v_team) THEN
      CONTINUE;
    END IF;
    INSERT INTO afs.collaboration_access AS c (bucket_start, team_id, surface, exposure, principal_kind, principal_id, outcome,
                                               service_admin_entry, requests, bytes)
    VALUES (v_bucket, v_team, v_surface, v_exp, e ->> 'principal_kind', coalesce(e ->> 'principal_id', ''), e ->> 'outcome',
            coalesce((e ->> 'service_admin_entry')::boolean, false), (e ->> 'requests')::integer,
            coalesce((e ->> 'bytes')::bigint, 0))
    ON CONFLICT (bucket_start, team_id, surface, exposure, principal_kind, principal_id, outcome, service_admin_entry)
    DO UPDATE SET requests = c.requests + EXCLUDED.requests, bytes = c.bytes + EXCLUDED.bytes, recorded_at = now();
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION afs.collab_routes(), afs.orchestration_routes(), afs.orchestration_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.collab_routes(), afs.orchestration_routes(), afs.orchestration_settings() TO afs_edge;

-- 7. Creating the orchestration agent (CD-21) ---------------------------------------------------------------------------
-- The logic, without the caller check, so instantiate_work_order_team (running as the owner) shares it.
CREATE FUNCTION afs.create_orchestration_agent_impl(
    p_team_id text, p_agent_id text, p_name text, p_tool text, p_web_ui_exposure text, p_web_api_exposure text,
    p_registration_mode text, p_model_access text, p_model_ids text[], p_default_model_id text, p_resources jsonb,
    p_storage_size_gib integer, p_storage_on_delete text) RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  t         afs.teams;
  v_tools   jsonb := (SELECT s.value FROM afs.service_settings s WHERE s.key = 'orchestration.tools');
  v_tool    text := p_tool;
  v_entry   jsonb;
  tpl       afs.agent_templates;
  v_access  text := coalesce(p_model_access, 'all');
  v_default text;
  v_ui      text;
  v_api     text;
  v_reg     text;
  v_res     jsonb;
  v_vol     integer;
  m         text;
BEGIN
  SELECT * INTO t FROM afs.teams x WHERE x.id = p_team_id FOR SHARE;
  IF NOT FOUND OR t.state IN ('deleting', 'deleted') THEN
    RAISE EXCEPTION 'team % does not exist or is being deleted', p_team_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF p_agent_id IS NULL OR NOT afs.ulid_ok(p_agent_id, 'agt') THEN
    RAISE EXCEPTION 'the agent id must be an agt_ ULID' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_tool IS NULL THEN
    SELECT e.key INTO v_tool FROM jsonb_each(v_tools) AS e WHERE (e.value ->> 'default')::boolean;
  END IF;
  v_entry := v_tools -> v_tool;
  IF v_entry IS NULL OR NOT (v_entry ->> 'enabled')::boolean THEN
    RAISE EXCEPTION 'tool % is not enabled for this service', coalesce(v_tool, '(none)')
      USING ERRCODE = 'check_violation', CONSTRAINT = 'orchestration_tool_not_enabled';
  END IF;
  SELECT * INTO tpl FROM afs.agent_templates x WHERE x.id = v_entry ->> 'templateId' FOR SHARE;
  IF NOT FOUND OR NOT tpl.enabled OR jsonb_typeof(v_entry -> 'imageRepository') <> 'string' THEN
    RAISE EXCEPTION 'the runtime of tool % is not set up: orchestration.tools needs an enabled template and an image repository', v_tool
      USING ERRCODE = 'object_not_in_prerequisite_state', CONSTRAINT = 'orchestration_runtime_unset';
  END IF;

  -- Defaults come from the settings; a default level is capped by the team's limit and by what the tool supports.
  v_ui := coalesce(p_web_ui_exposure, CASE WHEN afs.collab_tool_supports(v_tool, 'web_ui') THEN
            (SELECT CASE WHEN afs.exposure_rank(s.value #>> '{}') <= afs.exposure_rank(t.max_collaboration_exposure)
                         THEN s.value #>> '{}' ELSE t.max_collaboration_exposure END
               FROM afs.service_settings s WHERE s.key = 'orchestration.default_web_ui_exposure') END, 'off');
  v_api := coalesce(p_web_api_exposure, CASE WHEN afs.collab_tool_supports(v_tool, 'web_api') THEN
            (SELECT CASE WHEN afs.exposure_rank(s.value #>> '{}') <= afs.exposure_rank(t.max_collaboration_exposure)
                         THEN s.value #>> '{}' ELSE t.max_collaboration_exposure END
               FROM afs.service_settings s WHERE s.key = 'orchestration.default_web_api_exposure') END, 'off');
  v_reg := coalesce(p_registration_mode, CASE v_tool WHEN 'buzz' THEN 'managed' ELSE 'manual' END);
  v_res := coalesce(p_resources, (SELECT s.value FROM afs.service_settings s WHERE s.key = 'orchestration.default_resources'),
                    tpl.default_resources);
  v_vol := coalesce(p_storage_size_gib, (SELECT (s.value #>> '{}')::integer FROM afs.service_settings s WHERE s.key = 'orchestration.default_volume_gib'), 20);
  v_default := coalesce(p_default_model_id,
                        (SELECT s.value #>> '{}' FROM afs.service_settings s
                          WHERE s.key = 'models.default_model_id' AND jsonb_typeof(s.value) = 'string'),
                        p_model_ids[1]);
  IF v_default IS NULL THEN
    RAISE EXCEPTION 'no default model: pass one or set models.default_model_id'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_default_model_allowed';
  END IF;

  INSERT INTO afs.agents (id, team_id, name, template, image, model_id, default_model_id, model_access, resources, role,
                          template_id, iam_identity, snapshot_schedule, snapshot_retain_count, storage_on_delete, storage_size_gib)
  VALUES (p_agent_id, p_team_id, coalesce(p_name, 'orchestrator'), tpl.harness,
          (v_entry ->> 'imageRepository') || '@' || tpl.current_image_digest, v_default, v_default, v_access, v_res,
          'orchestration', tpl.id, 'dedicated', 'daily', 14, coalesce(p_storage_on_delete, 'snapshot_then_delete'), v_vol);
  IF v_access = 'selected' THEN
    FOR m IN SELECT DISTINCT x FROM unnest(coalesce(p_model_ids, ARRAY[]::text[])) AS x LOOP
      INSERT INTO afs.agent_models (team_id, agent_id, model_id) VALUES (p_team_id, p_agent_id, m);
    END LOOP;
  END IF;
  INSERT INTO afs.team_collaboration (team_id, agent_id, tool, web_ui_exposure, web_api_exposure, registration_mode)
  VALUES (p_team_id, p_agent_id, v_tool, v_ui, v_api, v_reg);
  IF NOT t.orchestration_required THEN
    UPDATE afs.teams SET orchestration_required = true WHERE id = p_team_id;
  END IF;

  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'CreateOrchestrationAgent', 'allowed', 'agents', p_agent_id, p_team_id,
          jsonb_build_object('agentId', p_agent_id, 'name', coalesce(p_name, 'orchestrator'), 'tool', v_tool,
                             'webUiExposure', v_ui, 'webApiExposure', v_api, 'registrationMode', v_reg,
                             'modelAccess', v_access, 'defaultModelId', v_default));
  INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES
    ('agent.created', 'agents', p_agent_id, p_team_id,
     afs.event_detail(p_team_id, NULL, jsonb_build_object('agentId', p_agent_id, 'teamId', p_team_id))),
    ('orchestration.created', 'team_collaboration', p_team_id, p_team_id,
     afs.event_detail(p_team_id, NULL, jsonb_build_object('teamId', p_team_id, 'agentId', p_agent_id, 'tool', v_tool)));
  RETURN p_agent_id;
END $$;
REVOKE ALL ON FUNCTION afs.create_orchestration_agent_impl(text, text, text, text, text, text, text, text, text[], text, jsonb, integer, text) FROM PUBLIC;

CREATE FUNCTION afs.create_orchestration_agent(
    p_team_id text, p_agent_id text, p_name text, p_tool text, p_web_ui_exposure text, p_web_api_exposure text,
    p_registration_mode text, p_model_access text, p_model_ids text[], p_default_model_id text, p_resources jsonb,
    p_storage_size_gib integer, p_storage_on_delete text) RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NOT afs.caller_is_service_admin() THEN
    RAISE EXCEPTION 'only service admins create an orchestration agent' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN afs.create_orchestration_agent_impl(p_team_id, p_agent_id, p_name, p_tool, p_web_ui_exposure, p_web_api_exposure,
                                             p_registration_mode, p_model_access, p_model_ids, p_default_model_id,
                                             p_resources, p_storage_size_gib, p_storage_on_delete);
END $$;
REVOKE ALL ON FUNCTION afs.create_orchestration_agent(text, text, text, text, text, text, text, text, text[], text, jsonb, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.create_orchestration_agent(text, text, text, text, text, text, text, text, text[], text, jsonb, integer, text) TO afs_app;

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
  v_cagent text;
  v_orch   jsonb;
  v_limit  text;
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
  -- spec.orchestration {tool?, webUiExposure?, webApiExposure?, defaultModelId?}; a legacy spec.collaboration is read as
  -- {tool: paperclip} and its templateId is ignored in favour of orchestration.tools.
  v_orch := CASE WHEN tpl.spec ? 'orchestration' THEN tpl.spec -> 'orchestration'
                 WHEN tpl.spec ? 'collaboration' THEN '{"tool": "paperclip"}'::jsonb
                 ELSE '{}'::jsonb END;
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
  v_limit := coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'orchestration.default_limit'), 'private');

  INSERT INTO afs.teams (id, slug, display_name, description, kind, cost_center, owner_email, max_budget_usd,
                         expires_at, teardown_rule, labels, max_collaboration_exposure, model_access)
  VALUES (v_team, 'wo-' || lower(substr(v_team, 6)), left('Remediation: ' || coalesce(wo.external_ref, wo.title), 120),
          wo.title, 'ephemeral', v_cc, v_owner, v_budget, v_expire, tpl.teardown_rule,
          jsonb_build_object('afs.work_order_id', wo.id, 'afs.swarm_template', tpl.name), v_limit, 'selected');
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

  -- Every work order team gets an orchestration agent (ORC-7): volume deleted with the team, all of the team's models,
  -- default model from the spec or the first pool. A tool whose runtime is unset raises 55000 and nothing is created.
  v_cagent := afs.create_orchestration_agent_impl(
    v_team, afs.new_id('agt'), NULL, v_orch ->> 'tool', v_orch ->> 'webUiExposure', v_orch ->> 'webApiExposure', NULL,
    'all', NULL, coalesce(v_orch ->> 'defaultModelId', tpl.spec -> 'pools' -> 0 ->> 'modelId'), NULL, NULL, 'delete');

  UPDATE afs.work_orders w SET team_id = v_team, status = 'assigned', assigned_at = now() WHERE w.id = wo.id;

  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'InstantiateWorkOrderTeam', 'allowed', 'work_orders', wo.id, v_team,
          jsonb_build_object('teamId', v_team, 'templateId', tpl.id, 'budgetUsd', v_budget, 'expiresAt', v_expire,
                             'pools', v_pools, 'orchestrationAgentId', v_cagent));
  INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES
    ('team.created', 'teams', v_team, v_team,
     afs.event_detail(v_team, NULL, jsonb_build_object('teamId', v_team, 'kind', 'ephemeral', 'workOrderId', wo.id))),
    ('work_order.assigned', 'work_orders', wo.id, v_team,
     afs.event_detail(v_team, NULL, jsonb_build_object('workOrderId', wo.id, 'teamId', v_team)));
  RETURN v_team;
END $$;

-- 8. Reserved secret names and Buzz keys (ORC-10) ----------------------------------------------------------------
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_managed_by_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_managed_by_check CHECK (managed_by IN ('user', 'afs', 'paperclip', 'buzz')) NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_managed_by_check;
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_registered_paperclip_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_registered_paperclip_check
  CHECK (origin = 'managed' OR managed_by IN ('paperclip', 'buzz')) NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_registered_paperclip_check;
DROP INDEX afs.secrets_paperclip_name_uq;
CREATE UNIQUE INDEX secrets_tool_name_uq ON afs.secrets (team_id, agent_id, name) WHERE managed_by IN ('paperclip', 'buzz');
COMMENT ON COLUMN afs.secrets.managed_by IS
  'Who creates and writes the row: user (a team), afs (AFS itself), paperclip or buzz (the tool, through the reconciler). Immutable.';

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
    IF NEW.managed_by IN ('paperclip', 'buzz') THEN
      v_prefix := afs.secret_path(NEW.team_id, NEW.agent_id, NEW.managed_by) || '/';
      IF v_arn_path IS NULL OR left(v_arn_path, length(v_prefix)) <> v_prefix OR length(v_arn_path) = length(v_prefix) THEN
        RAISE EXCEPTION 'a % secret must live below %', NEW.managed_by, v_prefix
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_' || NEW.managed_by || '_prefix';
      END IF;
      NEW.path := v_arn_path;
      v_name := left(NEW.managed_by || '-' || regexp_replace(lower(substr(v_arn_path, length(v_prefix) + 1)), '[^a-z0-9-]', '-', 'g'), 63);
      NEW.name := v_name;
      WHILE EXISTS (SELECT 1 FROM afs.secrets s WHERE s.team_id = NEW.team_id AND s.agent_id = NEW.agent_id
                     AND s.name = NEW.name AND s.managed_by = NEW.managed_by) AND v_try < 20 LOOP
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
    IF (TG_OP = 'INSERT' AND NEW.managed_by IN ('paperclip', 'buzz')) OR (TG_OP <> 'INSERT' AND OLD.managed_by IN ('paperclip', 'buzz')) THEN
      RAISE EXCEPTION 'paperclip and buzz secrets are written by the reconciler only' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn AND OLD.managed_by = 'afs' THEN
      RAISE EXCEPTION 'the ARN of an AFS-managed secret cannot be changed through the API'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' AND OLD.managed_by = 'afs' AND OLD.name = ANY (v_boot)
       AND EXISTS (SELECT 1 FROM afs.agents a WHERE a.team_id = OLD.team_id AND a.id = OLD.agent_id
                      AND a.role = 'orchestration' AND a.deleted_at IS NULL) THEN
      RAISE EXCEPTION 'secret % belongs to a live orchestration agent and cannot be deleted', OLD.name
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  ELSIF current_user = 'afs_reconciler' THEN
    IF (TG_OP = 'INSERT' AND NEW.managed_by NOT IN ('paperclip', 'buzz')) OR (TG_OP <> 'INSERT' AND OLD.managed_by NOT IN ('paperclip', 'buzz')) THEN
      RAISE EXCEPTION 'the reconciler writes paperclip and buzz secrets only' USING ERRCODE = 'insufficient_privilege';
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
    IF NEW.managed_by IN ('paperclip', 'buzz') THEN
      IF NEW.origin <> 'registered' THEN
        RAISE EXCEPTION 'a % secret is registered, not managed', NEW.managed_by
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_registered_paperclip_check';
      END IF;
      IF NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL OR (v_found AND (v_agent.role <> 'orchestration' OR v_agent.deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'a % secret is scoped to the team''s orchestration agent', NEW.managed_by
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_' || NEW.managed_by || '_scope';
      END IF;
      RETURN NEW;
    END IF;
    IF NEW.origin = 'registered' THEN
      RAISE EXCEPTION 'only paperclip and buzz secrets are registered' USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_registered_paperclip_check';
    END IF;
    IF NEW.name IN ('paperclip', 'buzz') THEN
      RAISE EXCEPTION 'the secret name % is reserved: it would sit beside the %/ prefix', NEW.name, NEW.name
        USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
    ELSIF NEW.name = ANY (v_boot) THEN
      IF NEW.managed_by <> 'afs' OR NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL
         OR (v_found AND (v_agent.role <> 'orchestration' OR v_agent.deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'secret % is AFS-managed and belongs to the team''s live orchestration agent', NEW.name
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
      END IF;
    ELSIF NEW.name = 'paperclip-agent-api-key' THEN
      IF NEW.managed_by NOT IN ('user', 'afs') OR NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL
         OR (v_found AND (v_agent.role <> 'worker' OR v_agent.deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'secret paperclip-agent-api-key belongs to a live worker agent'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
      END IF;
    ELSIF NEW.name = 'buzz-agent-private-key' THEN
      -- AFS-managed only: Buzz has no manual registration, so a user cannot write it.
      IF NEW.managed_by <> 'afs' OR NEW.agent_id IS NULL OR NEW.pool_id IS NOT NULL
         OR (v_found AND (v_agent.role <> 'worker' OR v_agent.deleted_at IS NOT NULL
                          OR NOT EXISTS (SELECT 1 FROM afs.team_collaboration c WHERE c.team_id = NEW.team_id AND c.tool = 'buzz'))) THEN
        RAISE EXCEPTION 'secret buzz-agent-private-key is AFS-managed and belongs to a live worker of a team that uses Buzz'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secrets_reserved_name';
      END IF;
    ELSIF NEW.name LIKE 'paperclip-%' OR NEW.name LIKE 'buzz-%' THEN
      RAISE EXCEPTION 'secret names starting with paperclip- or buzz- are reserved for the orchestration agent''s tool'
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
  IF v_by IN ('paperclip', 'buzz') THEN
    RAISE EXCEPTION 'secret % belongs to the orchestration tool and cannot be bound', NEW.secret_id
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

-- A connected worker's key: Paperclip's agent API key, or in a Buzz team the worker's Buzz private key.
CREATE OR REPLACE FUNCTION afs.record_collab_agent_key(p_team_id text, p_agent_id text, p_secret_arn text) RETURNS text
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  a        afs.agents;
  v_mode   text;
  v_tool   text;
  v_sec    text;
  v_name   text;
  v_target text;
BEGIN
  SELECT * INTO a FROM afs.agents x WHERE x.team_id = p_team_id AND x.id = p_agent_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no agent % in team %', p_agent_id, p_team_id USING ERRCODE = 'no_data_found';
  END IF;
  IF a.role <> 'worker' OR a.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'agent % is not a live worker agent', p_agent_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  SELECT c.registration_mode, c.tool INTO v_mode, v_tool FROM afs.team_collaboration c WHERE c.team_id = p_team_id;
  IF v_mode IS DISTINCT FROM 'managed' THEN
    RAISE EXCEPTION 'team % does not use managed registration', p_team_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.agent_collaboration ac WHERE ac.team_id = p_team_id AND ac.agent_id = p_agent_id AND ac.connect) THEN
    RAISE EXCEPTION 'agent % is not connected to the orchestration tool', p_agent_id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  v_name := CASE v_tool WHEN 'buzz' THEN 'buzz-agent-private-key' ELSE 'paperclip-agent-api-key' END;
  v_target := CASE v_tool WHEN 'buzz' THEN 'BUZZ_PRIVATE_KEY' ELSE 'PAPERCLIP_AGENT_API_KEY' END;
  IF NOT afs.collab_key_arn_ok(p_team_id, p_agent_id, v_name, p_secret_arn) THEN
    RAISE EXCEPTION 'the ARN must be a Secrets Manager ARN at path %', afs.secret_path(p_team_id, p_agent_id, v_name)
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT s.id INTO v_sec FROM afs.secrets s WHERE s.team_id = p_team_id AND s.agent_id = p_agent_id AND s.name = v_name;
  IF FOUND THEN
    UPDATE afs.secrets s SET secrets_manager_arn = p_secret_arn, last_changed_at = now() WHERE s.id = v_sec;
  ELSE
    v_sec := afs.new_id('sec');
    INSERT INTO afs.secrets (id, team_id, name, description, secrets_manager_arn, origin, managed_by, agent_id)
    VALUES (v_sec, p_team_id, v_name, '', p_secret_arn, 'managed', 'afs', p_agent_id);
  END IF;
  IF EXISTS (SELECT 1 FROM afs.agent_secret_bindings b
              WHERE b.agent_id = p_agent_id AND b.target = v_target AND b.secret_id <> v_sec) THEN
    RAISE EXCEPTION 'target % of agent % is already bound to another secret', v_target, p_agent_id
      USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO afs.agent_secret_bindings (team_id, agent_id, secret_id, delivery, target)
  VALUES (p_team_id, p_agent_id, v_sec, 'env', v_target)
  ON CONFLICT (agent_id, target) DO NOTHING;
  INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
  VALUES ('system', afs.current_actor(), 'RecordCollabAgentKey', 'allowed', 'secrets', v_sec, p_team_id,
          jsonb_build_object('agentId', p_agent_id, 'name', v_name));
  RETURN v_sec;
END $$;

CREATE OR REPLACE FUNCTION afs.remove_collab_agent_key(p_team_id text, p_agent_id text) RETURNS boolean
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  r         record;
  v_removed boolean := false;
BEGIN
  FOR r IN SELECT s.id, s.name FROM afs.secrets s
            WHERE s.team_id = p_team_id AND s.agent_id = p_agent_id AND s.managed_by = 'afs'
              AND s.name IN ('paperclip-agent-api-key', 'buzz-agent-private-key') LOOP
    DELETE FROM afs.agent_secret_bindings b WHERE b.team_id = p_team_id AND b.secret_id = r.id;
    DELETE FROM afs.secrets s WHERE s.id = r.id;
    v_removed := true;
    INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, resource_kind, resource_id, team_id, after)
    VALUES ('system', afs.current_actor(), 'RemoveCollabAgentKey', 'allowed', 'secrets', r.id, p_team_id,
            jsonb_build_object('agentId', p_agent_id, 'name', r.name));
  END LOOP;
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
  IF a.role <> 'orchestration' OR a.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'agent % is not a live orchestration agent', p_collab_agent_id USING ERRCODE = 'object_not_in_prerequisite_state';
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

-- The orchestration agent's boot secrets of a work order team (Paperclip's three; Buzz has none).
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
    -- The team's orchestration agent: only its boot secrets, AFS-managed, delivered as environment variables.
    PERFORM 1 FROM afs.agents a
     WHERE a.id = p_pool_id AND a.team_id = v_team AND a.role = 'orchestration' AND a.deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% is not the orchestration agent of team %', p_pool_id, v_team USING ERRCODE = 'check_violation';
    END IF;
    v_env := CASE p_name WHEN 'paperclip-better-auth-secret' THEN 'BETTER_AUTH_SECRET'
                         WHEN 'paperclip-tool-action-signing-secret' THEN 'PAPERCLIP_TOOL_ACTION_SIGNING_SECRET'
                         WHEN 'paperclip-secrets-master-key' THEN 'PAPERCLIP_SECRETS_MASTER_KEY' END;
    IF v_env IS NULL OR p_delivery <> 'env' OR p_target <> v_env THEN
      RAISE EXCEPTION 'an orchestration agent takes only its boot secrets, as environment variables' USING ERRCODE = 'check_violation';
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
