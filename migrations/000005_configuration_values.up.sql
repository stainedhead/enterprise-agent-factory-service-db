-- 000005 non-secret configuration values: namespace (team) level and agent level.
--
-- Team-admins set named values for their team's namespace (afs.namespace_config_values), shared by the
-- team's agents. Each agent has its own list (afs.agent_config_values): every entry is either a literal
-- value or a link to the namespace value with the same name. afs.agent_config_resolved gives the
-- effective value and where it came from. The reconciler renders the resolved list into the agent's
-- ConfigMap (environment variables and files).
--
-- Configuration values are never secret. Secrets go through afs.secrets and bindings. Names that look
-- like credentials are rejected, and a configuration name cannot reuse an environment variable already
-- used by one of the agent's secret bindings.
--
-- agents.env (a free-form JSON object from 000001) is replaced: its entries become literal values here
-- and the column is dropped, so there is one mechanism.
--
-- Decision: ADR-008 in the root repository (J's PRD review, 2026-11-21).
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.agents for DROP COLUMN (catalog only). The backfill reads
-- afs.agents once; schema v1 is unreleased, so it is small.

-- Names follow environment-variable rules so they work as env vars and file names alike, and must not
-- look like credentials.
CREATE FUNCTION afs.config_name_ok(p_name text) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p_name ~ '^[A-Z][A-Z0-9_]{0,127}$'
     AND p_name !~ '(PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE_KEY|API_KEY|ACCESS_KEY|CREDENTIAL)';

-- 1. Namespace-level values (one set per team) ---------------------------------------------------
CREATE TABLE afs.namespace_config_values (
  id           text PRIMARY KEY CHECK (afs.ulid_ok(id, 'ncv')),
  team_id      text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  name         text NOT NULL CHECK (afs.config_name_ok(name)),
  config_value text NOT NULL CHECK (length(config_value) <= 4096),
  description  text NOT NULL DEFAULT '',
  version      bigint NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text NOT NULL DEFAULT afs.current_actor(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, name)
);

-- 2. Agent-level values --------------------------------------------------------------------------
CREATE TABLE afs.agent_config_values (
  id           text PRIMARY KEY CHECK (afs.ulid_ok(id, 'acv')),
  team_id      text NOT NULL,
  agent_id     text NOT NULL,
  name         text NOT NULL CHECK (afs.config_name_ok(name)),
  -- literal: config_value holds the value. namespace: use the team's namespace value of the same name.
  source       text NOT NULL CHECK (source IN ('literal', 'namespace')),
  config_value text CHECK (length(config_value) <= 4096),
  version      bigint NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text NOT NULL DEFAULT afs.current_actor(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CHECK ((source = 'literal') = (config_value IS NOT NULL)),
  UNIQUE (agent_id, name),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE
);

CREATE INDEX agent_config_values_ns_idx ON afs.agent_config_values (team_id, name) WHERE source = 'namespace';

-- Effective value per agent entry.
CREATE VIEW afs.agent_config_resolved WITH (security_invoker = true) AS
SELECT a.team_id, a.agent_id, a.name, a.source,
       CASE a.source WHEN 'literal' THEN a.config_value ELSE n.config_value END AS resolved_value,
       n.id AS namespace_value_id
FROM afs.agent_config_values a
LEFT JOIN afs.namespace_config_values n
       ON a.source = 'namespace' AND n.team_id = a.team_id AND n.name = a.name;

-- 3. Guards --------------------------------------------------------------------------------------
-- A namespace link must point at an existing value; a name must not shadow a secret env var.
CREATE FUNCTION afs.agent_config_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.source = 'namespace' AND NOT EXISTS (
       SELECT 1 FROM afs.namespace_config_values n WHERE n.team_id = NEW.team_id AND n.name = NEW.name) THEN
    RAISE EXCEPTION 'no namespace value named % in this team', NEW.name
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM afs.agent_secret_bindings b
             WHERE b.agent_id = NEW.agent_id AND b.delivery = 'env' AND b.target = NEW.name) THEN
    RAISE EXCEPTION '% is already delivered to this agent as a secret', NEW.name
      USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agent_config_values_guard BEFORE INSERT OR UPDATE ON afs.agent_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.agent_config_guard();

-- The reverse: a secret binding cannot take an env var name a configuration value already uses.
CREATE FUNCTION afs.binding_config_clash() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.delivery = 'env' AND EXISTS (
       SELECT 1 FROM afs.agent_config_values v WHERE v.agent_id = NEW.agent_id AND v.name = NEW.target) THEN
    RAISE EXCEPTION '% is already a configuration value of this agent', NEW.target
      USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agent_secret_bindings_config_clash BEFORE INSERT OR UPDATE ON afs.agent_secret_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.binding_config_clash();

-- A namespace value that agents link to cannot be deleted or renamed out from under them.
-- (Deleting the whole team cascades and is not blocked: its agents go with it.)
CREATE FUNCTION afs.namespace_config_in_use() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF (TG_OP = 'DELETE' OR NEW.name IS DISTINCT FROM OLD.name)
     AND EXISTS (SELECT 1 FROM afs.agent_config_values a
                 WHERE a.source = 'namespace' AND a.team_id = OLD.team_id AND a.name = OLD.name)
     AND EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = OLD.team_id) THEN
    RAISE EXCEPTION 'namespace value % is used by agents; switch them to their own value first', OLD.name
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER namespace_config_values_in_use BEFORE UPDATE OR DELETE ON afs.namespace_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.namespace_config_in_use();

-- 4. Replace agents.env --------------------------------------------------------------------------
-- Old entries become literal values. Names that fail the new rules (or look like credentials) stop
-- the migration: they must be moved to secrets by hand rather than silently dropped.
INSERT INTO afs.agent_config_values (id, team_id, agent_id, name, source, config_value)
SELECT 'acv_' || translate(upper(substr(md5(a.id || e.key), 1, 26)), 'ILOU', '1105'),
       a.team_id, a.id, e.key, 'literal', e.value #>> '{}'
FROM afs.agents a, jsonb_each(a.env) e;

ALTER TABLE afs.agents DROP COLUMN env;

-- 5. Versioning, revisions, privileges, row-level security ---------------------------------------
CREATE TRIGGER namespace_config_values_touch BEFORE UPDATE ON afs.namespace_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER namespace_config_values_revision AFTER INSERT OR UPDATE OR DELETE ON afs.namespace_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER agent_config_values_touch BEFORE UPDATE ON afs.agent_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER agent_config_values_revision AFTER INSERT OR UPDATE OR DELETE ON afs.agent_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

GRANT SELECT, INSERT, UPDATE, DELETE ON afs.namespace_config_values, afs.agent_config_values TO afs_app;
GRANT SELECT ON afs.namespace_config_values, afs.agent_config_values, afs.agent_config_resolved
  TO afs_app, afs_reconciler, afs_readonly;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['namespace_config_values', 'agent_config_values']
  LOOP
    EXECUTE format('ALTER TABLE afs.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY app_team_scope ON afs.%I TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id))', t);
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_reconciler, afs_gateway, afs_billing, afs_readonly USING (true) WITH CHECK (true)', t);
  END LOOP;
END
$$;
