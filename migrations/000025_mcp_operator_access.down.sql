-- Reverses 000025 (local use and tests only; production is forward-only).
DROP POLICY app_shared_credential_read ON afs.mcp_credentials;
DROP POLICY app_security_read ON afs.mcp_usage_daily;
DROP POLICY app_security_read ON afs.mcp_events;
DROP POLICY app_operator_mcp_events ON afs.outbox_events;
