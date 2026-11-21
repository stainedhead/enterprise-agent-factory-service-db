-- 000003 one pod per agent; AFS-managed Secrets Manager hierarchy.
--
-- Decisions: ADR-005 and ADR-006 in the root repository (J's PRD review, 2026-11-21).
--
-- 1. Agents have no replica count. One agent is one identity and runs as one pod (a StatefulSet with
--    one replica); pause scales it to zero through agents.state.
-- 2. AFS alone names every secret in Secrets Manager:
--      <prefix>/<namespace>/<agent-name>/<secret-name>   secret only that agent can read
--      <prefix>/<namespace>/_shared/<secret-name>        secret any agent of the team can be bound to
--    <prefix> is service setting secrets.path_prefix (default "afs"). The database computes the path on
--    insert, ignoring any value supplied, and rejects an ARN that does not end in that path. Users and
--    the API cannot choose or change it. Registering arbitrary existing ARNs ("registered") is dropped.
--    Team slug, agent name and every path input are immutable so a path never changes.
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.agents, afs.secrets and afs.service_settings for catalog
-- changes. DROP COLUMN and ADD COLUMN (nullable) do not rewrite. secrets.path is added NOT NULL with no
-- default, which requires afs.secrets to be empty; schema v1 was never released, and the guard below
-- stops the migration rather than guess paths for existing rows.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM afs.secrets) THEN
    RAISE EXCEPTION '000003 requires afs.secrets to be empty; existing secrets need a planned move to managed paths';
  END IF;
END $$;

-- 1. One pod per agent ------------------------------------------------------------------------------
ALTER TABLE afs.agents DROP COLUMN replicas;

-- 2. Path prefix setting ----------------------------------------------------------------------------
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_secrets_path_prefix_check
  CHECK (key <> 'secrets.path_prefix'
         OR (jsonb_typeof(value) = 'string' AND (value #>> '{}') ~ '^[a-z][a-z0-9-]{0,30}$'));

INSERT INTO afs.service_settings (key, value, description)
VALUES ('secrets.path_prefix', '"afs"',
        'First segment of every Secrets Manager name AFS creates. A change applies to new secrets only.')
ON CONFLICT (key) DO NOTHING;

-- 3. Path computation -------------------------------------------------------------------------------
-- The API calls this before CreateSecret so it creates the secret under the right name; the insert
-- trigger calls it again and stores its result, so the two can never disagree.
CREATE FUNCTION afs.secret_path(p_team_id text, p_agent_id text, p_name text) RETURNS text
  LANGUAGE plpgsql STABLE
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_prefix text;
  v_ns     text;
  v_agent  text;
BEGIN
  SELECT value #>> '{}' INTO v_prefix FROM afs.service_settings WHERE key = 'secrets.path_prefix';
  v_prefix := coalesce(v_prefix, 'afs');

  SELECT namespace INTO v_ns FROM afs.teams WHERE id = p_team_id;
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'team % not found', p_team_id USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF p_agent_id IS NULL THEN
    v_agent := '_shared';  -- cannot collide: agent names start with a letter
  ELSE
    SELECT name INTO v_agent FROM afs.agents WHERE team_id = p_team_id AND id = p_agent_id;
    IF v_agent IS NULL THEN
      RAISE EXCEPTION 'agent % not found in team %', p_agent_id, p_team_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN v_prefix || '/' || v_ns || '/' || v_agent || '/' || p_name;
END;
$$;

-- 4. Secrets: scope, managed path, managed origin only ---------------------------------------------
ALTER TABLE afs.secrets
  ADD COLUMN agent_id text,
  ADD COLUMN path text NOT NULL,
  ADD CONSTRAINT secrets_agent_fk FOREIGN KEY (team_id, agent_id)
    REFERENCES afs.agents (team_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT secrets_path_key UNIQUE (path),
  -- Secrets Manager ARNs end in "<name>-<6 random characters>".
  ADD CONSTRAINT secrets_arn_matches_path
    CHECK (substring(secrets_manager_arn FROM ':secret:(.*)-[A-Za-z0-9]{6}$') = path),
  DROP CONSTRAINT secrets_origin_check,
  ADD CONSTRAINT secrets_origin_check CHECK (origin = 'managed'),
  -- Names are unique per scope (two agents may each have "github-token"); the path is the identity.
  DROP CONSTRAINT secrets_team_id_name_key;

COMMENT ON COLUMN afs.secrets.agent_id IS 'NULL: team-shared secret. Otherwise the only agent that may be bound to it.';
COMMENT ON COLUMN afs.secrets.path IS 'Secrets Manager name, set by afs.secret_path() on insert. Never user-supplied.';

CREATE FUNCTION afs.secrets_managed_path() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.path := afs.secret_path(NEW.team_id, NEW.agent_id, NEW.name);
  ELSIF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.path IS DISTINCT FROM OLD.path
     OR NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn THEN
    RAISE EXCEPTION 'a secret''s team, scope, name, path and ARN cannot change; create a new secret'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER secrets_managed_path BEFORE INSERT OR UPDATE ON afs.secrets
  FOR EACH ROW EXECUTE FUNCTION afs.secrets_managed_path();

-- 5. Path inputs are immutable ----------------------------------------------------------------------
CREATE FUNCTION afs.reject_identity_change() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  -- Nested IFs: plpgsql does not short-circuit AND, and NEW.slug does not exist on agents.
  IF TG_TABLE_NAME = 'teams' THEN
    IF NEW.slug IS DISTINCT FROM OLD.slug THEN
      RAISE EXCEPTION 'a team''s slug cannot change (it names the namespace and secret paths)'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  ELSIF TG_TABLE_NAME = 'agents' THEN
    IF NEW.name IS DISTINCT FROM OLD.name OR NEW.team_id IS DISTINCT FROM OLD.team_id THEN
      RAISE EXCEPTION 'an agent''s name and team cannot change (they name its identity and secret paths)'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER teams_identity_immutable BEFORE UPDATE OF slug ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.reject_identity_change();
CREATE TRIGGER agents_identity_immutable BEFORE UPDATE OF name, team_id ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.reject_identity_change();

-- 6. An agent secret binds only to its own agent ---------------------------------------------------
CREATE FUNCTION afs.binding_respects_scope() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_owner text;
BEGIN
  SELECT agent_id INTO v_owner FROM afs.secrets WHERE team_id = NEW.team_id AND id = NEW.secret_id;
  IF v_owner IS NOT NULL AND v_owner <> NEW.agent_id THEN
    RAISE EXCEPTION 'secret % belongs to agent % and cannot be bound to agent %',
      NEW.secret_id, v_owner, NEW.agent_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agent_secret_bindings_scope BEFORE INSERT OR UPDATE ON afs.agent_secret_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.binding_respects_scope();
