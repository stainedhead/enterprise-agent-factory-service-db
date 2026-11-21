-- Reverses 000013.

-- 8. Retention
DROP FUNCTION afs.drop_partitions_older_than(integer);
ALTER FUNCTION afs.ensure_usage_partition(date) SECURITY INVOKER RESET search_path;
ALTER FUNCTION afs.ensure_activity_partition(date) SECURITY INVOKER RESET search_path;
ALTER FUNCTION afs.ensure_traffic_partition(date) SECURITY INVOKER RESET search_path;

-- 7. Change feed
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT tr.tgname, c.relname FROM pg_trigger tr
      JOIN pg_class c ON c.oid = tr.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'afs' AND tr.tgname LIKE '%\_notify' AND NOT tr.tgisinternal
       AND tr.tgfoid = 'afs.notify_desired_state()'::regprocedure
  LOOP
    EXECUTE format('DROP TRIGGER %I ON afs.%I', r.tgname, r.relname);
  END LOOP;
END $$;
DROP FUNCTION afs.notify_desired_state();

-- 6. Spend periods and reservations
DROP FUNCTION afs.release_expired_reservations();
DROP FUNCTION afs.settle_reservation(uuid, numeric);
DROP FUNCTION afs.reserve_spend_held(text, timestamptz, numeric, text);
DROP FUNCTION afs.ensure_spend_counter(text, timestamptz);
DROP TABLE afs.spend_reservations;
ALTER TABLE afs.models DROP COLUMN max_output_tokens;

-- 5. Users and role bindings
DROP POLICY app_read ON afs.role_bindings;
DROP POLICY app_write ON afs.role_bindings;
DROP POLICY service_roles_all ON afs.role_bindings;
ALTER TABLE afs.role_bindings DISABLE ROW LEVEL SECURITY;
DROP POLICY app_read ON afs.users;
DROP POLICY app_write ON afs.users;
DROP POLICY service_roles_all ON afs.users;
ALTER TABLE afs.users DISABLE ROW LEVEL SECURITY;

-- 4. Service catalog and enabled models
DROP POLICY app_admin_insert ON afs.team_models;
DROP POLICY app_admin_update ON afs.team_models;
DROP POLICY app_admin_delete ON afs.team_models;
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['service_settings', 'models', 'model_prices', 'storage_classes'] LOOP
    EXECUTE format('DROP POLICY app_read ON afs.%I', t);
    EXECUTE format('DROP POLICY app_write ON afs.%I', t);
    EXECUTE format('DROP POLICY service_roles_all ON afs.%I', t);
    EXECUTE format('ALTER TABLE afs.%I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- 3. Budget exhaustion mode
DROP TRIGGER budgets_exhaust_guard ON afs.budgets;
DROP FUNCTION afs.budget_exhaust_guard();

-- 2. Teams: back to the 000009 guard and the base ceiling
REVOKE UPDATE (amount_usd) ON afs.budgets FROM afs_reconciler;
REVOKE UPDATE (ceiling_override_usd, ceiling_override_expires_at) ON afs.teams FROM afs_reconciler;

CREATE OR REPLACE FUNCTION afs.team_guardrail_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin() THEN
    IF NEW.may_add_external_systems IS DISTINCT FROM OLD.may_add_external_systems
       OR NEW.may_manage_aws_accounts IS DISTINCT FROM OLD.may_manage_aws_accounts THEN
      RAISE EXCEPTION 'only service admins decide what a team may manage itself'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.allowed_aws_accounts IS DISTINCT FROM OLD.allowed_aws_accounts AND NOT OLD.may_manage_aws_accounts THEN
      RAISE EXCEPTION 'this team''s allowed AWS accounts are managed by service admins'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER teams_guardrail_guard ON afs.teams;
CREATE TRIGGER teams_guardrail_guard
  BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems, may_manage_aws_accounts ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

CREATE OR REPLACE FUNCTION afs.check_budget_ceiling() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  ceiling numeric;
BEGIN
  SELECT max_budget_usd INTO ceiling FROM afs.teams WHERE id = NEW.team_id;
  IF NEW.amount_usd > ceiling THEN
    RAISE EXCEPTION 'budget % USD exceeds team ceiling % USD', NEW.amount_usd, ceiling
      USING ERRCODE = 'check_violation', CONSTRAINT = 'budgets_amount_within_ceiling';
  END IF;
  RETURN NEW;
END
$$;
DROP FUNCTION afs.team_ceiling(text);
ALTER TABLE afs.teams
  DROP CONSTRAINT teams_ceiling_override_check,
  DROP COLUMN ceiling_override_usd,
  DROP COLUMN ceiling_override_expires_at;

-- 1. Settings
DELETE FROM afs.service_settings
  WHERE key IN ('reports.idle_cpu_millicores', 'egress.denied_spike_threshold', 'gateway.reservation_ttl_seconds',
                'api.cors_origins');
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_runtime_check;
