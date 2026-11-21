-- 000011 tag snapshots; scheduled reports; isolation tier; idempotency keys.
--
-- From J's answers on 2026-11-21:
--
-- Tags as they were. Spend, activity and traffic roll up by the tags in effect when they happened,
-- not by a team's current tags. Writers stamp each usage, cost, activity and traffic row with a tag
-- set: an immutable, per-team snapshot of the team's service and team tags (system tags are not in
-- the set; team_id and agent_id are already columns). afs.current_team_tag_set(team) returns the id
-- of the team's tags now, creating the set on first use. CUR rows use the tags AWS billed with.
-- The *_by_tag views of 000010 are rebuilt on the snapshots.
--
-- Scheduled reports. Team-admins schedule their team's reports, delivered only to the team's own
-- notification channels (enforced by a composite foreign key). Viewers run reports on demand.
--
-- Isolation tier. A team runs on the shared node pool or a dedicated one. Only service admins set it.
-- Dedicated nodes carry the team's tags, so their cost reaches the team through CUR split cost
-- allocation (cur_eks rows).
--
-- Idempotency keys. A create retried with the same Idempotency-Key by the same caller returns the
-- first result while the key lives: service setting api.idempotency_key_ttl_seconds, default 3600.
--
-- Agent sign-ins to external systems (OPS-4) go to the team's log delivery only; no table.
--
-- Swarms, pools, ephemeral teardown and work orders follow in 000012.
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.teams (column with a constant default, no rewrite),
-- afs.usage_events, afs.agent_activity, afs.external_traffic (nullable column, no rewrite) and
-- afs.cost_daily (nullable column; its unique index is rebuilt, which is quick while the table is
-- small, as it is before the first release).

-- 1. Tag sets -------------------------------------------------------------------------------------
CREATE FUNCTION afs.tags_ok(p_tags jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN jsonb_typeof(p_tags) = 'object'
     AND NOT EXISTS (SELECT 1 FROM jsonb_each(p_tags) e
                     WHERE jsonb_typeof(e.value) <> 'string'
                        OR NOT afs.tag_key_ok(e.key) OR NOT afs.tag_value_ok(e.value #>> '{}'))
     AND (SELECT count(*) FROM jsonb_object_keys(p_tags)) <= 45;

-- id = 'ts_' || md5(team_id || ':' || tags::text). jsonb's text form is canonical (keys sorted),
-- so the same tags always give the same id.
CREATE TABLE afs.tag_sets (
  id         text PRIMARY KEY CHECK (id ~ '^ts_[0-9a-f]{32}$'),
  team_id    text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  tags       jsonb NOT NULL CHECK (afs.tags_ok(tags)),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, id),
  CHECK (id = 'ts_' || md5(team_id || ':' || tags::text))
);
COMMENT ON TABLE afs.tag_sets IS
  'Immutable snapshots of a team''s service and team tags, stamped on usage, cost, activity and traffic rows.';

CREATE FUNCTION afs.tag_set_immutable() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'tag sets are immutable' USING ERRCODE = 'object_not_in_prerequisite_state';
END;
$$;
CREATE TRIGGER tag_sets_immutable BEFORE UPDATE ON afs.tag_sets
  FOR EACH ROW EXECUTE FUNCTION afs.tag_set_immutable();

-- The id of a team's tag set for p_tags, creating it on first use.
CREATE FUNCTION afs.tag_set_for(p_team_id text, p_tags jsonb) RETURNS text
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
DECLARE
  v_id text := 'ts_' || md5(p_team_id || ':' || p_tags::text);
BEGIN
  INSERT INTO afs.tag_sets (id, team_id, tags) VALUES (v_id, p_team_id, p_tags)
  ON CONFLICT (id) DO NOTHING;
  RETURN v_id;
END;
$$;

-- The id of the team's tags as they are now (service and team tags with a value; no system tags).
CREATE FUNCTION afs.current_team_tag_set(p_team_id text) RETURNS text
  LANGUAGE sql SET search_path = pg_catalog, afs
  RETURN afs.tag_set_for(p_team_id,
           coalesce((SELECT jsonb_object_agg(e.key, e.value)
                     FROM afs.team_effective_tags e
                     WHERE e.team_id = p_team_id AND e.source <> 'system' AND e.value IS NOT NULL),
                    '{}'::jsonb));

ALTER TABLE afs.tag_sets ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.tag_sets TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.tag_sets TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
GRANT SELECT ON afs.tag_sets TO afs_app, afs_readonly;
GRANT SELECT, INSERT ON afs.tag_sets TO afs_reconciler, afs_gateway, afs_billing;
GRANT EXECUTE ON FUNCTION afs.tag_set_for(text, jsonb), afs.current_team_tag_set(text)
  TO afs_reconciler, afs_gateway, afs_billing;
REVOKE EXECUTE ON FUNCTION afs.tag_set_for(text, jsonb), afs.current_team_tag_set(text) FROM PUBLIC;

-- 2. Stamp the facts ------------------------------------------------------------------------------
-- NULL on rows written before this migration (none in production) and on CUR rows AWS billed with no
-- tags; those count as untagged.
ALTER TABLE afs.usage_events   ADD COLUMN tag_set_id text;
ALTER TABLE afs.agent_activity ADD COLUMN tag_set_id text;
ALTER TABLE afs.external_traffic ADD COLUMN tag_set_id text;
ALTER TABLE afs.cost_daily     ADD COLUMN tag_set_id text;
COMMENT ON COLUMN afs.usage_events.tag_set_id IS 'The team''s tags when the call was made (afs.tag_sets).';
COMMENT ON COLUMN afs.cost_daily.tag_set_id IS
  'Tags in effect for this spend: the gateway''s tag set, or the set built from the CUR line''s tags.';

-- Same team only. The ledgers keep no foreign key to teams (append-only, partitioned), so a check
-- trigger is used in place of a composite foreign key.
CREATE FUNCTION afs.tag_set_same_team() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF NEW.tag_set_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM afs.tag_sets s WHERE s.id = NEW.tag_set_id AND s.team_id = NEW.team_id) THEN
    RAISE EXCEPTION 'tag set % does not belong to team %', NEW.tag_set_id, NEW.team_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER usage_events_tag_set BEFORE INSERT OR UPDATE OF tag_set_id ON afs.usage_events
  FOR EACH ROW EXECUTE FUNCTION afs.tag_set_same_team();
CREATE TRIGGER agent_activity_tag_set BEFORE INSERT OR UPDATE OF tag_set_id ON afs.agent_activity
  FOR EACH ROW EXECUTE FUNCTION afs.tag_set_same_team();
CREATE TRIGGER external_traffic_tag_set BEFORE INSERT OR UPDATE OF tag_set_id ON afs.external_traffic
  FOR EACH ROW EXECUTE FUNCTION afs.tag_set_same_team();
ALTER TABLE afs.cost_daily ADD CONSTRAINT cost_daily_tag_set_fk
  FOREIGN KEY (team_id, tag_set_id) REFERENCES afs.tag_sets (team_id, id);

-- A tag change part way through a day splits that day's rows by tag set.
DROP INDEX afs.cost_daily_uq;
CREATE UNIQUE INDEX cost_daily_uq
  ON afs.cost_daily (team_id, day, source, agent_id, model_id, tag_set_id) NULLS NOT DISTINCT;

-- 3. Rollups by the tags in effect at the time ------------------------------------------------------
-- For each row: the keys in its tag set, plus each currently required key it lacks (value NULL), so
-- reports show (untagged) for that key. Same columns as 000010.
CREATE FUNCTION afs.tag_set_pairs(p_tag_set_id text) RETURNS TABLE (key text, value text)
  LANGUAGE sql STABLE SET search_path = pg_catalog, afs AS $$
  SELECT e.key, e.value
  FROM afs.tag_sets s, jsonb_each_text(s.tags) e
  WHERE s.id = p_tag_set_id
  UNION ALL
  SELECT st.key, NULL
  FROM afs.service_tags st
  WHERE st.mode = 'required'
    AND NOT EXISTS (SELECT 1 FROM afs.tag_sets s WHERE s.id = p_tag_set_id AND s.tags ? st.key)
$$;
GRANT EXECUTE ON FUNCTION afs.tag_set_pairs(text) TO afs_app, afs_reconciler, afs_billing, afs_readonly;

DROP VIEW afs.cost_daily_by_tag, afs.agent_activity_daily_by_tag, afs.external_traffic_daily_by_tag;

CREATE VIEW afs.cost_daily_by_tag WITH (security_invoker = true) AS
SELECT c.day, p.key AS tag_key, p.value AS tag_value, c.source, c.model_id,
       count(DISTINCT c.team_id) AS teams,
       sum(c.calls) AS calls, sum(c.input_tokens) AS input_tokens, sum(c.output_tokens) AS output_tokens,
       sum(c.cost_usd) AS cost_usd
FROM afs.cost_daily c
CROSS JOIN LATERAL afs.tag_set_pairs(c.tag_set_id) p
GROUP BY c.day, p.key, p.value, c.source, c.model_id;

CREATE VIEW afs.agent_activity_daily_by_tag WITH (security_invoker = true) AS
SELECT (a.bucket_start AT TIME ZONE 'UTC')::date AS day, p.key AS tag_key, p.value AS tag_value,
       count(DISTINCT a.agent_id) AS agents,
       count(*) FILTER (WHERE a.state = 'working') * 300 AS working_seconds,
       count(*) FILTER (WHERE a.state = 'idle') * 300 AS idle_seconds,
       sum(a.model_calls) AS model_calls, sum(a.cost_usd) AS cost_usd,
       round(100.0 * count(*) FILTER (WHERE a.state = 'working')
             / nullif(count(*) FILTER (WHERE a.state IN ('working', 'idle')), 0), 1) AS utilization_pct
FROM afs.agent_activity a
CROSS JOIN LATERAL afs.tag_set_pairs(a.tag_set_id) p
GROUP BY (a.bucket_start AT TIME ZONE 'UTC')::date, p.key, p.value;

-- Traffic is counts and bytes. AFS knows no price for an external service, so there is no cost here.
CREATE VIEW afs.external_traffic_daily_by_tag WITH (security_invoker = true) AS
SELECT (x.bucket_start AT TIME ZONE 'UTC')::date AS day, p.key AS tag_key, p.value AS tag_value, x.system_id,
       sum(x.connections) FILTER (WHERE x.verdict = 'allowed') AS connections,
       sum(x.requests) FILTER (WHERE x.verdict = 'allowed') AS requests,
       sum(x.errors) FILTER (WHERE x.verdict = 'allowed') AS errors,
       sum(x.bytes_out) AS bytes_out, sum(x.bytes_in) AS bytes_in,
       coalesce(sum(x.connections) FILTER (WHERE x.verdict = 'denied'), 0) AS denied_connections
FROM afs.external_traffic x
CROSS JOIN LATERAL afs.tag_set_pairs(x.tag_set_id) p
GROUP BY (x.bucket_start AT TIME ZONE 'UTC')::date, p.key, p.value, x.system_id;

GRANT SELECT ON afs.cost_daily_by_tag, afs.agent_activity_daily_by_tag, afs.external_traffic_daily_by_tag
  TO afs_app, afs_reconciler, afs_billing, afs_readonly;

-- 4. Scheduled reports ----------------------------------------------------------------------------
ALTER TABLE afs.notification_channels ADD CONSTRAINT notification_channels_team_id_uq UNIQUE (team_id, id);

CREATE TABLE afs.report_schedules (
  id          text PRIMARY KEY CHECK (afs.ulid_ok(id, 'rsc')),
  team_id     text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  report      text NOT NULL CHECK (report IN ('usage', 'costs', 'activity', 'traffic')),
  -- The report's query parameters as the API takes them (range, groupBy, filters).
  query       jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(query) = 'object'),
  cadence     text NOT NULL CHECK (cadence IN ('daily', 'weekly', 'monthly')),
  -- A notification channel of the same team (service-level channels have team_id NULL and never match).
  channel_id  text NOT NULL,
  format      text NOT NULL DEFAULT 'csv' CHECK (format = 'csv'),
  enabled     boolean NOT NULL DEFAULT true,
  next_run_at timestamptz NOT NULL,
  last_run_at timestamptz,
  last_status text CHECK (last_status IN ('sent', 'failed')),
  last_error  text CHECK (length(last_error) <= 500),
  version     bigint NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, name),
  UNIQUE (team_id, id),
  FOREIGN KEY (team_id, channel_id) REFERENCES afs.notification_channels (team_id, id) ON DELETE RESTRICT
);
CREATE INDEX report_schedules_due_idx ON afs.report_schedules (next_run_at) WHERE enabled;
CREATE TRIGGER report_schedules_touch BEFORE UPDATE ON afs.report_schedules
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER report_schedules_revision AFTER INSERT OR UPDATE OR DELETE ON afs.report_schedules
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

ALTER TABLE afs.report_schedules ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.report_schedules TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.report_schedules TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.report_schedules TO afs_app;
GRANT SELECT ON afs.report_schedules TO afs_readonly;
-- The billing job runs due schedules and records the outcome.
GRANT SELECT, UPDATE (next_run_at, last_run_at, last_status, last_error) ON afs.report_schedules TO afs_billing;
GRANT SELECT ON afs.notification_channels TO afs_billing;

-- 5. Isolation tier -------------------------------------------------------------------------------
ALTER TABLE afs.teams ADD COLUMN isolation_tier text NOT NULL DEFAULT 'shared'
  CONSTRAINT teams_isolation_tier_check CHECK (isolation_tier IN ('shared', 'dedicated'));
COMMENT ON COLUMN afs.teams.isolation_tier IS
  'shared: the environment''s shared node pool. dedicated: a node pool for this team only. Service admins only.';

CREATE FUNCTION afs.team_isolation_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
     AND (TG_OP = 'INSERT' AND NEW.isolation_tier <> 'shared'
          OR TG_OP = 'UPDATE' AND NEW.isolation_tier IS DISTINCT FROM OLD.isolation_tier) THEN
    RAISE EXCEPTION 'only service admins set a team''s isolation tier' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER teams_isolation_guard BEFORE INSERT OR UPDATE OF isolation_tier ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_isolation_guard();

-- 6. Idempotency keys -----------------------------------------------------------------------------
CREATE TABLE afs.idempotency_keys (
  -- The caller: afs.current_actor() of the request (user or API key).
  principal       text NOT NULL,
  key             text NOT NULL CHECK (key ~ '^[\x21-\x7e]+$' AND length(key) <= 255),
  team_id         text REFERENCES afs.teams (id) ON DELETE CASCADE,
  operation       text NOT NULL CHECK (operation ~ '^[A-Z][A-Za-z]+$'),
  request_sha256  bytea NOT NULL CHECK (length(request_sha256) = 32),
  state           text NOT NULL DEFAULT 'in_progress' CHECK (state IN ('in_progress', 'completed')),
  response_status smallint CHECK (response_status BETWEEN 200 AND 599),
  -- The response as returned. Responses that carry a one-time secret (CreateApiKey's secretKey) are
  -- never stored; the CHECK below refuses them anywhere in the body.
  response_body   jsonb CHECK (NOT jsonb_path_exists(response_body, 'strict $.**.secretKey')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  PRIMARY KEY (principal, key),
  CHECK ((state = 'completed') = (response_status IS NOT NULL)),
  CHECK (expires_at > created_at)
);
CREATE INDEX idempotency_keys_expiry_idx ON afs.idempotency_keys (expires_at);

ALTER TABLE afs.idempotency_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_own_keys ON afs.idempotency_keys TO afs_app
  USING (principal = afs.current_actor()) WITH CHECK (principal = afs.current_actor());
CREATE POLICY service_roles_all ON afs.idempotency_keys TO afs_reconciler, afs_readonly
  USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE (state, response_status, response_body), DELETE ON afs.idempotency_keys TO afs_app;
GRANT SELECT (principal, key, expires_at), DELETE ON afs.idempotency_keys TO afs_reconciler;

-- Removes expired keys; the reconciler runs it periodically. Returns the number removed.
CREATE FUNCTION afs.purge_idempotency_keys() RETURNS bigint
  LANGUAGE sql SET search_path = pg_catalog, afs AS $$
  WITH d AS (DELETE FROM afs.idempotency_keys WHERE expires_at <= now() RETURNING 1)
  SELECT count(*) FROM d
$$;
REVOKE EXECUTE ON FUNCTION afs.purge_idempotency_keys() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.purge_idempotency_keys() TO afs_reconciler;

-- 7. Settings -------------------------------------------------------------------------------------
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_idempotency_check
  CHECK (key <> 'api.idempotency_key_ttl_seconds'
         OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 60 AND 604800));
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('api.idempotency_key_ttl_seconds', '3600',
   'How long a create retried with the same Idempotency-Key returns the first result.')
ON CONFLICT (key) DO NOTHING;
