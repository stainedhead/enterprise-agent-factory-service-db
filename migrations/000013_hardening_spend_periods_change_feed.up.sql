-- 000013: database hardening and runtime support found in the PRD review (root D30, D31, D33, D34,
-- D35, D36, D45).
--
-- Hardening (D35). The database refuses, for afs-api callers who are not service admins:
--   * changes to a team's ceiling, quotas or temporary ceiling override (team_guardrail_guard);
--   * writes to the service catalog and settings (service_settings, models, model_prices,
--     storage_classes) and to a team's enabled models (team_models);
--   * service-level role bindings (service_admin, security_operator), and bindings on teams the caller
--     is not bound to;
--   * writes to another person's user row.
-- A ceiling can no longer drop below the team's current budget, whoever sets it.
--
-- Budget exhaustion (D33). Only service admins may choose notify-only for a budget, and never for an
-- ephemeral team, which always blocks at the cap.
--
-- Temporary ceiling raise (D34, root D5). teams.ceiling_override_usd with an expiry; while unexpired it
-- is the team's ceiling. The reconciler clears it at expiry (after lowering any budget above the base
-- ceiling).
--
-- Spend periods and reservations (D31). afs.ensure_spend_counter opens a budget period on demand, so a
-- new month never blocks a team. Reservations can now be held as rows with an expiry
-- (afs.reserve_spend_held / afs.settle_reservation), and afs.release_expired_reservations returns the
-- reserved amount of a gateway that died between reserve and settle. The 000001 functions stay.
--
-- Change feed (D30). Every desired-state table (the ones with a revision trigger) notifies channel
-- afs_desired_state with '<table>:<team_id>:<id>' after a change; the reconciler listens.
--
-- Retention (D36). afs.drop_partitions_older_than(months) drops monthly partitions of usage_events,
-- agent_activity and external_traffic older than the given number of whole months. The partition
-- functions become SECURITY DEFINER so the reconciler, which does not own the tables, can run them.
--
-- Gateway reservations need a worst case when a request has no max tokens (D28):
-- models.max_output_tokens.
--
-- Settings (D45): reports.idle_cpu_millicores, egress.denied_spike_threshold,
-- gateway.reservation_ttl_seconds, api.cors_origins.
--
-- Lock impact: brief ACCESS EXCLUSIVE on teams, models, service_settings, storage_classes, model_prices,
-- team_models, users and role_bindings to add columns (nullable), enable row-level security, add
-- policies and triggers. No table rewrite. spend_reservations is new.

-- 1. Settings -------------------------------------------------------------------------------------
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_runtime_check
  CHECK ((key <> 'reports.idle_cpu_millicores'
          OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 1 AND 4000))
     AND (key <> 'egress.denied_spike_threshold'
          OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 1 AND 100000))
     AND (key <> 'gateway.reservation_ttl_seconds'
          OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 60 AND 3600))
     AND (key <> 'api.cors_origins'
          OR (jsonb_typeof(value) = 'array'
              AND NOT jsonb_path_exists(value, 'strict $[*] ? (@.type() != "string" || !(@ like_regex "^https://[A-Za-z0-9.-]+(:[0-9]+)?$"))'))));
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('reports.idle_cpu_millicores', '50', 'An agent using more CPU than this in a 5-minute window counts as working.'),
  ('egress.denied_spike_threshold', '20', 'Denied connections from one agent in 5 minutes that raise egress.denied_spike.'),
  ('gateway.reservation_ttl_seconds', '900', 'A held spend reservation not settled within this time is released.'),
  ('api.cors_origins', '[]', 'Console origins (https) allowed to call the API from a browser.')
ON CONFLICT (key) DO NOTHING;

-- 2. Teams: ceiling override and guardrails -------------------------------------------------------
ALTER TABLE afs.teams
  ADD COLUMN ceiling_override_usd        numeric(12, 2),
  ADD COLUMN ceiling_override_expires_at timestamptz,
  ADD CONSTRAINT teams_ceiling_override_check
    CHECK ((ceiling_override_usd IS NULL) = (ceiling_override_expires_at IS NULL)
           AND (ceiling_override_usd IS NULL OR ceiling_override_usd > max_budget_usd));

-- The ceiling in force now: the override while it lasts, else the base ceiling.
CREATE FUNCTION afs.team_ceiling(p_team_id text) RETURNS numeric
  LANGUAGE sql STABLE SET search_path = pg_catalog, afs
  RETURN (SELECT CASE WHEN ceiling_override_usd IS NOT NULL AND ceiling_override_expires_at > now()
                      THEN ceiling_override_usd ELSE max_budget_usd END
          FROM afs.teams WHERE id = p_team_id);

CREATE OR REPLACE FUNCTION afs.check_budget_ceiling() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  ceiling numeric;
BEGIN
  ceiling := afs.team_ceiling(NEW.team_id);
  IF NEW.amount_usd > ceiling THEN
    RAISE EXCEPTION 'budget % USD exceeds team ceiling % USD', NEW.amount_usd, ceiling
      USING ERRCODE = 'check_violation', CONSTRAINT = 'budgets_amount_within_ceiling';
  END IF;
  RETURN NEW;
END
$$;

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
       OR NEW.may_manage_aws_accounts IS DISTINCT FROM OLD.may_manage_aws_accounts THEN
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
  BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems, may_manage_aws_accounts,
                   max_budget_usd, quotas, ceiling_override_usd, ceiling_override_expires_at ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

-- The reconciler clears an expired override, after lowering a budget above the base ceiling.
GRANT UPDATE (ceiling_override_usd, ceiling_override_expires_at) ON afs.teams TO afs_reconciler;
GRANT UPDATE (amount_usd) ON afs.budgets TO afs_reconciler;

-- 3. Budget exhaustion mode (D33) -----------------------------------------------------------------
CREATE FUNCTION afs.budget_exhaust_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF NEW.on_exhaust = 'notify' THEN
    IF (SELECT kind FROM afs.teams WHERE id = NEW.team_id) = 'ephemeral' THEN
      RAISE EXCEPTION 'an ephemeral team''s budget always blocks at the cap'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'budgets_ephemeral_blocks';
    END IF;
    IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
       AND (TG_OP = 'INSERT' OR OLD.on_exhaust <> 'notify') THEN
      RAISE EXCEPTION 'only service admins choose notify-only for a budget'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER budgets_exhaust_guard BEFORE INSERT OR UPDATE OF on_exhaust, team_id ON afs.budgets
  FOR EACH ROW EXECUTE FUNCTION afs.budget_exhaust_guard();

-- 4. Service catalog, settings and enabled models: service admins write ----------------------------
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['service_settings', 'models', 'model_prices', 'storage_classes'] LOOP
    EXECUTE format('ALTER TABLE afs.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY app_read ON afs.%I FOR SELECT TO afs_app USING (true)', t);
    EXECUTE format('CREATE POLICY app_write ON afs.%I TO afs_app USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin())', t);
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_reconciler, afs_gateway, afs_billing, afs_readonly USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;

-- team_models keeps its team scope for reads; writes also need a service admin (restrictive).
CREATE POLICY app_admin_insert ON afs.team_models AS RESTRICTIVE FOR INSERT TO afs_app
  WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY app_admin_update ON afs.team_models AS RESTRICTIVE FOR UPDATE TO afs_app
  USING (afs.caller_is_service_admin());
CREATE POLICY app_admin_delete ON afs.team_models AS RESTRICTIVE FOR DELETE TO afs_app
  USING (afs.caller_is_service_admin());

-- 5. Users and role bindings ----------------------------------------------------------------------
-- Everyone signed in may read users (names on members and audit pages); a person changes only their own
-- row. Sign-in sets afs.actor to the person's id (generated first for a new person) before writing it.
ALTER TABLE afs.users ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.users FOR SELECT TO afs_app USING (true);
CREATE POLICY app_write ON afs.users TO afs_app
  USING (id = afs.current_actor() OR afs.caller_is_service_admin())
  WITH CHECK (id = afs.current_actor() OR afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.users TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

-- Bindings are read before the caller's scope is known, so reads stay open. Writes: service-level roles
-- by service admins only; team roles only on teams the caller is bound to.
ALTER TABLE afs.role_bindings ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.role_bindings FOR SELECT TO afs_app USING (true);
CREATE POLICY app_write ON afs.role_bindings TO afs_app
  USING (CASE WHEN team_id IS NULL THEN afs.caller_is_service_admin() ELSE afs.caller_sees_team(team_id) END)
  WITH CHECK (CASE WHEN team_id IS NULL THEN afs.caller_is_service_admin() ELSE afs.caller_sees_team(team_id) END);
CREATE POLICY service_roles_all ON afs.role_bindings TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

-- 6. Spend periods and held reservations (D31) ----------------------------------------------------
ALTER TABLE afs.models ADD COLUMN max_output_tokens integer CHECK (max_output_tokens > 0);

-- Opens the period for a budget if it is not open yet, with the budget's amount as its limit.
-- Returns the period's limit. The gateway calls it before reserving; the reconciler at period start.
CREATE FUNCTION afs.ensure_spend_counter(p_budget_id text, p_period_start timestamptz) RETURNS numeric
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  v_limit numeric;
BEGIN
  INSERT INTO afs.spend_counters (budget_id, period_start, limit_usd)
  SELECT id, p_period_start, amount_usd FROM afs.budgets WHERE id = p_budget_id
  ON CONFLICT (budget_id, period_start) DO NOTHING;
  SELECT limit_usd INTO v_limit FROM afs.spend_counters
   WHERE budget_id = p_budget_id AND period_start = p_period_start;
  IF v_limit IS NULL THEN
    RAISE EXCEPTION 'no budget %', p_budget_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN v_limit;
END $$;

CREATE TABLE afs.spend_reservations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  budget_id    text NOT NULL,
  period_start timestamptz NOT NULL,
  amount_usd   numeric(14, 6) NOT NULL CHECK (amount_usd > 0),
  -- The gateway pod holding it, for troubleshooting.
  holder       text NOT NULL CHECK (length(holder) BETWEEN 1 AND 253),
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  CHECK (expires_at > created_at),
  FOREIGN KEY (budget_id, period_start) REFERENCES afs.spend_counters (budget_id, period_start) ON DELETE CASCADE
);
CREATE INDEX spend_reservations_expiry_idx ON afs.spend_reservations (expires_at);

-- Reserves like afs.reserve_spend and records the hold. Returns its id, or NULL when it does not fit.
CREATE FUNCTION afs.reserve_spend_held(p_budget_id text, p_period_start timestamptz, p_amount numeric,
                                       p_holder text) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  v_id uuid;
  v_ttl int := coalesce((SELECT (value #>> '{}')::int FROM afs.service_settings
                         WHERE key = 'gateway.reservation_ttl_seconds'), 900);
BEGIN
  IF NOT afs.reserve_spend(p_budget_id, p_period_start, p_amount) THEN
    RETURN NULL;
  END IF;
  INSERT INTO afs.spend_reservations (budget_id, period_start, amount_usd, holder, expires_at)
  VALUES (p_budget_id, p_period_start, p_amount, p_holder, now() + make_interval(secs => v_ttl))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Settles a held reservation with the actual cost and returns true. If the hold was already released
-- (it expired, or was settled before), it returns false and still adds the actual cost to the period
-- named by the caller, so a call that outlives the TTL is never lost from spend.
CREATE FUNCTION afs.settle_reservation(p_id uuid, p_budget_id text, p_period_start timestamptz,
                                       p_actual numeric) RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  r afs.spend_reservations;
BEGIN
  DELETE FROM afs.spend_reservations WHERE id = p_id RETURNING * INTO r;
  IF r.id IS NULL THEN
    PERFORM afs.settle_spend(p_budget_id, p_period_start, 0, p_actual);
    RETURN false;
  END IF;
  IF r.budget_id <> p_budget_id OR r.period_start <> p_period_start THEN
    RAISE EXCEPTION 'reservation % belongs to another budget period', p_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  PERFORM afs.settle_spend(r.budget_id, r.period_start, r.amount_usd, p_actual);
  RETURN true;
END $$;

-- Releases reservations past their expiry; returns how many. The reconciler runs it every minute.
CREATE FUNCTION afs.release_expired_reservations() RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  n bigint := 0;
  r record;
BEGIN
  FOR r IN DELETE FROM afs.spend_reservations WHERE expires_at <= now() RETURNING * LOOP
    PERFORM afs.settle_spend(r.budget_id, r.period_start, r.amount_usd, 0);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION afs.ensure_spend_counter(text, timestamptz),
  afs.reserve_spend_held(text, timestamptz, numeric, text), afs.settle_reservation(uuid, text, timestamptz, numeric),
  afs.release_expired_reservations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.ensure_spend_counter(text, timestamptz) TO afs_gateway, afs_reconciler;
GRANT EXECUTE ON FUNCTION afs.reserve_spend_held(text, timestamptz, numeric, text),
  afs.settle_reservation(uuid, text, timestamptz, numeric) TO afs_gateway;
GRANT EXECUTE ON FUNCTION afs.release_expired_reservations() TO afs_reconciler;
GRANT SELECT ON afs.spend_reservations TO afs_reconciler, afs_readonly;

-- 7. Change feed (D30) ----------------------------------------------------------------------------
CREATE FUNCTION afs.notify_desired_state() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
DECLARE
  j jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
BEGIN
  PERFORM pg_notify('afs_desired_state',
    TG_TABLE_NAME || ':' || coalesce(CASE WHEN TG_TABLE_NAME = 'teams' THEN j->>'id' ELSE j->>'team_id' END, '')
                  || ':' || coalesce(j->>'id', ''));
  RETURN NULL;
END $$;

DO $$
DECLARE
  t text;
BEGIN
  FOR t IN
    SELECT DISTINCT c.relname FROM pg_trigger tr
      JOIN pg_class c ON c.oid = tr.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'afs' AND tr.tgname LIKE '%revision' AND NOT tr.tgisinternal
  LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON afs.%I FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state()',
                   t || '_notify', t);
  END LOOP;
END $$;

-- 8. Retention (D36) ------------------------------------------------------------------------------
ALTER FUNCTION afs.ensure_usage_partition(date) SECURITY DEFINER SET search_path = pg_catalog, afs;
ALTER FUNCTION afs.ensure_activity_partition(date) SECURITY DEFINER SET search_path = pg_catalog, afs;
ALTER FUNCTION afs.ensure_traffic_partition(date) SECURITY DEFINER SET search_path = pg_catalog, afs;

-- Drops monthly partitions of the fact tables whose month ended more than p_months whole months ago.
-- Returns the names dropped.
CREATE FUNCTION afs.drop_partitions_older_than(p_months integer) RETURNS SETOF text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  r record;
  v_cutoff date := (date_trunc('month', now()) - make_interval(months => p_months))::date;
BEGIN
  IF p_months < 1 THEN
    RAISE EXCEPTION 'keep at least one month' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  FOR r IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace n ON n.oid = p.relnamespace
     WHERE n.nspname = 'afs' AND p.relname IN ('usage_events', 'agent_activity', 'external_traffic')
       AND c.relname ~ '_[0-9]{6}$'
       AND to_date(right(c.relname, 6), 'YYYYMM') < v_cutoff
     ORDER BY 1
  LOOP
    EXECUTE format('DROP TABLE afs.%I', r.relname);
    RETURN NEXT r.relname;
  END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION afs.drop_partitions_older_than(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.drop_partitions_older_than(integer) TO afs_reconciler;
