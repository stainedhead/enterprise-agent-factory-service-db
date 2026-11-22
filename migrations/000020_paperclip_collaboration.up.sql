-- 000020: Paperclip team collaboration (change PRD paperclip-team-collaboration-PRD.md; -db PRD DB-41 to DB-52,
-- DB-US-44 to DB-US-57; database contract section 7.2, v1.3.1; spec 261122-paperclip-collaboration).
--
-- Each team may run one collaboration agent (role 'collaboration'). This migration adds:
--   1. agents.role, the one-live-collaboration-agent-per-team index and guard; agent_templates.capabilities.
--   2. teams.may_expose_collaboration (guarded), identity_providers.collab_client_id and
--      collab_client_secret_arn, the team_collaborator role, seven collab.* settings and their constraint.
--   3. team_collaboration and agent_collaboration (desired state), their guards, the cleanup trigger and
--      the hostname hold (collab_hostname_holds).
--   4. secrets.managed_by, afs.secrets_managed_guard (reserved names and who writes), registered origin,
--      the binding refusal, and the three reconciler key functions.
--   5. Role afs_edge (no table privilege) with ten SECURITY DEFINER functions: routes, settings, principals,
--      access counts, the secret-detected event, and edge sessions with a single-use handoff
--      (collab_edge_sessions, collab_edge_handoffs: no grant to any role).
--   6. collaboration_access (monthly partitions, retention through drop_partitions_older_than).
--   7. afs.instantiate_work_order_team and afs.record_work_order_secret extended for a swarm's collaboration agent.
--
-- Pre-flight: role afs_edge must exist (afs-migrate bootstrap-roles); afs_owner cannot create cluster roles.
-- Decisions DB-D1 to DB-D19 of the -db PRD apply. One transaction; nothing here rewrites agents, secrets or teams.
--
-- Lock impact (existing tables):
--   agents: ADD COLUMN role with a constant default (no rewrite, brief ACCESS EXCLUSIVE); CHECK added NOT VALID then
--     VALIDATE (SHARE UPDATE EXCLUSIVE); the plain unique index agents_team_collaboration_uq takes a SHARE lock
--     while it builds (milliseconds for thousands of rows); two triggers (brief lock).
--   agent_templates: ADD COLUMN capabilities with a constant default (no rewrite), CHECK NOT VALID then VALIDATE.
--   teams: ADD COLUMN may_expose_collaboration with a constant default (no rewrite); trigger teams_guardrail_guard
--     is dropped and recreated; two new triggers.
--   secrets: ADD COLUMN managed_by with a constant default (no rewrite); secrets_origin_check is replaced NOT VALID
--     then VALIDATE; new partial unique index (SHARE lock while it builds, secrets is small); one trigger.
--   identity_providers: two nullable columns and three small checks (table has a handful of rows).
--   role_bindings, api_keys: role checks replaced NOT VALID then VALIDATE.
--   service_settings: one CHECK NOT VALID then VALIDATE; seven rows inserted.
--   Functions are replaced with CREATE OR REPLACE and take no table locks.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afs_edge') THEN
    RAISE EXCEPTION 'role afs_edge does not exist: run afs-migrate bootstrap-roles before applying 000020'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END $$;

-- 1. Collaboration agent role (DB-US-44) ---------------------------------------------------------------
-- Known capability values; adding one is a later migration (text plus CHECK, not a type).
CREATE FUNCTION afs.capabilities_ok(p text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN p IS NOT NULL
     AND coalesce(cardinality(p), 0) <= 8
     AND NOT EXISTS (SELECT 1 FROM unnest(p) AS c WHERE c IS NULL OR c <> ALL (ARRAY['paperclip']))
     AND (SELECT count(DISTINCT c) FROM unnest(p) AS c) = coalesce(cardinality(p), 0);
REVOKE ALL ON FUNCTION afs.capabilities_ok(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.capabilities_ok(text[]) TO afs_app, afs_reconciler, afs_readonly;

ALTER TABLE afs.agent_templates ADD COLUMN capabilities text[] NOT NULL DEFAULT '{}';
ALTER TABLE afs.agent_templates ADD CONSTRAINT agent_templates_capabilities_check
  CHECK (afs.capabilities_ok(capabilities)) NOT VALID;
ALTER TABLE afs.agent_templates VALIDATE CONSTRAINT agent_templates_capabilities_check;
COMMENT ON COLUMN afs.agent_templates.capabilities IS
  'Known capabilities of the image: paperclip marks a collaboration image. Service admins write it.';

ALTER TABLE afs.agents ADD COLUMN role text NOT NULL DEFAULT 'worker';
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

CREATE FUNCTION afs.agent_templates_capability_guard() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.agent_templates_capability_guard() FROM PUBLIC;
CREATE TRIGGER agent_templates_capability_guard
  BEFORE UPDATE OF capabilities ON afs.agent_templates
  FOR EACH ROW EXECUTE FUNCTION afs.agent_templates_capability_guard();

-- 2. Collaborator role, guardrail, provider client, settings (DB-US-47, DB-US-48) -----------------------
ALTER TABLE afs.role_bindings DROP CONSTRAINT role_bindings_role_check;
ALTER TABLE afs.role_bindings ADD CONSTRAINT role_bindings_role_check
  CHECK (role IN ('service_admin', 'security_operator', 'team_admin', 'team_viewer', 'team_collaborator')) NOT VALID;
ALTER TABLE afs.role_bindings VALIDATE CONSTRAINT role_bindings_role_check;
ALTER TABLE afs.api_keys DROP CONSTRAINT api_keys_role_check;
ALTER TABLE afs.api_keys ADD CONSTRAINT api_keys_role_check
  CHECK (role IN ('team_admin', 'team_viewer', 'team_collaborator', 'security_operator')) NOT VALID;
ALTER TABLE afs.api_keys VALIDATE CONSTRAINT api_keys_role_check;

ALTER TABLE afs.teams ADD COLUMN may_expose_collaboration boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN afs.teams.may_expose_collaboration IS
  'Guardrail: whether the team''s collaboration agent may be reached from the public endpoint. Service admins only.';

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

ALTER TABLE afs.identity_providers
  ADD COLUMN collab_client_id text,
  ADD COLUMN collab_client_secret_arn text,
  ADD CONSTRAINT identity_providers_collab_client_id_check CHECK (collab_client_id ~ '^[A-Za-z0-9._:@-]{1,255}$'),
  ADD CONSTRAINT identity_providers_collab_client_secret_arn_check
    CHECK (collab_client_secret_arn ~ '^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$'),
  ADD CONSTRAINT identity_providers_collab_secret_needs_client
    CHECK (collab_client_secret_arn IS NULL OR collab_client_id IS NOT NULL);
COMMENT ON COLUMN afs.identity_providers.collab_client_id IS
  'OIDC client id the collaboration edge signs people in with. Not a secret.';
COMMENT ON COLUMN afs.identity_providers.collab_client_secret_arn IS
  'Secrets Manager ARN of that client''s secret. A reference, never a value.';

-- Helpers for the collab.* settings. Both are IMMUTABLE so a later migration can reuse them.
CREATE FUNCTION afs.dns_name_ok(p jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  RETURN jsonb_typeof(p) = 'string'
     AND length(p #>> '{}') BETWEEN 4 AND 253
     AND (p #>> '{}') ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$';

CREATE FUNCTION afs.cidr_list_ok(p jsonb) RETURNS boolean
  LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  e jsonb;
BEGIN
  IF jsonb_typeof(p) <> 'array' OR jsonb_array_length(p) > 100 THEN
    RETURN false;
  END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(p) LOOP
    IF jsonb_typeof(e) <> 'string' OR position('/' IN (e #>> '{}')) = 0 THEN
      RETURN false;
    END IF;
    PERFORM (e #>> '{}')::cidr;
  END LOOP;
  RETURN true;
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value OR data_exception THEN
  RETURN false;
END $$;
REVOKE ALL ON FUNCTION afs.dns_name_ok(jsonb), afs.cidr_list_ok(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.dns_name_ok(jsonb), afs.cidr_list_ok(jsonb) TO afs_app, afs_reconciler, afs_readonly;

ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_collab_check CHECK (
  (key <> 'collab.base_domain' OR jsonb_typeof(value) = 'null' OR afs.dns_name_ok(value))
  AND (key <> 'collab.public_endpoints' OR jsonb_typeof(value) = 'boolean')
  AND (key <> 'collab.allowed_source_cidrs' OR afs.cidr_list_ok(value))
  AND (key <> 'collab.session_ttl_minutes' OR CASE WHEN jsonb_typeof(value) = 'number'
         THEN (value #>> '{}')::numeric = trunc((value #>> '{}')::numeric)
              AND (value #>> '{}')::numeric BETWEEN 15 AND 1440 ELSE false END)
  AND (key <> 'collab.content_scan' OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') IN ('block', 'warn', 'off')))
  AND (key <> 'collab.max_body_mb' OR CASE WHEN jsonb_typeof(value) = 'number'
         THEN (value #>> '{}')::numeric = trunc((value #>> '{}')::numeric)
              AND (value #>> '{}')::numeric BETWEEN 1 AND 100 ELSE false END)
  AND (key <> 'collab.denied_spike_threshold' OR CASE WHEN jsonb_typeof(value) = 'number'
         THEN (value #>> '{}')::numeric = trunc((value #>> '{}')::numeric)
              AND (value #>> '{}')::numeric BETWEEN 1 AND 100000 ELSE false END)
) NOT VALID;
ALTER TABLE afs.service_settings VALIDATE CONSTRAINT service_settings_collab_check;

INSERT INTO afs.service_settings (key, value, description) VALUES
  ('collab.base_domain', 'null', 'DNS name under which team collaboration hostnames are served (<slug>.<base domain>). null: no public endpoint.'),
  ('collab.public_endpoints', 'true', 'Master switch for the public collaboration endpoints.'),
  ('collab.allowed_source_cidrs', '[]', 'CIDR ranges allowed to reach the public endpoints; empty means no source restriction beyond the WAF default.'),
  ('collab.session_ttl_minutes', '480', 'Lifetime of a collaboration web session, in minutes (15 to 1440).'),
  ('collab.content_scan', '"block"', 'What the edge does when it finds a credential in a request: block, warn or off.'),
  ('collab.max_body_mb', '25', 'Largest request body the edge accepts, in MB (1 to 100).'),
  ('collab.denied_spike_threshold', '50', 'Denied requests per five minutes for one team that raise the collaboration.denied_spike alert.')
ON CONFLICT (key) DO NOTHING;

-- 3. team_collaboration (DB-US-45) ---------------------------------------------------------------------
CREATE TABLE afs.team_collaboration (
  team_id           text PRIMARY KEY REFERENCES afs.teams (id) ON DELETE CASCADE,
  agent_id          text NOT NULL,
  web_ui_enabled    boolean NOT NULL DEFAULT true,
  rest_api_enabled  boolean NOT NULL DEFAULT false,
  registration_mode text NOT NULL DEFAULT 'manual' CHECK (registration_mode IN ('manual', 'managed')),
  version           bigint NOT NULL DEFAULT 1,
  generation        bigint NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        text NOT NULL DEFAULT afs.current_actor(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id)
);
COMMENT ON TABLE afs.team_collaboration IS
  'One row per team that has a collaboration agent: the team''s stored choices (guardrails apply when the route is computed).';

-- The agent must be a collaboration agent. A missing agent is left to the composite foreign key (23503).
CREATE FUNCTION afs.team_collaboration_guard() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.team_collaboration_guard() FROM PUBLIC;
CREATE TRIGGER team_collaboration_guard BEFORE INSERT OR UPDATE OF agent_id ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.team_collaboration_guard();

-- afs.touch_row() bumps version only; the database, not the API, bumps generation when a spec column changes (DB-D1).
CREATE FUNCTION afs.team_collaboration_generation() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.team_collaboration_generation() FROM PUBLIC;
CREATE TRIGGER team_collaboration_generation BEFORE UPDATE ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.team_collaboration_generation();
CREATE TRIGGER team_collaboration_touch BEFORE UPDATE ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();

-- The revision key of a table with no id column is built from team_id, model_id, key, agent_id and target;
-- team_collaboration is keyed by its team alone (contract 7.2.2), whatever agent it points at.
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
CREATE TRIGGER team_collaboration_revision AFTER INSERT OR UPDATE OR DELETE ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER team_collaboration_notify AFTER INSERT OR UPDATE OR DELETE ON afs.team_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();

ALTER TABLE afs.team_collaboration ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.team_collaboration TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.team_collaboration TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);
GRANT SELECT ON afs.team_collaboration TO afs_app, afs_reconciler, afs_readonly;
GRANT INSERT (team_id, agent_id, web_ui_enabled, rest_api_enabled, registration_mode) ON afs.team_collaboration TO afs_app;
GRANT UPDATE (web_ui_enabled, rest_api_enabled, registration_mode) ON afs.team_collaboration TO afs_app;

-- 3b. agent_collaboration (DB-US-46) -------------------------------------------------------------------
CREATE TABLE afs.agent_collaboration (
  team_id            text NOT NULL,
  agent_id           text NOT NULL,
  connect            boolean NOT NULL,
  paperclip_agent_id text CHECK (paperclip_agent_id ~ '^[A-Za-z0-9._:-]{1,128}$'),
  link_state         text NOT NULL CHECK (link_state IN ('pending', 'linked', 'failed', 'disabled')),
  last_synced_at     timestamptz,
  last_error         text CHECK (length(last_error) <= 500),
  version            bigint NOT NULL DEFAULT 1,
  generation         bigint NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         text NOT NULL DEFAULT afs.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, agent_id),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id)
);
COMMENT ON TABLE afs.agent_collaboration IS
  'Whether a worker agent is connected to the team''s Paperclip, and the link state the reconciler observed. No row: not connected.';

-- SECURITY INVOKER on purpose: the rules below depend on who is writing (current_user).
CREATE FUNCTION afs.agent_collaboration_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_role text;
  v_mode text;
  v_id_changed boolean;
BEGIN
  SELECT a.role INTO v_role FROM afs.agents a WHERE a.team_id = NEW.team_id AND a.id = NEW.agent_id;
  IF FOUND AND v_role <> 'worker' THEN
    RAISE EXCEPTION 'agent % is not a worker agent', NEW.agent_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agent_collaboration_worker_only';
  END IF;
  IF NEW.connect AND (TG_OP = 'INSERT' OR NEW.connect IS DISTINCT FROM OLD.connect)
     AND NOT EXISTS (SELECT 1 FROM afs.team_collaboration c WHERE c.team_id = NEW.team_id) THEN
    RAISE EXCEPTION 'team % has no collaboration agent to connect to', NEW.team_id
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  v_id_changed := CASE WHEN TG_OP = 'INSERT' THEN NEW.paperclip_agent_id IS NOT NULL
                       ELSE NEW.paperclip_agent_id IS DISTINCT FROM OLD.paperclip_agent_id END;
  IF v_id_changed AND current_user <> 'afs_reconciler' THEN
    SELECT c.registration_mode INTO v_mode FROM afs.team_collaboration c WHERE c.team_id = NEW.team_id;
    IF v_mode = 'managed' THEN
      RAISE EXCEPTION 'registration is managed: only the reconciler records the Paperclip agent id'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.link_state := CASE WHEN NEW.connect THEN 'pending' ELSE 'disabled' END;
  ELSIF NEW.connect IS DISTINCT FROM OLD.connect THEN
    NEW.link_state := CASE WHEN NEW.connect THEN 'pending' ELSE 'disabled' END;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agent_collaboration_guard() FROM PUBLIC;
CREATE TRIGGER agent_collaboration_guard BEFORE INSERT OR UPDATE ON afs.agent_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.agent_collaboration_guard();

CREATE FUNCTION afs.agent_collaboration_generation() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.connect IS DISTINCT FROM OLD.connect OR NEW.paperclip_agent_id IS DISTINCT FROM OLD.paperclip_agent_id THEN
    NEW.generation := OLD.generation + 1;
  ELSE
    NEW.generation := OLD.generation;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.agent_collaboration_generation() FROM PUBLIC;
CREATE TRIGGER agent_collaboration_generation BEFORE UPDATE ON afs.agent_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.agent_collaboration_generation();
CREATE TRIGGER agent_collaboration_touch BEFORE UPDATE ON afs.agent_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER agent_collaboration_revision AFTER INSERT OR UPDATE OR DELETE ON afs.agent_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER agent_collaboration_notify AFTER INSERT OR UPDATE OR DELETE ON afs.agent_collaboration
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();

ALTER TABLE afs.agent_collaboration ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.agent_collaboration TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.agent_collaboration TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);
GRANT SELECT ON afs.agent_collaboration TO afs_app, afs_reconciler, afs_readonly;
GRANT INSERT (team_id, agent_id, connect, paperclip_agent_id) ON afs.agent_collaboration TO afs_app;
GRANT UPDATE (connect, paperclip_agent_id) ON afs.agent_collaboration TO afs_app;
GRANT UPDATE (paperclip_agent_id, link_state, last_synced_at, last_error) ON afs.agent_collaboration TO afs_reconciler;

-- 3c. A collaboration agent that goes takes its route with it (DB-US-50) --------------------------------
CREATE FUNCTION afs.agents_collaboration_cleanup() RETURNS trigger
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

-- 3d. A deleted team's hostname is held for 30 days (DB-US-53) -------------------------------------------
CREATE TABLE afs.collab_hostname_holds (
  slug       text PRIMARY KEY,
  team_id    text NOT NULL,
  held_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE afs.collab_hostname_holds IS
  'Slugs of deleted teams that had a collaboration agent, held so a new team cannot take over old links. No foreign key.';
GRANT SELECT ON afs.collab_hostname_holds TO afs_app, afs_readonly;
GRANT SELECT, DELETE ON afs.collab_hostname_holds TO afs_reconciler;
-- The slug of a deleted team is not secret, but the row names the team, so it follows the team-scope rule.
-- The two trigger functions below are SECURITY DEFINER (the table owner bypasses row-level security), so a
-- new team's insert still sees every hold.
ALTER TABLE afs.collab_hostname_holds ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.collab_hostname_holds FOR SELECT TO afs_app USING (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.collab_hostname_holds TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);

CREATE FUNCTION afs.teams_collab_hold() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.teams_collab_hold() FROM PUBLIC;
CREATE TRIGGER teams_collab_hold AFTER UPDATE OF deleted_at ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.teams_collab_hold();

CREATE FUNCTION afs.teams_collab_hold_refuse() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM afs.collab_hostname_holds h
              WHERE h.slug = NEW.slug AND h.held_until > now() AND h.team_id <> NEW.id) THEN
    RAISE EXCEPTION 'hostname % is held for a deleted team until its hold expires', NEW.slug
      USING ERRCODE = 'unique_violation', CONSTRAINT = 'collab_hostname_held';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.teams_collab_hold_refuse() FROM PUBLIC;
CREATE TRIGGER teams_collab_hold_refuse BEFORE INSERT ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.teams_collab_hold_refuse();

-- 4. Managed secrets and reserved names (DB-US-49) -----------------------------------------------------
ALTER TABLE afs.secrets ADD COLUMN managed_by text NOT NULL DEFAULT 'user';
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_managed_by_check CHECK (managed_by IN ('user', 'afs', 'paperclip')) NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_managed_by_check;
COMMENT ON COLUMN afs.secrets.managed_by IS
  'Who creates and writes the row: user (a team), afs (AFS itself), paperclip (Paperclip, through the reconciler). Immutable.';

-- Paperclip creates its own secrets under the agent's paperclip/ prefix, so those rows are "registered" (DB-D3).
ALTER TABLE afs.secrets DROP CONSTRAINT secrets_origin_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_origin_check CHECK (origin IN ('managed', 'registered')) NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_origin_check;
ALTER TABLE afs.secrets ADD CONSTRAINT secrets_registered_paperclip_check
  CHECK (origin = 'managed' OR managed_by = 'paperclip') NOT VALID;
ALTER TABLE afs.secrets VALIDATE CONSTRAINT secrets_registered_paperclip_check;
CREATE UNIQUE INDEX secrets_paperclip_name_uq ON afs.secrets (team_id, agent_id, name) WHERE managed_by = 'paperclip';

-- Path (and, for paperclip rows, name) computation. For managed_by = 'paperclip' the path comes from the ARN,
-- which must lie under <prefix>/<namespace>/<agent>/paperclip/. A new ARN with the same path (a rotation that
-- recreated the secret) is accepted for rows AFS or Paperclip manage; a user's secret keeps its ARN.
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

-- Who may write which rows, and the reserved names. SECURITY INVOKER on purpose: it keys on current_user, so the
-- SECURITY DEFINER functions below (record_work_order_secret, the three key functions) pass as the owner.
-- It fires before secrets_managed_path (trigger names sort that way).
CREATE FUNCTION afs.secrets_managed_guard() RETURNS trigger
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
REVOKE ALL ON FUNCTION afs.secrets_managed_guard() FROM PUBLIC;
CREATE TRIGGER secrets_managed_guard BEFORE INSERT OR UPDATE OR DELETE ON afs.secrets
  FOR EACH ROW EXECUTE FUNCTION afs.secrets_managed_guard();

-- The reconciler writes Paperclip's own rows; the guard refuses it every other row with 42501 (DB-D4).
GRANT INSERT, UPDATE, DELETE ON afs.secrets TO afs_reconciler;

-- A paperclip secret is never bound to an agent.
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

-- 4b. Reconciler key functions (DB-US-56) ----------------------------------------------------------------
-- The reconciler creates the Secrets Manager secret itself and passes its ARN; no value is ever here.
CREATE FUNCTION afs.collab_key_arn_ok(p_team_id text, p_agent_id text, p_name text, p_arn text) RETURNS boolean
  LANGUAGE sql STABLE
  SET search_path = pg_catalog, afs
  RETURN p_arn ~ '^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$'
     AND substring(p_arn FROM ':secret:(.*)-[A-Za-z0-9]{6}$') = afs.secret_path(p_team_id, p_agent_id, p_name);
REVOKE ALL ON FUNCTION afs.collab_key_arn_ok(text, text, text, text) FROM PUBLIC;

CREATE FUNCTION afs.record_collab_agent_key(p_team_id text, p_agent_id text, p_secret_arn text) RETURNS text
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

CREATE FUNCTION afs.remove_collab_agent_key(p_team_id text, p_agent_id text) RETURNS boolean
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

CREATE FUNCTION afs.record_collab_board_key(p_team_id text, p_collab_agent_id text, p_secret_arn text) RETURNS text
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

REVOKE ALL ON FUNCTION afs.record_collab_agent_key(text, text, text), afs.remove_collab_agent_key(text, text),
  afs.record_collab_board_key(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.record_collab_agent_key(text, text, text), afs.remove_collab_agent_key(text, text),
  afs.record_collab_board_key(text, text, text) TO afs_reconciler;

-- 5. Collaboration access facts (DB-US-52) -----------------------------------------------------------------
CREATE TABLE afs.collaboration_access (
  bucket_start        timestamptz NOT NULL CHECK (extract(epoch FROM bucket_start)::bigint % 300 = 0),
  team_id             text NOT NULL,
  surface             text NOT NULL CHECK (surface IN ('web_ui', 'rest_api')),
  principal_kind      text NOT NULL CHECK (principal_kind IN ('user', 'api_key', 'anonymous')),
  principal_id        text NOT NULL CHECK (length(principal_id) <= 64),
  outcome             text NOT NULL CHECK (outcome IN ('signed_in', 'signed_out', 'allowed', 'secret_warned',
                        'denied_unauthenticated', 'denied_forbidden', 'denied_surface_disabled',
                        'denied_secret_detected', 'denied_bad_request', 'throttled', 'unavailable')),
  service_admin_entry boolean NOT NULL DEFAULT false,
  requests            integer NOT NULL CHECK (requests > 0),
  bytes               bigint NOT NULL DEFAULT 0 CHECK (bytes >= 0),
  recorded_at         timestamptz NOT NULL DEFAULT now(),
  CHECK ((principal_kind = 'anonymous') = (principal_id = '')),
  PRIMARY KEY (bucket_start, team_id, surface, principal_kind, principal_id, outcome, service_admin_entry)
) PARTITION BY RANGE (bucket_start);
CREATE TABLE afs.collaboration_access_default PARTITION OF afs.collaboration_access DEFAULT;
CREATE INDEX collaboration_access_team_time_idx ON afs.collaboration_access (team_id, bucket_start);
COMMENT ON TABLE afs.collaboration_access IS
  'Five-minute access counts at the collaboration edge. Counts only: never a body, path or header. No foreign key (facts outlive the team).';

ALTER TABLE afs.collaboration_access ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.collaboration_access FOR SELECT TO afs_app USING (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.collaboration_access TO afs_billing, afs_gateway, afs_readonly, afs_reconciler
  USING (true) WITH CHECK (true);
GRANT SELECT ON afs.collaboration_access TO afs_app, afs_reconciler, afs_readonly;

CREATE FUNCTION afs.ensure_collaboration_access_partition(p_month date) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  start_ts date := date_trunc('month', p_month)::date;
  name text := format('collaboration_access_%s', to_char(start_ts, 'YYYYMM'));
BEGIN
  IF to_regclass('afs.' || name) IS NULL THEN
    EXECUTE format('CREATE TABLE afs.%I PARTITION OF afs.collaboration_access FOR VALUES FROM (%L) TO (%L)',
                   name, start_ts, (start_ts + interval '1 month')::date);
  END IF;
  RETURN name;
END $$;
REVOKE ALL ON FUNCTION afs.ensure_collaboration_access_partition(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.ensure_collaboration_access_partition(date) TO afs_reconciler;

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
     WHERE n.nspname = 'afs'
       AND p.relname IN ('usage_events', 'agent_activity', 'external_traffic', 'collaboration_access')
       AND c.relname ~ '_[0-9]{6}$'
       AND to_date(right(c.relname, 6), 'YYYYMM') < v_cutoff
     ORDER BY 1
  LOOP
    EXECUTE format('DROP TABLE afs.%I', r.relname);
    RETURN NEXT r.relname;
  END LOOP;
END $$;

-- 6. Edge sessions and the single-use handoff (DB-US-55) ---------------------------------------------------
-- Only SHA-256 hashes are stored. No grant to any role, RLS on with no policy: the functions below are the interface.
CREATE TABLE afs.collab_edge_sessions (
  id_hash      bytea PRIMARY KEY CHECK (length(id_hash) = 32),
  team_id      text NOT NULL,
  issuer       text NOT NULL,
  subject      text NOT NULL,
  provider_id  text NOT NULL,
  groups       text[] NOT NULL DEFAULT '{}' CHECK (cardinality(groups) <= 500),
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL CHECK (expires_at > created_at),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);
CREATE TABLE afs.collab_edge_handoffs (
  code_hash   bytea PRIMARY KEY CHECK (length(code_hash) = 32),
  team_id     text NOT NULL,
  host        text NOT NULL,
  issuer      text NOT NULL,
  subject     text NOT NULL,
  provider_id text NOT NULL,
  groups      text[] NOT NULL DEFAULT '{}' CHECK (cardinality(groups) <= 500),
  expires_at  timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE afs.collab_edge_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.collab_edge_handoffs ENABLE ROW LEVEL SECURITY;
-- No role has a grant; the explicit deny policy states the intent and satisfies the rule that every
-- row-level-security table has a policy for afs_app. Only the SECURITY DEFINER functions below reach the rows.
CREATE POLICY deny_all ON afs.collab_edge_sessions TO afs_app USING (false) WITH CHECK (false);
CREATE POLICY deny_all ON afs.collab_edge_handoffs TO afs_app USING (false) WITH CHECK (false);
COMMENT ON TABLE afs.collab_edge_sessions IS 'Server-side sessions of the collaboration edge, keyed by the SHA-256 of the cookie id. No grant to any role.';
COMMENT ON TABLE afs.collab_edge_handoffs IS 'Single-use 60 second handoff codes (hashed) from the apex callback to a team host. No grant to any role.';

CREATE FUNCTION afs.collab_handoff_create(p_code_hash bytea, p_team_id text, p_host text, p_issuer text, p_subject text,
                                          p_provider_id text, p_groups text[]) RETURNS timestamptz
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_exp timestamptz := now() + interval '60 seconds';
BEGIN
  IF coalesce(cardinality(p_groups), 0) > 500 THEN
    RAISE EXCEPTION 'at most 500 groups' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.team_collaboration c JOIN afs.teams t ON t.id = c.team_id
                  WHERE c.team_id = p_team_id AND t.state NOT IN ('deleting', 'deleted') AND t.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'team % has no live collaboration agent', p_team_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  INSERT INTO afs.collab_edge_handoffs (code_hash, team_id, host, issuer, subject, provider_id, groups, expires_at)
  VALUES (p_code_hash, p_team_id, p_host, p_issuer, p_subject, p_provider_id, coalesce(p_groups, '{}'), v_exp);
  RETURN v_exp;
END $$;

CREATE FUNCTION afs.collab_handoff_consume(p_code_hash bytea, p_host text, p_session_id_hash bytea)
  RETURNS TABLE (team_id text, expires_at timestamptz)
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  h     afs.collab_edge_handoffs;
  v_ttl integer;
  v_exp timestamptz;
BEGIN
  UPDATE afs.collab_edge_handoffs x SET consumed_at = now()
   WHERE x.code_hash = p_code_hash AND x.host = p_host AND x.consumed_at IS NULL AND x.expires_at > now()
  RETURNING x.* INTO h;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  SELECT (s.value #>> '{}')::integer INTO v_ttl FROM afs.service_settings s WHERE s.key = 'collab.session_ttl_minutes';
  v_exp := now() + make_interval(mins => coalesce(v_ttl, 480));
  INSERT INTO afs.collab_edge_sessions (id_hash, team_id, issuer, subject, provider_id, groups, expires_at)
  VALUES (p_session_id_hash, h.team_id, h.issuer, h.subject, h.provider_id, h.groups, v_exp);
  RETURN QUERY SELECT h.team_id, v_exp;
END $$;

CREATE FUNCTION afs.collab_session_get(p_id_hash bytea)
  RETURNS TABLE (team_id text, issuer text, subject text, provider_id text, groups text[], expires_at timestamptz, last_seen_at timestamptz)
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  s afs.collab_edge_sessions;
BEGIN
  SELECT x.* INTO s FROM afs.collab_edge_sessions x JOIN afs.teams t ON t.id = x.team_id
   WHERE x.id_hash = p_id_hash AND x.revoked_at IS NULL AND x.expires_at > now()
     AND t.state NOT IN ('deleting', 'deleted') AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF s.last_seen_at < now() - interval '1 minute' THEN
    UPDATE afs.collab_edge_sessions x SET last_seen_at = now() WHERE x.id_hash = p_id_hash;
    s.last_seen_at := now();
  END IF;
  RETURN QUERY SELECT s.team_id, s.issuer, s.subject, s.provider_id, s.groups, s.expires_at, s.last_seen_at;
END $$;

CREATE FUNCTION afs.collab_session_revoke(p_id_hash bytea) RETURNS boolean
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  UPDATE afs.collab_edge_sessions x SET revoked_at = now()
   WHERE x.id_hash = p_id_hash AND x.revoked_at IS NULL AND x.expires_at > now();
  RETURN FOUND;
END $$;

CREATE FUNCTION afs.purge_collab_edge_sessions() RETURNS bigint
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  n1 bigint;
  n2 bigint;
BEGIN
  DELETE FROM afs.collab_edge_sessions x
   WHERE x.expires_at < now() - interval '1 hour' OR x.revoked_at < now() - interval '1 hour';
  GET DIAGNOSTICS n1 = ROW_COUNT;
  DELETE FROM afs.collab_edge_handoffs x WHERE x.expires_at < now() - interval '1 hour';
  GET DIAGNOSTICS n2 = ROW_COUNT;
  RETURN n1 + n2;
END $$;

-- 7. Edge read functions (DB-US-47) and principals (DB-US-51) ----------------------------------------------
CREATE FUNCTION afs.collab_settings() RETURNS TABLE (key text, value jsonb)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$ SELECT s.key, s.value FROM afs.service_settings s WHERE s.key LIKE 'collab.%' ORDER BY s.key $$;

CREATE FUNCTION afs.collab_routes() RETURNS TABLE (
    team_id text, slug text, namespace text, hostname text, team_state text, agent_id text, agent_state text,
    web_ui_enabled boolean, rest_api_enabled boolean, web_ui_effective boolean, rest_api_effective boolean,
    may_expose boolean, ready boolean, not_ready_reason text, service_name text, port integer,
    provider_id text, issuer_url text, groups_claim text, collab_client_id text, collab_client_secret_arn text)
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
         'paperclip'::text, 3100, r.pid, r.pissuer, r.pgroups, r.pclient, r.parn
    FROM r CROSS JOIN cfg
   ORDER BY r.tid
$$;

CREATE FUNCTION afs.collab_principal(p_team_id text, p_subject text, p_provider_id text, p_groups text[])
  RETURNS TABLE (binding_id text, role text, subject_type text, user_id text)
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_user    text;
  v_default text;
  v_team_idp text;
BEGIN
  IF coalesce(cardinality(p_groups), 0) > 500 THEN
    RAISE EXCEPTION 'at most 500 groups' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = p_team_id AND t.state NOT IN ('deleting', 'deleted') AND t.deleted_at IS NULL) THEN
    RETURN;
  END IF;
  SELECT u.id INTO v_user
    FROM afs.users u JOIN afs.identity_providers p ON p.issuer_url = u.oidc_issuer
   WHERE p.id = p_provider_id AND u.oidc_subject = p_subject AND u.disabled_at IS NULL;
  SELECT d.id INTO v_default FROM afs.identity_providers d WHERE d.is_default;
  -- A team's group bindings name no provider (000010): they use the team's provider, else the default.
  SELECT coalesce(t.identity_provider_id, v_default) INTO v_team_idp FROM afs.teams t WHERE t.id = p_team_id;
  RETURN QUERY
    SELECT b.id, b.role, b.subject_type, v_user
      FROM afs.role_bindings b
     WHERE ((b.team_id = p_team_id AND b.role IN ('team_admin', 'team_viewer', 'team_collaborator'))
            OR (b.team_id IS NULL AND b.role = 'service_admin'))
       AND ((b.subject_type = 'user' AND v_user IS NOT NULL AND b.user_id = v_user)
            OR (b.subject_type = 'group' AND b.group_name = ANY (coalesce(p_groups, '{}'))
                AND p_provider_id IS NOT NULL
                AND p_provider_id = CASE WHEN b.team_id IS NOT NULL THEN v_team_idp
                                         ELSE coalesce(b.identity_provider_id, v_default) END))
     ORDER BY b.id;
END $$;

CREATE FUNCTION afs.collab_principal_key(p_team_id text, p_key_sha256 bytea)
  RETURNS TABLE (key_id text, role text, state text, expires_at timestamptz, revoked_at timestamptz)
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  k afs.api_keys;
  v_state text;
BEGIN
  SELECT a.* INTO k FROM afs.api_keys a JOIN afs.teams t ON t.id = a.team_id
   WHERE a.key_sha256 = p_key_sha256 AND a.team_id = p_team_id AND t.state NOT IN ('deleting', 'deleted') AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  v_state := CASE WHEN k.revoked_at IS NOT NULL THEN 'revoked' WHEN k.expires_at <= now() THEN 'expired' ELSE 'active' END;
  IF v_state = 'active' AND (k.last_used_at IS NULL OR k.last_used_at < now() - interval '1 minute') THEN
    UPDATE afs.api_keys a SET last_used_at = now() WHERE a.id = k.id;
  END IF;
  RETURN QUERY SELECT k.id, k.role, v_state, k.expires_at, k.revoked_at;
END $$;

-- 8. Access counts and the secret-detected event (DB-US-52) -------------------------------------------------
-- Counts only: the function takes no body, path or header. Additive, so the edge must not retry a batch that succeeded.
CREATE FUNCTION afs.record_collab_access(p_rows jsonb) RETURNS integer
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

CREATE FUNCTION afs.emit_collab_secret_detected(p_team_id text, p_surface text, p_principal_kind text, p_principal_id text,
                                                p_pattern text, p_action text, p_count integer) RETURNS bigint
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_id bigint;
BEGIN
  IF p_surface IS NULL OR p_surface NOT IN ('web_ui', 'rest_api')
     OR p_principal_kind IS NULL OR p_principal_kind NOT IN ('user', 'api_key', 'anonymous')
     OR (p_principal_kind = 'anonymous') <> (coalesce(p_principal_id, '') = '')
     OR length(coalesce(p_principal_id, '')) > 64
     OR p_pattern IS NULL OR p_pattern NOT IN ('aws_access_key', 'github_token', 'slack_token', 'private_key', 'jwt',
                                               'okta_client_secret', 'entra_client_secret', 'generic_assignment')
     OR p_action IS NULL OR p_action NOT IN ('blocked', 'warned')
     OR p_count IS NULL OR p_count < 1 THEN
    RAISE EXCEPTION 'invalid secret-detected event' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = p_team_id) THEN
    RAISE EXCEPTION 'team % not found', p_team_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload)
  VALUES ('collaboration.secret_detected', 'team_collaboration', p_team_id, p_team_id,
          jsonb_set(afs.event_detail(p_team_id, NULL,
                      jsonb_build_object('surface', p_surface, 'principalKind', p_principal_kind,
                                         'principalId', coalesce(p_principal_id, ''), 'pattern', p_pattern,
                                         'action', p_action, 'count', p_count)),
                    '{actor}', '"system:edge"'))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- 9. Role afs_edge: no table privilege, ten functions (DB-US-47) -----------------------------------------------
GRANT USAGE ON SCHEMA afs TO afs_edge;
REVOKE ALL ON FUNCTION
  afs.collab_routes(), afs.collab_settings(), afs.collab_principal(text, text, text, text[]),
  afs.collab_principal_key(text, bytea), afs.record_collab_access(jsonb),
  afs.emit_collab_secret_detected(text, text, text, text, text, text, integer),
  afs.collab_handoff_create(bytea, text, text, text, text, text, text[]),
  afs.collab_handoff_consume(bytea, text, bytea), afs.collab_session_get(bytea), afs.collab_session_revoke(bytea),
  afs.purge_collab_edge_sessions()
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  afs.collab_routes(), afs.collab_settings(), afs.collab_principal(text, text, text, text[]),
  afs.collab_principal_key(text, bytea), afs.record_collab_access(jsonb),
  afs.emit_collab_secret_detected(text, text, text, text, text, text, integer),
  afs.collab_handoff_create(bytea, text, text, text, text, text, text[]),
  afs.collab_handoff_consume(bytea, text, bytea), afs.collab_session_get(bytea), afs.collab_session_revoke(bytea)
  TO afs_edge;
GRANT EXECUTE ON FUNCTION afs.purge_collab_edge_sessions() TO afs_reconciler;
GRANT EXECUTE ON FUNCTION afs.schema_version() TO afs_edge;

-- 10. Swarm collaboration (DB-US-57): a swarm template's spec may carry collaboration: {templateId[, image]}.
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

-- Hardening: the partition helpers were executable by PUBLIC (a default for functions). They are
-- SECURITY DEFINER, so the login-less afs_edge role must not reach them. The reconciler keeps its
-- explicit grants from 000002 and 000008.
REVOKE EXECUTE ON FUNCTION afs.ensure_usage_partition(date), afs.ensure_activity_partition(date),
  afs.ensure_traffic_partition(date) FROM PUBLIC;
