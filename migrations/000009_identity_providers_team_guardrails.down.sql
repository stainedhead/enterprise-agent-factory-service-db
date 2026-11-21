-- Local and test use only. Production migrations are forward-only.
DROP TRIGGER teams_guardrail_guard ON afs.teams;
CREATE OR REPLACE FUNCTION afs.team_guardrail_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
     AND (NEW.allowed_aws_accounts IS DISTINCT FROM OLD.allowed_aws_accounts
          OR NEW.may_add_external_systems IS DISTINCT FROM OLD.may_add_external_systems) THEN
    RAISE EXCEPTION 'only service admins change a team''s allowed AWS accounts or external-system rights'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER teams_guardrail_guard BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();
ALTER TABLE afs.teams DROP COLUMN may_manage_aws_accounts;

DROP TRIGGER IF EXISTS role_bindings_idp_guard ON afs.role_bindings;
DROP FUNCTION IF EXISTS afs.role_binding_idp_guard();
ALTER TABLE afs.role_bindings DROP COLUMN identity_provider_id;
DROP TABLE IF EXISTS afs.identity_providers;
