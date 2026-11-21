-- 000015: gaps found while proving the PRD's acceptance criteria (spec 261121-db-feature-complete).
--
-- 1. Service-level notification channels hold no secret reference (DB-US-34). The (team_id, secret_id)
--    foreign key is MATCH SIMPLE, so with team_id NULL it is not checked: a service-level channel could
--    name any team's secret, or one that does not exist, and that team could not delete its secret's
--    row without knowing. Secrets are always team-owned, so a service-level channel carries none.
-- 2. afs.teams_due_for_teardown lists only teams whose rule has fired (DB-US-13). It returned every
--    active ephemeral team, with a NULL reason when nothing was due.
-- 3. cost_reconciliations.status is derived (DB-US-26): 'over_threshold' when the gateway estimate is
--    more than service setting billing.variance_alert_pct away from the billed cost, 'missing_billing'
--    when nothing was billed for a day the gateway metered, else 'ok'. The value the billing job writes
--    is replaced at insert and update; rows written earlier keep their status.
-- 4. api_keys.created_at is the real creation time (DB-US-27). The 90-day expiry CHECK compares
--    expires_at with created_at, which a caller could set, so a key could live for years. created_at is
--    now set to now() on insert and cannot change on update (55000).
--
-- Lock impact: notification_channels and api_keys take a brief ACCESS EXCLUSIVE lock for ADD CONSTRAINT
-- NOT VALID and CREATE TRIGGER (SHARE ROW EXCLUSIVE); the VALIDATE that follows holds SHARE UPDATE
-- EXCLUSIVE, which does not block writes. cost_reconciliations takes SHARE ROW EXCLUSIVE for its
-- trigger. The view is replaced in place (ACCESS EXCLUSIVE on the view only). All four tables are small
-- configuration or per-team-day tables; nothing is rewritten.

-- 1. Service-level channels -----------------------------------------------------------------------
ALTER TABLE afs.notification_channels
  ADD CONSTRAINT notification_channels_service_no_secret CHECK (team_id IS NOT NULL OR secret_id IS NULL) NOT VALID;
ALTER TABLE afs.notification_channels VALIDATE CONSTRAINT notification_channels_service_no_secret;

-- 2. Teams due for teardown -----------------------------------------------------------------------
CREATE OR REPLACE VIEW afs.teams_due_for_teardown WITH (security_invoker = true) AS
SELECT d.team_id, d.teardown_rule, d.reason
FROM (
  SELECT t.id AS team_id, t.teardown_rule,
         CASE
           WHEN t.expires_at <= now() THEN 'expired'
           WHEN t.teardown_rule = 'at_cap_or_expiry' AND p.spent_usd >= p.limit_usd THEN 'cap_reached'
           WHEN t.teardown_rule = 'at_work_complete'
                AND EXISTS (SELECT 1 FROM afs.work_orders w WHERE w.team_id = t.id AND w.status IN ('done', 'cancelled'))
                AND NOT EXISTS (SELECT 1 FROM afs.work_orders w WHERE w.team_id = t.id
                                AND w.status NOT IN ('done', 'failed', 'cancelled')) THEN 'work_complete'
         END AS reason
  FROM afs.teams t
  LEFT JOIN afs.team_budget_position p ON p.team_id = t.id
  WHERE t.kind = 'ephemeral' AND t.state = 'active'
) d
WHERE d.reason IS NOT NULL;

-- 3. Reconciliation status ------------------------------------------------------------------------
-- SECURITY DEFINER so afs_billing need not read service_settings; it reads one documented key.
CREATE FUNCTION afs.cost_reconciliation_status() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  v_threshold numeric := coalesce(
    (SELECT (value #>> '{}')::numeric FROM afs.service_settings WHERE key = 'billing.variance_alert_pct'), 5);
BEGIN
  NEW.status := CASE
    WHEN NEW.billed_usd = 0 THEN CASE WHEN NEW.gateway_usd = 0 THEN 'ok' ELSE 'missing_billing' END
    WHEN abs((NEW.gateway_usd - NEW.billed_usd) / NEW.billed_usd * 100) > v_threshold THEN 'over_threshold'
    ELSE 'ok'
  END;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION afs.cost_reconciliation_status() FROM PUBLIC;
CREATE TRIGGER cost_reconciliations_status BEFORE INSERT OR UPDATE ON afs.cost_reconciliations
  FOR EACH ROW EXECUTE FUNCTION afs.cost_reconciliation_status();

-- 4. API key creation time ------------------------------------------------------------------------
CREATE FUNCTION afs.api_key_created_at_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at := now();
  ELSIF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'api key % created_at cannot change', OLD.id USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER api_keys_created_at_guard BEFORE INSERT OR UPDATE OF created_at ON afs.api_keys
  FOR EACH ROW EXECUTE FUNCTION afs.api_key_created_at_guard();
