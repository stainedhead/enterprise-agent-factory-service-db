-- Local and test use only. Production migrations are forward-only.
ALTER TABLE afs.agents
  ADD COLUMN env jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(env) = 'object');

UPDATE afs.agents a
SET env = coalesce((SELECT jsonb_object_agg(v.name, v.config_value) FROM afs.agent_config_values v
                    WHERE v.agent_id = a.id AND v.source = 'literal'), '{}');

DROP TRIGGER IF EXISTS agent_secret_bindings_config_clash ON afs.agent_secret_bindings;
DROP FUNCTION IF EXISTS afs.binding_config_clash();

DROP VIEW IF EXISTS afs.agent_config_resolved;
DROP TABLE IF EXISTS afs.agent_config_values;
DROP TABLE IF EXISTS afs.namespace_config_values;

DROP FUNCTION IF EXISTS afs.agent_config_guard();
DROP FUNCTION IF EXISTS afs.namespace_config_in_use();
DROP FUNCTION IF EXISTS afs.config_name_ok(text);
