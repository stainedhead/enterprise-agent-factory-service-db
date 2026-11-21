-- Reverses 000016. Down migrations are for local use and tests.

DROP POLICY app_operator_work_order_events ON afs.outbox_events;
DROP POLICY app_own_audit ON afs.audit_log;
REVOKE UPDATE (state, deleted_at) ON afs.agent_pools FROM afs_reconciler;
DROP FUNCTION afs.instantiate_work_order_team(text);
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_work_order_team_check;
DROP FUNCTION afs.team_directory();
DROP FUNCTION afs.resolve_workload(text, text);
DROP FUNCTION afs.authenticate_api_key(bytea);
DROP FUNCTION afs.new_id(text);
