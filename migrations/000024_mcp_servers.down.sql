-- Reverses 000024 (local use and tests only; production is forward-only).
DROP VIEW afs.effective_agent_mcp;
DROP FUNCTION afs.mcp_events_for_review(timestamptz, timestamptz, text, text, integer);
DROP FUNCTION afs.mcp_review_queue();
DROP FUNCTION afs.mcp_approver(text, text);
DROP TRIGGER teams_mcp_defaults ON afs.teams;
DROP TRIGGER teams_mcp_defaults_on_gateway ON afs.teams;
DROP FUNCTION afs.teams_mcp_defaults();
DROP FUNCTION afs.mcp_admission(text, text);
DROP FUNCTION afs.mcp_rule_specificity(text, text, text, text, jsonb, boolean);
DROP FUNCTION afs.mcp_read_only(jsonb);
DROP FUNCTION afs.rollup_mcp_usage(date);
DROP TABLE afs.mcp_usage_daily;
DROP FUNCTION afs.drop_old_mcp_event_partitions();
DROP FUNCTION afs.ensure_mcp_event_partitions(integer);
DROP TABLE afs.mcp_events;
DROP FUNCTION afs.mcp_events_capture();

DROP TRIGGER external_systems_mcp_guard ON afs.external_systems;
DROP FUNCTION afs.external_systems_mcp_guard();
DROP FUNCTION afs.mcp_governed_host(text);
DROP FUNCTION afs.mcp_host_of(text);
DELETE FROM afs.external_systems WHERE category = 'mcp';
ALTER TABLE afs.external_systems DROP CONSTRAINT external_systems_category_check;
ALTER TABLE afs.external_systems ADD CONSTRAINT external_systems_category_check
  CHECK (category IN ('dev_tools', 'collaboration', 'email', 'cloud', 'identity', 'llm', 'other'));

DROP TABLE afs.agent_federated_identities, afs.pool_federated_identities;
DROP FUNCTION afs.federated_identity_defaults();
DROP FUNCTION afs.federated_identity_guard();
DROP FUNCTION afs.mcp_capture_open();
DROP TABLE afs.mcp_query_captures;
DROP FUNCTION afs.mcp_query_captures_guard();
DROP TABLE afs.mcp_federation_states;
DROP TRIGGER mcp_primitives_auto_review ON afs.mcp_primitives;
DROP FUNCTION afs.mcp_primitives_auto_review();
DROP TABLE afs.mcp_reviews;
DROP FUNCTION afs.mcp_append_only();
DROP FUNCTION afs.claim_mcp_oauth_state(bytea);
DROP TABLE afs.mcp_oauth_states;
DROP TABLE afs.mcp_credentials;
DROP FUNCTION afs.mcp_credentials_guard();
DROP FUNCTION afs.mcp_credential_path(text, text);
DROP TABLE afs.mcp_policies;
DROP FUNCTION afs.mcp_policies_limit();
DROP TABLE afs.agent_mcp_servers, afs.pool_mcp_servers;
DROP FUNCTION afs.subject_mcp_servers_guard();
DROP FUNCTION afs.mcp_enabled_for_team(text, text);
DROP TABLE afs.team_mcp_servers;
DROP FUNCTION afs.team_mcp_servers_guard();
DROP TABLE afs.mcp_primitives;
DROP FUNCTION afs.mcp_primitives_guard();
DROP TABLE afs.mcp_hosted_specs;
DROP FUNCTION afs.mcp_copy_server_team();
DROP FUNCTION afs.mcp_env_names_ok(text[]);
DROP TABLE afs.mcp_servers;
DROP FUNCTION afs.mcp_servers_guard();
DROP FUNCTION afs.mcp_servers_slug_guard();

DELETE FROM afs.config_revisions WHERE resource_kind IN ('mcp_servers', 'mcp_hosted_specs', 'team_mcp_servers',
  'agent_mcp_servers', 'pool_mcp_servers', 'mcp_policies', 'mcp_credentials', 'agent_federated_identities',
  'pool_federated_identities');

ALTER TABLE afs.agent_pools DROP COLUMN mcp_access, DROP COLUMN mcp_mode;
ALTER TABLE afs.agents DROP COLUMN mcp_access, DROP COLUMN mcp_mode;
DROP TRIGGER teams_mcp_guardrail_guard ON afs.teams;
DROP FUNCTION afs.teams_mcp_guardrail_guard();
ALTER TABLE afs.teams DROP COLUMN may_add_mcp_servers, DROP COLUMN mcp_placement;

DROP TRIGGER service_settings_mcp_guard ON afs.service_settings;
DROP FUNCTION afs.service_settings_mcp_guard();
DROP FUNCTION afs.mcp_setting(text);
DELETE FROM afs.service_settings WHERE key IN ('mcp.enabled', 'mcp.team_server_approval', 'mcp.host_deny_list',
  'mcp.corporate_domains', 'mcp.allowed_image_registries', 'mcp.image_signature_policy', 'mcp.default_agent_mode',
  'mcp.search_limit_max', 'mcp.refresh_interval_minutes', 'mcp.limits', 'mcp.query_capture_max_days',
  'mcp.events_retention_months', 'gateway.mcp.placement_default', 'federation.allowed_audiences');
