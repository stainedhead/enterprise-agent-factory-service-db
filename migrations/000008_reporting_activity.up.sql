-- 000008 reporting: agent activity (working or idle), traffic to external systems, and rollups for
-- service, team and agent reports.
--
-- Reports answer four questions at the service, team (namespace) and agent levels: spend against
-- budget, usage (calls and tokens), cost by Bedrock model, and whether agents are working or idle.
-- Spend and usage come from the gateway's metering (afs.usage_events, rolled up daily into
-- afs.cost_daily with source 'gateway') and are reconciled daily against CUR (sources 'cur_*').
--
-- Activity is new. Every five minutes the reconciler's activity collector writes one sample per agent
-- (afs.agent_activity): the agent's state in that window and what it did. An agent is *working* in a
-- window when it made a model call through the gateway, reported itself busy on its status endpoint, or
-- used more CPU than the idle threshold; it is *idle* when it is running and did none of these. Paused,
-- stopped, unhealthy and budget-blocked windows are recorded as such and count as neither.
--
-- External traffic is new too. Every five minutes the collector writes, per agent and destination host,
-- the connections the agent's egress policy allowed or denied, with bytes each way. It comes from the
-- Cilium flow logs (Hubble), which see every connection and the DNS name it was for; request and error
-- counts are filled only where an egress proxy sees HTTP (NULL otherwise). Denied connections record
-- why: the system is off at the service, team or agent level, or the host is in no system the agent
-- can see. Denied attempts are a security signal and are kept like any other flow.
--
-- Decision: ADR-011 in the root repository (J's PRD review, 2026-11-21).
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.cost_daily to add a column with a constant default (no
-- rewrite). New tables only otherwise.

-- 1. Calls in the daily rollup ------------------------------------------------------------------
ALTER TABLE afs.cost_daily
  ADD COLUMN calls bigint NOT NULL DEFAULT 0 CONSTRAINT cost_daily_calls_check CHECK (calls >= 0);

COMMENT ON COLUMN afs.cost_daily.calls IS 'Model calls in the day (gateway source only; 0 for CUR rows).';

-- 2. Agent activity samples, five-minute windows, partitioned by month ---------------------------
CREATE TABLE afs.agent_activity (
  bucket_start        timestamptz NOT NULL
                        CHECK (extract(epoch FROM bucket_start)::bigint % 300 = 0),
  team_id             text NOT NULL,
  agent_id            text NOT NULL,
  state               text NOT NULL
                        CHECK (state IN ('working', 'idle', 'paused', 'stopped', 'unhealthy', 'blocked_budget')),
  -- Seconds of the window the agent was doing work (0 when idle; up to 300).
  active_seconds      smallint NOT NULL DEFAULT 0 CHECK (active_seconds BETWEEN 0 AND 300),
  model_calls         integer NOT NULL DEFAULT 0 CHECK (model_calls >= 0),
  input_tokens        bigint NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
  output_tokens       bigint NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
  cost_usd            numeric(14, 6) NOT NULL DEFAULT 0 CHECK (cost_usd >= 0),
  cpu_millicores_avg  integer CHECK (cpu_millicores_avg >= 0),
  memory_mib_avg      integer CHECK (memory_mib_avg >= 0),
  -- What the agent reported it was doing, when it reports (e.g. "reviewing PR 482"). Not a secret.
  activity_note       text CHECK (length(activity_note) <= 200),
  recorded_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (state = 'working' OR active_seconds = 0),
  CHECK (state = 'working' OR model_calls = 0),
  PRIMARY KEY (bucket_start, agent_id)
) PARTITION BY RANGE (bucket_start);

CREATE TABLE afs.agent_activity_default PARTITION OF afs.agent_activity DEFAULT;
CREATE INDEX agent_activity_team_time_idx ON afs.agent_activity (team_id, bucket_start);
CREATE INDEX agent_activity_agent_working_idx ON afs.agent_activity (agent_id, bucket_start DESC)
  WHERE state = 'working';

-- Samples outlive the agent row for reporting, so there is no foreign key to afs.agents (as with
-- afs.usage_events). The collector writes only agents it found in afs.agents.

CREATE FUNCTION afs.ensure_activity_partition(p_month date) RETURNS text
  LANGUAGE plpgsql AS $$
DECLARE
  start_ts date := date_trunc('month', p_month)::date;
  name text := format('agent_activity_%s', to_char(start_ts, 'YYYYMM'));
BEGIN
  IF to_regclass('afs.' || name) IS NULL THEN
    EXECUTE format('CREATE TABLE afs.%I PARTITION OF afs.agent_activity FOR VALUES FROM (%L) TO (%L)',
                   name, start_ts, (start_ts + interval '1 month')::date);
  END IF;
  RETURN name;
END
$$;

-- 3. Report views -------------------------------------------------------------------------------
-- Daily activity per agent: time in each state and utilization (working share of running time).
CREATE VIEW afs.agent_activity_daily WITH (security_invoker = true) AS
SELECT team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date AS day,
       count(*) FILTER (WHERE state = 'working') * 300 AS working_seconds,
       count(*) FILTER (WHERE state = 'idle') * 300 AS idle_seconds,
       count(*) FILTER (WHERE state IN ('paused', 'stopped')) * 300 AS off_seconds,
       count(*) FILTER (WHERE state IN ('unhealthy', 'blocked_budget')) * 300 AS impaired_seconds,
       sum(active_seconds) AS active_seconds,
       sum(model_calls) AS model_calls,
       sum(input_tokens) AS input_tokens,
       sum(output_tokens) AS output_tokens,
       sum(cost_usd) AS cost_usd,
       round(100.0 * count(*) FILTER (WHERE state = 'working')
             / nullif(count(*) FILTER (WHERE state IN ('working', 'idle')), 0), 1) AS utilization_pct
FROM afs.agent_activity
GROUP BY team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date;

-- Current state per agent and, when idle, since when (the end of its last working window).
CREATE VIEW afs.agent_activity_current WITH (security_invoker = true) AS
SELECT a.team_id, a.id AS agent_id, l.state, l.bucket_start AS last_sample_at, l.activity_note,
       w.last_working_at,
       CASE WHEN l.state = 'idle' THEN coalesce(w.last_working_at + interval '5 minutes', a.created_at) END AS idle_since
FROM afs.agents a
LEFT JOIN LATERAL (SELECT s.state, s.bucket_start, s.activity_note FROM afs.agent_activity s
                   WHERE s.agent_id = a.id ORDER BY s.bucket_start DESC LIMIT 1) l ON true
LEFT JOIN LATERAL (SELECT max(s.bucket_start) AS last_working_at FROM afs.agent_activity s
                   WHERE s.agent_id = a.id AND s.state = 'working') w ON true;

-- Budget position per team for the current period: limit, spent, reserved and percentage used.
CREATE VIEW afs.team_budget_position WITH (security_invoker = true) AS
SELECT b.team_id, b.id AS budget_id, b.period, b.amount_usd, c.period_start, c.limit_usd,
       c.spent_usd, c.reserved_usd,
       round(100 * c.spent_usd / c.limit_usd, 1) AS used_pct
FROM afs.budgets b
JOIN LATERAL (SELECT * FROM afs.spend_counters s WHERE s.budget_id = b.id
              ORDER BY s.period_start DESC LIMIT 1) c ON true;

-- 4. Traffic to external systems, five-minute windows, partitioned by month ----------------------
CREATE TABLE afs.external_traffic (
  bucket_start   timestamptz NOT NULL CHECK (extract(epoch FROM bucket_start)::bigint % 300 = 0),
  team_id        text NOT NULL,
  agent_id       text NOT NULL,
  -- The catalog or team system the host belongs to; NULL when it matches none the agent can see.
  system_id      text,
  host           text NOT NULL
                   CHECK (host ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  port           integer NOT NULL DEFAULT 443 CHECK (port BETWEEN 1 AND 65535),
  verdict        text NOT NULL CHECK (verdict IN ('allowed', 'denied')),
  denied_reason  text CHECK (denied_reason IN ('system_off_service', 'system_off_team', 'system_off_agent',
                                               'not_in_catalog')),
  connections    integer NOT NULL DEFAULT 0 CHECK (connections >= 0),
  -- HTTP requests and errors (5xx, resets, TLS failures), only where an egress proxy sees them.
  requests       integer CHECK (requests >= 0),
  errors         integer CHECK (errors >= 0),
  bytes_out      bigint NOT NULL DEFAULT 0 CHECK (bytes_out >= 0),
  bytes_in       bigint NOT NULL DEFAULT 0 CHECK (bytes_in >= 0),
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((verdict = 'denied') = (denied_reason IS NOT NULL)),
  CHECK (denied_reason <> 'not_in_catalog' OR system_id IS NULL),
  PRIMARY KEY (bucket_start, agent_id, host, port, verdict)
) PARTITION BY RANGE (bucket_start);

CREATE TABLE afs.external_traffic_default PARTITION OF afs.external_traffic DEFAULT;
CREATE INDEX external_traffic_team_time_idx ON afs.external_traffic (team_id, bucket_start);
CREATE INDEX external_traffic_denied_idx ON afs.external_traffic (team_id, bucket_start) WHERE verdict = 'denied';

CREATE FUNCTION afs.ensure_traffic_partition(p_month date) RETURNS text
  LANGUAGE plpgsql AS $$
DECLARE
  start_ts date := date_trunc('month', p_month)::date;
  name text := format('external_traffic_%s', to_char(start_ts, 'YYYYMM'));
BEGIN
  IF to_regclass('afs.' || name) IS NULL THEN
    EXECUTE format('CREATE TABLE afs.%I PARTITION OF afs.external_traffic FOR VALUES FROM (%L) TO (%L)',
                   name, start_ts, (start_ts + interval '1 month')::date);
  END IF;
  RETURN name;
END
$$;

-- Daily traffic per agent and system (or host, for hosts in no system).
CREATE VIEW afs.external_traffic_daily WITH (security_invoker = true) AS
SELECT team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date AS day, system_id,
       CASE WHEN system_id IS NULL THEN host END AS unmatched_host,
       sum(connections) FILTER (WHERE verdict = 'allowed') AS connections,
       sum(requests) FILTER (WHERE verdict = 'allowed') AS requests,
       sum(errors) FILTER (WHERE verdict = 'allowed') AS errors,
       sum(bytes_out) AS bytes_out,
       sum(bytes_in) AS bytes_in,
       coalesce(sum(connections) FILTER (WHERE verdict = 'denied'), 0) AS denied_connections,
       array_agg(DISTINCT denied_reason) FILTER (WHERE denied_reason IS NOT NULL) AS denied_reasons
FROM afs.external_traffic
GROUP BY team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date, system_id,
         CASE WHEN system_id IS NULL THEN host END;

-- 5. Privileges and row-level security ----------------------------------------------------------
GRANT SELECT ON afs.agent_activity, afs.agent_activity_daily, afs.agent_activity_current,
  afs.team_budget_position TO afs_app, afs_reconciler, afs_billing, afs_readonly;
GRANT SELECT ON afs.external_traffic, afs.external_traffic_daily TO afs_app, afs_reconciler, afs_readonly;
GRANT INSERT, UPDATE ON afs.agent_activity, afs.external_traffic TO afs_reconciler;
GRANT EXECUTE ON FUNCTION afs.ensure_activity_partition(date), afs.ensure_traffic_partition(date) TO afs_reconciler;
-- The views read budgets and spend counters, which the billing role reports on.
GRANT SELECT ON afs.budgets, afs.spend_counters TO afs_billing;

ALTER TABLE afs.agent_activity ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.agent_activity TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.agent_activity TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

ALTER TABLE afs.external_traffic ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.external_traffic TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.external_traffic TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
