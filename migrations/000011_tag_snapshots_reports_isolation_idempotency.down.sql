-- Reverses 000011.

DELETE FROM afs.service_settings WHERE key = 'api.idempotency_key_ttl_seconds';
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_idempotency_check;

DROP FUNCTION afs.purge_idempotency_keys();
DROP TABLE afs.idempotency_keys;

DROP TRIGGER teams_isolation_guard ON afs.teams;
DROP FUNCTION afs.team_isolation_guard();
ALTER TABLE afs.teams DROP COLUMN isolation_tier;

DROP TABLE afs.report_schedules;
REVOKE SELECT ON afs.notification_channels FROM afs_billing;
ALTER TABLE afs.notification_channels DROP CONSTRAINT notification_channels_team_id_uq;

-- Rollups back to the 000010 definitions (current tags).
DROP VIEW afs.cost_daily_by_tag, afs.agent_activity_daily_by_tag, afs.external_traffic_daily_by_tag;
DROP FUNCTION afs.tag_set_pairs(text);

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

GRANT SELECT ON afs.cost_daily_by_tag, afs.agent_activity_daily_by_tag, afs.external_traffic_daily_by_tag
  TO afs_app, afs_reconciler, afs_billing, afs_readonly;

DROP INDEX afs.cost_daily_uq;
CREATE UNIQUE INDEX cost_daily_uq
  ON afs.cost_daily (team_id, day, source, agent_id, model_id) NULLS NOT DISTINCT;
ALTER TABLE afs.cost_daily DROP CONSTRAINT cost_daily_tag_set_fk;

DROP TRIGGER usage_events_tag_set ON afs.usage_events;
DROP TRIGGER agent_activity_tag_set ON afs.agent_activity;
DROP TRIGGER external_traffic_tag_set ON afs.external_traffic;
DROP FUNCTION afs.tag_set_same_team();

ALTER TABLE afs.usage_events DROP COLUMN tag_set_id;
ALTER TABLE afs.agent_activity DROP COLUMN tag_set_id;
ALTER TABLE afs.external_traffic DROP COLUMN tag_set_id;
ALTER TABLE afs.cost_daily DROP COLUMN tag_set_id;

DROP FUNCTION afs.current_team_tag_set(text);
DROP FUNCTION afs.tag_set_for(text, jsonb);
DROP TABLE afs.tag_sets;
DROP FUNCTION afs.tag_set_immutable();
DROP FUNCTION afs.tags_ok(jsonb);
