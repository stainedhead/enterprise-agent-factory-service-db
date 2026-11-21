-- Reverses 000015. Down migrations are for local use and tests.

-- 4. API key creation time
DROP TRIGGER api_keys_created_at_guard ON afs.api_keys;
DROP FUNCTION afs.api_key_created_at_guard();

-- 3. Reconciliation status
DROP TRIGGER cost_reconciliations_status ON afs.cost_reconciliations;
DROP FUNCTION afs.cost_reconciliation_status();

-- 2. Teams due for teardown: the 000012 definition
CREATE OR REPLACE VIEW afs.teams_due_for_teardown WITH (security_invoker = true) AS
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
WHERE t.kind = 'ephemeral' AND t.state = 'active';

-- 1. Service-level channels
ALTER TABLE afs.notification_channels DROP CONSTRAINT notification_channels_service_no_secret;
