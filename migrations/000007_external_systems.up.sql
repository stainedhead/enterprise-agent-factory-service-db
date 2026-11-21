-- 000007 external systems catalog: service, team and agent levels.
--
-- External systems are the outside services agents may reach (GitHub, Atlassian, Slack, Okta, ...).
-- Service admins keep the catalog: a set of built-in entries, plus any custom endpoints they add, each of
-- which can be switched off for every team. Teams inherit every enabled entry, on by default, and can
-- switch entries off for the whole team; agents inherit from their team and can switch entries off for
-- themselves (afs.external_system_optouts). A lower level can only narrow the one above. Where service
-- admins allow it (teams.may_add_external_systems), a team can also declare its own systems, with an
-- owner, a purpose and documentation, so the services it depends on are written down and controlled.
--
-- Each entry lists its network endpoints (host or *.domain, optional port). The reconciler renders the
-- endpoints of every system an agent may use into that agent's egress policy (default deny), so the
-- catalog is enforced in the network, not only in the UI. A secret can name the system it is a
-- credential for (afs.secrets.external_system_id); the reconciler does not deliver it to agents for
-- which that system is off.
--
-- afs.team_egress_rules (free-form host allow-list from 000001) is replaced: each team's rules become
-- one team-declared system, so there is one mechanism for egress.
--
-- Decision: ADR-010 in the root repository (J's PRD review, 2026-11-21).
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.teams and afs.secrets to add a column with a constant
-- default or no default (catalog only). The backfill reads afs.team_egress_rules once; schema v1 is
-- unreleased, so it is small.

-- Endpoints are 'host', 'host:port' or '*.domain[:port]'. Hosts are lower case.
CREATE FUNCTION afs.endpoints_ok(p_endpoints text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN cardinality(p_endpoints) BETWEEN 1 AND 50
     AND array_position(p_endpoints, NULL) IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM unnest(p_endpoints) AS e
       WHERE e !~ '^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?$');

-- True when the caller may write a row at this level: service admins for the service level (NULL
-- team), callers bound to the team for a team's own rows.
CREATE FUNCTION afs.caller_owns_scope(p_team_id text) RETURNS boolean
  LANGUAGE sql STABLE
  RETURN CASE WHEN p_team_id IS NULL THEN afs.caller_is_service_admin()
              ELSE afs.caller_sees_team(p_team_id) END;

-- 1. The catalog ---------------------------------------------------------------------------------
-- Service admins decide, per team, whether the team may declare its own systems.
ALTER TABLE afs.teams
  ADD COLUMN may_add_external_systems boolean NOT NULL DEFAULT false;

CREATE TABLE afs.external_systems (
  id                text PRIMARY KEY CHECK (afs.ulid_ok(id, 'ext')),
  -- NULL: a service-level entry, offered to every team. Set: declared by that team, for that team only.
  team_id           text REFERENCES afs.teams (id) ON DELETE CASCADE,
  slug              text NOT NULL CHECK (slug ~ '^[a-z][a-z0-9-]{1,62}$'),
  name              text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  category          text NOT NULL CHECK (category IN ('dev_tools', 'collaboration', 'email', 'cloud',
                                                      'identity', 'llm', 'other')),
  description       text NOT NULL DEFAULT '',
  documentation_url text CHECK (documentation_url ~ '^https://' AND length(documentation_url) <= 500),
  -- Who owns the dependency and why the team needs it. Required for team-declared entries.
  owner             text NOT NULL DEFAULT '',
  purpose           text NOT NULL DEFAULT '',
  endpoints         text[] NOT NULL CHECK (afs.endpoints_ok(endpoints)),
  -- Off: unavailable to every agent at and below this entry's level.
  enabled           boolean NOT NULL DEFAULT true,
  -- Shipped with AFS. Can be switched off and its endpoints edited, but not deleted.
  builtin           boolean NOT NULL DEFAULT false,
  version           bigint NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        text NOT NULL DEFAULT afs.current_actor(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (team_id IS NULL OR (owner <> '' AND purpose <> '')),
  CHECK (team_id IS NULL OR NOT builtin)
);

CREATE UNIQUE INDEX external_systems_slug_uq ON afs.external_systems (coalesce(team_id, ''), slug);
CREATE INDEX external_systems_team_idx ON afs.external_systems (team_id) WHERE team_id IS NOT NULL;

COMMENT ON COLUMN afs.external_systems.category IS
  'llm: a model provider other than Bedrock. Calls to it bypass the AFS gateway, so they are not metered or held to the team''s hard cap.';

-- 2. Switching entries off for a team or one agent -----------------------------------------------
-- Default on: a row here turns one system off for the whole team (agent_id NULL) or for one agent.
CREATE TABLE afs.external_system_optouts (
  id         text PRIMARY KEY CHECK (afs.ulid_ok(id, 'xso')),
  team_id    text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  agent_id   text,
  system_id  text NOT NULL REFERENCES afs.external_systems (id) ON DELETE CASCADE,
  reason     text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  UNIQUE NULLS NOT DISTINCT (team_id, agent_id, system_id),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE CASCADE
);

-- 3. Secrets can name the system they are a credential for ---------------------------------------
ALTER TABLE afs.secrets
  ADD COLUMN external_system_id text REFERENCES afs.external_systems (id) ON DELETE SET NULL;

-- 4. Effective access per agent ------------------------------------------------------------------
-- One row per (agent, system the agent's team can see). disabled_at names the level that switched it
-- off (service, team or agent), or is NULL when the agent may use the system.
CREATE VIEW afs.agent_external_access WITH (security_invoker = true) AS
SELECT a.team_id, a.id AS agent_id, s.id AS system_id, s.slug, s.name, s.category, s.endpoints,
       s.team_id IS NOT NULL AS team_declared,
       CASE
         WHEN NOT s.enabled THEN CASE WHEN s.team_id IS NULL THEN 'service' ELSE 'team' END
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.team_id = a.team_id AND o.agent_id IS NULL AND o.system_id = s.id) THEN 'team'
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.agent_id = a.id AND o.system_id = s.id) THEN 'agent'
       END AS disabled_at
FROM afs.agents a
JOIN afs.external_systems s ON s.team_id IS NULL OR s.team_id = a.team_id;

-- 5. Guards --------------------------------------------------------------------------------------
CREATE FUNCTION afs.external_system_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- A team being deleted cascades to its own entries, which are never built in.
    IF OLD.builtin THEN
      RAISE EXCEPTION 'built-in system % cannot be deleted; switch it off instead', OLD.slug
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.team_id IS DISTINCT FROM OLD.team_id OR NEW.builtin IS DISTINCT FROM OLD.builtin
                           OR NEW.slug IS DISTINCT FROM OLD.slug) THEN
    RAISE EXCEPTION 'a system''s level, slug and built-in flag cannot change'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF TG_OP = 'INSERT' AND NEW.team_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM afs.teams WHERE id = NEW.team_id AND may_add_external_systems) THEN
      RAISE EXCEPTION 'this team may not add its own external systems; ask a service admin'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF EXISTS (SELECT 1 FROM afs.external_systems WHERE team_id IS NULL AND slug = NEW.slug) THEN
      RAISE EXCEPTION '% is already in the service catalog; use that entry', NEW.slug
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER external_systems_guard BEFORE INSERT OR UPDATE OR DELETE ON afs.external_systems
  FOR EACH ROW EXECUTE FUNCTION afs.external_system_guard();

-- An opt-out or a secret can only point at a service-level system or one of its own team's.
CREATE FUNCTION afs.external_system_same_team() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  -- Read through jsonb: plpgsql would resolve both fields of a CASE on NEW.
  sys_id text := to_jsonb(NEW) ->> CASE TG_TABLE_NAME WHEN 'secrets' THEN 'external_system_id' ELSE 'system_id' END;
BEGIN
  IF sys_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM afs.external_systems s
       WHERE s.id = sys_id AND (s.team_id IS NULL OR s.team_id = NEW.team_id)) THEN
    RAISE EXCEPTION 'external system % does not belong to this team', sys_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER external_system_optouts_same_team BEFORE INSERT OR UPDATE ON afs.external_system_optouts
  FOR EACH ROW EXECUTE FUNCTION afs.external_system_same_team();
CREATE TRIGGER secrets_external_system_same_team BEFORE INSERT OR UPDATE OF external_system_id, team_id ON afs.secrets
  FOR EACH ROW EXECUTE FUNCTION afs.external_system_same_team();

-- Guardrails on a team row that only service admins set: the allowed AWS accounts (000006) and whether
-- the team may add its own external systems. Defense in depth behind the API for afs_app callers.
CREATE FUNCTION afs.team_guardrail_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
     AND (NEW.allowed_aws_accounts IS DISTINCT FROM OLD.allowed_aws_accounts
          OR NEW.may_add_external_systems IS DISTINCT FROM OLD.may_add_external_systems) THEN
    RAISE EXCEPTION 'only service admins change a team''s allowed AWS accounts or external-system rights'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER teams_guardrail_guard BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

-- 6. Built-in catalog ----------------------------------------------------------------------------
-- Vendors' public endpoints. Model providers other than Bedrock start switched off: calls to them
-- bypass the gateway's metering and hard caps, so a service admin turns them on deliberately.
INSERT INTO afs.external_systems (id, slug, name, category, description, documentation_url, endpoints, enabled, builtin) VALUES
  ('ext_01JDX0000000000000000000A1', 'atlassian', 'Atlassian (Jira and Confluence)', 'dev_tools',
   'Jira issues and Confluence pages in the company''s Atlassian Cloud site.',
   'https://developer.atlassian.com/cloud/', '{*.atlassian.net,api.atlassian.com,auth.atlassian.com}', true, true),
  ('ext_01JDX0000000000000000000A2', 'github', 'GitHub', 'dev_tools',
   'Repositories, pull requests, issues, Actions and packages.',
   'https://docs.github.com/rest', '{github.com,api.github.com,*.githubusercontent.com,ghcr.io}', true, true),
  ('ext_01JDX0000000000000000000A3', 'outlook', 'Microsoft Outlook', 'email',
   'Mail and calendar through Microsoft Graph.',
   'https://learn.microsoft.com/graph/outlook-mail-concept-overview', '{graph.microsoft.com,outlook.office365.com,login.microsoftonline.com}', true, true),
  ('ext_01JDX0000000000000000000A4', 'microsoft-teams', 'Microsoft Teams', 'collaboration',
   'Chats, channels and meetings through Microsoft Graph and the Bot Framework.',
   'https://learn.microsoft.com/graph/teams-concept-overview', '{graph.microsoft.com,login.microsoftonline.com,smba.trafficmanager.net}', true, true),
  ('ext_01JDX0000000000000000000A5', 'azure', 'Microsoft Azure', 'cloud',
   'Azure Resource Manager and storage.',
   'https://learn.microsoft.com/rest/api/azure/', '{management.azure.com,login.microsoftonline.com,*.blob.core.windows.net}', true, true),
  ('ext_01JDX0000000000000000000A6', 'google', 'Google Workspace and Cloud', 'cloud',
   'Google APIs (Drive, Docs, Gmail, Cloud).',
   'https://developers.google.com/apis-explorer', '{*.googleapis.com,accounts.google.com}', true, true),
  ('ext_01JDX0000000000000000000A7', 'slack', 'Slack', 'collaboration',
   'Messages, channels and files through the Slack Web API.',
   'https://api.slack.com/web', '{slack.com,*.slack.com}', true, true),
  ('ext_01JDX0000000000000000000A8', 'okta', 'Okta', 'identity',
   'Okta management and authentication APIs for the company''s org.',
   'https://developer.okta.com/docs/reference/', '{*.okta.com,*.oktapreview.com}', true, true),
  ('ext_01JDX0000000000000000000A9', 'openai', 'OpenAI', 'llm',
   'OpenAI API. Not metered by the AFS gateway or held to hard caps.',
   'https://platform.openai.com/docs/api-reference', '{api.openai.com}', false, true),
  ('ext_01JDX0000000000000000000AA', 'openrouter', 'OpenRouter', 'llm',
   'OpenRouter model router. Not metered by the AFS gateway or held to hard caps.',
   'https://openrouter.ai/docs', '{openrouter.ai}', false, true);

-- 7. Replace team_egress_rules -------------------------------------------------------------------
-- Each team's rules become one team-declared system; the team is allowed to declare systems so the
-- entry stays editable.
UPDATE afs.teams t SET may_add_external_systems = true
WHERE EXISTS (SELECT 1 FROM afs.team_egress_rules r WHERE r.team_id = t.id);

INSERT INTO afs.external_systems (id, team_id, slug, name, category, description, owner, purpose, endpoints)
SELECT 'ext_' || translate(upper(substr(md5(r.team_id || '/egress'), 1, 26)), 'ILOU', '1105'),
       r.team_id, 'egress-allow-list', 'Egress allow-list (migrated)', 'other',
       'Hosts from the team''s egress allow-list before the external systems catalog.',
       'team-admins', string_agg(DISTINCT r.purpose, '; '),
       array_agg(r.host || CASE WHEN r.port = 443 THEN '' ELSE ':' || r.port END ORDER BY r.host, r.port)
FROM afs.team_egress_rules r
GROUP BY r.team_id;

DROP TABLE afs.team_egress_rules;

-- 8. Versioning, revisions, privileges, row-level security ---------------------------------------
CREATE TRIGGER external_systems_touch BEFORE UPDATE ON afs.external_systems
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER external_systems_revision AFTER INSERT OR UPDATE OR DELETE ON afs.external_systems
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER external_system_optouts_revision AFTER INSERT OR UPDATE OR DELETE ON afs.external_system_optouts
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

GRANT SELECT, INSERT, UPDATE, DELETE ON afs.external_systems, afs.external_system_optouts TO afs_app;
GRANT SELECT ON afs.external_systems, afs.external_system_optouts, afs.agent_external_access
  TO afs_app, afs_reconciler, afs_readonly;

-- Service-level entries are visible to every afs_app caller and writable only by service admins.
ALTER TABLE afs.external_systems ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.external_systems FOR SELECT TO afs_app
  USING (team_id IS NULL OR afs.caller_sees_team(team_id));
CREATE POLICY app_insert ON afs.external_systems FOR INSERT TO afs_app
  WITH CHECK (afs.caller_owns_scope(team_id));
CREATE POLICY app_update ON afs.external_systems FOR UPDATE TO afs_app
  USING (afs.caller_owns_scope(team_id)) WITH CHECK (afs.caller_owns_scope(team_id));
CREATE POLICY app_delete ON afs.external_systems FOR DELETE TO afs_app
  USING (afs.caller_owns_scope(team_id));
CREATE POLICY service_roles_all ON afs.external_systems TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

ALTER TABLE afs.external_system_optouts ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.external_system_optouts TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.external_system_optouts TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
