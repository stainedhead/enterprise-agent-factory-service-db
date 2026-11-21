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
--    is replaced at insert and update; rows written earlier keep their status. Both amounts must be
--    zero or more (23514), or the variance means nothing.
-- 4. api_keys.created_at is the real creation time (DB-US-27). The 90-day expiry CHECK compares
--    expires_at with created_at, which a caller could set, so a key could live for years. created_at is
--    now set to now() on insert and cannot change on update (55000).
-- 5. Agent and pool images end in a full digest, @sha256:<64 lowercase hex> (DB-US-22). The 000001 and
--    000012 checks only asked for '@sha256:' somewhere in the image, so '@sha256:abc' passed; the
--    template guard (000014) checks the full digest only for rows with a template. Rows that do not
--    match must be corrected before this migration (none exist before the first release).
--
-- Lock impact: notification_channels, cost_reconciliations, agents and agent_pools take a brief ACCESS
-- EXCLUSIVE lock for ADD CONSTRAINT ... NOT VALID; each VALIDATE that follows scans its table once under
-- SHARE UPDATE EXCLUSIVE, which does not block writes. cost_reconciliations and api_keys take SHARE ROW
-- EXCLUSIVE for CREATE TRIGGER. The view is replaced in place (ACCESS EXCLUSIVE on the view only).
-- Nothing is rewritten.

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
ALTER TABLE afs.cost_reconciliations
  ADD CONSTRAINT cost_reconciliations_amounts_check CHECK (gateway_usd >= 0 AND billed_usd >= 0) NOT VALID;
ALTER TABLE afs.cost_reconciliations VALIDATE CONSTRAINT cost_reconciliations_amounts_check;

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

-- 5. Image digests --------------------------------------------------------------------------------
ALTER TABLE afs.agents
  ADD CONSTRAINT agents_image_digest_check CHECK (image ~ '@sha256:[0-9a-f]{64}$') NOT VALID;
ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_image_digest_check;
ALTER TABLE afs.agent_pools
  ADD CONSTRAINT agent_pools_image_digest_check CHECK (image ~ '@sha256:[0-9a-f]{64}$') NOT VALID;
ALTER TABLE afs.agent_pools VALIDATE CONSTRAINT agent_pools_image_digest_check;
