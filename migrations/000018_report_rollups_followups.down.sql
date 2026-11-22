-- Reverses 000018. Revisions already recorded for agent_secret_bindings stay as history.

DROP TRIGGER report_schedules_touch ON afs.report_schedules;
CREATE TRIGGER report_schedules_touch BEFORE UPDATE ON afs.report_schedules
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
DROP FUNCTION afs.touch_row_runner_exempt();

REVOKE SELECT (team_id, model_id, inference_profile_arn) ON afs.team_models FROM afs_billing;
REVOKE SELECT (key, value) ON afs.service_settings FROM afs_billing;

DROP TRIGGER agent_secret_bindings_notify ON afs.agent_secret_bindings;
DROP TRIGGER agent_secret_bindings_revision ON afs.agent_secret_bindings;
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

DROP FUNCTION afs.rollup_reports_recent(integer);
DROP FUNCTION afs.rollup_reports_daily(date, date);
DROP TABLE afs.external_traffic_rollup_daily;
DROP TABLE afs.agent_activity_rollup_daily;

DROP INDEX afs.agent_activity_agent_time_idx;
