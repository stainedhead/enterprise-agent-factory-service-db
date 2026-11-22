-- 000018: follow-ups from the -restapi integration (X-DB-8, X-DB-9, X-DB-10) and two gaps found with them.
--
-- 1. X-DB-9. A full index on afs.agent_activity (agent_id, bucket_start). The agent activity report reads
--    one agent over a range in any state; the only agent index was partial (state = 'working').
-- 2. X-DB-8. Daily rollups of agent activity and external traffic, so the service-wide activity and
--    traffic reports over 90 days read one row per group and day instead of scanning the five-minute
--    tables (about 6 s at 200 agents). Real tables filled by afs.rollup_reports_daily(from, to), a
--    SECURITY DEFINER function the reconciler calls; afs.rollup_reports_recent(days) is its usual form.
--    The grain keeps what the reports group by: day, team, agent or pool, and the tag set. Tables, not
--    materialized views, because (a) REFRESH MATERIALIZED VIEW recomputes the whole 90-day range every
--    time, while the function recomputes only the days asked for; (b) a non-concurrent refresh takes
--    ACCESS EXCLUSIVE and a concurrent one needs a unique index and still rewrites the range; (c) a
--    materialized view cannot carry row-level security, so team scoping would need a wrapper view and
--    would be one more place to get wrong. The function is idempotent (delete the days, insert them
--    again, in one transaction under an advisory lock), so a late sample or a missed run is fixed by
--    running it again; readers see the old rows until the transaction commits.
-- 3. agent_secret_bindings gets the revision trigger and the change-feed trigger every other
--    desired-state table has, so "restore revision" can rebuild bindings and the reconciler hears about
--    a binding change. The table has no id, so afs.record_revision() keys its revisions
--    '<team_id>/<agent_id>/<target>' (before this, the key would have been the bare team id). Bindings
--    hold references and a target name, never a secret value.
-- 4. X-DB-10. afs_billing may read afs.service_settings (key, value) for the price list sync setting
--    and afs.team_models (team_id, model_id, inference_profile_arn) for inference-profile attribution.
-- 5. Report schedule run state no longer bumps version. A scheduled run writes last_run_at,
--    last_status, last_error and next_run_at; touch_row() bumped version and updated_at each time, so
--    every client ETag went stale after every run. A new trigger function skips the bump when the
--    update changes only those columns. Any other change, mixed or not, and an update that changes
--    nothing, bump as before. Revision and change-feed triggers still fire on every update.
--
-- Lock impact: (1) CREATE INDEX on a partitioned table takes SHARE on afs.agent_activity and each of
-- its partitions for the build, which blocks the collector's writes for its duration (seconds at 200
-- agents; run in a quiet window on a large installation). (2) New tables and functions only. (3) SHARE
-- ROW EXCLUSIVE on agent_secret_bindings for CREATE TRIGGER (a short lock; no rewrite); record_revision
-- is replaced in place. (4) GRANT changes the catalog only. (5) SHARE ROW EXCLUSIVE on report_schedules
-- to replace its trigger. Nothing is rewritten.

-- 1. Agent activity by agent ------------------------------------------------------------------------
CREATE INDEX agent_activity_agent_time_idx ON afs.agent_activity (agent_id, bucket_start);

-- 2. Daily rollups ----------------------------------------------------------------------------------
-- One row per day, team, subject (an agent, or a pool's workers) and tag set. Samples written with no
-- tag set form their own group (tag_set_id NULL). A report sums rows to the level it shows, exactly as
-- it sums the five-minute tables; utilization is 100 * working / (working + idle) over those sums.
CREATE TABLE afs.agent_activity_rollup_daily (
  day               date NOT NULL,
  team_id           text NOT NULL,
  agent_id          text,
  pool_id           text,
  tag_set_id        text,
  working_seconds   bigint NOT NULL CHECK (working_seconds >= 0),
  idle_seconds      bigint NOT NULL CHECK (idle_seconds >= 0),
  off_seconds       bigint NOT NULL CHECK (off_seconds >= 0),
  impaired_seconds  bigint NOT NULL CHECK (impaired_seconds >= 0),
  active_seconds    bigint NOT NULL CHECK (active_seconds >= 0),
  model_calls       bigint NOT NULL CHECK (model_calls >= 0),
  input_tokens      bigint NOT NULL CHECK (input_tokens >= 0),
  output_tokens     bigint NOT NULL CHECK (output_tokens >= 0),
  cost_usd          numeric(18, 6) NOT NULL CHECK (cost_usd >= 0),
  -- Distinct worker pods of the pool in this group (0 for an agent). Across tag sets it is a per-group
  -- count: take the maximum, not the sum.
  workers           integer NOT NULL DEFAULT 0 CHECK (workers >= 0),
  rolled_up_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((agent_id IS NOT NULL AND pool_id IS NULL) OR (agent_id IS NULL AND pool_id IS NOT NULL))
);
CREATE UNIQUE INDEX agent_activity_rollup_daily_uq
  ON afs.agent_activity_rollup_daily (day, team_id, agent_id, pool_id, tag_set_id) NULLS NOT DISTINCT;
CREATE INDEX agent_activity_rollup_daily_team_idx ON afs.agent_activity_rollup_daily (team_id, day);
CREATE INDEX agent_activity_rollup_daily_agent_idx ON afs.agent_activity_rollup_daily (agent_id, day)
  WHERE agent_id IS NOT NULL;

COMMENT ON TABLE afs.agent_activity_rollup_daily IS
  'Daily rollup of afs.agent_activity (UTC days), filled by afs.rollup_reports_daily; same figures as afs.agent_activity_daily.';

-- One row per day, team, subject, system (or unmatched host) and tag set.
CREATE TABLE afs.external_traffic_rollup_daily (
  day                 date NOT NULL,
  team_id             text NOT NULL,
  agent_id            text,
  pool_id             text,
  system_id           text,
  unmatched_host      text,
  tag_set_id          text,
  connections         bigint NOT NULL CHECK (connections >= 0),
  -- NULL when no egress proxy saw HTTP for the group (as in afs.external_traffic_daily).
  requests            bigint CHECK (requests >= 0),
  errors              bigint CHECK (errors >= 0),
  bytes_out           bigint NOT NULL CHECK (bytes_out >= 0),
  bytes_in            bigint NOT NULL CHECK (bytes_in >= 0),
  denied_connections  bigint NOT NULL CHECK (denied_connections >= 0),
  denied_reasons      text[],
  rolled_up_at        timestamptz NOT NULL DEFAULT now(),
  CHECK ((agent_id IS NOT NULL AND pool_id IS NULL) OR (agent_id IS NULL AND pool_id IS NOT NULL))
);
CREATE UNIQUE INDEX external_traffic_rollup_daily_uq
  ON afs.external_traffic_rollup_daily (day, team_id, agent_id, pool_id, system_id, unmatched_host, tag_set_id)
  NULLS NOT DISTINCT;
CREATE INDEX external_traffic_rollup_daily_team_idx ON afs.external_traffic_rollup_daily (team_id, day);

COMMENT ON TABLE afs.external_traffic_rollup_daily IS
  'Daily rollup of afs.external_traffic (UTC days), filled by afs.rollup_reports_daily; same figures as afs.external_traffic_daily.';

-- Recomputes both rollups for the UTC days p_from..p_to (inclusive, at most 121 days). Returns the rows
-- written. Idempotent. Run it for today and yesterday every few minutes (afs.rollup_reports_recent(2))
-- and for the last week or so once a night to pick up late samples; run it over a wider range to
-- backfill after a restore.
CREATE FUNCTION afs.rollup_reports_daily(p_from date, p_to date) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  v_lo timestamptz;
  v_hi timestamptz;
  v_rows bigint := 0;
  v_n bigint;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to OR p_to - p_from > 120 THEN
    RAISE EXCEPTION 'rollup range must be 1 to 121 days with from <= to' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('afs.rollup_reports_daily'));
  v_lo := p_from::timestamp AT TIME ZONE 'UTC';
  v_hi := (p_to + 1)::timestamp AT TIME ZONE 'UTC';

  DELETE FROM afs.agent_activity_rollup_daily WHERE day BETWEEN p_from AND p_to;
  INSERT INTO afs.agent_activity_rollup_daily
    (day, team_id, agent_id, pool_id, tag_set_id, working_seconds, idle_seconds, off_seconds, impaired_seconds,
     active_seconds, model_calls, input_tokens, output_tokens, cost_usd, workers)
  SELECT (a.bucket_start AT TIME ZONE 'UTC')::date, a.team_id, a.agent_id, a.pool_id, a.tag_set_id,
         count(*) FILTER (WHERE a.state = 'working') * 300,
         count(*) FILTER (WHERE a.state = 'idle') * 300,
         count(*) FILTER (WHERE a.state IN ('paused', 'stopped')) * 300,
         count(*) FILTER (WHERE a.state IN ('unhealthy', 'blocked_budget')) * 300,
         sum(a.active_seconds), sum(a.model_calls), sum(a.input_tokens), sum(a.output_tokens), sum(a.cost_usd),
         count(DISTINCT a.worker_pod)
    FROM afs.agent_activity a
   WHERE a.bucket_start >= v_lo AND a.bucket_start < v_hi
   GROUP BY 1, a.team_id, a.agent_id, a.pool_id, a.tag_set_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_rows := v_rows + v_n;

  DELETE FROM afs.external_traffic_rollup_daily WHERE day BETWEEN p_from AND p_to;
  INSERT INTO afs.external_traffic_rollup_daily
    (day, team_id, agent_id, pool_id, system_id, unmatched_host, tag_set_id, connections, requests, errors,
     bytes_out, bytes_in, denied_connections, denied_reasons)
  SELECT (x.bucket_start AT TIME ZONE 'UTC')::date, x.team_id, x.agent_id, x.pool_id, x.system_id,
         CASE WHEN x.system_id IS NULL THEN x.host END, x.tag_set_id,
         coalesce(sum(x.connections) FILTER (WHERE x.verdict = 'allowed'), 0),
         sum(x.requests) FILTER (WHERE x.verdict = 'allowed'),
         sum(x.errors) FILTER (WHERE x.verdict = 'allowed'),
         sum(x.bytes_out), sum(x.bytes_in),
         coalesce(sum(x.connections) FILTER (WHERE x.verdict = 'denied'), 0),
         array_agg(DISTINCT x.denied_reason) FILTER (WHERE x.denied_reason IS NOT NULL)
    FROM afs.external_traffic x
   WHERE x.bucket_start >= v_lo AND x.bucket_start < v_hi
   GROUP BY 1, x.team_id, x.agent_id, x.pool_id, x.system_id, CASE WHEN x.system_id IS NULL THEN x.host END, x.tag_set_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_rows + v_n;
END $$;

-- The last p_days UTC days including today (1 to 121).
CREATE FUNCTION afs.rollup_reports_recent(p_days integer DEFAULT 2) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'UTC')::date;
BEGIN
  IF p_days IS NULL OR p_days < 1 OR p_days > 121 THEN
    RAISE EXCEPTION 'days must be 1 to 121' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN afs.rollup_reports_daily(v_today - (p_days - 1), v_today);
END $$;

REVOKE EXECUTE ON FUNCTION afs.rollup_reports_daily(date, date), afs.rollup_reports_recent(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.rollup_reports_daily(date, date), afs.rollup_reports_recent(integer) TO afs_reconciler;

-- Read-only for every role that reads the five-minute tables; only the function writes.
GRANT SELECT ON afs.agent_activity_rollup_daily, afs.external_traffic_rollup_daily
  TO afs_app, afs_reconciler, afs_billing, afs_readonly;

ALTER TABLE afs.agent_activity_rollup_daily ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.agent_activity_rollup_daily FOR SELECT TO afs_app
  USING (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_read ON afs.agent_activity_rollup_daily FOR SELECT TO afs_reconciler, afs_billing, afs_readonly
  USING (true);

ALTER TABLE afs.external_traffic_rollup_daily ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.external_traffic_rollup_daily FOR SELECT TO afs_app
  USING (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_read ON afs.external_traffic_rollup_daily FOR SELECT TO afs_reconciler, afs_billing, afs_readonly
  USING (true);

-- 3. agent_secret_bindings revisions and change feed -------------------------------------------------
-- Tables without an id are keyed by their natural key; bindings are (team, agent, target).
CREATE OR REPLACE FUNCTION afs.record_revision() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
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

CREATE TRIGGER agent_secret_bindings_revision AFTER INSERT OR UPDATE OR DELETE ON afs.agent_secret_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER agent_secret_bindings_notify AFTER INSERT OR UPDATE OR DELETE ON afs.agent_secret_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();

-- 4. Billing reads (X-DB-10) -------------------------------------------------------------------------
GRANT SELECT (key, value) ON afs.service_settings TO afs_billing;
GRANT SELECT (team_id, model_id, inference_profile_arn) ON afs.team_models TO afs_billing;

-- 5. Report schedule run state keeps the version ----------------------------------------------------
-- Like touch_row(), but an update that changes only the columns named in the trigger arguments leaves
-- version and updated_at alone. Anything else bumps, including an update that changes nothing.
CREATE FUNCTION afs.touch_row_runner_exempt() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_meta text[] := ARRAY['version', 'updated_at'];
  v_old jsonb := to_jsonb(OLD) - v_meta;
  v_new jsonb := to_jsonb(NEW) - v_meta;
BEGIN
  IF v_old <> v_new AND v_old - TG_ARGV = v_new - TG_ARGV THEN
    NEW.version := OLD.version;
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER report_schedules_touch ON afs.report_schedules;
CREATE TRIGGER report_schedules_touch BEFORE UPDATE ON afs.report_schedules
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row_runner_exempt('last_run_at', 'last_status', 'last_error', 'next_run_at');
