-- Local and test use only. Production migrations are forward-only.
DELETE FROM afs.service_settings WHERE key IN ('pricing.price_list_sync', 'billing.variance_alert_pct');
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_pricing_check;
REVOKE SELECT ON afs.model_prices FROM afs_billing;
REVOKE SELECT ON afs.agent_activity, afs.external_traffic FROM afs_billing;
DROP TABLE IF EXISTS afs.model_price_proposals;
DROP FUNCTION IF EXISTS afs.model_price_proposal_apply();
DROP FUNCTION IF EXISTS afs.model_price_proposal_guard();

CREATE OR REPLACE FUNCTION afs.record_revision() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  rec jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  rid text := coalesce(rec ->> 'id', concat_ws('/', rec ->> 'team_id', rec ->> 'model_id'));
BEGIN
  INSERT INTO afs.config_revisions (resource_kind, resource_id, team_id, operation, version, snapshot, changed_by)
  VALUES (TG_TABLE_NAME, rid,
          CASE WHEN TG_TABLE_NAME = 'teams' THEN rec ->> 'id' ELSE rec ->> 'team_id' END,
          TG_OP, (rec ->> 'version')::bigint, rec, afs.current_actor());
  RETURN NULL;
END
$$;

DROP VIEW IF EXISTS afs.external_traffic_daily_by_tag;
DROP VIEW IF EXISTS afs.agent_activity_daily_by_tag;
DROP VIEW IF EXISTS afs.cost_daily_by_tag;
DROP VIEW IF EXISTS afs.agent_effective_tags;
DROP VIEW IF EXISTS afs.team_effective_tags;
DROP TRIGGER IF EXISTS teams_required_tags ON afs.teams;
DROP TRIGGER IF EXISTS team_tags_required_kept ON afs.team_tags;
DROP FUNCTION IF EXISTS afs.team_required_tags_check();
DROP FUNCTION IF EXISTS afs.team_missing_required_tags(text, text);
DROP TABLE IF EXISTS afs.team_tags;
DROP TABLE IF EXISTS afs.service_tags;
DROP FUNCTION IF EXISTS afs.service_tag_guard();
DROP FUNCTION IF EXISTS afs.team_tag_guard();
DROP FUNCTION IF EXISTS afs.tag_values_ok(text[]);
DROP FUNCTION IF EXISTS afs.tag_value_ok(text);
DROP FUNCTION IF EXISTS afs.tag_key_ok(text);

CREATE OR REPLACE FUNCTION afs.role_binding_idp_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.identity_provider_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM afs.identity_providers p
       WHERE p.id = NEW.identity_provider_id
         AND (p.team_id IS NULL OR p.team_id IS NOT DISTINCT FROM NEW.team_id)) THEN
    RAISE EXCEPTION 'identity provider % is not available to this binding', NEW.identity_provider_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS identity_providers_in_use_guard ON afs.identity_providers;
DROP FUNCTION IF EXISTS afs.identity_provider_in_use_guard();
DROP TRIGGER IF EXISTS teams_idp_guard ON afs.teams;
DROP FUNCTION IF EXISTS afs.team_idp_guard();
ALTER TABLE afs.teams DROP COLUMN identity_provider_id;

DROP POLICY app_read ON afs.identity_providers;
DROP INDEX afs.identity_providers_issuer_uq;
ALTER TABLE afs.identity_providers DROP CONSTRAINT identity_providers_default_enabled;
ALTER TABLE afs.identity_providers ADD COLUMN team_id text REFERENCES afs.teams (id) ON DELETE CASCADE;
ALTER TABLE afs.identity_providers ADD CHECK (NOT is_default OR (team_id IS NULL AND enabled));
CREATE UNIQUE INDEX identity_providers_issuer_uq ON afs.identity_providers (coalesce(team_id, ''), issuer_url);
CREATE POLICY app_read ON afs.identity_providers FOR SELECT TO afs_app
  USING (team_id IS NULL OR afs.caller_sees_team(team_id));
