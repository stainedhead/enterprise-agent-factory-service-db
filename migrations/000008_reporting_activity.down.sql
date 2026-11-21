-- Local and test use only. Production migrations are forward-only.
REVOKE SELECT ON afs.budgets, afs.spend_counters FROM afs_billing;
DROP VIEW IF EXISTS afs.external_traffic_daily;
DROP TABLE IF EXISTS afs.external_traffic;
DROP FUNCTION IF EXISTS afs.ensure_traffic_partition(date);
DROP VIEW IF EXISTS afs.team_budget_position;
DROP VIEW IF EXISTS afs.agent_activity_current;
DROP VIEW IF EXISTS afs.agent_activity_daily;
DROP TABLE IF EXISTS afs.agent_activity;
DROP FUNCTION IF EXISTS afs.ensure_activity_partition(date);
ALTER TABLE afs.cost_daily DROP COLUMN calls;
