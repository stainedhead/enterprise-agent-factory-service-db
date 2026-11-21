-- Local and test use only. Production migrations are forward-only.
DROP TRIGGER IF EXISTS agent_secret_bindings_scope ON afs.agent_secret_bindings;
DROP FUNCTION IF EXISTS afs.binding_respects_scope();

DROP TRIGGER IF EXISTS agents_identity_immutable ON afs.agents;
DROP TRIGGER IF EXISTS teams_identity_immutable ON afs.teams;
DROP FUNCTION IF EXISTS afs.reject_identity_change();

DROP TRIGGER IF EXISTS secrets_managed_path ON afs.secrets;
DROP FUNCTION IF EXISTS afs.secrets_managed_path();

ALTER TABLE afs.secrets
  DROP CONSTRAINT secrets_arn_matches_path,
  DROP CONSTRAINT secrets_path_key,
  DROP CONSTRAINT secrets_agent_fk,
  DROP CONSTRAINT secrets_origin_check,
  ADD CONSTRAINT secrets_origin_check CHECK (origin IN ('managed', 'registered')),
  ADD CONSTRAINT secrets_team_id_name_key UNIQUE (team_id, name),
  DROP COLUMN path,
  DROP COLUMN agent_id;

DROP FUNCTION IF EXISTS afs.secret_path(text, text, text);

DELETE FROM afs.service_settings WHERE key = 'secrets.path_prefix';
ALTER TABLE afs.service_settings DROP CONSTRAINT service_settings_secrets_path_prefix_check;

ALTER TABLE afs.agents
  ADD COLUMN replicas integer NOT NULL DEFAULT 1 CHECK (replicas BETWEEN 0 AND 50);
