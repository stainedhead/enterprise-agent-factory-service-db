-- 000023: team model gateway, routes and provider switches (root PRD model-endpoint-gateway-PRD.md sections 7, 9.4,
-- 11 and Appendix D.2, MEG-DB-1 to MEG-DB-7; database contract section 7.4, v1.5.0, CD-42 and CD-43; spec
-- specs/261125-model-endpoint-gateway). Release 1.2.0, lockstep with -restapi.
--
--   1. inference_providers: one switch per provider, Bedrock included, seeded (Azure and Google off), the guard that
--      keeps afs_app writes to service admins and the Bedrock-off guard (no_fallback_model).
--   2. model_endpoints (service and team rows), the built-in catalog entries (all off, placeholder base URLs),
--      endpoint_models, endpoint_model_prices (append-only), endpoint_price_proposals, endpoint_capacity_costs.
--   3. endpoint_credentials at _gateway paths (afs.secret_path accepts the reserved scope _gateway),
--      endpoint_federations (metadata only), provider_statements.
--   4. team_model_endpoints (opt-in), agent_model_endpoints, pool_model_endpoints; teams.may_add_model_endpoints and
--      gateway_deployment; agents and pools gain route_access and default_route (CD-42: the foreign keys of
--      default_model_id and model_id to models become a check trigger that applies while default_route is NULL).
--   5. afs.provider_for_host, afs.provider_enabled, the view effective_agent_routes and afs.route_admission; the
--      Bedrock switch also applies to effective_agent_models and model_admission.
--   6. usage_events route and timing columns; cost_daily sources route and route_capacity.
--   7. Row-level security, grants per role, revision and change-feed triggers.
--
-- Pre-flight: none beyond 000022 (no new role). One transaction. Contract notes recorded in
-- specs/261125-model-endpoint-gateway/implementation-notes.md apply.
--
-- Lock impact (existing tables):
--   teams: two ADD COLUMN with constant defaults (no rewrite, brief ACCESS EXCLUSIVE); the guardrail trigger is
--     recreated (instant).
--   agents, agent_pools: two ADD COLUMN each (one constant default, one nullable; no rewrite, brief ACCESS EXCLUSIVE);
--     the default_route CHECKs are added NOT VALID then VALIDATEd (SHARE UPDATE EXCLUSIVE, every row passes: the
--     column is NULL); four foreign keys to models are dropped (instant) and replaced by row triggers; the model
--     constraint triggers are recreated (instant). No row is rewritten or updated.
--   models: one BEFORE DELETE OR UPDATE OF id trigger (instant).
--   usage_events (partitioned): eight nullable columns added on the parent (metadata only, no rewrite on
--     PostgreSQL 17), model_id DROP NOT NULL (metadata only); brief ACCESS EXCLUSIVE on the parent and its partitions.
--     The new CHECK is added NOT VALID on the parent, then VALIDATEd (SHARE UPDATE EXCLUSIVE, one scan per partition
--     with writes allowed); every existing row passes (endpoint_id is NULL, model_id is set).
--   cost_daily: the source CHECK is replaced: dropped, re-added NOT VALID, then VALIDATEd (SHARE UPDATE EXCLUSIVE).
--   service_settings: the models CHECK is replaced NOT VALID then VALIDATEd (tens of rows).
--   Functions and views: CREATE OR REPLACE, no table locks. New tables: no existing rows.

-- 0. Helpers ---------------------------------------------------------------------------------------------------------
-- A host glob: lower-case labels, '*' standing for one or more labels or label characters, a top-level domain.
CREATE FUNCTION afs.host_globs_ok(p text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p IS NOT NULL
     AND coalesce(cardinality(p), 0) <= 20
     AND array_position(p, NULL::text) IS NULL
     AND NOT EXISTS (SELECT 1 FROM unnest(p) AS h
                      WHERE length(h) > 253
                         OR h !~ '^(\*[.-])?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.([a-z0-9]([a-z0-9-]*[a-z0-9])?|\*))*\.[a-z]{2,63}$');

-- Does p_host match glob p_glob? '*' matches one or more host characters (labels and dots), never an empty string.
CREATE FUNCTION afs.host_matches(p_host text, p_glob text) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p_host ~ ('^' || replace(replace(p_glob, '.', '\.'), '*', '[a-z0-9]([a-z0-9.-]*[a-z0-9])?') || '$');

-- The host of an http(s) URL, lower-cased, without port.
CREATE FUNCTION afs.url_host(p_url text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN lower(substring(p_url FROM '^[A-Za-z][A-Za-z0-9+.-]*://([^/:?#]+)'));

-- A route model written as <slug>/<model>: the slug never holds '/', the model name may.
CREATE FUNCTION afs.route_model_slug(p text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN CASE WHEN p ~ '^[a-z][a-z0-9-]{1,30}/.' THEN split_part(p, '/', 1) END;

CREATE FUNCTION afs.route_model_name(p text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN CASE WHEN p ~ '^[a-z][a-z0-9-]{1,30}/.' THEN substring(p FROM position('/' IN p) + 1) END;

REVOKE ALL ON FUNCTION afs.host_globs_ok(text[]), afs.host_matches(text, text), afs.url_host(text),
  afs.route_model_slug(text), afs.route_model_name(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.host_globs_ok(text[]), afs.host_matches(text, text), afs.url_host(text),
  afs.route_model_slug(text), afs.route_model_name(text) TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;

-- Per-namespace gateways (teams.gateway_deployment = per_namespace) connect as afs_gateway with afs.team_ids set to
-- their team: they read service rows and their team's rows only. The shared gateway sets no team and reads all.
CREATE FUNCTION afs.gateway_sees_team(p_team_id text) RETURNS boolean
  LANGUAGE sql STABLE
  RETURN p_team_id IS NULL
      OR coalesce(current_setting('afs.team_ids', true), '') = ''
      OR p_team_id = ANY (string_to_array(current_setting('afs.team_ids', true), ','));
REVOKE ALL ON FUNCTION afs.gateway_sees_team(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.gateway_sees_team(text) TO afs_gateway, afs_app, afs_reconciler, afs_billing, afs_readonly;

-- 1. Providers (section 7.4.1) ---------------------------------------------------------------------------------------
CREATE TABLE afs.inference_providers (
  provider        text PRIMARY KEY CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$' AND provider <> 'internal'),
  display_name    text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 100),
  hosts           text[] NOT NULL DEFAULT '{}' CHECK (afs.host_globs_ok(hosts)),
  enabled         boolean NOT NULL,
  team_selection  text NOT NULL DEFAULT 'team_admin' CHECK (team_selection IN ('team_admin', 'service_admin')),
  disabled_reason text CHECK (length(disabled_reason) <= 500),
  fallback_model  text CHECK (fallback_model IS NULL OR (length(fallback_model) <= 240 AND afs.route_model_slug(fallback_model) IS NOT NULL)),
  version         bigint NOT NULL DEFAULT 1,
  changed_by      text NOT NULL DEFAULT afs.current_actor(),
  changed_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inference_providers_fallback_bedrock CHECK (fallback_model IS NULL OR provider = 'bedrock')
);
COMMENT ON TABLE afs.inference_providers IS
  'One switch per model provider, Bedrock included, set by service admins. Off: every route of the provider (service and team) is refused with provider_disabled. other matches any external host not listed; corporate and in-namespace endpoints (provider internal) have no switch.';
COMMENT ON COLUMN afs.inference_providers.team_selection IS
  'team_admin: team-admins opt their team in to the provider''s service endpoints; service_admin: only service admins select them for a team.';
COMMENT ON COLUMN afs.inference_providers.fallback_model IS
  'Bedrock only: the <route>/<model> chosen as the service default when Bedrock was turned off (recorded by the API).';

INSERT INTO afs.inference_providers (provider, display_name, hosts, enabled, team_selection, changed_by) VALUES
  ('bedrock', 'Amazon Bedrock', '{bedrock-runtime.*.amazonaws.com}', true, 'team_admin', 'system:migration'),
  ('openai', 'OpenAI', '{api.openai.com}', true, 'team_admin', 'system:migration'),
  ('openrouter', 'OpenRouter', '{openrouter.ai}', true, 'team_admin', 'system:migration'),
  ('nous', 'Nous Portal', '{inference-api.nousresearch.com}', true, 'team_admin', 'system:migration'),
  ('opencode', 'OpenCode Console', '{opencode.ai}', true, 'team_admin', 'system:migration'),
  ('azure', 'Azure (Azure OpenAI and Foundry models)', '{*.openai.azure.com,*.services.ai.azure.com,*.cognitiveservices.azure.com}', false, 'service_admin', 'system:migration'),
  ('google', 'Google (Vertex AI)', '{aiplatform.googleapis.com,*-aiplatform.googleapis.com}', false, 'service_admin', 'system:migration'),
  ('other', 'Other external hosts', '{}', true, 'team_admin', 'system:migration');

-- The first provider (by name) whose hosts match, else other. An empty or unparsable host is other.
CREATE FUNCTION afs.provider_for_host(p_host text) RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN coalesce((SELECT p.provider FROM afs.inference_providers p
                    WHERE p.provider <> 'other'
                      AND EXISTS (SELECT 1 FROM unnest(p.hosts) AS g WHERE afs.host_matches(lower(p_host), g))
                    ORDER BY p.provider LIMIT 1), 'other');

-- internal (corporate and in-namespace endpoints) is always on; an unknown provider is off.
CREATE FUNCTION afs.provider_enabled(p_provider text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN p_provider = 'internal'
      OR coalesce((SELECT p.enabled FROM afs.inference_providers p WHERE p.provider = p_provider), false);
REVOKE ALL ON FUNCTION afs.provider_for_host(text), afs.provider_enabled(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.provider_for_host(text), afs.provider_enabled(text)
  TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;

-- 2. Endpoints, models and prices (section 7.4.2) ---------------------------------------------------------------------
CREATE FUNCTION afs.endpoint_protocols_ok(p text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN coalesce(cardinality(p), 0) BETWEEN 1 AND 3
     AND p <@ ARRAY['openai_chat', 'openai_responses', 'openai_embeddings']
     AND (SELECT count(DISTINCT x) FROM unnest(p) AS x) = cardinality(p);
REVOKE ALL ON FUNCTION afs.endpoint_protocols_ok(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.endpoint_protocols_ok(text[]) TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;

CREATE TABLE afs.model_endpoints (
  id                 text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mep')),
  team_id            text REFERENCES afs.teams (id) ON DELETE CASCADE,
  slug               text NOT NULL,
  display_name       text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 100),
  description        text NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
  owner              text NOT NULL DEFAULT '' CHECK (length(owner) <= 200),
  purpose            text NOT NULL DEFAULT '' CHECK (length(purpose) <= 500),
  provider           text NOT NULL,
  protocols          text[] NOT NULL DEFAULT '{openai_chat}',
  location           text NOT NULL CHECK (location IN ('external', 'corporate', 'in_namespace')),
  base_url           text NOT NULL CHECK (length(base_url) <= 500),
  ca_bundle          text CHECK (length(ca_bundle) <= 16384 AND ca_bundle LIKE '-----BEGIN CERTIFICATE-----%'),
  auth_kind          text NOT NULL CHECK (auth_kind IN ('none', 'bearer', 'header', 'azure_federated', 'google_federated')),
  auth_header        text CHECK (auth_header ~ '^[A-Za-z0-9-]{1,64}$'),
  metrics_port       integer CHECK (metrics_port BETWEEN 1 AND 65535),
  credential_mode    text NOT NULL DEFAULT 'per_team' CHECK (credential_mode IN ('shared', 'per_team')),
  pricing_mode       text NOT NULL CHECK (pricing_mode IN ('per_token', 'capacity', 'free')),
  requires_terms     boolean NOT NULL DEFAULT false,
  use_provider_cost  boolean NOT NULL DEFAULT false,
  enabled            boolean NOT NULL DEFAULT false,
  timeout_seconds    integer NOT NULL DEFAULT 300 CHECK (timeout_seconds BETWEEN 5 AND 3600),
  max_body_mib       integer NOT NULL DEFAULT 20 CHECK (max_body_mib BETWEEN 1 AND 100),
  external_system_id text REFERENCES afs.external_systems (id) ON DELETE SET NULL,
  builtin            boolean NOT NULL DEFAULT false,
  version            bigint NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         text NOT NULL DEFAULT afs.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, id),
  CONSTRAINT model_endpoints_slug_check CHECK (slug ~ '^[a-z][a-z0-9-]{1,30}$' AND slug <> 'bedrock'),
  CONSTRAINT model_endpoints_owner_purpose_check CHECK (team_id IS NULL OR (btrim(owner) <> '' AND btrim(purpose) <> '')),
  CONSTRAINT model_endpoints_protocols_check CHECK (afs.endpoint_protocols_ok(protocols)),
  CONSTRAINT model_endpoints_in_namespace_check CHECK (location <> 'in_namespace' OR team_id IS NOT NULL),
  CONSTRAINT model_endpoints_base_url_scheme CHECK (
    CASE WHEN location = 'in_namespace' THEN base_url ~ '^https?://[^/?#]+' ELSE base_url ~ '^https://[^/?#]+' END),
  CONSTRAINT model_endpoints_auth_header_kind CHECK ((auth_kind = 'header') = (auth_header IS NOT NULL)),
  CONSTRAINT model_endpoints_metrics_port_location CHECK (metrics_port IS NULL OR location = 'in_namespace'),
  CONSTRAINT model_endpoints_team_credential_check CHECK (team_id IS NULL OR credential_mode = 'per_team'),
  CONSTRAINT model_endpoints_team_terms_check CHECK (team_id IS NULL OR (NOT requires_terms AND NOT builtin))
);
CREATE UNIQUE INDEX model_endpoints_service_slug_uq ON afs.model_endpoints (slug) WHERE team_id IS NULL;
CREATE UNIQUE INDEX model_endpoints_team_slug_uq ON afs.model_endpoints (team_id, slug) WHERE team_id IS NOT NULL;
CREATE INDEX model_endpoints_provider_idx ON afs.model_endpoints (provider);
COMMENT ON TABLE afs.model_endpoints IS
  'OpenAI-compatible model endpoints behind the team gateway. team_id NULL: a service endpoint (service admins), shipped off, reaching a team only through team_model_endpoints. team_id set: declared by that team (teams.may_add_model_endpoints). The slug is the route name. No credential value.';
COMMENT ON COLUMN afs.model_endpoints.provider IS
  'Set by trigger: from the base URL host (afs.provider_for_host) when it matches a listed provider; internal for in-namespace endpoints and unlisted corporate hosts; other for unlisted external team hosts; a service admin may name the provider of an unlisted host.';
COMMENT ON COLUMN afs.model_endpoints.base_url IS
  'https for external and corporate endpoints; an in-namespace Service may use http. A built-in entry carries placeholders (<resource>, <project>, <location>) that must be replaced before it is switched on.';

-- Built-in catalog entries (CD-43): service level, off, no models; the placeholders block enabling until replaced.
INSERT INTO afs.model_endpoints (id, team_id, slug, display_name, description, provider, protocols, location, base_url,
                                 auth_kind, credential_mode, pricing_mode, requires_terms, use_provider_cost, enabled,
                                 builtin, created_by) VALUES
  ('mep_00000000000000000000000001', NULL, 'openrouter', 'OpenRouter',
   'OpenRouter: many providers behind one OpenAI-compatible API; per-call usage.cost. Has its own terms.', 'openrouter',
   '{openai_chat}', 'external', 'https://openrouter.ai/api/v1', 'bearer', 'per_team', 'per_token', true, true, false, true,
   'system:migration'),
  ('mep_00000000000000000000000002', NULL, 'nous-portal', 'Nous Portal',
   'Nous Research Hermes models (OpenAI-compatible chat completions). Reconciled monthly from the portal statement.', 'nous',
   '{openai_chat}', 'external', 'https://inference-api.nousresearch.com/v1', 'bearer', 'per_team', 'per_token', false, false,
   false, true, 'system:migration'),
  ('mep_00000000000000000000000003', NULL, 'opencode', 'OpenCode Console',
   'OpenCode pay-as-you-go Console (paid models only); per-call usage.cost in USD. Reconciled monthly from the usage CSV.',
   'opencode', '{openai_chat,openai_responses}', 'external', 'https://opencode.ai/inference/openai/v1', 'bearer', 'per_team',
   'per_token', false, true, false, true, 'system:migration'),
  ('mep_00000000000000000000000004', NULL, 'azure-openai', 'Azure OpenAI',
   'Azure OpenAI v1 API; model names are deployment names. Replace <resource> in the base URL before switching it on.',
   'azure', '{openai_chat,openai_responses,openai_embeddings}', 'external', 'https://<resource>.openai.azure.com/openai/v1',
   'azure_federated', 'per_team', 'per_token', false, false, false, true, 'system:migration'),
  ('mep_00000000000000000000000005', NULL, 'vertex-ai', 'Google Vertex AI',
   'Vertex AI OpenAI-compatible chat completions. Replace <project> and <location> in the base URL before switching it on.',
   'google', '{openai_chat}', 'external',
   'https://aiplatform.googleapis.com/v1/projects/<project>/locations/<location>/endpoints/openapi',
   'google_federated', 'per_team', 'per_token', false, false, false, true, 'system:migration');

CREATE TABLE afs.endpoint_models (
  endpoint_id       text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  model_name        text NOT NULL,
  team_id           text,
  max_output_tokens integer NOT NULL CHECK (max_output_tokens BETWEEN 1 AND 1000000),
  context_tokens    integer CHECK (context_tokens BETWEEN 1 AND 100000000),
  enabled           boolean NOT NULL DEFAULT true,
  version           bigint NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        text NOT NULL DEFAULT afs.current_actor(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, model_name),
  FOREIGN KEY (team_id, endpoint_id) REFERENCES afs.model_endpoints (team_id, id) ON DELETE CASCADE,
  CONSTRAINT endpoint_models_model_name_check CHECK (model_name ~ '^[[:print:]]{1,200}$' AND model_name !~ '^[/[:space:]]')
);
CREATE INDEX endpoint_models_team_idx ON afs.endpoint_models (team_id) WHERE team_id IS NOT NULL;
COMMENT ON TABLE afs.endpoint_models IS
  'The model names a route serves (what a client sends in model), with the gateway''s worst-case output limit. team_id is copied from the endpoint (NULL for service endpoints). At most 500 per endpoint.';

CREATE TABLE afs.endpoint_model_prices (
  endpoint_id               text NOT NULL,
  model_name                text NOT NULL,
  effective_from            timestamptz NOT NULL,
  team_id                   text,
  input_per_mtok_usd        numeric(14, 6) NOT NULL CHECK (input_per_mtok_usd >= 0),
  output_per_mtok_usd       numeric(14, 6) NOT NULL CHECK (output_per_mtok_usd >= 0),
  cached_input_per_mtok_usd numeric(14, 6) CHECK (cached_input_per_mtok_usd >= 0),
  request_fee_usd           numeric(14, 8) NOT NULL DEFAULT 0 CHECK (request_fee_usd >= 0),
  source                    text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'price_list', 'transfer', 'provider')),
  approved_by               text NOT NULL DEFAULT afs.current_actor(),
  created_at                timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, model_name, effective_from),
  FOREIGN KEY (endpoint_id, model_name) REFERENCES afs.endpoint_models (endpoint_id, model_name) ON DELETE CASCADE,
  FOREIGN KEY (team_id, endpoint_id) REFERENCES afs.model_endpoints (team_id, id) ON DELETE CASCADE
);
COMMENT ON TABLE afs.endpoint_model_prices IS
  'Effective-dated USD prices per million tokens for a route model. Append-only: a change is a new row. cached_input_per_mtok_usd NULL bills cached input at the input price. Written by service admins (or by an approved proposal).';

CREATE TABLE afs.endpoint_price_proposals (
  id                        text PRIMARY KEY CHECK (afs.ulid_ok(id, 'epp')),
  endpoint_id               text NOT NULL,
  model_name                text NOT NULL,
  team_id                   text,
  effective_from            timestamptz NOT NULL,
  input_per_mtok_usd        numeric(14, 6) NOT NULL CHECK (input_per_mtok_usd >= 0),
  output_per_mtok_usd       numeric(14, 6) NOT NULL CHECK (output_per_mtok_usd >= 0),
  cached_input_per_mtok_usd numeric(14, 6) CHECK (cached_input_per_mtok_usd >= 0),
  request_fee_usd           numeric(14, 8) NOT NULL DEFAULT 0 CHECK (request_fee_usd >= 0),
  source                    text NOT NULL DEFAULT 'price_list' CHECK (source IN ('price_list', 'provider')),
  fetched_at                timestamptz NOT NULL DEFAULT now(),
  state                     text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'approved', 'rejected', 'superseded')),
  note                      text NOT NULL DEFAULT '' CHECK (length(note) <= 500),
  decided_at                timestamptz,
  decided_by                text,
  FOREIGN KEY (endpoint_id, model_name) REFERENCES afs.endpoint_models (endpoint_id, model_name) ON DELETE CASCADE,
  FOREIGN KEY (team_id, endpoint_id) REFERENCES afs.model_endpoints (team_id, id) ON DELETE CASCADE,
  CONSTRAINT endpoint_price_proposals_decided_check CHECK ((state IN ('approved', 'rejected')) = (decided_at IS NOT NULL AND decided_by IS NOT NULL))
);
CREATE UNIQUE INDEX endpoint_price_proposals_one_pending ON afs.endpoint_price_proposals (endpoint_id, model_name) WHERE state = 'pending';
COMMENT ON TABLE afs.endpoint_price_proposals IS
  'Route model prices found by the billing job (a price list or the provider''s published prices). Only service admins approve or reject; approval writes an endpoint_model_prices row effective no earlier than the approval. The billing job supersedes a pending proposal it replaces.';

CREATE TABLE afs.endpoint_capacity_costs (
  endpoint_id    text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  team_id        text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  effective_from date NOT NULL,
  monthly_usd    numeric(14, 6) CHECK (monthly_usd >= 0),
  hourly_usd     numeric(14, 6) CHECK (hourly_usd >= 0),
  allocation     text NOT NULL DEFAULT 'by_tokens' CHECK (allocation IN ('by_tokens', 'by_agent')),
  version        bigint NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text NOT NULL DEFAULT afs.current_actor(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, team_id, effective_from),
  CONSTRAINT endpoint_capacity_costs_amount_check CHECK ((monthly_usd IS NULL) <> (hourly_usd IS NULL))
);
CREATE INDEX endpoint_capacity_costs_team_idx ON afs.endpoint_capacity_costs (team_id);
COMMENT ON TABLE afs.endpoint_capacity_costs IS
  'Monthly or hourly cost of a capacity route for one team, for capacity not costed by CUR, allocated daily by token share or by agent. Service admins write it.';

-- 3. Credentials, federation and statements (section 7.4.3) ----------------------------------------------------------
-- afs.secret_path accepts the reserved scope _gateway beside _shared (NULL): <prefix>/<namespace>/_gateway/<route>.
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
  ELSIF p_agent_id = '_gateway' THEN
    v_agent := '_gateway'; -- the team gateway's route credentials (000023); no agent role can read it
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

CREATE TABLE afs.endpoint_credentials (
  endpoint_id text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  scope       text NOT NULL,
  team_id     text REFERENCES afs.teams (id) ON DELETE CASCADE,
  secret_arn  text NOT NULL CHECK (length(secret_arn) <= 2048),
  status      text NOT NULL DEFAULT 'set' CHECK (status IN ('set', 'missing')),
  rotated_at  timestamptz,
  version     bigint NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, scope),
  CONSTRAINT endpoint_credentials_scope_check CHECK ((scope = '_shared' AND team_id IS NULL) OR (team_id IS NOT NULL AND scope = team_id))
);
CREATE INDEX endpoint_credentials_team_idx ON afs.endpoint_credentials (team_id) WHERE team_id IS NOT NULL;
COMMENT ON TABLE afs.endpoint_credentials IS
  'Secrets Manager reference of a route credential: scope _shared (one credential, <prefix>/_service/gateway/<route>) or a team id (<prefix>/<namespace>/_gateway/<route>). Never a value. status is the reconciler''s view.';

CREATE TABLE afs.endpoint_federations (
  endpoint_id    text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  team_id        text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  kind           text NOT NULL CHECK (kind IN ('azure', 'google')),
  tenant_id      text CHECK (tenant_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  client_id      text CHECK (client_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  project_number text CHECK (project_number ~ '^[0-9]{1,20}$'),
  pool_id        text CHECK (pool_id ~ '^[a-z0-9-]{4,32}$'),
  provider_id    text CHECK (provider_id ~ '^[a-z0-9-]{4,32}$'),
  project_id     text CHECK (project_id ~ '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'),
  location       text CHECK (location ~ '^[a-z][a-z0-9-]{1,30}$'),
  status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready', 'failing')),
  last_error     text CHECK (length(last_error) <= 500),
  checked_at     timestamptz,
  version        bigint NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text NOT NULL DEFAULT afs.current_actor(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, team_id),
  CONSTRAINT endpoint_federations_fields_check CHECK (
    CASE kind
      WHEN 'azure' THEN tenant_id IS NOT NULL AND client_id IS NOT NULL
                        AND project_number IS NULL AND pool_id IS NULL AND provider_id IS NULL AND project_id IS NULL AND location IS NULL
      ELSE project_number IS NOT NULL AND pool_id IS NOT NULL AND provider_id IS NOT NULL AND project_id IS NOT NULL AND location IS NOT NULL
           AND tenant_id IS NULL AND client_id IS NULL
    END)
);
CREATE INDEX endpoint_federations_team_idx ON afs.endpoint_federations (team_id);
COMMENT ON TABLE afs.endpoint_federations IS
  'Workload identity federation per endpoint and team (Azure Entra or Google WIF): identifiers only, no secret. Service admins write it; the gateway records status, last_error and checked_at.';

CREATE FUNCTION afs.statement_rows_ok(p jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN jsonb_typeof(p) = 'array'
     AND jsonb_array_length(p) <= 10000
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(p) AS r
        WHERE jsonb_typeof(r) <> 'object'
           OR NOT (r ?& ARRAY['teamId', 'model', 'amountUsd'])
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(r) AS k WHERE k NOT IN ('teamId', 'model', 'amountUsd', 'tokens'))
           OR jsonb_typeof(r -> 'teamId') <> 'string' OR NOT afs.ulid_ok(r ->> 'teamId', 'team')
           OR jsonb_typeof(r -> 'model') <> 'string' OR length(r ->> 'model') NOT BETWEEN 1 AND 200
           OR jsonb_typeof(r -> 'amountUsd') <> 'number' OR (r ->> 'amountUsd')::numeric < 0
           OR (r ? 'tokens' AND (jsonb_typeof(r -> 'tokens') <> 'number'
                                 OR (r ->> 'tokens')::numeric < 0
                                 OR (r ->> 'tokens')::numeric <> trunc((r ->> 'tokens')::numeric))));
REVOKE ALL ON FUNCTION afs.statement_rows_ok(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.statement_rows_ok(jsonb) TO afs_app, afs_billing, afs_readonly, afs_reconciler;

CREATE TABLE afs.provider_statements (
  id          text PRIMARY KEY CHECK (afs.ulid_ok(id, 'pst')),
  endpoint_id text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE RESTRICT,
  period      date NOT NULL CHECK (period = date_trunc('month', period)::date),
  source      text NOT NULL CHECK (source IN ('nous_statement', 'opencode_csv')),
  rows        jsonb NOT NULL CHECK (afs.statement_rows_ok(rows)),
  imported_by text NOT NULL DEFAULT afs.current_actor(),
  imported_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (endpoint_id, period, source)
);
COMMENT ON TABLE afs.provider_statements IS
  'A provider''s monthly usage statement imported by a service admin (Nous Portal statement, OpenCode usage CSV): rows of {teamId, model, amountUsd, tokens?}. Read by afs-billing for monthly reconciliation. Insert-only.';

-- 4. Selections and agents (section 7.4.4) ----------------------------------------------------------------------------
CREATE TABLE afs.team_model_endpoints (
  team_id     text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  endpoint_id text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  selected_by text NOT NULL DEFAULT (CASE WHEN afs.caller_is_service_admin() THEN 'service_admin' ELSE 'team_admin' END)
                   CHECK (selected_by IN ('team_admin', 'service_admin')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, endpoint_id)
);
CREATE INDEX team_model_endpoints_endpoint_idx ON afs.team_model_endpoints (endpoint_id);
COMMENT ON TABLE afs.team_model_endpoints IS
  'A team''s opt-in to a service endpoint. Kept while the endpoint or its provider is off. selected_by records who chose it (set from the caller); an endpoint with requires_terms, or whose provider has team_selection = service_admin, is selected only by service admins, and only they remove a row they selected.';

ALTER TABLE afs.teams
  ADD COLUMN may_add_model_endpoints boolean NOT NULL DEFAULT false,
  ADD COLUMN gateway_deployment text NOT NULL DEFAULT 'shared' CHECK (gateway_deployment IN ('shared', 'per_namespace'));
COMMENT ON COLUMN afs.teams.may_add_model_endpoints IS 'The team may declare its own model endpoints. Service admins only.';
COMMENT ON COLUMN afs.teams.gateway_deployment IS 'shared: the service-wide gateway; per_namespace: the team''s own gateway in its namespace. Service admins only.';

ALTER TABLE afs.agents
  ADD COLUMN route_access text NOT NULL DEFAULT 'all' CHECK (route_access IN ('all', 'selected')),
  ADD COLUMN default_route text;
ALTER TABLE afs.agent_pools
  ADD COLUMN route_access text NOT NULL DEFAULT 'all' CHECK (route_access IN ('all', 'selected')),
  ADD COLUMN default_route text;
ALTER TABLE afs.agents ADD CONSTRAINT agents_default_route_check
  CHECK (default_route IS NULL OR (default_route ~ '^[a-z][a-z0-9-]{1,30}$' AND default_route <> 'bedrock')) NOT VALID;
ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_default_route_check;
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_default_route_check
  CHECK (default_route IS NULL OR (default_route ~ '^[a-z][a-z0-9-]{1,30}$' AND default_route <> 'bedrock')) NOT VALID;
ALTER TABLE afs.agent_pools VALIDATE CONSTRAINT agent_pools_default_route_check;
COMMENT ON COLUMN afs.agents.route_access IS 'all: every route in the team''s set; selected: the routes in agent_model_endpoints. Bedrock stays under model_access.';
COMMENT ON COLUMN afs.agents.default_route IS 'NULL: default_model_id is a Bedrock model. Set: the route (endpoint slug) of the default model, and default_model_id holds the route''s model name (CD-42).';
COMMENT ON COLUMN afs.agent_pools.route_access IS 'all: every route in the team''s set; selected: the routes in pool_model_endpoints.';
COMMENT ON COLUMN afs.agent_pools.default_route IS 'NULL: default_model_id is a Bedrock model. Set: the route of the default model (CD-42).';

CREATE TABLE afs.agent_model_endpoints (
  team_id     text NOT NULL,
  agent_id    text NOT NULL,
  endpoint_id text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, agent_id, endpoint_id),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE
);
CREATE TABLE afs.pool_model_endpoints (
  team_id     text NOT NULL,
  pool_id     text NOT NULL,
  endpoint_id text NOT NULL REFERENCES afs.model_endpoints (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (team_id, pool_id, endpoint_id),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);
CREATE INDEX agent_model_endpoints_endpoint_idx ON afs.agent_model_endpoints (endpoint_id);
CREATE INDEX pool_model_endpoints_endpoint_idx ON afs.pool_model_endpoints (endpoint_id);
COMMENT ON TABLE afs.agent_model_endpoints IS 'The routes an agent in route_access = selected may call; narrows the team''s set. At most 50.';
COMMENT ON TABLE afs.pool_model_endpoints IS 'The routes a pool in route_access = selected may call; narrows the team''s set. At most 50.';

-- 5. Guards --------------------------------------------------------------------------------------------------------------
-- Is p_value (a service default model) a usable fallback for Bedrock? A <route>/<model> on an enabled service
-- endpoint, an enabled model, an enabled provider other than p_except_provider, selected for every team that is not
-- deleted.
CREATE FUNCTION afs.fallback_route_ok(p_value text, p_except_provider text) RETURNS boolean
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  e afs.model_endpoints;
BEGIN
  IF p_value IS NULL OR afs.route_model_slug(p_value) IS NULL
     OR EXISTS (SELECT 1 FROM afs.models m WHERE m.id = p_value) THEN
    RETURN false;
  END IF;
  SELECT * INTO e FROM afs.model_endpoints x WHERE x.team_id IS NULL AND x.slug = afs.route_model_slug(p_value);
  IF NOT FOUND OR NOT e.enabled OR e.provider = p_except_provider OR NOT afs.provider_enabled(e.provider) THEN
    RETURN false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.endpoint_models m WHERE m.endpoint_id = e.id AND m.model_name = afs.route_model_name(p_value) AND m.enabled) THEN
    RETURN false;
  END IF;
  RETURN NOT EXISTS (SELECT 1 FROM afs.teams t
                      WHERE t.state <> 'deleted'
                        AND NOT EXISTS (SELECT 1 FROM afs.team_model_endpoints tm WHERE tm.team_id = t.id AND tm.endpoint_id = e.id));
END $$;
REVOKE ALL ON FUNCTION afs.fallback_route_ok(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.fallback_route_ok(text, text) TO afs_app, afs_readonly;

-- inference_providers: afs_app writes need a service admin (42501); provider is fixed; Bedrock off needs a fallback,
-- and so does turning off the fallback's own provider while Bedrock is off (no_fallback_model).
CREATE FUNCTION afs.inference_provider_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin() THEN
    RAISE EXCEPTION 'only service admins change the provider policy' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.provider IS DISTINCT FROM OLD.provider THEN
      RAISE EXCEPTION 'a provider''s key cannot change' USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF NEW IS NOT DISTINCT FROM OLD THEN
      RETURN NEW;
    END IF;
    IF OLD.enabled AND NOT NEW.enabled THEN
      IF NEW.provider = 'bedrock'
         AND NOT afs.fallback_route_ok((SELECT s.value #>> '{}' FROM afs.service_settings s
                                         WHERE s.key = 'models.default_model_id' AND jsonb_typeof(s.value) = 'string'), 'bedrock') THEN
        RAISE EXCEPTION 'Bedrock can be turned off only when models.default_model_id is a route model on an enabled endpoint and provider, selected for every team'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'no_fallback_model';
      END IF;
      IF NEW.provider <> 'bedrock' AND NOT afs.provider_enabled('bedrock')
         AND NEW.provider = (SELECT e.provider FROM afs.model_endpoints e
                              WHERE e.team_id IS NULL
                                AND e.slug = afs.route_model_slug((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'models.default_model_id'))) THEN
        RAISE EXCEPTION 'provider % serves the service default model while Bedrock is off; choose another fallback first', NEW.provider
          USING ERRCODE = 'check_violation', CONSTRAINT = 'no_fallback_model';
      END IF;
    END IF;
    NEW.version := OLD.version + 1;
  END IF;
  NEW.changed_by := afs.current_actor();
  NEW.changed_at := now();
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.inference_provider_guard() FROM PUBLIC;
CREATE TRIGGER inference_providers_guard BEFORE INSERT OR UPDATE OR DELETE ON afs.inference_providers
  FOR EACH ROW EXECUTE FUNCTION afs.inference_provider_guard();

-- Slug taken: a team slug may not equal a service slug, a service slug may not equal any team's slug.
CREATE FUNCTION afs.model_endpoint_slug_taken(p_team_id text, p_slug text, p_id text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN EXISTS (SELECT 1 FROM afs.model_endpoints e
                  WHERE e.slug = p_slug AND e.id <> p_id
                    AND (e.team_id IS NULL OR p_team_id IS NULL OR e.team_id = p_team_id));
REVOKE ALL ON FUNCTION afs.model_endpoint_slug_taken(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.model_endpoint_slug_taken(text, text, text) TO afs_app;

-- model_endpoints, before the row is written. SECURITY INVOKER: it keys on current_user.
CREATE FUNCTION afs.model_endpoint_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_host    text;
  v_derived text;
  v_ns      text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.builtin THEN
      RAISE EXCEPTION 'built-in endpoint % cannot be deleted; switch it off instead', OLD.slug
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.team_id IS DISTINCT FROM OLD.team_id OR NEW.slug IS DISTINCT FROM OLD.slug
                           OR NEW.builtin IS DISTINCT FROM OLD.builtin) THEN
    RAISE EXCEPTION 'an endpoint''s level, slug and built-in flag cannot change'
      USING ERRCODE = 'object_not_in_prerequisite_state', CONSTRAINT = 'model_endpoints_identity_immutable';
  END IF;
  IF NEW.team_id IS NOT NULL AND current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
     AND NOT EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = NEW.team_id AND t.may_add_model_endpoints) THEN
    RAISE EXCEPTION 'this team may not declare its own model endpoints; ask a service admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Provider: from the host when it is a listed provider's; internal inside the namespace (section 7.4).
  v_host := afs.url_host(NEW.base_url);
  v_derived := afs.provider_for_host(v_host);
  IF NEW.location = 'in_namespace' THEN
    NEW.provider := 'internal';
  ELSIF v_derived <> 'other' THEN
    NEW.provider := v_derived;
  ELSIF NEW.team_id IS NOT NULL THEN
    NEW.provider := CASE NEW.location WHEN 'corporate' THEN 'internal' ELSE 'other' END;
  ELSE
    NEW.provider := coalesce(NEW.provider, CASE NEW.location WHEN 'corporate' THEN 'internal' ELSE 'other' END);
    IF NEW.provider = 'internal' AND NEW.location = 'external' THEN
      RAISE EXCEPTION 'an external endpoint has a provider switch; internal is for corporate and in-namespace endpoints'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'model_endpoints_provider_check';
    END IF;
  END IF;
  IF NEW.provider <> 'internal' AND NOT EXISTS (SELECT 1 FROM afs.inference_providers p WHERE p.provider = NEW.provider) THEN
    RAISE EXCEPTION 'provider % is not in inference_providers', NEW.provider
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'model_endpoints_provider_fkey';
  END IF;
  IF (NEW.auth_kind = 'azure_federated' AND NEW.provider <> 'azure') OR (NEW.auth_kind = 'google_federated' AND NEW.provider <> 'google') THEN
    RAISE EXCEPTION 'auth kind % needs an endpoint of provider %', NEW.auth_kind, split_part(NEW.auth_kind, '_', 1)
      USING ERRCODE = 'check_violation', CONSTRAINT = 'model_endpoints_auth_kind_provider';
  END IF;
  -- An endpoint of a provider that is off cannot be created, switched on or moved to it; one that is kept off may
  -- still be edited (for example to replace a placeholder before the provider is turned on).
  IF NOT afs.provider_enabled(NEW.provider)
     AND (TG_OP = 'INSERT' OR NEW.enabled OR NEW.provider IS DISTINCT FROM OLD.provider) THEN
    RAISE EXCEPTION 'provider % is turned off by the provider policy', NEW.provider
      USING ERRCODE = 'check_violation', CONSTRAINT = 'provider_disabled';
  END IF;
  IF NEW.enabled AND NEW.base_url ~ '[<>]' THEN
    RAISE EXCEPTION 'replace the placeholders in the base URL of % before switching it on', NEW.slug
      USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_base_url_placeholder';
  END IF;
  IF NEW.location = 'in_namespace' AND NEW.team_id IS NOT NULL THEN
    SELECT t.namespace INTO v_ns FROM afs.teams t WHERE t.id = NEW.team_id;
    IF v_host IS NULL OR NOT (v_host ~ '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
                              OR v_host ~ ('^[a-z]([a-z0-9-]{0,61}[a-z0-9])?\.' || replace(coalesce(v_ns, '-'), '.', '\.') || '(\.svc(\.cluster\.local)?)?$')) THEN
      RAISE EXCEPTION 'an in-namespace endpoint names a Service in the team''s namespace %', v_ns
        USING ERRCODE = 'check_violation', CONSTRAINT = 'model_endpoints_in_namespace_host';
    END IF;
  END IF;
  IF NEW.external_system_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.external_system_id IS DISTINCT FROM OLD.external_system_id)
     AND NOT EXISTS (SELECT 1 FROM afs.external_systems x
                      WHERE x.id = NEW.external_system_id AND (x.team_id IS NULL OR x.team_id = NEW.team_id)) THEN
    RAISE EXCEPTION 'external system % is not in the service catalog or the endpoint''s team', NEW.external_system_id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'model_endpoints_external_system_id_fkey';
  END IF;
  IF TG_OP = 'INSERT' THEN
    PERFORM pg_advisory_xact_lock(hashtext('afs.model_endpoints.slug:' || NEW.slug));
    IF afs.model_endpoint_slug_taken(NEW.team_id, NEW.slug, NEW.id) THEN
      RAISE EXCEPTION 'route % is taken by a service endpoint or by this team', NEW.slug
        USING ERRCODE = 'unique_violation', CONSTRAINT = 'model_endpoints_slug_taken';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.model_endpoint_guard() FROM PUBLIC;
CREATE TRIGGER model_endpoints_guard BEFORE INSERT OR UPDATE OR DELETE ON afs.model_endpoints
  FOR EACH ROW EXECUTE FUNCTION afs.model_endpoint_guard();

-- Children of an endpoint: team_id is the endpoint's (copied) or must agree with it.
CREATE FUNCTION afs.endpoint_child_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  e afs.model_endpoints;
  n integer;
  v_prefix text;
  v_path text;
BEGIN
  SELECT * INTO e FROM afs.model_endpoints x WHERE x.id = NEW.endpoint_id;
  IF NOT FOUND THEN
    RETURN NEW; -- the foreign key reports it
  END IF;
  IF TG_TABLE_NAME IN ('endpoint_models', 'endpoint_model_prices', 'endpoint_price_proposals') THEN
    NEW.team_id := e.team_id;
  ELSIF e.team_id IS NOT NULL AND NEW.team_id IS DISTINCT FROM e.team_id THEN
    RAISE EXCEPTION 'endpoint % belongs to another team', e.slug
      USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_endpoint_team';
  END IF;

  IF TG_TABLE_NAME = 'endpoint_models' AND TG_OP = 'INSERT' THEN
    SELECT count(*) INTO n FROM afs.endpoint_models m WHERE m.endpoint_id = NEW.endpoint_id;
    IF n >= 500 THEN
      RAISE EXCEPTION 'at most 500 models per endpoint' USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_models_limit';
    END IF;
  ELSIF TG_TABLE_NAME = 'endpoint_capacity_costs' AND e.pricing_mode <> 'capacity' THEN
    RAISE EXCEPTION 'endpoint % is not priced by capacity', e.slug
      USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_capacity_costs_mode';
  ELSIF TG_TABLE_NAME = 'endpoint_federations' THEN
    IF e.auth_kind <> (to_jsonb(NEW) ->> 'kind') || '_federated' THEN
      RAISE EXCEPTION 'endpoint % does not use % workload identity federation', e.slug, to_jsonb(NEW) ->> 'kind'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_federations_kind';
    END IF;
  ELSIF TG_TABLE_NAME = 'endpoint_credentials' THEN
    IF NOT ((NEW.scope = '_shared' AND NEW.team_id IS NULL) OR (NEW.team_id IS NOT NULL AND NEW.scope = NEW.team_id)) THEN
      RETURN NEW; -- endpoint_credentials_scope_check reports it
    END IF;
    IF e.auth_kind NOT IN ('bearer', 'header') THEN
      RAISE EXCEPTION 'endpoint % (auth kind %) takes no stored credential', e.slug, e.auth_kind
        USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_credentials_auth_kind';
    END IF;
    IF (e.team_id IS NULL AND e.credential_mode = 'shared') <> (NEW.scope = '_shared') THEN
      RAISE EXCEPTION 'endpoint % takes % credentials', e.slug,
        CASE WHEN e.team_id IS NULL AND e.credential_mode = 'shared' THEN 'one shared' ELSE 'per-team' END
        USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_credentials_scope';
    END IF;
    IF NEW.scope = '_shared' THEN
      v_prefix := coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'secrets.path_prefix'), 'afs');
      v_path := v_prefix || '/_service/gateway/' || e.slug;
    ELSE
      v_path := afs.secret_path(NEW.team_id, '_gateway', e.slug);
    END IF;
    IF NEW.secret_arn !~ '^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+-[A-Za-z0-9]{6}$'
       OR substring(NEW.secret_arn FROM ':secret:(.*)-[A-Za-z0-9]{6}$') IS DISTINCT FROM v_path THEN
      RAISE EXCEPTION 'the credential must be a Secrets Manager ARN at path %', v_path
        USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_credential_path';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.endpoint_child_guard() FROM PUBLIC;
CREATE TRIGGER endpoint_models_guard BEFORE INSERT OR UPDATE ON afs.endpoint_models
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_child_guard();
CREATE TRIGGER endpoint_model_prices_guard BEFORE INSERT ON afs.endpoint_model_prices
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_child_guard();
CREATE TRIGGER endpoint_price_proposals_team BEFORE INSERT ON afs.endpoint_price_proposals
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_child_guard();
CREATE TRIGGER endpoint_capacity_costs_guard BEFORE INSERT OR UPDATE ON afs.endpoint_capacity_costs
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_child_guard();
CREATE TRIGGER endpoint_federations_guard BEFORE INSERT OR UPDATE OF endpoint_id, team_id, kind ON afs.endpoint_federations
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_child_guard();
CREATE TRIGGER endpoint_credentials_guard BEFORE INSERT OR UPDATE OF endpoint_id, scope, team_id, secret_arn ON afs.endpoint_credentials
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_child_guard();

-- Prices are append-only; a row goes only with its model or endpoint (a cascade).
CREATE FUNCTION afs.endpoint_model_prices_append_only() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'UPDATE' OR pg_trigger_depth() < 2 THEN
    RAISE EXCEPTION 'route prices are append-only: add a row with a later effective_from'
      USING ERRCODE = 'object_not_in_prerequisite_state', CONSTRAINT = 'endpoint_model_prices_append_only';
  END IF;
  RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION afs.endpoint_model_prices_append_only() FROM PUBLIC;
CREATE TRIGGER endpoint_model_prices_append_only BEFORE UPDATE OR DELETE ON afs.endpoint_model_prices
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_model_prices_append_only();

-- Proposals: as model_price_proposals (000010).
CREATE FUNCTION afs.endpoint_price_proposal_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.state <> 'pending' OR NEW.decided_at IS NOT NULL OR NEW.decided_by IS NOT NULL THEN
      RAISE EXCEPTION 'a proposal starts pending' USING ERRCODE = 'check_violation', CONSTRAINT = 'endpoint_price_proposals_pending';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.state = OLD.state THEN
    RETURN NEW;
  END IF;
  IF OLD.state <> 'pending' THEN
    RAISE EXCEPTION 'proposal % is already %', OLD.id, OLD.state USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NEW.state IN ('approved', 'rejected') THEN
    IF current_user = 'afs_billing' OR (current_user = 'afs_app' AND NOT afs.caller_is_service_admin()) THEN
      RAISE EXCEPTION 'only service admins approve or reject prices' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.decided_at := now();
    NEW.decided_by := afs.current_actor();
  ELSIF NEW.state = 'superseded' AND current_user = 'afs_app' THEN
    RAISE EXCEPTION 'only the billing job supersedes a proposal' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.endpoint_price_proposal_guard() FROM PUBLIC;
CREATE TRIGGER endpoint_price_proposals_guard BEFORE INSERT OR UPDATE ON afs.endpoint_price_proposals
  FOR EACH ROW EXECUTE FUNCTION afs.endpoint_price_proposal_guard();

CREATE FUNCTION afs.endpoint_price_proposal_apply() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  INSERT INTO afs.endpoint_model_prices (endpoint_id, model_name, effective_from, input_per_mtok_usd, output_per_mtok_usd,
                                         cached_input_per_mtok_usd, request_fee_usd, source, approved_by)
  VALUES (NEW.endpoint_id, NEW.model_name, greatest(NEW.effective_from, now()), NEW.input_per_mtok_usd, NEW.output_per_mtok_usd,
          NEW.cached_input_per_mtok_usd, NEW.request_fee_usd, NEW.source, NEW.decided_by);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.endpoint_price_proposal_apply() FROM PUBLIC;
CREATE TRIGGER endpoint_price_proposals_apply AFTER UPDATE OF state ON afs.endpoint_price_proposals
  FOR EACH ROW WHEN (NEW.state = 'approved' AND OLD.state = 'pending')
  EXECUTE FUNCTION afs.endpoint_price_proposal_apply();

-- Opt-ins: service endpoints only; extra terms and service-selected providers need a service admin (42501);
-- selected_by is the caller's.
CREATE FUNCTION afs.team_model_endpoint_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_team_id  text;
  v_terms    boolean;
  v_provider text;
  v_admin    boolean := afs.caller_is_service_admin();
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF current_user = 'afs_app' AND NOT v_admin AND OLD.selected_by = 'service_admin' THEN
      RAISE EXCEPTION 'a service admin selected this endpoint for the team; only a service admin removes it'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN OLD;
  END IF;
  SELECT x.team_id, x.requires_terms, x.provider INTO v_team_id, v_terms, v_provider
    FROM afs.model_endpoints x WHERE x.id = NEW.endpoint_id;
  IF NOT FOUND OR v_team_id IS NOT NULL THEN
    RAISE EXCEPTION 'only a service endpoint is selected for a team; a team''s own endpoints are always in its set'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'team_model_endpoints_service_only';
  END IF;
  IF current_user = 'afs_app' THEN
    IF NOT v_admin AND (v_terms OR (SELECT p.team_selection FROM afs.inference_providers p WHERE p.provider = v_provider) = 'service_admin') THEN
      RAISE EXCEPTION 'this endpoint is selected for a team by a service admin' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.selected_by := CASE WHEN v_admin THEN 'service_admin' ELSE 'team_admin' END;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.team_model_endpoint_guard() FROM PUBLIC;
CREATE TRIGGER team_model_endpoints_guard BEFORE INSERT OR UPDATE OR DELETE ON afs.team_model_endpoints
  FOR EACH ROW EXECUTE FUNCTION afs.team_model_endpoint_guard();

-- Is the endpoint in the team's set: the team's own, or a service endpoint the team opted in to.
CREATE FUNCTION afs.endpoint_in_team_set(p_team_id text, p_endpoint_id text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
  RETURN EXISTS (SELECT 1 FROM afs.model_endpoints e
                  WHERE e.id = p_endpoint_id
                    AND (e.team_id = p_team_id
                         OR (e.team_id IS NULL AND EXISTS (SELECT 1 FROM afs.team_model_endpoints tm
                                                            WHERE tm.team_id = p_team_id AND tm.endpoint_id = e.id))));
REVOKE ALL ON FUNCTION afs.endpoint_in_team_set(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.endpoint_in_team_set(text, text) TO afs_app, afs_reconciler, afs_gateway, afs_readonly;

CREATE FUNCTION afs.subject_routes_insert_check() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  n integer;
BEGIN
  IF NOT afs.endpoint_in_team_set(NEW.team_id, NEW.endpoint_id) THEN
    RAISE EXCEPTION 'endpoint % is not in team %''s set of routes', NEW.endpoint_id, NEW.team_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agent_routes_team';
  END IF;
  IF TG_TABLE_NAME = 'agent_model_endpoints' THEN
    SELECT count(*) INTO n FROM afs.agent_model_endpoints x WHERE x.team_id = NEW.team_id AND x.agent_id = NEW.agent_id;
  ELSE
    SELECT count(*) INTO n FROM afs.pool_model_endpoints x WHERE x.team_id = NEW.team_id AND x.pool_id = NEW.pool_id;
  END IF;
  IF n >= 50 THEN
    RAISE EXCEPTION 'at most 50 routes per agent or pool' USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_limit';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.subject_routes_insert_check() FROM PUBLIC;
CREATE TRIGGER agent_model_endpoints_insert_check BEFORE INSERT ON afs.agent_model_endpoints
  FOR EACH ROW EXECUTE FUNCTION afs.subject_routes_insert_check();
CREATE TRIGGER pool_model_endpoints_insert_check BEFORE INSERT ON afs.pool_model_endpoints
  FOR EACH ROW EXECUTE FUNCTION afs.subject_routes_insert_check();

-- teams: the two new switches are service-admin only (as may_add_external_systems).
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
       OR NEW.orchestration_required IS DISTINCT FROM OLD.orchestration_required
       OR NEW.may_add_model_endpoints IS DISTINCT FROM OLD.may_add_model_endpoints
       OR NEW.gateway_deployment IS DISTINCT FROM OLD.gateway_deployment THEN
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
                   max_collaboration_exposure, model_access, orchestration_required, may_add_model_endpoints,
                   gateway_deployment ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

-- A new team is selected for the service default route model, so the default works for its agents and the
-- Bedrock-off rule ("selected for every team") keeps holding.
CREATE FUNCTION afs.teams_default_route_select() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_default text := (SELECT s.value #>> '{}' FROM afs.service_settings s
                      WHERE s.key = 'models.default_model_id' AND jsonb_typeof(s.value) = 'string');
  v_endpoint text;
BEGIN
  IF afs.route_model_slug(v_default) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM afs.models m WHERE m.id = v_default) THEN
    SELECT e.id INTO v_endpoint FROM afs.model_endpoints e WHERE e.team_id IS NULL AND e.slug = afs.route_model_slug(v_default);
    IF v_endpoint IS NOT NULL THEN
      INSERT INTO afs.team_model_endpoints (team_id, endpoint_id, selected_by) VALUES (NEW.id, v_endpoint, 'service_admin')
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.teams_default_route_select() FROM PUBLIC;
CREATE TRIGGER teams_default_route_select AFTER INSERT ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.teams_default_route_select();

-- 6. Default models that are route models (CD-42) -----------------------------------------------------------------------
ALTER TABLE afs.agents DROP CONSTRAINT agents_default_model_id_fkey;
ALTER TABLE afs.agents DROP CONSTRAINT agents_model_id_fkey;
ALTER TABLE afs.agent_pools DROP CONSTRAINT agent_pools_default_model_id_fkey;
ALTER TABLE afs.agent_pools DROP CONSTRAINT agent_pools_model_id_fkey;

-- Runs after default_model_sync (names sort). A <route>/<model> written as default_model_id with no default_route (the
-- service default of create_orchestration_agent, or a 1.1.0 client) is split. While default_route is NULL the default
-- must be a Bedrock model, as the dropped foreign keys required (23503).
CREATE FUNCTION afs.default_model_ref() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_slug  text;
  v_model text;
BEGIN
  IF NEW.default_route IS NULL AND NEW.default_model_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM afs.models m WHERE m.id = NEW.default_model_id) THEN
    v_slug := afs.route_model_slug(NEW.default_model_id);
    v_model := afs.route_model_name(NEW.default_model_id);
    IF v_slug IS NOT NULL AND EXISTS (SELECT 1 FROM afs.model_endpoints e JOIN afs.endpoint_models m ON m.endpoint_id = e.id
                                       WHERE e.slug = v_slug AND (e.team_id IS NULL OR e.team_id = NEW.team_id)
                                         AND m.model_name = v_model) THEN
      NEW.default_route := v_slug;
      NEW.default_model_id := v_model;
    ELSE
      RAISE EXCEPTION 'default model % is neither a Bedrock model nor a route model', NEW.default_model_id
        USING ERRCODE = 'foreign_key_violation', CONSTRAINT = TG_TABLE_NAME || '_default_model_id_fkey';
    END IF;
  END IF;
  IF NEW.model_id IS DISTINCT FROM NEW.default_model_id AND NEW.default_model_id IS NOT NULL THEN
    NEW.model_id := NEW.default_model_id;
  END IF;
  IF NEW.default_route IS NULL AND NOT EXISTS (SELECT 1 FROM afs.models m WHERE m.id = NEW.model_id) THEN
    RAISE EXCEPTION 'model % is not in the model catalog', NEW.model_id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = TG_TABLE_NAME || '_model_id_fkey';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION afs.default_model_ref() FROM PUBLIC;
CREATE TRIGGER agents_default_route_ref BEFORE INSERT OR UPDATE ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.default_model_ref();
CREATE TRIGGER agent_pools_default_route_ref BEFORE INSERT OR UPDATE ON afs.agent_pools
  FOR EACH ROW EXECUTE FUNCTION afs.default_model_ref();

-- The other side of the dropped foreign keys: a model used as a Bedrock default keeps its row and id.
CREATE FUNCTION afs.models_in_use_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.id = OLD.id THEN
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM afs.agents a WHERE a.default_route IS NULL AND (a.default_model_id = OLD.id OR a.model_id = OLD.id)) THEN
    RAISE EXCEPTION 'model % is the default model of an agent', OLD.id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'agents_default_model_id_fkey';
  END IF;
  IF EXISTS (SELECT 1 FROM afs.agent_pools p WHERE p.default_route IS NULL AND (p.default_model_id = OLD.id OR p.model_id = OLD.id)) THEN
    RAISE EXCEPTION 'model % is the default model of a pool', OLD.id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'agent_pools_default_model_id_fkey';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
REVOKE ALL ON FUNCTION afs.models_in_use_guard() FROM PUBLIC;
CREATE TRIGGER models_in_use_guard BEFORE DELETE OR UPDATE OF id ON afs.models
  FOR EACH ROW EXECUTE FUNCTION afs.models_in_use_guard();

-- The Bedrock checks of 000022 apply to a Bedrock default only; a route default is checked by subject_routes_check.
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
  v_route   text;
  n         integer;
  v_in      boolean;
BEGIN
  IF v_is_pool THEN
    SELECT p.model_access, p.default_model_id, p.default_route INTO v_access, v_default, v_route
      FROM afs.agent_pools p WHERE p.team_id = v_team AND p.id = v_id AND p.deleted_at IS NULL;
  ELSE
    SELECT a.model_access, a.default_model_id, a.default_route INTO v_access, v_default, v_route
      FROM afs.agents a WHERE a.team_id = v_team AND a.id = v_id AND a.deleted_at IS NULL;
  END IF;
  IF NOT FOUND OR v_route IS NOT NULL THEN
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
DROP TRIGGER agents_models_check ON afs.agents;
DROP TRIGGER agent_pools_models_check ON afs.agent_pools;
CREATE CONSTRAINT TRIGGER agents_models_check AFTER INSERT OR UPDATE OF model_access, default_model_id, default_route ON afs.agents
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();
CREATE CONSTRAINT TRIGGER agent_pools_models_check AFTER INSERT OR UPDATE OF model_access, default_model_id, default_route ON afs.agent_pools
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_models_check();

-- 7. Effective routes and admission (section 7.4.4) -----------------------------------------------------------------------
-- The routes each live agent and pool may call: (the team's opted-in enabled service endpoints plus its enabled own
-- endpoints) narrowed by the subject, on enabled providers, for enabled callable models (per_token needs a price in
-- force). Runs with the caller's rights.
CREATE VIEW afs.effective_agent_routes WITH (security_invoker = true) AS
WITH subjects AS (
  SELECT a.team_id, 'agent'::text AS subject_kind, a.id AS subject_id, a.route_access, a.default_route, a.default_model_id
    FROM afs.agents a WHERE a.deleted_at IS NULL AND a.state <> 'deleted'
  UNION ALL
  SELECT p.team_id, 'pool', p.id, p.route_access, p.default_route, p.default_model_id
    FROM afs.agent_pools p WHERE p.deleted_at IS NULL AND p.state <> 'deleted'
)
SELECT s.team_id, s.subject_kind, s.subject_id, e.id AS endpoint_id, e.slug, m.model_name,
       coalesce(e.slug = s.default_route AND m.model_name = s.default_model_id, false) AS is_default
  FROM subjects s
  JOIN afs.teams t ON t.id = s.team_id AND t.state <> 'deleted'
  JOIN afs.model_endpoints e
    ON e.enabled
   AND (e.team_id = s.team_id
        OR (e.team_id IS NULL AND EXISTS (SELECT 1 FROM afs.team_model_endpoints tm WHERE tm.team_id = s.team_id AND tm.endpoint_id = e.id)))
  JOIN afs.endpoint_models m ON m.endpoint_id = e.id AND m.enabled
 WHERE afs.provider_enabled(e.provider)
   AND (s.route_access = 'all'
        OR (s.subject_kind = 'agent' AND EXISTS (SELECT 1 FROM afs.agent_model_endpoints x WHERE x.team_id = s.team_id AND x.agent_id = s.subject_id AND x.endpoint_id = e.id))
        OR (s.subject_kind = 'pool' AND EXISTS (SELECT 1 FROM afs.pool_model_endpoints x WHERE x.team_id = s.team_id AND x.pool_id = s.subject_id AND x.endpoint_id = e.id)))
   AND (e.pricing_mode <> 'per_token'
        OR EXISTS (SELECT 1 FROM afs.endpoint_model_prices pr WHERE pr.endpoint_id = e.id AND pr.model_name = m.model_name AND pr.effective_from <= now()));
COMMENT ON VIEW afs.effective_agent_routes IS
  'The route models each live agent and pool may call: provider, service, team, agent or pool, and callable. Bedrock is not a route here (effective_agent_models). Runs with the caller''s rights.';

-- Why a route model is refused for one subject: the first failing level, in the fixed order of the gateway contract.
-- Every enabled model on a service endpoint or on the subject's team's own endpoints; NULL reason = admitted. A name
-- absent from the result is model_not_on_route (the gateway decides it).
CREATE FUNCTION afs.route_admission(p_subject_kind text, p_subject_id text)
  RETURNS TABLE (endpoint_id text, slug text, model_name text, reason text)
  LANGUAGE sql STABLE
  SET search_path = pg_catalog, afs
AS $$
  WITH subj AS (
    SELECT a.team_id, a.id AS subject_id, a.route_access FROM afs.agents a
     WHERE p_subject_kind = 'agent' AND a.id = p_subject_id AND a.deleted_at IS NULL
    UNION ALL
    SELECT p.team_id, p.id, p.route_access FROM afs.agent_pools p
     WHERE p_subject_kind = 'pool' AND p.id = p_subject_id AND p.deleted_at IS NULL
  )
  SELECT e.id, e.slug, m.model_name,
         CASE WHEN NOT afs.provider_enabled(e.provider) THEN 'provider_disabled'
              WHEN e.team_id IS NULL AND NOT e.enabled THEN 'route_not_enabled_for_service'
              WHEN (e.team_id IS NULL AND NOT EXISTS (SELECT 1 FROM afs.team_model_endpoints tm WHERE tm.team_id = s.team_id AND tm.endpoint_id = e.id))
                   OR (e.team_id IS NOT NULL AND NOT e.enabled) THEN 'route_not_enabled_for_team'
              WHEN NOT (s.route_access = 'all'
                        OR (p_subject_kind = 'agent' AND EXISTS (SELECT 1 FROM afs.agent_model_endpoints x WHERE x.team_id = s.team_id AND x.agent_id = s.subject_id AND x.endpoint_id = e.id))
                        OR (p_subject_kind = 'pool' AND EXISTS (SELECT 1 FROM afs.pool_model_endpoints x WHERE x.team_id = s.team_id AND x.pool_id = s.subject_id AND x.endpoint_id = e.id)))
                   THEN 'route_not_enabled_for_agent'
              WHEN e.pricing_mode = 'per_token'
                   AND NOT EXISTS (SELECT 1 FROM afs.endpoint_model_prices pr WHERE pr.endpoint_id = e.id AND pr.model_name = m.model_name AND pr.effective_from <= now())
                   THEN 'model_not_priced'
         END
    FROM subj s
    JOIN afs.teams t ON t.id = s.team_id
    JOIN afs.model_endpoints e ON e.team_id IS NULL OR e.team_id = s.team_id
    JOIN afs.endpoint_models m ON m.endpoint_id = e.id AND m.enabled
   ORDER BY e.slug, m.model_name
$$;
REVOKE ALL ON FUNCTION afs.route_admission(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.route_admission(text, text) TO afs_app, afs_reconciler, afs_gateway, afs_readonly;

-- The default route model, at commit (23514 agents_default_route_allowed).
CREATE FUNCTION afs.subject_routes_check() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_rec     jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  v_is_pool boolean := TG_TABLE_NAME IN ('agent_pools', 'pool_model_endpoints');
  v_id      text := CASE TG_TABLE_NAME WHEN 'agent_model_endpoints' THEN v_rec ->> 'agent_id'
                                       WHEN 'pool_model_endpoints' THEN v_rec ->> 'pool_id' ELSE v_rec ->> 'id' END;
  v_team    text := v_rec ->> 'team_id';
  v_route   text;
  v_default text;
BEGIN
  IF v_is_pool THEN
    SELECT p.default_route, p.default_model_id INTO v_route, v_default
      FROM afs.agent_pools p WHERE p.team_id = v_team AND p.id = v_id AND p.deleted_at IS NULL AND p.state <> 'deleted';
  ELSE
    SELECT a.default_route, a.default_model_id INTO v_route, v_default
      FROM afs.agents a WHERE a.team_id = v_team AND a.id = v_id AND a.deleted_at IS NULL AND a.state <> 'deleted';
  END IF;
  IF NOT FOUND OR v_route IS NULL THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.effective_agent_routes r
                  WHERE r.subject_kind = CASE WHEN v_is_pool THEN 'pool' ELSE 'agent' END AND r.subject_id = v_id
                    AND r.slug = v_route AND r.model_name = v_default) THEN
    RAISE EXCEPTION 'default model %/% is not one of the routes % may call', v_route, v_default, v_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'agents_default_route_allowed';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION afs.subject_routes_check() FROM PUBLIC;
CREATE CONSTRAINT TRIGGER agents_routes_check AFTER INSERT OR UPDATE OF route_access, default_route, default_model_id ON afs.agents
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_routes_check();
CREATE CONSTRAINT TRIGGER agent_pools_routes_check AFTER INSERT OR UPDATE OF route_access, default_route, default_model_id ON afs.agent_pools
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_routes_check();
CREATE CONSTRAINT TRIGGER agent_model_endpoints_check AFTER INSERT OR DELETE ON afs.agent_model_endpoints
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_routes_check();
CREATE CONSTRAINT TRIGGER pool_model_endpoints_check AFTER INSERT OR DELETE ON afs.pool_model_endpoints
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.subject_routes_check();

-- The Bedrock switch applies to the Bedrock model set too (section 7.4: "Bedrock models return to every effective set").
CREATE OR REPLACE VIEW afs.effective_agent_models WITH (security_invoker = true) AS
WITH cfg AS (
  SELECT coalesce((SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'models.service_access'), 'all') AS service_access
), svc AS (
  SELECT m.id FROM afs.models m CROSS JOIN cfg WHERE (cfg.service_access = 'all' OR m.enabled) AND afs.provider_enabled('bedrock')
), subjects AS (
  SELECT a.team_id, 'agent'::text AS subject_kind, a.id AS subject_id, a.model_access, a.default_model_id, a.default_route
    FROM afs.agents a WHERE a.deleted_at IS NULL AND a.state <> 'deleted'
  UNION ALL
  SELECT p.team_id, 'pool', p.id, p.model_access, p.default_model_id, p.default_route
    FROM afs.agent_pools p WHERE p.deleted_at IS NULL AND p.state <> 'deleted'
)
SELECT s.team_id, s.subject_kind, s.subject_id, m.id AS model_id, (m.id = s.default_model_id AND s.default_route IS NULL) AS is_default
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
         CASE WHEN NOT afs.provider_enabled('bedrock') THEN 'provider_disabled'
              WHEN NOT (cfg.service_access = 'all' OR m.enabled) THEN 'model_not_enabled_for_service'
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

-- 8. Settings: the service default model may be a route model (section 7.4.1) ------------------------------------------
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_models_check;
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_models_check CHECK (
  (key NOT IN ('models.service_access', 'models.default_team_access')
   OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') IN ('all', 'selected')))
  AND (key <> 'models.default_team_models' OR afs.model_id_list_ok(value))
  AND (key <> 'models.default_model_id' OR jsonb_typeof(value) = 'null'
       OR (jsonb_typeof(value) = 'string' AND length(value #>> '{}') BETWEEN 1 AND 240))
) NOT VALID;
ALTER TABLE afs.service_settings VALIDATE CONSTRAINT service_settings_models_check;

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
    -- A Bedrock model id, or <route>/<model> naming a model of a service endpoint (000023).
    IF NOT EXISTS (SELECT 1 FROM afs.models x WHERE x.id = NEW.value #>> '{}')
       AND NOT EXISTS (SELECT 1 FROM afs.model_endpoints e JOIN afs.endpoint_models em ON em.endpoint_id = e.id
                        WHERE e.team_id IS NULL AND e.slug = afs.route_model_slug(NEW.value #>> '{}')
                          AND em.model_name = afs.route_model_name(NEW.value #>> '{}')) THEN
      RAISE EXCEPTION 'model % does not exist', NEW.value #>> '{}'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'service_settings_models_check';
    END IF;
    -- While Bedrock is off the default stays a usable route model.
    IF NOT afs.provider_enabled('bedrock') AND NOT afs.fallback_route_ok(NEW.value #>> '{}', 'bedrock') THEN
      RAISE EXCEPTION 'Bedrock is off: the service default model must be a route model on an enabled endpoint and provider, selected for every team'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'no_fallback_model';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- 9. Usage and cost (section 7.4.5) ---------------------------------------------------------------------------------------
ALTER TABLE afs.usage_events
  ADD COLUMN endpoint_id text,
  ADD COLUMN model_name text CHECK (length(model_name) BETWEEN 1 AND 200),
  ADD COLUMN usage_source text CHECK (usage_source IN ('response', 'estimated', 'provider_cost')),
  ADD COLUMN reasoning_tokens bigint CHECK (reasoning_tokens >= 0),
  ADD COLUMN ttft_ms integer CHECK (ttft_ms >= 0),
  ADD COLUMN upstream_ms integer CHECK (upstream_ms >= 0),
  ADD COLUMN gateway_ms integer CHECK (gateway_ms >= 0),
  ADD COLUMN http_status smallint CHECK (http_status BETWEEN 100 AND 599);
ALTER TABLE afs.usage_events ALTER COLUMN model_id DROP NOT NULL;
ALTER TABLE afs.usage_events ADD CONSTRAINT usage_events_route_check
  CHECK ((model_id IS NULL) <> (endpoint_id IS NULL) OR outcome <> 'ok') NOT VALID;
ALTER TABLE afs.usage_events VALIDATE CONSTRAINT usage_events_route_check;
COMMENT ON COLUMN afs.usage_events.endpoint_id IS 'Route calls: the model endpoint (model_id is NULL). NULL for Bedrock calls.';
COMMENT ON COLUMN afs.usage_events.model_name IS 'Route calls: the model name sent on the route.';
COMMENT ON COLUMN afs.usage_events.usage_source IS 'response (usage in the response), estimated (settled to the reservation), provider_cost (the provider''s own cost was larger).';

ALTER TABLE afs.cost_daily DROP CONSTRAINT cost_daily_source_check;
ALTER TABLE afs.cost_daily ADD CONSTRAINT cost_daily_source_check
  CHECK (source IN ('gateway', 'cur_bedrock', 'cur_eks', 'cur_other', 'route', 'route_capacity')) NOT VALID;
ALTER TABLE afs.cost_daily VALIDATE CONSTRAINT cost_daily_source_check;
COMMENT ON COLUMN afs.cost_daily.model_id IS 'Bedrock model id; for sources route and route_capacity, <route>/<model> (route_capacity may name the route alone).';

-- 10. Row-level security, grants, revisions and change feed (section 7.4.6) ---------------------------------------------
ALTER TABLE afs.model_endpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.endpoint_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.endpoint_model_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.endpoint_price_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.endpoint_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.endpoint_federations ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.endpoint_capacity_costs ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.team_model_endpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.agent_model_endpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.pool_model_endpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE afs.provider_statements ENABLE ROW LEVEL SECURITY;

-- Service rows are read by every caller and written by service admins; team rows by the team.
CREATE POLICY app_read ON afs.model_endpoints FOR SELECT TO afs_app USING (team_id IS NULL OR afs.caller_sees_team(team_id));
CREATE POLICY app_write ON afs.model_endpoints TO afs_app USING (afs.caller_owns_scope(team_id)) WITH CHECK (afs.caller_owns_scope(team_id));
CREATE POLICY app_read ON afs.endpoint_models FOR SELECT TO afs_app USING (team_id IS NULL OR afs.caller_sees_team(team_id));
CREATE POLICY app_write ON afs.endpoint_models TO afs_app USING (afs.caller_owns_scope(team_id)) WITH CHECK (afs.caller_owns_scope(team_id));
-- Prices and proposals: read like the endpoint, written by service admins only.
CREATE POLICY app_read ON afs.endpoint_model_prices FOR SELECT TO afs_app USING (team_id IS NULL OR afs.caller_sees_team(team_id));
CREATE POLICY app_write ON afs.endpoint_model_prices TO afs_app USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY app_read ON afs.endpoint_price_proposals FOR SELECT TO afs_app USING (team_id IS NULL OR afs.caller_sees_team(team_id));
CREATE POLICY app_write ON afs.endpoint_price_proposals TO afs_app USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
-- Credentials: a team's own, or _shared for service admins.
CREATE POLICY app_team_scope ON afs.endpoint_credentials TO afs_app USING (afs.caller_owns_scope(team_id)) WITH CHECK (afs.caller_owns_scope(team_id));
-- Federations and capacity costs: the team reads, service admins write.
CREATE POLICY app_team_scope ON afs.endpoint_federations FOR SELECT TO afs_app USING (afs.caller_sees_team(team_id));
CREATE POLICY app_admin_insert ON afs.endpoint_federations FOR INSERT TO afs_app WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY app_admin_update ON afs.endpoint_federations FOR UPDATE TO afs_app USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY app_admin_delete ON afs.endpoint_federations FOR DELETE TO afs_app USING (afs.caller_is_service_admin());
CREATE POLICY app_team_scope ON afs.endpoint_capacity_costs FOR SELECT TO afs_app USING (afs.caller_sees_team(team_id));
CREATE POLICY app_admin_insert ON afs.endpoint_capacity_costs FOR INSERT TO afs_app WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY app_admin_update ON afs.endpoint_capacity_costs FOR UPDATE TO afs_app USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY app_admin_delete ON afs.endpoint_capacity_costs FOR DELETE TO afs_app USING (afs.caller_is_service_admin());
CREATE POLICY app_team_scope ON afs.team_model_endpoints TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY app_team_scope ON afs.agent_model_endpoints TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY app_team_scope ON afs.pool_model_endpoints TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
-- Statements name every team's spend: service admins only.
CREATE POLICY app_admin_all ON afs.provider_statements TO afs_app USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['model_endpoints', 'endpoint_models', 'endpoint_model_prices', 'endpoint_price_proposals',
                           'endpoint_credentials', 'endpoint_federations', 'endpoint_capacity_costs', 'team_model_endpoints',
                           'agent_model_endpoints', 'pool_model_endpoints', 'provider_statements'] LOOP
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_billing, afs_readonly, afs_reconciler USING (true) WITH CHECK (true)', t);
    IF t <> 'provider_statements' THEN
      EXECUTE format('CREATE POLICY gateway_team_scope ON afs.%I TO afs_gateway USING (afs.gateway_sees_team(team_id)) WITH CHECK (afs.gateway_sees_team(team_id))', t);
    END IF;
  END LOOP;
END $$;

-- afs_app
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.model_endpoints, afs.endpoint_models, afs.endpoint_credentials,
  afs.endpoint_federations, afs.endpoint_capacity_costs TO afs_app;
GRANT SELECT, INSERT ON afs.endpoint_model_prices, afs.provider_statements TO afs_app;
GRANT SELECT ON afs.endpoint_price_proposals TO afs_app;
GRANT UPDATE (state, note) ON afs.endpoint_price_proposals TO afs_app;
GRANT SELECT, INSERT, DELETE ON afs.team_model_endpoints, afs.agent_model_endpoints, afs.pool_model_endpoints TO afs_app;
GRANT SELECT ON afs.inference_providers TO afs_app;
GRANT INSERT (provider, display_name, hosts, enabled, team_selection, disabled_reason) ON afs.inference_providers TO afs_app;
GRANT UPDATE (enabled, team_selection, disabled_reason, fallback_model) ON afs.inference_providers TO afs_app;
-- afs_gateway: every table except provider_statements; federation status.
GRANT SELECT ON afs.inference_providers, afs.model_endpoints, afs.endpoint_models, afs.endpoint_model_prices,
  afs.endpoint_price_proposals, afs.endpoint_credentials, afs.endpoint_federations, afs.endpoint_capacity_costs,
  afs.team_model_endpoints, afs.agent_model_endpoints, afs.pool_model_endpoints TO afs_gateway;
GRANT UPDATE (status, last_error, checked_at) ON afs.endpoint_federations TO afs_gateway;
-- afs_reconciler and afs_readonly: read everything; the reconciler records credential status.
GRANT SELECT ON afs.inference_providers, afs.model_endpoints, afs.endpoint_models, afs.endpoint_model_prices,
  afs.endpoint_price_proposals, afs.endpoint_credentials, afs.endpoint_federations, afs.endpoint_capacity_costs,
  afs.team_model_endpoints, afs.agent_model_endpoints, afs.pool_model_endpoints, afs.provider_statements
  TO afs_reconciler, afs_readonly;
GRANT UPDATE (status) ON afs.endpoint_credentials TO afs_reconciler;
-- afs_billing: what reconciliation and price proposals need.
GRANT SELECT ON afs.model_endpoints, afs.endpoint_models, afs.endpoint_model_prices, afs.endpoint_capacity_costs,
  afs.provider_statements, afs.endpoint_federations, afs.endpoint_price_proposals TO afs_billing;
GRANT INSERT ON afs.endpoint_price_proposals TO afs_billing;
GRANT UPDATE (state, note) ON afs.endpoint_price_proposals TO afs_billing;
-- Views.
GRANT SELECT ON afs.effective_agent_routes TO afs_app, afs_reconciler, afs_gateway, afs_readonly;

-- Revisions: composite keys get a readable resource id.
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
                WHEN 'inference_providers' THEN rec ->> 'provider'
                WHEN 'endpoint_models' THEN concat_ws('/', rec ->> 'endpoint_id', rec ->> 'model_name')
                WHEN 'endpoint_credentials' THEN concat_ws('/', rec ->> 'endpoint_id', rec ->> 'scope')
                WHEN 'endpoint_federations' THEN concat_ws('/', rec ->> 'endpoint_id', rec ->> 'team_id')
                WHEN 'endpoint_capacity_costs' THEN concat_ws('/', rec ->> 'endpoint_id', rec ->> 'team_id', rec ->> 'effective_from')
                WHEN 'team_model_endpoints' THEN concat_ws('/', rec ->> 'team_id', rec ->> 'endpoint_id')
                WHEN 'agent_model_endpoints' THEN concat_ws('/', rec ->> 'team_id', rec ->> 'agent_id', rec ->> 'endpoint_id')
                WHEN 'pool_model_endpoints' THEN concat_ws('/', rec ->> 'team_id', rec ->> 'pool_id', rec ->> 'endpoint_id')
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

-- Change feed: <table>:<team_id>:<id>; inference_providers sends the provider, endpoint children the endpoint id.
CREATE OR REPLACE FUNCTION afs.notify_desired_state() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
DECLARE
  j jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
BEGIN
  PERFORM pg_notify('afs_desired_state',
    TG_TABLE_NAME || ':' || coalesce(CASE WHEN TG_TABLE_NAME = 'teams' THEN j->>'id' ELSE j->>'team_id' END, '')
                  || ':' || coalesce(j->>'id', CASE WHEN TG_TABLE_NAME = 'inference_providers' THEN j->>'provider' END,
                                     j->>'endpoint_id', ''));
  RETURN NULL;
END $$;

-- Touch: version and updated_at; status written by the gateway or reconciler does not bump the version.
CREATE TRIGGER inference_providers_revision AFTER INSERT OR UPDATE OR DELETE ON afs.inference_providers
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER model_endpoints_touch BEFORE UPDATE ON afs.model_endpoints FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER endpoint_models_touch BEFORE UPDATE ON afs.endpoint_models FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER endpoint_capacity_costs_touch BEFORE UPDATE ON afs.endpoint_capacity_costs FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER endpoint_credentials_touch BEFORE UPDATE ON afs.endpoint_credentials
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row_runner_exempt('status');
CREATE TRIGGER endpoint_federations_touch BEFORE UPDATE ON afs.endpoint_federations
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row_runner_exempt('status', 'last_error', 'checked_at');

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['model_endpoints', 'endpoint_models', 'endpoint_credentials', 'endpoint_federations',
                           'endpoint_capacity_costs', 'team_model_endpoints', 'agent_model_endpoints', 'pool_model_endpoints'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON afs.%I FOR EACH ROW EXECUTE FUNCTION afs.record_revision()',
                   t || '_revision', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['inference_providers', 'model_endpoints', 'endpoint_models', 'endpoint_model_prices',
                           'endpoint_price_proposals', 'endpoint_credentials', 'endpoint_federations', 'endpoint_capacity_costs',
                           'team_model_endpoints', 'agent_model_endpoints', 'pool_model_endpoints', 'provider_statements'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON afs.%I FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state()',
                   t || '_notify', t);
  END LOOP;
END $$;
