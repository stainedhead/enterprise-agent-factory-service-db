-- 000024: governed MCP servers (release 1.3.0; database contract §7.5, MCP gateway PRD §7, §8, §11, App. C, E.2).
--
-- The enterprise and team MCP catalog, the inventory of tools, resources and prompts with pinned digests, opt-in per
-- team and narrowing per agent and pool, service/team/agent policy, upstream credential references (ARNs only),
-- reviews, OAuth state, workload federation state, query capture windows, per-agent federated identities, and the
-- append-only call ledger with its daily rollup. afs.mcp_admission is the single policy decision (CD-51) that the
-- API, the reconciler and the gateway share.
--
-- Lock impact:
--   teams, agents, agent_pools: ADD COLUMN with constant defaults or NULL (no rewrite, brief ACCESS EXCLUSIVE).
--   external_systems: the category CHECK is replaced NOT VALID then validated (SHARE UPDATE EXCLUSIVE while validating).
--   New triggers on teams and external_systems take a brief ACCESS EXCLUSIVE. Every other object is new.

-- 1. Settings (PRD Appendix B) ----------------------------------------------------------------------------------
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('mcp.enabled', 'false', 'Feature switch for MCP servers: off means no /mcp paths and no catalog screens for teams.'),
  ('mcp.team_server_approval', '"team_all"', 'Who approves team MCP servers: team_all, team_low_security_higher or security_all.'),
  ('mcp.host_deny_list', '[]', 'Host or *.domain globs an MCP server may not use; a denied host makes the risk tier high.'),
  ('mcp.corporate_domains', '[]', '*.domain globs that count as the corporate network for location and risk.'),
  ('mcp.allowed_image_registries', '[]', 'Registry hosts hosted MCP server images may come from.'),
  ('mcp.image_signature_policy', '"required"', 'Hosted image signatures: required, or warn (non-production only).'),
  ('mcp.default_agent_mode', '"search"', 'MCP mode of a new agent or pool: search (meta-tools) or full.'),
  ('mcp.search_limit_max', '25', 'Largest result count afs_search returns (5 to 50).'),
  ('mcp.refresh_interval_minutes', '15', 'Inventory refresh interval when a server sends no list-changed signal (1 to 1440).'),
  ('mcp.limits', '{"requestBytes": 1048576, "responseBytes": 8388608, "timeoutSeconds": 60, "concurrentPerAgent": 8}',
   'Default per-server MCP limits; a server may override them.'),
  ('mcp.query_capture_max_days', '7', 'Longest window in which afs_search query text is recorded (1 to 14).'),
  ('mcp.events_retention_months', '13', 'Months of MCP call ledger kept (3 to 36).'),
  ('gateway.mcp.placement_default', '"combined"', 'Where a team gateway serves MCP: combined with model routes, or separate.'),
  ('federation.allowed_audiences', '[]', 'Exact audiences or globs an agent federated identity may request.')
ON CONFLICT (key) DO NOTHING;

CREATE FUNCTION afs.mcp_setting(p_key text) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN (SELECT s.value FROM afs.service_settings s WHERE s.key = p_key AND (p_key LIKE 'mcp.%' OR p_key LIKE 'federation.%'
                                                                              OR p_key LIKE 'gateway.mcp.%'));
REVOKE ALL ON FUNCTION afs.mcp_setting(text) FROM PUBLIC;

-- Values are checked here so a bad PutSetting never reaches the gateway.
CREATE FUNCTION afs.service_settings_mcp_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v jsonb := NEW.value;
  ok boolean;
BEGIN
  ok := CASE NEW.key
    WHEN 'mcp.enabled' THEN jsonb_typeof(v) = 'boolean'
    WHEN 'mcp.team_server_approval' THEN v #>> '{}' IN ('team_all', 'team_low_security_higher', 'security_all') AND jsonb_typeof(v) = 'string'
    WHEN 'mcp.image_signature_policy' THEN v #>> '{}' IN ('required', 'warn') AND jsonb_typeof(v) = 'string'
    WHEN 'mcp.default_agent_mode' THEN v #>> '{}' IN ('search', 'full') AND jsonb_typeof(v) = 'string'
    WHEN 'gateway.mcp.placement_default' THEN v #>> '{}' IN ('combined', 'separate') AND jsonb_typeof(v) = 'string'
    WHEN 'mcp.search_limit_max' THEN jsonb_typeof(v) = 'number' AND (v #>> '{}')::numeric BETWEEN 5 AND 50
    WHEN 'mcp.refresh_interval_minutes' THEN jsonb_typeof(v) = 'number' AND (v #>> '{}')::numeric BETWEEN 1 AND 1440
    WHEN 'mcp.query_capture_max_days' THEN jsonb_typeof(v) = 'number' AND (v #>> '{}')::numeric BETWEEN 1 AND 14
    WHEN 'mcp.events_retention_months' THEN jsonb_typeof(v) = 'number' AND (v #>> '{}')::numeric BETWEEN 3 AND 36
    WHEN 'mcp.limits' THEN jsonb_typeof(v) = 'object'
    ELSE jsonb_typeof(v) = 'array'
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE jsonb_typeof(e) <> 'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 253)
  END;
  IF NOT ok THEN
    RAISE EXCEPTION 'setting % has an invalid value %', NEW.key, NEW.value
      USING ERRCODE = 'check_violation', CONSTRAINT = 'service_settings_mcp_value';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER service_settings_mcp_guard BEFORE INSERT OR UPDATE ON afs.service_settings
  FOR EACH ROW WHEN (NEW.key IN ('mcp.enabled', 'mcp.team_server_approval', 'mcp.host_deny_list', 'mcp.corporate_domains',
                                 'mcp.allowed_image_registries', 'mcp.image_signature_policy', 'mcp.default_agent_mode',
                                 'mcp.search_limit_max', 'mcp.refresh_interval_minutes', 'mcp.limits',
                                 'mcp.query_capture_max_days', 'mcp.events_retention_months',
                                 'gateway.mcp.placement_default', 'federation.allowed_audiences'))
  EXECUTE FUNCTION afs.service_settings_mcp_guard();

-- 2. Team, agent and pool columns --------------------------------------------------------------------------------
ALTER TABLE afs.teams
  ADD COLUMN may_add_mcp_servers boolean NOT NULL DEFAULT false,
  ADD COLUMN mcp_placement text CHECK (mcp_placement IN ('combined', 'separate'));

-- Its own trigger beside teams_guardrail_guard, so 000023's replacement of that function stays independent.
CREATE FUNCTION afs.teams_mcp_guardrail_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
     AND (NEW.may_add_mcp_servers IS DISTINCT FROM OLD.may_add_mcp_servers OR NEW.mcp_placement IS DISTINCT FROM OLD.mcp_placement) THEN
    RAISE EXCEPTION 'only service admins decide whether a team may add MCP servers and where its gateway serves them'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER teams_mcp_guardrail_guard BEFORE UPDATE OF may_add_mcp_servers, mcp_placement ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.teams_mcp_guardrail_guard();

ALTER TABLE afs.agents
  ADD COLUMN mcp_access text NOT NULL DEFAULT 'all' CHECK (mcp_access IN ('all', 'selected')),
  ADD COLUMN mcp_mode text CHECK (mcp_mode IN ('search', 'full'));
ALTER TABLE afs.agent_pools
  ADD COLUMN mcp_access text NOT NULL DEFAULT 'all' CHECK (mcp_access IN ('all', 'selected')),
  ADD COLUMN mcp_mode text CHECK (mcp_mode IN ('search', 'full'));

-- 3. Catalog -----------------------------------------------------------------------------------------------------
CREATE TABLE afs.mcp_servers (
  id                    text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mcp')),
  -- NULL: an enterprise server in the service catalog. Set: a server that team added for itself.
  team_id               text REFERENCES afs.teams (id) ON DELETE CASCADE,
  slug                  text NOT NULL CHECK (slug ~ '^[a-z][a-z0-9-]{1,30}$' AND slug !~ '--' AND slug !~ '-$' AND slug <> 'afs'),
  display_name          text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 100),
  owner                 text NOT NULL DEFAULT '' CHECK (length(owner) <= 200),
  purpose               text NOT NULL DEFAULT '' CHECK (length(purpose) <= 1000),
  doc_url               text CHECK (doc_url ~ '^https://' AND length(doc_url) <= 500),
  data_classification   text NOT NULL CHECK (data_classification IN ('public', 'internal', 'confidential', 'restricted')),
  transport             text NOT NULL CHECK (transport IN ('streamable_http', 'hosted')),
  location              text NOT NULL CHECK (location IN ('external', 'corporate', 'in_namespace')),
  url                   text,
  ca_bundle             text CHECK (length(ca_bundle) <= 16384 AND ca_bundle LIKE '-----BEGIN CERTIFICATE-----%'),
  auth_kind             text NOT NULL CHECK (auth_kind IN ('none', 'static', 'oauth_client', 'workload_federation', 'oauth_user', 'aws_sigv4')),
  auth_header           text CHECK (auth_header ~ '^[A-Za-z][A-Za-z0-9-]{0,63}$'),
  credential_mode       text NOT NULL DEFAULT 'per_team' CHECK (credential_mode IN ('shared', 'per_team')),
  federation            jsonb CHECK (federation IS NULL OR jsonb_typeof(federation) = 'object'),
  oauth                 jsonb CHECK (oauth IS NULL OR jsonb_typeof(oauth) = 'object'),
  protocol_version      text CHECK (length(protocol_version) <= 20),
  review_status         text NOT NULL DEFAULT 'draft'
                        CHECK (review_status IN ('draft', 'pending_review', 'approved', 'rejected', 'suspended')),
  suspended_from        text CHECK (suspended_from IN ('draft', 'pending_review', 'approved', 'rejected')),
  published             boolean NOT NULL DEFAULT false,
  risk_tier             text CHECK (risk_tier IN ('low', 'elevated', 'high')),
  risk_reasons          text[] NOT NULL DEFAULT '{}',
  checks                jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(checks) = 'array'),
  drift_policy          text NOT NULL DEFAULT 'hold' CHECK (drift_policy IN ('hold', 'auto_approve_compatible')),
  default_for_new_teams boolean NOT NULL DEFAULT false,
  allow_sampling        boolean NOT NULL DEFAULT false,
  trust_annotations     boolean NOT NULL DEFAULT false,
  args_hashing          boolean NOT NULL DEFAULT false,
  limits                jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(limits) = 'object'),
  suspended_reason      text CHECK (length(suspended_reason) <= 500),
  promoted_from         text,
  refresh_requested_at  timestamptz,
  version               bigint NOT NULL DEFAULT 1,
  generation            bigint NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            text NOT NULL DEFAULT afs.current_actor(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, id),
  CONSTRAINT mcp_servers_url CHECK (
    (transport = 'hosted' AND location = 'in_namespace' AND url IS NULL)
    OR (transport = 'streamable_http' AND location <> 'in_namespace' AND url IS NOT NULL
        AND url ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$' AND length(url) <= 500)),
  CONSTRAINT mcp_servers_federation CHECK (auth_kind <> 'workload_federation'
    OR (federation IS NOT NULL AND federation ? 'issuer' AND federation ? 'audience' AND federation ? 'tokenEndpoint')),
  CONSTRAINT mcp_servers_enterprise_only CHECK (team_id IS NULL OR NOT (published OR default_for_new_teams)),
  CONSTRAINT mcp_servers_default_published CHECK (NOT default_for_new_teams OR published),
  CONSTRAINT mcp_servers_suspension CHECK ((review_status = 'suspended') = (suspended_from IS NOT NULL))
);
CREATE UNIQUE INDEX mcp_servers_enterprise_slug_uq ON afs.mcp_servers (slug) WHERE team_id IS NULL;
CREATE UNIQUE INDEX mcp_servers_team_slug_uq ON afs.mcp_servers (team_id, slug) WHERE team_id IS NOT NULL;
CREATE INDEX mcp_servers_review_idx ON afs.mcp_servers (review_status) WHERE review_status = 'pending_review';
COMMENT ON TABLE afs.mcp_servers IS
  'MCP servers: enterprise (team_id NULL) and team-added. No credential values; upstream credentials are ARNs in mcp_credentials.';

-- A team slug never equals an enterprise slug, nor the reverse, so /mcp/<slug> and the prefixed names stay unique.
CREATE FUNCTION afs.mcp_servers_slug_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('afs.mcp_servers.slug'), hashtext(NEW.slug));
  IF EXISTS (SELECT 1 FROM afs.mcp_servers s
              WHERE s.slug = NEW.slug AND s.id <> NEW.id
                AND (s.team_id IS NULL OR NEW.team_id IS NULL OR s.team_id = NEW.team_id)) THEN
    RAISE EXCEPTION 'MCP server slug % is taken', NEW.slug
      USING ERRCODE = 'unique_violation', CONSTRAINT = 'mcp_servers_slug_taken';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_servers_slug_guard() FROM PUBLIC;
CREATE TRIGGER mcp_servers_slug_guard BEFORE INSERT OR UPDATE OF slug, team_id ON afs.mcp_servers
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_servers_slug_guard();

CREATE FUNCTION afs.mcp_servers_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  o text := CASE WHEN TG_OP = 'UPDATE' THEN OLD.review_status END;
  n text := NEW.review_status;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF n NOT IN ('draft', 'pending_review') AND current_user = 'afs_app' AND NOT afs.caller_is_service_admin() THEN
      RAISE EXCEPTION 'a new MCP server starts as draft' USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_review_transition';
    END IF;
    IF NEW.team_id IS NOT NULL AND current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
       AND NOT (SELECT t.may_add_mcp_servers FROM afs.teams t WHERE t.id = NEW.team_id) THEN
      RAISE EXCEPTION 'team % may not add MCP servers', NEW.team_id USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF o IS DISTINCT FROM n THEN
    IF n = 'suspended' THEN
      NEW.suspended_from := o;
    ELSIF o = 'suspended' THEN
      IF n IS DISTINCT FROM OLD.suspended_from THEN
        RAISE EXCEPTION 'a suspended MCP server returns to %', OLD.suspended_from
          USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_review_transition';
      END IF;
      NEW.suspended_from := NULL;
      NEW.suspended_reason := NULL;
    ELSIF NOT ((o = 'draft' AND n = 'pending_review')
               OR (o = 'pending_review' AND n IN ('approved', 'rejected', 'draft'))
               OR (o = 'rejected' AND n = 'draft')
               OR (o = 'approved' AND n = 'pending_review')) THEN
      RAISE EXCEPTION 'an MCP server cannot move from % to %', o, n
        USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_review_transition';
    END IF;
  END IF;
  IF NEW.published AND (TG_OP = 'INSERT' OR NOT OLD.published) AND n <> 'approved' THEN
    RAISE EXCEPTION 'only an approved MCP server can be published' USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_servers_publish';
  END IF;
  -- Enterprise rows change only with a service admin (or a security operator's review); RLS hides the rest.
  IF TG_OP = 'UPDATE' AND (NEW.url, NEW.location, NEW.auth_kind, NEW.transport, NEW.federation, NEW.ca_bundle)
                          IS DISTINCT FROM (OLD.url, OLD.location, OLD.auth_kind, OLD.transport, OLD.federation, OLD.ca_bundle) THEN
    NEW.generation := OLD.generation + 1;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mcp_servers_guard BEFORE INSERT OR UPDATE ON afs.mcp_servers
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_servers_guard();
-- The gateway's bookkeeping (refresh done, protocol seen) is not a change the API's If-Match should trip on.
CREATE TRIGGER mcp_servers_touch BEFORE UPDATE ON afs.mcp_servers
  FOR EACH ROW WHEN (current_user <> 'afs_gateway') EXECUTE FUNCTION afs.touch_row();

CREATE FUNCTION afs.mcp_env_names_ok(p text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN cardinality(p) <= 64 AND NOT EXISTS (SELECT 1 FROM unnest(p) n WHERE n !~ '^[A-Z_][A-Z0-9_]{0,63}$');

-- Child rows carry their server's team, so composite keys and row-level security work on them directly.
CREATE FUNCTION afs.mcp_copy_server_team() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  SELECT s.team_id INTO NEW.team_id FROM afs.mcp_servers s WHERE s.id = NEW.server_id;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_copy_server_team() FROM PUBLIC;

CREATE TABLE afs.mcp_hosted_specs (
  server_id             text PRIMARY KEY,
  id                    text GENERATED ALWAYS AS (server_id) STORED,
  team_id               text,
  image                 text NOT NULL,
  args                  text[] NOT NULL DEFAULT '{}' CHECK (cardinality(args) <= 64),
  env_names             text[] NOT NULL DEFAULT '{}',
  instance_mode         text NOT NULL DEFAULT 'per_team' CHECK (instance_mode IN ('per_team', 'per_agent')),
  egress_hosts          text[] NOT NULL DEFAULT '{}' CHECK (cardinality(egress_hosts) <= 50),
  resources             jsonb CHECK (resources IS NULL OR jsonb_typeof(resources) = 'object'),
  needs_aws             boolean NOT NULL DEFAULT false,
  signature_verified_at timestamptz,
  version               bigint NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            text NOT NULL DEFAULT afs.current_actor(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (team_id, server_id) REFERENCES afs.mcp_servers (team_id, id) ON DELETE CASCADE,
  FOREIGN KEY (server_id) REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  CONSTRAINT mcp_hosted_specs_image CHECK (image ~ '^[^@[:space:]]+@sha256:[0-9a-f]{64}$'),
  CONSTRAINT mcp_hosted_specs_env_names CHECK (afs.mcp_env_names_ok(env_names))
);
CREATE TRIGGER mcp_hosted_specs_team BEFORE INSERT OR UPDATE OF server_id ON afs.mcp_hosted_specs
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_copy_server_team();
CREATE TRIGGER mcp_hosted_specs_touch BEFORE UPDATE ON afs.mcp_hosted_specs
  FOR EACH ROW WHEN (current_user <> 'afs_reconciler') EXECUTE FUNCTION afs.touch_row();

-- 4. Inventory and pinning ---------------------------------------------------------------------------------------
CREATE TABLE afs.mcp_primitives (
  id                 text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mpr')),
  server_id          text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  team_id            text,
  kind               text NOT NULL CHECK (kind IN ('tool', 'resource', 'resource_template', 'prompt')),
  name               text NOT NULL CHECK (length(name) BETWEEN 1 AND 500),
  title              text CHECK (length(title) <= 200),
  summary            text CHECK (length(summary) <= 200),
  annotations        jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(annotations) = 'object'),
  -- The approved definition (tool metadata only, never call arguments or results).
  definition         jsonb NOT NULL,
  digest             text NOT NULL CHECK (digest ~ '^sha256:[0-9a-f]{64}$'),
  approved_digest    text CHECK (approved_digest ~ '^sha256:[0-9a-f]{64}$'),
  -- A held change: the definition the upstream now serves, waiting for review.
  pending_definition jsonb,
  -- How the held change compares with the approved definition, as the gateway's drift check found it.
  change             text CHECK (change IN ('new', 'compatible', 'incompatible')),
  status             text NOT NULL CHECK (status IN ('approved', 'pending_review', 'blocked')),
  decided_by         text,
  decided_at         timestamptz,
  first_seen         timestamptz NOT NULL DEFAULT now(),
  last_seen          timestamptz NOT NULL DEFAULT now(),
  removed_at         timestamptz,
  UNIQUE (server_id, kind, name),
  UNIQUE (team_id, id),
  FOREIGN KEY (team_id, server_id) REFERENCES afs.mcp_servers (team_id, id) ON DELETE CASCADE
);
CREATE INDEX mcp_primitives_pending_idx ON afs.mcp_primitives (server_id) WHERE status = 'pending_review';
CREATE TRIGGER mcp_primitives_team BEFORE INSERT OR UPDATE OF server_id ON afs.mcp_primitives
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_copy_server_team();

-- SECURITY INVOKER on purpose: it keys on current_user, which a definer function would hide (CD-52).
CREATE FUNCTION afs.mcp_primitives_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  o text := CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END;
  n text := NEW.status;
  v_drift text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM pg_advisory_xact_lock(hashtext('afs.mcp_primitives'), hashtext(NEW.server_id));
    IF (SELECT count(*) FROM afs.mcp_primitives p WHERE p.server_id = NEW.server_id AND p.removed_at IS NULL) >= 2000 THEN
      RAISE EXCEPTION 'MCP server % already has 2000 primitives', NEW.server_id
        USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_primitives_limit';
    END IF;
    IF current_user = 'afs_gateway' AND n <> 'pending_review' THEN
      RAISE EXCEPTION 'the gateway records a new primitive as pending_review'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_primitive_transition';
    END IF;
  ELSIF o IS DISTINCT FROM n THEN
    IF NOT ((o = 'pending_review' AND n IN ('approved', 'blocked'))
            OR (o = 'approved' AND n = 'pending_review' AND NEW.digest IS DISTINCT FROM OLD.digest)
            OR (o = 'blocked' AND n = 'approved')) THEN
      RAISE EXCEPTION 'a primitive cannot move from % to %', o, n
        USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_primitive_transition';
    END IF;
    IF current_user = 'afs_gateway' AND n = 'approved' THEN
      SELECT s.drift_policy INTO v_drift FROM afs.mcp_servers s WHERE s.id = NEW.server_id;
      IF v_drift IS DISTINCT FROM 'auto_approve_compatible' OR NEW.change IS DISTINCT FROM 'compatible'
         OR OLD.approved_digest IS NULL OR o <> 'pending_review' THEN
        RAISE EXCEPTION 'the gateway can hold a change but not approve it'
          USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'mcp_gateway_cannot_approve';
      END IF;
      NEW.decided_by := 'system:auto_approve';
      NEW.decided_at := now();
    END IF;
  END IF;
  -- Approval adopts the held definition and pins its digest; whoever approves.
  IF n = 'approved' AND (TG_OP = 'INSERT' OR o IS DISTINCT FROM 'approved') THEN
    IF NEW.pending_definition IS NOT NULL THEN
      NEW.definition := NEW.pending_definition;
    END IF;
    NEW.pending_definition := NULL;
    NEW.approved_digest := NEW.digest;
    NEW.change := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mcp_primitives_guard BEFORE INSERT OR UPDATE ON afs.mcp_primitives
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_primitives_guard();

-- 5. Opt-in per team, narrowing per agent and pool ---------------------------------------------------------------
CREATE TABLE afs.team_mcp_servers (
  team_id    text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  server_id  text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  id         text GENERATED ALWAYS AS (team_id || '/' || server_id) STORED,
  enabled    boolean NOT NULL,
  mode       text NOT NULL DEFAULT 'full' CHECK (mode IN ('full', 'read_only')),
  enabled_by text NOT NULL DEFAULT afs.current_actor(),
  enabled_at timestamptz NOT NULL DEFAULT now(),
  version    bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, server_id)
);
CREATE INDEX team_mcp_servers_server_idx ON afs.team_mcp_servers (server_id);

CREATE FUNCTION afs.team_mcp_servers_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  s afs.mcp_servers;
BEGIN
  SELECT * INTO s FROM afs.mcp_servers x WHERE x.id = NEW.server_id;
  IF NOT coalesce((s.team_id IS NULL AND (s.published OR (TG_OP = 'UPDATE' AND NOT NEW.enabled))) OR s.team_id = NEW.team_id, false) THEN
    RAISE EXCEPTION 'MCP server % is neither published nor this team''s', NEW.server_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'team_mcp_servers_scope';
  END IF;
  IF NEW.enabled AND (SELECT t.gateway_deployment FROM afs.teams t WHERE t.id = NEW.team_id) IS DISTINCT FROM 'per_namespace' THEN
    RAISE EXCEPTION 'team % needs its own gateway before it can switch on MCP servers', NEW.team_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'team_gateway_required';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.enabled AND NOT OLD.enabled THEN
    NEW.enabled_by := afs.current_actor();
    NEW.enabled_at := now();
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.team_mcp_servers_guard() FROM PUBLIC;
CREATE TRIGGER team_mcp_servers_guard BEFORE INSERT OR UPDATE ON afs.team_mcp_servers
  FOR EACH ROW EXECUTE FUNCTION afs.team_mcp_servers_guard();
CREATE TRIGGER team_mcp_servers_touch BEFORE UPDATE ON afs.team_mcp_servers
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();

-- Whether a server is switched on for a team right now (enterprise: published and on; team: its own and on).
CREATE FUNCTION afs.mcp_enabled_for_team(p_team_id text, p_server_id text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN EXISTS (SELECT 1 FROM afs.team_mcp_servers tm WHERE tm.team_id = p_team_id AND tm.server_id = p_server_id AND tm.enabled);
REVOKE ALL ON FUNCTION afs.mcp_enabled_for_team(text, text) FROM PUBLIC;

CREATE TABLE afs.agent_mcp_servers (
  team_id    text NOT NULL,
  agent_id   text NOT NULL,
  server_id  text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  id         text GENERATED ALWAYS AS (agent_id || '/' || server_id) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, agent_id, server_id),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE
);
CREATE TABLE afs.pool_mcp_servers (
  team_id    text NOT NULL,
  pool_id    text NOT NULL,
  server_id  text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  id         text GENERATED ALWAYS AS (pool_id || '/' || server_id) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, pool_id, server_id),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);

CREATE FUNCTION afs.subject_mcp_servers_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NOT afs.mcp_enabled_for_team(NEW.team_id, NEW.server_id) THEN
    RAISE EXCEPTION 'MCP server % is not switched on for team %', NEW.server_id, NEW.team_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agent_mcp_servers_team';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER agent_mcp_servers_guard BEFORE INSERT OR UPDATE ON afs.agent_mcp_servers
  FOR EACH ROW EXECUTE FUNCTION afs.subject_mcp_servers_guard();
CREATE TRIGGER pool_mcp_servers_guard BEFORE INSERT OR UPDATE ON afs.pool_mcp_servers
  FOR EACH ROW EXECUTE FUNCTION afs.subject_mcp_servers_guard();

-- 6. Policy ------------------------------------------------------------------------------------------------------
CREATE TABLE afs.mcp_policies (
  id                    text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mpol')),
  level                 text NOT NULL CHECK (level IN ('service', 'team', 'agent', 'pool')),
  team_id               text REFERENCES afs.teams (id) ON DELETE CASCADE,
  agent_id              text,
  pool_id               text,
  server_id             text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  -- Exactly one: a primitive name (exact, or a glob where * matches any run) or an annotation class.
  name                  text CHECK (length(name) BETWEEN 1 AND 500),
  class                 text CHECK (class IN ('read_only', 'destructive', 'open_world')),
  effect                text NOT NULL CHECK (effect IN ('allow', 'block')),
  rate_limit_per_minute integer CHECK (rate_limit_per_minute > 0),
  version               bigint NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            text NOT NULL DEFAULT afs.current_actor(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mcp_policies_selector CHECK ((name IS NULL) <> (class IS NULL)),
  CONSTRAINT mcp_policies_scope CHECK (
    (level = 'service' AND team_id IS NULL AND agent_id IS NULL AND pool_id IS NULL)
    OR (level = 'team' AND team_id IS NOT NULL AND agent_id IS NULL AND pool_id IS NULL)
    OR (level = 'agent' AND team_id IS NOT NULL AND agent_id IS NOT NULL AND pool_id IS NULL)
    OR (level = 'pool' AND team_id IS NOT NULL AND agent_id IS NULL AND pool_id IS NOT NULL)),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE,
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX mcp_policies_rule_uq ON afs.mcp_policies
  (server_id, level, coalesce(team_id, ''), coalesce(agent_id, ''), coalesce(pool_id, ''), coalesce(name, ''), coalesce(class, ''));
CREATE INDEX mcp_policies_scope_idx ON afs.mcp_policies (server_id, team_id);
CREATE TRIGGER mcp_policies_touch BEFORE UPDATE ON afs.mcp_policies
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();

CREATE FUNCTION afs.mcp_policies_limit() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('afs.mcp_policies'), hashtext(NEW.server_id || coalesce(NEW.team_id, '')));
  IF (SELECT count(*) FROM afs.mcp_policies p
       WHERE p.server_id = NEW.server_id AND p.level = NEW.level AND p.team_id IS NOT DISTINCT FROM NEW.team_id
         AND p.agent_id IS NOT DISTINCT FROM NEW.agent_id AND p.pool_id IS NOT DISTINCT FROM NEW.pool_id) >= 500 THEN
    RAISE EXCEPTION 'at most 500 rules per server per scope' USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_policies_limit';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_policies_limit() FROM PUBLIC;
CREATE TRIGGER mcp_policies_limit BEFORE INSERT ON afs.mcp_policies
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_policies_limit();

-- 7. Credentials (ARNs only), OAuth state, reviews, federation state and query capture ---------------------------
-- <prefix>/<namespace>/_gateway/mcp/<slug> for a team, <prefix>/_service/gateway/mcp/<slug> for _shared.
CREATE FUNCTION afs.mcp_credential_path(p_team_id text, p_slug text) RETURNS text
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_prefix text := coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'secrets.path_prefix'), 'afs');
  v_ns     text;
BEGIN
  IF p_team_id IS NULL THEN
    RETURN v_prefix || '/_service/gateway/mcp/' || p_slug;
  END IF;
  SELECT t.namespace INTO v_ns FROM afs.teams t WHERE t.id = p_team_id;
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'team % not found', p_team_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN v_prefix || '/' || v_ns || '/_gateway/mcp/' || p_slug;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_credential_path(text, text) FROM PUBLIC;

CREATE TABLE afs.mcp_credentials (
  id         text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mcr')),
  server_id  text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  scope      text NOT NULL CHECK (scope = '_shared' OR afs.ulid_ok(scope, 'team')),
  team_id    text REFERENCES afs.teams (id) ON DELETE CASCADE,
  kind       text NOT NULL CHECK (kind IN ('static', 'oauth_client', 'oauth_user')),
  secret_arn text NOT NULL CHECK (secret_arn ~ '^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$'),
  -- The connected account of a user-delegated OAuth credential, for display (never a token).
  subject    text CHECK (length(subject) <= 200),
  scopes     text[] NOT NULL DEFAULT '{}',
  expires_at timestamptz,
  status     text NOT NULL CHECK (status IN ('set', 'missing', 'expired')),
  rotated_at timestamptz,
  version    bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (server_id, scope),
  CONSTRAINT mcp_credentials_scope_team CHECK ((scope = '_shared') = (team_id IS NULL) AND (team_id IS NULL OR scope = team_id)),
  CONSTRAINT mcp_credentials_subject CHECK (kind <> 'oauth_user' OR subject IS NOT NULL)
);
CREATE FUNCTION afs.mcp_credentials_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_slug text;
  v_owner text;
BEGIN
  SELECT s.slug, s.team_id INTO v_slug, v_owner FROM afs.mcp_servers s WHERE s.id = NEW.server_id;
  IF v_owner IS NOT NULL AND NEW.team_id IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'a team server''s credential belongs to its team' USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_credential_path';
  END IF;
  IF substring(NEW.secret_arn FROM ':secret:(.*)-[A-Za-z0-9]{6}$') IS DISTINCT FROM afs.mcp_credential_path(NEW.team_id, v_slug) THEN
    RAISE EXCEPTION 'the credential ARN must be at %', afs.mcp_credential_path(NEW.team_id, v_slug)
      USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_credential_path';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_credentials_guard() FROM PUBLIC;
CREATE TRIGGER mcp_credentials_guard BEFORE INSERT OR UPDATE OF secret_arn, server_id, team_id ON afs.mcp_credentials
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_credentials_guard();
CREATE TRIGGER mcp_credentials_touch BEFORE UPDATE ON afs.mcp_credentials
  FOR EACH ROW WHEN (current_user <> 'afs_gateway') EXECUTE FUNCTION afs.touch_row();

CREATE TABLE afs.mcp_oauth_states (
  state_hash        bytea PRIMARY KEY CHECK (length(state_hash) = 32),
  team_id           text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  server_id         text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  created_by        text NOT NULL DEFAULT afs.current_actor(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  code_verifier_arn text NOT NULL CHECK (code_verifier_arn ~ '^arn:aws[a-z-]*:secretsmanager:'),
  expires_at        timestamptz NOT NULL,
  used_at           timestamptz,
  CONSTRAINT mcp_oauth_states_ttl CHECK (expires_at <= created_at + interval '10 minutes')
);

-- Single use: the callback claims the state once, before it expires. The caller learns nothing about other states.
CREATE FUNCTION afs.claim_mcp_oauth_state(p_state_hash bytea)
  RETURNS TABLE (team_id text, server_id text, created_by text, code_verifier_arn text)
  LANGUAGE sql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  UPDATE afs.mcp_oauth_states s SET used_at = now()
   WHERE s.state_hash = p_state_hash AND s.used_at IS NULL AND s.expires_at > now()
  RETURNING s.team_id, s.server_id, s.created_by, s.code_verifier_arn
$$;
REVOKE ALL ON FUNCTION afs.claim_mcp_oauth_state(bytea) FROM PUBLIC;

CREATE TABLE afs.mcp_reviews (
  id           text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mrv')),
  -- No foreign keys: a review is history and outlives the server, primitive or team it is about.
  server_id    text NOT NULL CHECK (afs.ulid_ok(server_id, 'mcp')),
  team_id      text,
  primitive_id text CHECK (afs.ulid_ok(primitive_id, 'mpr')),
  at           timestamptz NOT NULL DEFAULT now(),
  checks       jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(checks) = 'array'),
  risk_tier    text CHECK (risk_tier IN ('low', 'elevated', 'high')),
  approver     text NOT NULL CHECK (approver IN ('team_admin', 'security')),
  decision     text NOT NULL CHECK (decision IN ('approved', 'rejected', 'changes_requested', 'blocked', 'auto_approved')),
  note         text CHECK (length(note) <= 2000),
  decided_by   text NOT NULL DEFAULT afs.current_actor(),
  CONSTRAINT mcp_reviews_note CHECK (decision = 'auto_approved' OR length(coalesce(note, '')) > 0)
);
CREATE INDEX mcp_reviews_server_idx ON afs.mcp_reviews (server_id, at);
CREATE TRIGGER mcp_reviews_team BEFORE INSERT ON afs.mcp_reviews
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_copy_server_team();
CREATE FUNCTION afs.mcp_append_only() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'afs.% is append-only', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
END $$;
CREATE TRIGGER mcp_reviews_no_update BEFORE UPDATE OR DELETE ON afs.mcp_reviews
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_append_only();
CREATE TRIGGER mcp_reviews_no_truncate BEFORE TRUNCATE ON afs.mcp_reviews
  FOR EACH STATEMENT EXECUTE FUNCTION afs.mcp_append_only();

-- An automatic approval by the gateway still leaves a review record.
CREATE FUNCTION afs.mcp_primitives_auto_review() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  INSERT INTO afs.mcp_reviews (id, server_id, primitive_id, approver, decision, decided_by, checks)
  VALUES (afs.new_id('mrv'), NEW.server_id, NEW.id, 'team_admin', 'auto_approved', 'system:auto_approve',
          jsonb_build_array(jsonb_build_object('check', 'drift', 'result', 'compatible', 'digest', NEW.digest)));
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_primitives_auto_review() FROM PUBLIC;
CREATE TRIGGER mcp_primitives_auto_review AFTER UPDATE OF status ON afs.mcp_primitives
  FOR EACH ROW WHEN (NEW.status = 'approved' AND OLD.status <> 'approved' AND NEW.decided_by = 'system:auto_approve')
  EXECUTE FUNCTION afs.mcp_primitives_auto_review();

CREATE TABLE afs.mcp_federation_states (
  server_id         text NOT NULL REFERENCES afs.mcp_servers (id) ON DELETE CASCADE,
  team_id           text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready', 'failing')),
  last_error        text CHECK (length(last_error) <= 500),
  checked_at        timestamptz,
  test_requested_at timestamptz,
  PRIMARY KEY (server_id, team_id)
);

CREATE TABLE afs.mcp_query_captures (
  id         text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mqc')),
  started_by text NOT NULL DEFAULT afs.current_actor(),
  reason     text NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
  started_at timestamptz NOT NULL DEFAULT now(),
  until      timestamptz NOT NULL,
  stopped_at timestamptz,
  stopped_by text,
  CONSTRAINT mcp_query_captures_window CHECK (until > started_at)
);
-- At most one window not stopped. An expired window is stopped by the reconciler (or the next start).
CREATE UNIQUE INDEX capture_active ON afs.mcp_query_captures ((true)) WHERE stopped_at IS NULL;

CREATE FUNCTION afs.mcp_query_captures_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_max integer := coalesce((afs.mcp_setting('mcp.query_capture_max_days') #>> '{}')::integer, 7);
BEGIN
  IF NEW.until > NEW.started_at + make_interval(days => v_max) THEN
    RAISE EXCEPTION 'a capture window lasts at most % days', v_max
      USING ERRCODE = 'check_violation', CONSTRAINT = 'mcp_query_captures_window';
  END IF;
  -- An expired, never-stopped window does not block a new one.
  UPDATE afs.mcp_query_captures c SET stopped_at = c.until, stopped_by = 'system:expired'
   WHERE c.stopped_at IS NULL AND c.until <= now();
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_query_captures_guard() FROM PUBLIC;
CREATE TRIGGER mcp_query_captures_guard BEFORE INSERT ON afs.mcp_query_captures
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_query_captures_guard();

CREATE FUNCTION afs.mcp_capture_open() RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN (SELECT c.id FROM afs.mcp_query_captures c WHERE c.stopped_at IS NULL AND c.until > now() LIMIT 1);
REVOKE ALL ON FUNCTION afs.mcp_capture_open() FROM PUBLIC;

-- 8. Per-agent federated identities (PRD Appendix C) -------------------------------------------------------------
CREATE FUNCTION afs.federated_identity_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_allowed jsonb := coalesce(afs.mcp_setting('federation.allowed_audiences'), '[]');
  v_count   integer;
BEGIN
  IF lower(NEW.audience) IN ('sts.amazonaws.com', 'afs-gateway') THEN
    RAISE EXCEPTION 'audience % is reserved', NEW.audience USING ERRCODE = 'check_violation', CONSTRAINT = 'audience_reserved';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) a
                  WHERE NEW.audience LIKE replace(replace(replace(a, '\', '\\'), '_', '\_'), '*', '%')) THEN
    RAISE EXCEPTION 'audience % is not in federation.allowed_audiences', NEW.audience
      USING ERRCODE = 'check_violation', CONSTRAINT = 'audience_not_allowed';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF TG_TABLE_NAME = 'agent_federated_identities' THEN
      PERFORM pg_advisory_xact_lock(hashtext('afs.federated_identities'), hashtext(to_jsonb(NEW) ->> 'agent_id'));
      SELECT count(*) INTO v_count FROM afs.agent_federated_identities f WHERE f.team_id = NEW.team_id AND f.agent_id = to_jsonb(NEW) ->> 'agent_id';
    ELSE
      PERFORM pg_advisory_xact_lock(hashtext('afs.federated_identities'), hashtext(to_jsonb(NEW) ->> 'pool_id'));
      SELECT count(*) INTO v_count FROM afs.pool_federated_identities f WHERE f.team_id = NEW.team_id AND f.pool_id = to_jsonb(NEW) ->> 'pool_id';
    END IF;
    IF v_count >= 10 THEN
      RAISE EXCEPTION 'at most 10 federated identities per agent or pool'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'federated_identity_limit';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.federated_identity_guard() FROM PUBLIC;

CREATE TABLE afs.agent_federated_identities (
  team_id            text NOT NULL,
  agent_id           text NOT NULL,
  name               text NOT NULL CHECK (name ~ '^[a-z][a-z0-9-]{0,30}$'),
  id                 text NOT NULL UNIQUE CHECK (afs.ulid_ok(id, 'afi')),
  audience           text NOT NULL CHECK (length(audience) BETWEEN 1 AND 300),
  file_path          text NOT NULL CHECK (file_path ~ '^/var/run/secrets/afs/federation/[a-z0-9-]+/[A-Za-z0-9._-]+$'),
  env_var            text NOT NULL CHECK (env_var ~ '^[A-Z_][A-Z0-9_]{0,63}$'),
  expiration_seconds integer NOT NULL DEFAULT 3600 CHECK (expiration_seconds BETWEEN 600 AND 86400),
  version            bigint NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         text NOT NULL DEFAULT afs.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, agent_id, name),
  UNIQUE (team_id, agent_id, env_var),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE
);
CREATE TABLE afs.pool_federated_identities (
  team_id            text NOT NULL,
  pool_id            text NOT NULL,
  name               text NOT NULL CHECK (name ~ '^[a-z][a-z0-9-]{0,30}$'),
  id                 text NOT NULL UNIQUE CHECK (afs.ulid_ok(id, 'pfi')),
  audience           text NOT NULL CHECK (length(audience) BETWEEN 1 AND 300),
  file_path          text NOT NULL CHECK (file_path ~ '^/var/run/secrets/afs/federation/[a-z0-9-]+/[A-Za-z0-9._-]+$'),
  env_var            text NOT NULL CHECK (env_var ~ '^[A-Z_][A-Z0-9_]{0,63}$'),
  expiration_seconds integer NOT NULL DEFAULT 3600 CHECK (expiration_seconds BETWEEN 600 AND 86400),
  version            bigint NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         text NOT NULL DEFAULT afs.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, pool_id, name),
  UNIQUE (team_id, pool_id, env_var),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);
-- Defaults derive from the name: /var/run/secrets/afs/federation/<name>/token and AFS_FEDERATED_TOKEN_FILE_<NAME>.
CREATE FUNCTION afs.federated_identity_defaults() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  NEW.file_path := coalesce(NEW.file_path, '/var/run/secrets/afs/federation/' || NEW.name || '/token');
  NEW.env_var := coalesce(NEW.env_var, 'AFS_FEDERATED_TOKEN_FILE_' || upper(replace(NEW.name, '-', '_')));
  RETURN NEW;
END $$;
CREATE TRIGGER agent_federated_identities_defaults BEFORE INSERT OR UPDATE ON afs.agent_federated_identities
  FOR EACH ROW EXECUTE FUNCTION afs.federated_identity_defaults();
CREATE TRIGGER pool_federated_identities_defaults BEFORE INSERT OR UPDATE ON afs.pool_federated_identities
  FOR EACH ROW EXECUTE FUNCTION afs.federated_identity_defaults();
CREATE TRIGGER agent_federated_identities_guard BEFORE INSERT OR UPDATE OF audience ON afs.agent_federated_identities
  FOR EACH ROW EXECUTE FUNCTION afs.federated_identity_guard();
CREATE TRIGGER pool_federated_identities_guard BEFORE INSERT OR UPDATE OF audience ON afs.pool_federated_identities
  FOR EACH ROW EXECUTE FUNCTION afs.federated_identity_guard();
CREATE TRIGGER agent_federated_identities_touch BEFORE UPDATE ON afs.agent_federated_identities
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER pool_federated_identities_touch BEFORE UPDATE ON afs.pool_federated_identities
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();

-- 9. External systems: mcp category, and hosts an MCP server governs ---------------------------------------------
ALTER TABLE afs.external_systems DROP CONSTRAINT external_systems_category_check;
ALTER TABLE afs.external_systems ADD CONSTRAINT external_systems_category_check
  CHECK (category IN ('dev_tools', 'collaboration', 'email', 'cloud', 'identity', 'llm', 'mcp', 'other')) NOT VALID;
ALTER TABLE afs.external_systems VALIDATE CONSTRAINT external_systems_category_check;

CREATE FUNCTION afs.mcp_host_of(p_url text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN lower(substring(p_url FROM '^(?:[a-z]+://)?([^/:?#]+)'));

-- The approved, live MCP server that covers a host, if any.
CREATE FUNCTION afs.mcp_governed_host(p_host text) RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN (SELECT s.id FROM afs.mcp_servers s
           WHERE s.url IS NOT NULL AND s.review_status IN ('approved', 'suspended')
             AND afs.mcp_host_of(s.url) = afs.mcp_host_of(p_host)
           ORDER BY s.team_id NULLS FIRST, s.id LIMIT 1);
REVOKE ALL ON FUNCTION afs.mcp_governed_host(text) FROM PUBLIC;

CREATE FUNCTION afs.external_systems_mcp_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  e text;
  v text;
BEGIN
  FOREACH e IN ARRAY NEW.endpoints LOOP
    v := afs.mcp_governed_host(e);
    IF v IS NOT NULL THEN
      RAISE EXCEPTION 'host % is governed by MCP server %; switch that server on instead', afs.mcp_host_of(e), v
        USING ERRCODE = 'check_violation', CONSTRAINT = 'governed_by_mcp_server';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER external_systems_mcp_guard BEFORE INSERT OR UPDATE OF category, endpoints ON afs.external_systems
  FOR EACH ROW WHEN (NEW.category = 'mcp') EXECUTE FUNCTION afs.external_systems_mcp_guard();

-- 10. Ledger and rollup ------------------------------------------------------------------------------------------
-- One row per MCP request the gateway handled. Metadata only: never arguments, results or credentials. Query text
-- of afs_search is kept only while a capture window is open (CD-50).
CREATE TABLE afs.mcp_events (
  id                  bigint GENERATED ALWAYS AS IDENTITY,
  at                  timestamptz NOT NULL,
  request_id          text NOT NULL CHECK (length(request_id) BETWEEN 1 AND 128),
  team_id             text NOT NULL,
  agent_id            text,
  pool_id             text,
  worker_pod          text CHECK (length(worker_pod) <= 253),
  server_id           text,
  server_kind         text CHECK (server_kind IN ('enterprise', 'team', 'afs')),
  method              text NOT NULL CHECK (length(method) BETWEEN 1 AND 64),
  name                text CHECK (length(name) <= 500),
  primitive_id        text,
  digest              text CHECK (digest ~ '^sha256:[0-9a-f]{64}$'),
  outcome             text NOT NULL CHECK (outcome IN ('ok', 'tool_error', 'protocol_error', 'refused', 'upstream_unavailable',
                                                       'timeout', 'cancelled')),
  reason              text CHECK (length(reason) <= 64),
  jsonrpc_code        integer,
  http_status         smallint,
  gateway_ms          integer CHECK (gateway_ms >= 0),
  upstream_ms         integer CHECK (upstream_ms >= 0),
  request_bytes       integer CHECK (request_bytes >= 0),
  response_bytes      integer CHECK (response_bytes >= 0),
  auth_kind           text,
  protocol_downstream text CHECK (length(protocol_downstream) <= 20),
  protocol_upstream   text CHECK (length(protocol_upstream) <= 20),
  args_sha256         text CHECK (args_sha256 ~ '^[0-9a-f]{64}$'),
  search_results      text[] CHECK (cardinality(search_results) <= 50),
  search_hit          boolean,
  query_text          text CHECK (length(query_text) <= 1000),
  capture_id          text,
  PRIMARY KEY (at, id)
) PARTITION BY RANGE (at);
CREATE TABLE afs.mcp_events_default PARTITION OF afs.mcp_events DEFAULT;
CREATE INDEX mcp_events_team_time_idx ON afs.mcp_events (team_id, at);
CREATE INDEX mcp_events_server_time_idx ON afs.mcp_events (server_id, at);

CREATE TRIGGER mcp_events_no_update BEFORE UPDATE OR DELETE ON afs.mcp_events
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_append_only();
CREATE TRIGGER mcp_events_no_truncate BEFORE TRUNCATE ON afs.mcp_events
  FOR EACH STATEMENT EXECUTE FUNCTION afs.mcp_append_only();

CREATE FUNCTION afs.mcp_events_capture() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_capture text := afs.mcp_capture_open();
BEGIN
  IF v_capture IS NULL THEN
    NEW.query_text := NULL;
    NEW.capture_id := NULL;
  ELSIF NEW.query_text IS NOT NULL THEN
    NEW.capture_id := v_capture;
  ELSE
    NEW.capture_id := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mcp_events_capture BEFORE INSERT ON afs.mcp_events
  FOR EACH ROW EXECUTE FUNCTION afs.mcp_events_capture();

-- Daily partitions from yesterday to p_days ahead; returns the names it created.
CREATE FUNCTION afs.ensure_mcp_event_partitions(p_days integer) RETURNS SETOF text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  d    date;
  name text;
BEGIN
  IF p_days NOT BETWEEN 0 AND 60 THEN
    RAISE EXCEPTION 'create between 0 and 60 days ahead' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  FOR d IN SELECT generate_series(current_date - 1, current_date + p_days, interval '1 day')::date LOOP
    name := format('mcp_events_%s', to_char(d, 'YYYYMMDD'));
    IF to_regclass('afs.' || name) IS NULL THEN
      EXECUTE format('CREATE TABLE afs.%I PARTITION OF afs.mcp_events FOR VALUES FROM (%L) TO (%L)', name, d, d + 1);
      RETURN NEXT name;
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION afs.ensure_mcp_event_partitions(integer) FROM PUBLIC;
SELECT afs.ensure_mcp_event_partitions(7);

-- Drops whole daily partitions older than mcp.events_retention_months; returns their names.
CREATE FUNCTION afs.drop_old_mcp_event_partitions() RETURNS SETOF text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  r record;
  v_months integer := coalesce((afs.mcp_setting('mcp.events_retention_months') #>> '{}')::integer, 13);
  v_cutoff date := (date_trunc('month', now()) - make_interval(months => v_months))::date;
BEGIN
  FOR r IN
    SELECT c.relname FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace n ON n.oid = p.relnamespace
     WHERE n.nspname = 'afs' AND p.relname = 'mcp_events' AND c.relname ~ '^mcp_events_[0-9]{8}$'
       AND to_date(right(c.relname, 8), 'YYYYMMDD') < v_cutoff
     ORDER BY 1
  LOOP
    EXECUTE format('DROP TABLE afs.%I', r.relname);
    RETURN NEXT r.relname;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION afs.drop_old_mcp_event_partitions() FROM PUBLIC;

CREATE TABLE afs.mcp_usage_daily (
  day            date NOT NULL,
  team_id        text NOT NULL,
  agent_or_pool  text NOT NULL,
  server_id      text NOT NULL,
  method         text NOT NULL,
  name           text NOT NULL,
  outcome        text NOT NULL,
  calls          bigint NOT NULL DEFAULT 0,
  errors         bigint NOT NULL DEFAULT 0,
  p50_ms         integer,
  p95_ms         integer,
  bytes_in       bigint NOT NULL DEFAULT 0,
  bytes_out      bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (day, team_id, agent_or_pool, server_id, method, name, outcome)
);
CREATE INDEX mcp_usage_daily_team_idx ON afs.mcp_usage_daily (team_id, day);

-- Idempotent: replaces the day's rows. '' stands for no agent or pool, server or name.
CREATE FUNCTION afs.rollup_mcp_usage(p_day date) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  n integer;
BEGIN
  DELETE FROM afs.mcp_usage_daily WHERE day = p_day;
  INSERT INTO afs.mcp_usage_daily (day, team_id, agent_or_pool, server_id, method, name, outcome, calls, errors,
                                   p50_ms, p95_ms, bytes_in, bytes_out)
  SELECT p_day, e.team_id, coalesce(e.agent_id, e.pool_id, ''), coalesce(e.server_id, ''), e.method, coalesce(e.name, ''),
         e.outcome, count(*), count(*) FILTER (WHERE e.outcome <> 'ok'),
         percentile_disc(0.5) WITHIN GROUP (ORDER BY e.gateway_ms + coalesce(e.upstream_ms, 0)),
         percentile_disc(0.95) WITHIN GROUP (ORDER BY e.gateway_ms + coalesce(e.upstream_ms, 0)),
         coalesce(sum(e.request_bytes), 0), coalesce(sum(e.response_bytes), 0)
    FROM afs.mcp_events e
   WHERE e.at >= p_day AND e.at < p_day + 1
   GROUP BY 2, 3, 4, 5, 6, 7;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION afs.rollup_mcp_usage(date) FROM PUBLIC;

-- 11. Admission: the one decision (CD-51) -------------------------------------------------------------------------
-- MCP annotation hints: readOnlyHint defaults false; destructiveHint and openWorldHint default true.
CREATE FUNCTION afs.mcp_read_only(p_ann jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN coalesce(p_ann -> 'readOnlyHint' = 'true'::jsonb, false);

-- Specificity of one rule for one primitive: exact name 3, glob 2, annotation class 1 (trusted tools only), else 0.
CREATE FUNCTION afs.mcp_rule_specificity(p_rule_name text, p_rule_class text, p_kind text, p_name text, p_ann jsonb,
                                         p_trusted boolean) RETURNS integer
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN CASE
    WHEN p_rule_class IS NOT NULL THEN
      CASE WHEN p_trusted AND p_kind = 'tool' AND (
             (p_rule_class = 'read_only' AND afs.mcp_read_only(p_ann))
          OR (p_rule_class = 'destructive' AND NOT afs.mcp_read_only(p_ann) AND coalesce(p_ann -> 'destructiveHint' <> 'false'::jsonb, true))
          OR (p_rule_class = 'open_world' AND coalesce(p_ann -> 'openWorldHint' <> 'false'::jsonb, true))) THEN 1 ELSE 0 END
    WHEN strpos(p_rule_name, '*') = 0 THEN CASE WHEN p_rule_name = p_name THEN 3 ELSE 0 END
    WHEN p_name LIKE replace(replace(replace(replace(p_rule_name, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%') THEN 2
    ELSE 0
  END;

-- One row per live primitive of every server the subject's team can reach, with the first refusal reason of the
-- gateway contract §13.4 and the level that decided it. A block at any level wins; within a level the most
-- specific rule wins and, at equal specificity, a block. Read-only team mode blocks every tool not marked read-only.
CREATE FUNCTION afs.mcp_admission(p_subject_kind text, p_subject_id text)
  RETURNS TABLE (server_id text, slug text, server_kind text, mode text, primitive_id text, kind text, name text,
                 digest text, allowed boolean, level text, reason text, rate_limit_per_minute integer)
  LANGUAGE sql STABLE
  SET search_path = pg_catalog, afs
AS $$
  WITH subj AS (
    SELECT a.team_id, a.id AS subject_id, a.mcp_access FROM afs.agents a
     WHERE p_subject_kind = 'agent' AND a.id = p_subject_id AND a.deleted_at IS NULL
    UNION ALL
    SELECT p.team_id, p.id, p.mcp_access FROM afs.agent_pools p
     WHERE p_subject_kind = 'pool' AND p.id = p_subject_id AND p.deleted_at IS NULL
  ), srv AS (
    SELECT s.id, s.slug, s.team_id, s.review_status, s.trust_annotations, sj.team_id AS subj_team, sj.subject_id,
           CASE WHEN s.team_id IS NULL THEN 'enterprise' ELSE 'team' END AS server_kind,
           coalesce(tm.mode, 'full') AS mode,
           (s.team_id IS NOT NULL OR s.published) AND s.review_status IN ('approved', 'suspended') AS pub_ok,
           coalesce(tm.enabled, false) AS team_on,
           (sj.mcp_access = 'all'
            OR (p_subject_kind = 'agent' AND EXISTS (SELECT 1 FROM afs.agent_mcp_servers x
                                                      WHERE x.team_id = sj.team_id AND x.agent_id = sj.subject_id AND x.server_id = s.id))
            OR (p_subject_kind = 'pool' AND EXISTS (SELECT 1 FROM afs.pool_mcp_servers x
                                                     WHERE x.team_id = sj.team_id AND x.pool_id = sj.subject_id AND x.server_id = s.id))) AS agent_on
      FROM subj sj
      JOIN afs.mcp_servers s ON s.team_id = sj.team_id OR (s.team_id IS NULL AND (s.published OR EXISTS (
             SELECT 1 FROM afs.team_mcp_servers x WHERE x.team_id = sj.team_id AND x.server_id = s.id)))
      LEFT JOIN afs.team_mcp_servers tm ON tm.team_id = sj.team_id AND tm.server_id = s.id
  ), dec AS (
    SELECT srv.*, p.id AS primitive_id, p.kind, p.name, p.digest, p.status,
           coalesce(pol.b_service, false) AS b_service,
           coalesce(pol.b_team, false) OR (srv.mode = 'read_only' AND p.kind = 'tool' AND NOT afs.mcp_read_only(p.annotations)) AS b_team,
           coalesce(pol.b_agent, false) AS b_agent,
           pol.rate
      FROM srv
      JOIN afs.mcp_primitives p ON p.server_id = srv.id AND p.removed_at IS NULL
      LEFT JOIN LATERAL (
        SELECT bool_or(y.blocked) FILTER (WHERE y.g = 'service') AS b_service,
               bool_or(y.blocked) FILTER (WHERE y.g = 'team') AS b_team,
               bool_or(y.blocked) FILTER (WHERE y.g = 'agent') AS b_agent,
               min(y.rate) AS rate
          FROM (SELECT x.g, (array_agg(x.effect ORDER BY x.spec DESC, x.effect = 'block' DESC))[1] = 'block' AS blocked,
                       min(x.rate) AS rate
                  FROM (SELECT CASE WHEN r.level = 'pool' THEN 'agent' ELSE r.level END AS g, r.effect,
                               r.rate_limit_per_minute AS rate,
                               afs.mcp_rule_specificity(r.name, r.class, p.kind, p.name, p.annotations, srv.trust_annotations) AS spec
                          FROM afs.mcp_policies r
                         WHERE r.server_id = srv.id
                           AND (r.level = 'service'
                                OR (r.level = 'team' AND r.team_id = srv.subj_team)
                                OR (r.level = 'agent' AND p_subject_kind = 'agent' AND r.agent_id = srv.subject_id)
                                OR (r.level = 'pool' AND p_subject_kind = 'pool' AND r.pool_id = srv.subject_id))) x
                 WHERE x.spec > 0
                 GROUP BY x.g) y) pol ON true
  ), why AS (
    SELECT dec.*,
           CASE WHEN NOT dec.pub_ok THEN 'server_not_published'
                WHEN dec.review_status = 'suspended' THEN 'server_suspended'
                WHEN NOT dec.team_on THEN 'server_not_enabled_for_team'
                WHEN NOT dec.agent_on THEN 'server_not_enabled_for_agent'
                WHEN dec.b_service THEN 'primitive_blocked_service'
                WHEN dec.b_team THEN 'primitive_blocked_team'
                WHEN dec.b_agent THEN 'primitive_blocked_agent'
                WHEN dec.status = 'blocked' THEN 'primitive_blocked_service'
                WHEN dec.status <> 'approved' THEN 'primitive_pending_review'
           END AS reason
      FROM dec
  )
  SELECT why.id, why.slug, why.server_kind, why.mode, why.primitive_id, why.kind, why.name, why.digest,
         why.reason IS NULL,
         CASE WHEN why.reason IS NULL THEN NULL
              WHEN why.reason IN ('server_not_published', 'primitive_pending_review')
                THEN CASE WHEN why.server_kind = 'team' THEN 'team' ELSE 'service' END
              WHEN why.reason IN ('server_suspended', 'primitive_blocked_service') THEN 'service'
              WHEN why.reason IN ('server_not_enabled_for_team', 'primitive_blocked_team') THEN 'team'
              ELSE CASE WHEN p_subject_kind = 'pool' THEN 'pool' ELSE 'agent' END
         END,
         why.reason, CASE WHEN why.reason IS NULL THEN why.rate END
    FROM why
   ORDER BY why.slug, why.kind, why.name
$$;
REVOKE ALL ON FUNCTION afs.mcp_admission(text, text) FROM PUBLIC;

CREATE VIEW afs.effective_agent_mcp WITH (security_invoker = true) AS
SELECT 'agent'::text AS subject_kind, a.team_id, a.id AS subject_id, m.*
  FROM afs.agents a CROSS JOIN LATERAL afs.mcp_admission('agent', a.id) m
 WHERE a.deleted_at IS NULL AND m.allowed
UNION ALL
SELECT 'pool'::text, p.team_id, p.id, m.*
  FROM afs.agent_pools p CROSS JOIN LATERAL afs.mcp_admission('pool', p.id) m
 WHERE p.deleted_at IS NULL AND m.allowed;
COMMENT ON VIEW afs.effective_agent_mcp IS
  'The MCP primitives each live agent and pool may list and call (afs.mcp_admission, allowed rows). Runs with the caller''s rights.';

-- 12. Default servers for new teams ------------------------------------------------------------------------------
-- A team with its own gateway gets every published enterprise server marked default_for_new_teams switched on, when
-- it is created with one or first moves to one. Switches the team already has, on or off, are kept.
CREATE FUNCTION afs.teams_mcp_defaults() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  s record;
BEGIN
  IF NEW.gateway_deployment <> 'per_namespace' OR NEW.deleted_at IS NOT NULL THEN
    RETURN NULL;
  END IF;
  FOR s IN
    INSERT INTO afs.team_mcp_servers (team_id, server_id, enabled, mode)
    SELECT NEW.id, m.id, true, 'full' FROM afs.mcp_servers m
     WHERE m.team_id IS NULL AND m.published AND m.default_for_new_teams AND m.review_status = 'approved'
    ON CONFLICT (team_id, server_id) DO NOTHING
    RETURNING server_id
  LOOP
    INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload)
    VALUES ('team_mcp_server.enabled', 'team_mcp_servers', NEW.id || '/' || s.server_id, NEW.id,
            afs.event_detail(NEW.id, NULL, jsonb_build_object('teamId', NEW.id, 'mcpServerId', s.server_id,
                                                              'mode', 'full', 'reason', 'default_for_new_teams')));
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.teams_mcp_defaults() FROM PUBLIC;
CREATE TRIGGER teams_mcp_defaults AFTER INSERT ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.teams_mcp_defaults();
CREATE TRIGGER teams_mcp_defaults_on_gateway AFTER UPDATE OF gateway_deployment ON afs.teams
  FOR EACH ROW WHEN (OLD.gateway_deployment IS DISTINCT FROM NEW.gateway_deployment) EXECUTE FUNCTION afs.teams_mcp_defaults();

-- 13. Review queue and ledger for security operators -------------------------------------------------------------
-- Who approves a server of a given tier under mcp.team_server_approval; enterprise servers go to security.
CREATE FUNCTION afs.mcp_approver(p_team_id text, p_tier text) RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN CASE
    WHEN p_team_id IS NULL THEN 'security'
    WHEN coalesce(afs.mcp_setting('mcp.team_server_approval') #>> '{}', 'team_all') = 'team_all' THEN 'team_admin'
    WHEN afs.mcp_setting('mcp.team_server_approval') #>> '{}' = 'team_low_security_higher' AND p_tier = 'low' THEN 'team_admin'
    ELSE 'security'
  END;
REVOKE ALL ON FUNCTION afs.mcp_approver(text, text) FROM PUBLIC;

CREATE FUNCTION afs.mcp_review_queue()
  RETURNS TABLE (item_kind text, server_id text, team_id text, primitive_id text, slug text, name text, risk_tier text,
                 approver text, since timestamptz)
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NOT (afs.caller_is_service_admin() OR afs.caller_is_security_operator()) THEN
    RAISE EXCEPTION 'the MCP review queue is for service admins and security operators' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
    SELECT 'server'::text, s.id, s.team_id, NULL::text, s.slug, s.display_name, s.risk_tier,
           afs.mcp_approver(s.team_id, s.risk_tier), s.updated_at
      FROM afs.mcp_servers s WHERE s.review_status = 'pending_review'
    UNION ALL
    SELECT 'primitive', s.id, s.team_id, p.id, s.slug, p.name, s.risk_tier,
           afs.mcp_approver(s.team_id, s.risk_tier), p.last_seen
      FROM afs.mcp_primitives p JOIN afs.mcp_servers s ON s.id = p.server_id
     WHERE p.status = 'pending_review' AND p.removed_at IS NULL AND s.review_status <> 'pending_review'
    ORDER BY 9;
END $$;
REVOKE ALL ON FUNCTION afs.mcp_review_queue() FROM PUBLIC;

CREATE FUNCTION afs.mcp_events_for_review(p_from timestamptz, p_to timestamptz, p_team_id text, p_server_id text,
                                          p_limit integer)
  RETURNS SETOF afs.mcp_events
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NOT (afs.caller_is_service_admin() OR afs.caller_is_security_operator()) THEN
    RAISE EXCEPTION 'the MCP ledger across teams is for service admins and security operators' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
    SELECT * FROM afs.mcp_events e
     WHERE e.at >= p_from AND e.at < p_to
       AND (p_team_id IS NULL OR e.team_id = p_team_id) AND (p_server_id IS NULL OR e.server_id = p_server_id)
     ORDER BY e.at DESC, e.id DESC
     LIMIT least(greatest(coalesce(p_limit, 100), 1), 1000);
END $$;
REVOKE ALL ON FUNCTION afs.mcp_events_for_review(timestamptz, timestamptz, text, text, integer) FROM PUBLIC;

-- 14. Row-level security, grants, revisions and change feed ------------------------------------------------------
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_hosted_specs', 'mcp_primitives', 'team_mcp_servers', 'agent_mcp_servers',
                           'pool_mcp_servers', 'mcp_policies', 'mcp_credentials', 'mcp_reviews', 'mcp_oauth_states',
                           'mcp_federation_states', 'agent_federated_identities', 'pool_federated_identities',
                           'mcp_events', 'mcp_usage_daily'] LOOP
    EXECUTE format('ALTER TABLE afs.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  -- Team rows by team; enterprise rows (team_id NULL) only with afs.service_admin (afs.caller_sees_team(NULL)).
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_hosted_specs', 'mcp_primitives', 'team_mcp_servers', 'agent_mcp_servers',
                           'pool_mcp_servers', 'mcp_policies', 'mcp_credentials', 'mcp_reviews', 'mcp_federation_states',
                           'agent_federated_identities', 'pool_federated_identities'] LOOP
    EXECUTE format('CREATE POLICY app_team_scope ON afs.%I TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id))', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['mcp_events', 'mcp_usage_daily'] LOOP
    EXECUTE format('CREATE POLICY app_team_scope ON afs.%I FOR SELECT TO afs_app USING (afs.caller_sees_team(team_id))', t);
  END LOOP;
  -- The enterprise catalog, its inventory and its service-level rules are readable by every caller.
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_hosted_specs', 'mcp_primitives', 'mcp_policies'] LOOP
    EXECUTE format('CREATE POLICY app_enterprise_read ON afs.%I FOR SELECT TO afs_app USING (team_id IS NULL)', t);
  END LOOP;
  -- Security operators review every team's servers and primitives (PRD §8).
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_hosted_specs', 'mcp_primitives', 'mcp_reviews'] LOOP
    EXECUTE format('CREATE POLICY app_security_read ON afs.%I FOR SELECT TO afs_app USING (afs.caller_is_security_operator())', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_primitives'] LOOP
    EXECUTE format('CREATE POLICY app_security_review ON afs.%I FOR UPDATE TO afs_app USING (afs.caller_is_security_operator()) WITH CHECK (afs.caller_is_security_operator())', t);
  END LOOP;
  EXECUTE 'CREATE POLICY app_security_review ON afs.mcp_reviews FOR INSERT TO afs_app WITH CHECK (afs.caller_is_security_operator())';
  -- Service roles see every row; their table and column grants below limit what they may change.
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_hosted_specs', 'mcp_primitives', 'team_mcp_servers', 'agent_mcp_servers',
                           'pool_mcp_servers', 'mcp_policies', 'mcp_credentials', 'mcp_reviews', 'mcp_federation_states',
                           'agent_federated_identities', 'pool_federated_identities', 'mcp_usage_daily'] LOOP
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_billing, afs_readonly, afs_reconciler USING (true) WITH CHECK (true)', t);
    -- A per-namespace gateway (afs.team_ids set) sees its teams and the enterprise rows only (000023).
    EXECUTE format('CREATE POLICY gateway_team_scope ON afs.%I TO afs_gateway USING (afs.gateway_sees_team(team_id)) WITH CHECK (afs.gateway_sees_team(team_id))', t);
  END LOOP;
END $$;

-- OAuth state: afs_app writes it and claims it through afs.claim_mcp_oauth_state only.
CREATE POLICY app_insert ON afs.mcp_oauth_states FOR INSERT TO afs_app WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_read ON afs.mcp_oauth_states FOR SELECT TO afs_reconciler USING (true);
-- The ledger: the gateway inserts for its own team only; the readers see everything.
CREATE POLICY gateway_own_team ON afs.mcp_events FOR INSERT TO afs_gateway
  WITH CHECK (team_id = ANY (string_to_array(coalesce(current_setting('afs.team_ids', true), ''), ',')));
CREATE POLICY service_roles_read ON afs.mcp_events FOR SELECT TO afs_billing, afs_readonly, afs_reconciler USING (true);
CREATE POLICY gateway_team_scope ON afs.mcp_events FOR SELECT TO afs_gateway USING (afs.gateway_sees_team(team_id));

-- afs_app
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.mcp_servers, afs.mcp_hosted_specs, afs.mcp_primitives, afs.team_mcp_servers,
  afs.agent_mcp_servers, afs.pool_mcp_servers, afs.mcp_policies, afs.mcp_credentials, afs.agent_federated_identities,
  afs.pool_federated_identities TO afs_app;
GRANT SELECT, INSERT ON afs.mcp_reviews TO afs_app;
GRANT INSERT ON afs.mcp_oauth_states TO afs_app;
GRANT SELECT, INSERT, DELETE ON afs.mcp_federation_states TO afs_app;
GRANT UPDATE (test_requested_at) ON afs.mcp_federation_states TO afs_app;
GRANT SELECT, INSERT ON afs.mcp_query_captures TO afs_app;
GRANT UPDATE (stopped_at, stopped_by) ON afs.mcp_query_captures TO afs_app;
GRANT SELECT ON afs.mcp_events, afs.mcp_usage_daily, afs.effective_agent_mcp TO afs_app;
-- afs_gateway: holds changes, records refreshes, credential and federation state and the ledger; never approves.
GRANT SELECT ON afs.mcp_servers, afs.mcp_hosted_specs, afs.mcp_primitives, afs.team_mcp_servers, afs.agent_mcp_servers,
  afs.pool_mcp_servers, afs.mcp_policies, afs.mcp_credentials, afs.mcp_reviews, afs.mcp_federation_states,
  afs.agent_federated_identities, afs.pool_federated_identities, afs.mcp_events, afs.mcp_usage_daily,
  afs.effective_agent_mcp TO afs_gateway;
GRANT INSERT ON afs.mcp_events TO afs_gateway;
GRANT INSERT (id, server_id, kind, name, title, summary, annotations, definition, digest, change, status, first_seen, last_seen),
  UPDATE (digest, pending_definition, change, status, last_seen, removed_at, title, summary, annotations) ON afs.mcp_primitives TO afs_gateway;
GRANT UPDATE (status, expires_at) ON afs.mcp_credentials TO afs_gateway;
GRANT UPDATE (status, last_error, checked_at) ON afs.mcp_federation_states TO afs_gateway;
GRANT UPDATE (refresh_requested_at, protocol_version) ON afs.mcp_servers TO afs_gateway;
-- afs_reconciler
GRANT SELECT ON afs.mcp_servers, afs.mcp_hosted_specs, afs.mcp_primitives, afs.team_mcp_servers, afs.agent_mcp_servers,
  afs.pool_mcp_servers, afs.mcp_policies, afs.mcp_credentials, afs.mcp_reviews, afs.mcp_oauth_states,
  afs.mcp_federation_states, afs.mcp_query_captures, afs.agent_federated_identities, afs.pool_federated_identities,
  afs.mcp_events, afs.mcp_usage_daily, afs.effective_agent_mcp TO afs_reconciler;
GRANT UPDATE (signature_verified_at) ON afs.mcp_hosted_specs TO afs_reconciler;
GRANT UPDATE (stopped_at, stopped_by) ON afs.mcp_query_captures TO afs_reconciler;
-- afs_billing and afs_readonly
GRANT SELECT ON afs.mcp_usage_daily TO afs_billing;
GRANT SELECT ON afs.mcp_servers, afs.mcp_hosted_specs, afs.mcp_primitives, afs.team_mcp_servers, afs.agent_mcp_servers,
  afs.pool_mcp_servers, afs.mcp_policies, afs.mcp_credentials, afs.mcp_reviews, afs.mcp_federation_states,
  afs.mcp_query_captures, afs.agent_federated_identities, afs.pool_federated_identities, afs.mcp_events,
  afs.mcp_usage_daily, afs.effective_agent_mcp TO afs_readonly;

GRANT EXECUTE ON FUNCTION afs.mcp_admission(text, text) TO afs_app, afs_gateway, afs_reconciler, afs_readonly;
GRANT EXECUTE ON FUNCTION afs.mcp_setting(text) TO afs_app, afs_gateway, afs_reconciler, afs_readonly;
GRANT EXECUTE ON FUNCTION afs.mcp_enabled_for_team(text, text) TO afs_app;
GRANT EXECUTE ON FUNCTION afs.mcp_credential_path(text, text) TO afs_app;
GRANT EXECUTE ON FUNCTION afs.claim_mcp_oauth_state(bytea) TO afs_app;
GRANT EXECUTE ON FUNCTION afs.mcp_capture_open() TO afs_app, afs_gateway, afs_reconciler;
GRANT EXECUTE ON FUNCTION afs.mcp_governed_host(text) TO afs_app, afs_reconciler, afs_readonly;
GRANT EXECUTE ON FUNCTION afs.mcp_approver(text, text) TO afs_app;
GRANT EXECUTE ON FUNCTION afs.mcp_review_queue() TO afs_app;
GRANT EXECUTE ON FUNCTION afs.mcp_events_for_review(timestamptz, timestamptz, text, text, integer) TO afs_app;
GRANT EXECUTE ON FUNCTION afs.ensure_mcp_event_partitions(integer), afs.drop_old_mcp_event_partitions(),
  afs.rollup_mcp_usage(date) TO afs_reconciler;

-- Revisions and the change feed for the desired-state tables (payload <table>:<team_id>:<id>).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['mcp_servers', 'mcp_hosted_specs', 'team_mcp_servers', 'agent_mcp_servers', 'pool_mcp_servers',
                           'mcp_policies', 'mcp_credentials', 'agent_federated_identities', 'pool_federated_identities'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON afs.%I FOR EACH ROW EXECUTE FUNCTION afs.record_revision()',
                   t || '_revision', t);
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON afs.%I FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state()',
                   t || '_notify', t);
  END LOOP;
END $$;
-- Primitives: the gateway touches last_seen on every refresh; announce only what changes a decision. Reviews hold
-- their history, so they get no revision trigger.
CREATE TRIGGER mcp_primitives_notify AFTER INSERT OR DELETE ON afs.mcp_primitives
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();
CREATE TRIGGER mcp_primitives_notify_change AFTER UPDATE ON afs.mcp_primitives
  FOR EACH ROW WHEN ((OLD.status, OLD.digest, OLD.approved_digest, OLD.annotations, OLD.removed_at)
                     IS DISTINCT FROM (NEW.status, NEW.digest, NEW.approved_digest, NEW.annotations, NEW.removed_at))
  EXECUTE FUNCTION afs.notify_desired_state();
CREATE TRIGGER mcp_federation_states_notify AFTER INSERT OR UPDATE OF test_requested_at OR DELETE ON afs.mcp_federation_states
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();
