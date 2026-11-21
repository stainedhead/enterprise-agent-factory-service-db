-- 000010 cost-allocation tags; a team's identity provider; model price sync with approval.
--
-- From J's answers on 2026-11-21:
--
-- Tags. Every AWS resource AFS creates for a team or agent, and every Bedrock call the gateway makes,
-- carries cost-allocation tags, so spend rolls up by whatever the organization cares about (AFS has no
-- access to the organization's hierarchy; tags carry it in). Three kinds:
--   * system tags, always present and not configurable by anyone: afs-team-id and afs-agent-id;
--   * service tags, defined by service admins: either *fixed* (one value for every team, for example
--     environment=prod) or *required* (every team must give a value, optionally from a list, for
--     example business-unit), with an optional default for teams that predate the key;
--   * team tags, optional, any other key a team adds for itself.
-- Reports roll cost, activity and external traffic up by tag (views *_by_tag below).
--
-- Identity providers. Service admins configure providers at service level only. When there is more
-- than one, the team's provider is chosen when the team is created or managed
-- (teams.identity_provider_id; NULL means the service default). The team-level providers of 000009
-- are replaced by this choice, and a team's group role bindings use the team's provider.
--
-- Prices. Token and model prices drive budgets, so they must stay current. The billing job reads the
-- AWS Price List daily and proposes new effective-dated prices (afs.model_price_proposals); a service
-- admin approves or rejects each. An approved proposal becomes a model_prices row, effective no
-- earlier than the approval. CUR variance is reported per team per day (cost_reconciliations, 000001)
-- against the threshold in service setting billing.variance_alert_pct.
--
-- Decision: ADR-013 in the root repository.
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.teams (nullable column, no rewrite), afs.identity_providers
-- (drop column; the table is new in 000009 and unreleased) and afs.role_bindings (trigger replaced).

-- 1. Identity provider per team -------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM afs.identity_providers WHERE team_id IS NOT NULL) THEN
    RAISE EXCEPTION 'team-level identity providers exist; move them to service level before migrating'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

DROP POLICY app_read ON afs.identity_providers;
ALTER TABLE afs.identity_providers DROP COLUMN team_id;   -- drops identity_providers_issuer_uq and the default check
CREATE UNIQUE INDEX identity_providers_issuer_uq ON afs.identity_providers (issuer_url);
ALTER TABLE afs.identity_providers
  ADD CONSTRAINT identity_providers_default_enabled CHECK (NOT is_default OR enabled);
-- Every signed-in caller needs the provider list to sign in; only service admins write (app_write).
CREATE POLICY app_read ON afs.identity_providers FOR SELECT TO afs_app USING (true);

ALTER TABLE afs.teams
  ADD COLUMN identity_provider_id text REFERENCES afs.identity_providers (id);
COMMENT ON COLUMN afs.teams.identity_provider_id IS
  'Provider the team''s people sign in with. NULL: the service default. Chosen when the team is created or managed.';

-- A team can only choose an enabled provider, and a provider in use cannot be disabled.
CREATE FUNCTION afs.team_idp_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  -- An unknown id is left to the foreign key.
  IF EXISTS (SELECT 1 FROM afs.identity_providers p WHERE p.id = NEW.identity_provider_id AND NOT p.enabled) THEN
    RAISE EXCEPTION 'identity provider % is disabled', NEW.identity_provider_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER teams_idp_guard BEFORE INSERT OR UPDATE OF identity_provider_id ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_idp_guard();

CREATE FUNCTION afs.identity_provider_in_use_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF OLD.enabled AND NOT NEW.enabled AND EXISTS (
       SELECT 1 FROM afs.teams t WHERE t.identity_provider_id = NEW.id AND t.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'identity provider % is used by a team; move the team first', NEW.id
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER identity_providers_in_use_guard BEFORE UPDATE OF enabled ON afs.identity_providers
  FOR EACH ROW EXECUTE FUNCTION afs.identity_provider_in_use_guard();

-- Group bindings: a service-level binding names the provider its group comes from (NULL: the default);
-- a team's group bindings use the team's provider and name none.
CREATE OR REPLACE FUNCTION afs.role_binding_idp_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.identity_provider_id IS NOT NULL AND NEW.team_id IS NOT NULL THEN
    RAISE EXCEPTION 'a team''s group bindings use the team''s identity provider'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

-- 2. Cost-allocation tags -------------------------------------------------------------------------
-- AWS tag rules, minus the reserved prefixes (aws:, afs-, afs:) and anything that looks like a
-- credential: tags appear in billing data and in pods, so they are never secret.
CREATE FUNCTION afs.tag_key_ok(p_key text) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p_key ~ '^[A-Za-z0-9 _.:/=+@-]{1,128}$'
     AND lower(p_key) !~ '^(aws:|afs-|afs:)'
     AND upper(p_key) !~ '(PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE.?KEY|API.?KEY|ACCESS.?KEY|CREDENTIAL)';

CREATE FUNCTION afs.tag_value_ok(p_value text) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p_value ~ '^[A-Za-z0-9 _.:/=+@-]+$' AND length(p_value) <= 256;   -- ARE repetition counts stop at 255

CREATE FUNCTION afs.tag_values_ok(p_values text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN cardinality(p_values) BETWEEN 1 AND 200
     AND NOT EXISTS (SELECT 1 FROM unnest(p_values) v WHERE v IS NULL OR NOT afs.tag_value_ok(v));

CREATE TABLE afs.service_tags (
  key            text PRIMARY KEY CHECK (afs.tag_key_ok(key)),
  -- fixed: value applies to every team. required: every team gives its own value.
  mode           text NOT NULL CHECK (mode IN ('fixed', 'required')),
  value          text CHECK (value IS NULL OR afs.tag_value_ok(value)),
  -- required only: the value a team gets until it sets its own (for teams that predate the key).
  default_value  text CHECK (default_value IS NULL OR afs.tag_value_ok(default_value)),
  -- required only: when set, a team's value must be one of these.
  allowed_values text[] CHECK (allowed_values IS NULL OR afs.tag_values_ok(allowed_values)),
  description    text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  version        bigint NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text NOT NULL DEFAULT afs.current_actor(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((mode = 'fixed') = (value IS NOT NULL)),
  CHECK (mode = 'required' OR (default_value IS NULL AND allowed_values IS NULL)),
  CHECK (default_value IS NULL OR allowed_values IS NULL OR default_value = ANY (allowed_values))
);
CREATE UNIQUE INDEX service_tags_key_ci_uq ON afs.service_tags (lower(key));

CREATE TABLE afs.team_tags (
  team_id     text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  key         text NOT NULL CHECK (afs.tag_key_ok(key)),
  value       text NOT NULL CHECK (afs.tag_value_ok(value)),
  version     bigint NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, key)
);
CREATE UNIQUE INDEX team_tags_key_ci_uq ON afs.team_tags (team_id, lower(key));

-- AWS allows 50 tags per resource. AFS keeps 5 for its own (afs-team-id, afs-agent-id and room to
-- grow), so service tags plus a team's own tags stay within 45.
CREATE FUNCTION afs.team_tag_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  s afs.service_tags;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.key IS DISTINCT FROM OLD.key THEN
    RAISE EXCEPTION 'a tag''s key cannot change; remove it and add the new key'
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO s FROM afs.service_tags WHERE lower(key) = lower(NEW.key);
  IF FOUND THEN
    IF s.key <> NEW.key THEN
      RAISE EXCEPTION 'tag key % must be spelled %', NEW.key, s.key USING ERRCODE = 'check_violation';
    END IF;
    IF s.mode = 'fixed' THEN
      RAISE EXCEPTION 'tag % is set by service admins for every team', NEW.key
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF s.allowed_values IS NOT NULL AND NOT NEW.value = ANY (s.allowed_values) THEN
      RAISE EXCEPTION 'tag % must be one of %', NEW.key, array_to_string(s.allowed_values, ', ')
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF TG_OP = 'INSERT'
        AND (SELECT count(*) FROM afs.service_tags)
            + (SELECT count(*) FROM afs.team_tags t
               WHERE t.team_id = NEW.team_id
                 AND NOT EXISTS (SELECT 1 FROM afs.service_tags x WHERE x.key = t.key)) >= 45 THEN
    RAISE EXCEPTION 'a team can carry at most 45 tags including the service''s'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER team_tags_guard BEFORE INSERT OR UPDATE ON afs.team_tags
  FOR EACH ROW EXECUTE FUNCTION afs.team_tag_guard();

-- A service key cannot become fixed while teams set it themselves, or narrow its allowed values
-- under a team's existing value.
CREATE FUNCTION afs.service_tag_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.mode = 'fixed' AND EXISTS (SELECT 1 FROM afs.team_tags t WHERE lower(t.key) = lower(NEW.key)) THEN
    RAISE EXCEPTION 'teams already set tag %; make it required, or remove their values first', NEW.key
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NEW.allowed_values IS NOT NULL AND EXISTS (
       SELECT 1 FROM afs.team_tags t WHERE t.key = NEW.key AND NOT t.value = ANY (NEW.allowed_values)) THEN
    RAISE EXCEPTION 'some teams use a value of % outside the allowed list', NEW.key
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER service_tags_guard BEFORE INSERT OR UPDATE ON afs.service_tags
  FOR EACH ROW EXECUTE FUNCTION afs.service_tag_guard();

-- A new team must give every required tag that has no default, in the same transaction; a team
-- cannot later remove one. Teams created before a key was added are reported as missing it
-- (afs.team_effective_tags, source 'missing') rather than blocked.
CREATE FUNCTION afs.team_missing_required_tags(p_team_id text, p_only_key text) RETURNS text
  LANGUAGE sql STABLE
  SET search_path = pg_catalog, afs
  RETURN (SELECT string_agg(s.key, ', ' ORDER BY s.key)
          FROM afs.service_tags s
          WHERE s.mode = 'required' AND s.default_value IS NULL
            AND (p_only_key IS NULL OR s.key = p_only_key)
            AND EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = p_team_id AND t.deleted_at IS NULL)
            AND NOT EXISTS (SELECT 1 FROM afs.team_tags x WHERE x.team_id = p_team_id AND x.key = s.key));

CREATE FUNCTION afs.team_required_tags_check() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_team    text;
  v_missing text;
BEGIN
  -- Fields are read through jsonb: the trigger serves two tables with different columns.
  IF TG_TABLE_NAME = 'teams' THEN
    v_team := to_jsonb(NEW) ->> 'id';
    v_missing := afs.team_missing_required_tags(v_team, NULL);
  ELSE
    v_team := to_jsonb(OLD) ->> 'team_id';
    v_missing := afs.team_missing_required_tags(v_team, to_jsonb(OLD) ->> 'key');
  END IF;
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'team % is missing required tags: %', v_team, v_missing
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER teams_required_tags AFTER INSERT ON afs.teams
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.team_required_tags_check();
CREATE CONSTRAINT TRIGGER team_tags_required_kept AFTER DELETE ON afs.team_tags
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.team_required_tags_check();

-- The tags each team carries, with where each came from. Required keys a team has no value for are
-- listed with value NULL and source 'missing', so reports show them as untagged.
CREATE VIEW afs.team_effective_tags WITH (security_invoker = true) AS
SELECT t.id AS team_id, 'afs-team-id'::text AS key, t.id AS value, 'system'::text AS source
FROM afs.teams t
UNION ALL
SELECT t.id, s.key, s.value, 'service'
FROM afs.teams t CROSS JOIN afs.service_tags s
WHERE s.mode = 'fixed'
UNION ALL
SELECT t.id, s.key, coalesce(tt.value, s.default_value),
       CASE WHEN tt.value IS NOT NULL THEN 'team'
            WHEN s.default_value IS NOT NULL THEN 'service_default'
            ELSE 'missing' END
FROM afs.teams t CROSS JOIN afs.service_tags s
LEFT JOIN afs.team_tags tt ON tt.team_id = t.id AND tt.key = s.key
WHERE s.mode = 'required'
UNION ALL
SELECT tt.team_id, tt.key, tt.value, 'team'
FROM afs.team_tags tt
WHERE NOT EXISTS (SELECT 1 FROM afs.service_tags s WHERE s.key = tt.key);

-- What the reconciler puts on an agent's AWS resources and pod, and the gateway sends with each of
-- the agent's Bedrock calls: the team's tags plus afs-agent-id.
CREATE VIEW afs.agent_effective_tags WITH (security_invoker = true) AS
SELECT a.team_id, a.id AS agent_id, e.key, e.value, e.source
FROM afs.agents a JOIN afs.team_effective_tags e ON e.team_id = a.team_id
WHERE e.value IS NOT NULL
UNION ALL
SELECT a.team_id, a.id, 'afs-agent-id', a.id, 'system'
FROM afs.agents a;

-- Rollups by tag. They attribute each team's figures to the team's current tags (tag changes are in
-- config_revisions and the audit log). The system key afs-team-id is left out: per-team reports
-- already cover it.
CREATE VIEW afs.cost_daily_by_tag WITH (security_invoker = true) AS
SELECT c.day, e.key AS tag_key, e.value AS tag_value, c.source, c.model_id,
       count(DISTINCT c.team_id) AS teams,
       sum(c.calls) AS calls, sum(c.input_tokens) AS input_tokens, sum(c.output_tokens) AS output_tokens,
       sum(c.cost_usd) AS cost_usd
FROM afs.cost_daily c
JOIN afs.team_effective_tags e ON e.team_id = c.team_id AND e.source <> 'system'
GROUP BY c.day, e.key, e.value, c.source, c.model_id;

CREATE VIEW afs.agent_activity_daily_by_tag WITH (security_invoker = true) AS
SELECT d.day, e.key AS tag_key, e.value AS tag_value,
       count(DISTINCT d.agent_id) AS agents,
       sum(d.working_seconds) AS working_seconds, sum(d.idle_seconds) AS idle_seconds,
       sum(d.model_calls) AS model_calls, sum(d.cost_usd) AS cost_usd,
       round(100.0 * sum(d.working_seconds) / nullif(sum(d.working_seconds) + sum(d.idle_seconds), 0), 1)
         AS utilization_pct
FROM afs.agent_activity_daily d
JOIN afs.team_effective_tags e ON e.team_id = d.team_id AND e.source <> 'system'
GROUP BY d.day, e.key, e.value;

CREATE VIEW afs.external_traffic_daily_by_tag WITH (security_invoker = true) AS
SELECT d.day, e.key AS tag_key, e.value AS tag_value, d.system_id,
       sum(d.connections) AS connections, sum(d.requests) AS requests, sum(d.errors) AS errors,
       sum(d.bytes_out) AS bytes_out, sum(d.bytes_in) AS bytes_in,
       sum(d.denied_connections) AS denied_connections
FROM afs.external_traffic_daily d
JOIN afs.team_effective_tags e ON e.team_id = d.team_id AND e.source <> 'system'
GROUP BY d.day, e.key, e.value, d.system_id;

-- 3. Model price proposals ------------------------------------------------------------------------
CREATE TABLE afs.model_price_proposals (
  id                       text PRIMARY KEY CHECK (afs.ulid_ok(id, 'mpp')),
  model_id                 text NOT NULL REFERENCES afs.models (id) ON DELETE CASCADE,
  effective_from           timestamptz NOT NULL,
  input_usd_per_mtok       numeric(12, 6) NOT NULL CHECK (input_usd_per_mtok >= 0),
  output_usd_per_mtok      numeric(12, 6) NOT NULL CHECK (output_usd_per_mtok >= 0),
  cache_read_usd_per_mtok  numeric(12, 6) NOT NULL DEFAULT 0 CHECK (cache_read_usd_per_mtok >= 0),
  cache_write_usd_per_mtok numeric(12, 6) NOT NULL DEFAULT 0 CHECK (cache_write_usd_per_mtok >= 0),
  source                   text NOT NULL DEFAULT 'aws_price_list' CHECK (source IN ('aws_price_list')),
  fetched_at               timestamptz NOT NULL DEFAULT now(),
  status                   text NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'approved', 'rejected', 'superseded')),
  note                     text NOT NULL DEFAULT '' CHECK (length(note) <= 500),
  decided_at               timestamptz,
  decided_by               text,
  CHECK ((status IN ('approved', 'rejected')) = (decided_at IS NOT NULL AND decided_by IS NOT NULL))
);
-- One open proposal per model: the billing job supersedes the old one before proposing a newer price.
CREATE UNIQUE INDEX model_price_proposals_one_pending ON afs.model_price_proposals (model_id)
  WHERE status = 'pending';

-- Only a pending proposal moves; only a service admin approves or rejects; only the billing job
-- supersedes. Approval writes the price, effective no earlier than now.
CREATE FUNCTION afs.model_price_proposal_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF OLD.status <> 'pending' THEN
    RAISE EXCEPTION 'proposal % is already %', OLD.id, OLD.status
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NEW.status IN ('approved', 'rejected') THEN
    IF current_user = 'afs_billing' OR (current_user = 'afs_app' AND NOT afs.caller_is_service_admin()) THEN
      RAISE EXCEPTION 'only service admins approve or reject prices' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.decided_at := now();
    NEW.decided_by := afs.current_actor();
  ELSIF NEW.status = 'superseded' AND current_user = 'afs_app' THEN
    RAISE EXCEPTION 'only the billing job supersedes a proposal' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER model_price_proposals_guard BEFORE UPDATE ON afs.model_price_proposals
  FOR EACH ROW EXECUTE FUNCTION afs.model_price_proposal_guard();

CREATE FUNCTION afs.model_price_proposal_apply() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  INSERT INTO afs.model_prices (model_id, effective_from, input_usd_per_mtok, output_usd_per_mtok,
                                cache_read_usd_per_mtok, cache_write_usd_per_mtok, source)
  VALUES (NEW.model_id, greatest(NEW.effective_from, now()), NEW.input_usd_per_mtok, NEW.output_usd_per_mtok,
          NEW.cache_read_usd_per_mtok, NEW.cache_write_usd_per_mtok, NEW.source);
  RETURN NULL;
END;
$$;
CREATE TRIGGER model_price_proposals_apply AFTER UPDATE OF status ON afs.model_price_proposals
  FOR EACH ROW WHEN (NEW.status = 'approved' AND OLD.status = 'pending')
  EXECUTE FUNCTION afs.model_price_proposal_apply();

-- Settings: price sync on or off, and the CUR variance that raises an alert.
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_pricing_check
  CHECK ((key <> 'pricing.price_list_sync' OR jsonb_typeof(value) = 'boolean')
     AND (key <> 'billing.variance_alert_pct'
          OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 0 AND 100)));
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('pricing.price_list_sync', 'true',
   'Billing job reads the AWS Price List daily and proposes new model prices for service admins to approve.'),
  ('billing.variance_alert_pct', '5',
   'Alert when a team''s gateway figure and its CUR figure for a day differ by more than this percent.')
ON CONFLICT (key) DO NOTHING;

-- 4. Versioning, revisions, privileges, row-level security ----------------------------------------
-- Revisions of tag rows are keyed by tag key (service_tags) or team/key (team_tags).
CREATE OR REPLACE FUNCTION afs.record_revision() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  rec jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  rid text := coalesce(rec ->> 'id', concat_ws('/', rec ->> 'team_id', rec ->> 'model_id', rec ->> 'key'));
BEGIN
  INSERT INTO afs.config_revisions (resource_kind, resource_id, team_id, operation, version, snapshot, changed_by)
  VALUES (TG_TABLE_NAME, rid,
          CASE WHEN TG_TABLE_NAME = 'teams' THEN rec ->> 'id' ELSE rec ->> 'team_id' END,
          TG_OP, (rec ->> 'version')::bigint, rec, afs.current_actor());
  RETURN NULL;
END
$$;

CREATE TRIGGER service_tags_touch BEFORE UPDATE ON afs.service_tags
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER service_tags_revision AFTER INSERT OR UPDATE OR DELETE ON afs.service_tags
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER team_tags_touch BEFORE UPDATE ON afs.team_tags
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER team_tags_revision AFTER INSERT OR UPDATE OR DELETE ON afs.team_tags
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

GRANT SELECT, INSERT, UPDATE, DELETE ON afs.service_tags, afs.team_tags TO afs_app;
GRANT SELECT ON afs.service_tags, afs.team_tags TO afs_reconciler, afs_gateway, afs_billing, afs_readonly;
GRANT SELECT ON afs.team_effective_tags, afs.agent_effective_tags
  TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;
GRANT SELECT ON afs.cost_daily_by_tag, afs.agent_activity_daily_by_tag, afs.external_traffic_daily_by_tag
  TO afs_app, afs_reconciler, afs_billing, afs_readonly;
GRANT SELECT ON afs.agent_activity, afs.external_traffic TO afs_billing;

GRANT SELECT, UPDATE (status, note) ON afs.model_price_proposals TO afs_app;
GRANT SELECT, INSERT, UPDATE (status, note) ON afs.model_price_proposals TO afs_billing;
GRANT SELECT ON afs.model_price_proposals TO afs_reconciler, afs_readonly;
GRANT SELECT ON afs.model_prices TO afs_billing;
-- An approval by afs_app writes the price row as the caller (afs_app already writes model_prices).

ALTER TABLE afs.service_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.service_tags FOR SELECT TO afs_app USING (true);
CREATE POLICY app_write ON afs.service_tags FOR ALL TO afs_app
  USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.service_tags TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

ALTER TABLE afs.team_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.team_tags TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.team_tags TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
