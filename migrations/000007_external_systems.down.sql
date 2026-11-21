-- Local and test use only. Production migrations are forward-only.
CREATE TABLE afs.team_egress_rules (
  id         text PRIMARY KEY CHECK (afs.ulid_ok(id, 'egr')),
  team_id    text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  host       text NOT NULL CHECK (host ~ '^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  port       integer NOT NULL DEFAULT 443 CHECK (port BETWEEN 1 AND 65535),
  purpose    text NOT NULL,
  version    bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, host, port)
);

-- Team-declared systems become plain egress rules again.
INSERT INTO afs.team_egress_rules (id, team_id, host, port, purpose)
SELECT DISTINCT ON (s.team_id, split_part(e, ':', 1), coalesce(nullif(split_part(e, ':', 2), '')::int, 443))
       'egr_' || translate(upper(substr(md5(s.id || e), 1, 26)), 'ILOU', '1105'),
       s.team_id, split_part(e, ':', 1), coalesce(nullif(split_part(e, ':', 2), '')::int, 443),
       s.name || ': ' || s.purpose
FROM afs.external_systems s, unnest(s.endpoints) AS e
WHERE s.team_id IS NOT NULL;

CREATE TRIGGER team_egress_rules_touch BEFORE UPDATE ON afs.team_egress_rules
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER team_egress_rules_revision AFTER INSERT OR UPDATE OR DELETE ON afs.team_egress_rules
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.team_egress_rules TO afs_app;
GRANT SELECT ON afs.team_egress_rules TO afs_reconciler, afs_readonly;
ALTER TABLE afs.team_egress_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.team_egress_rules TO afs_app
  USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id));
CREATE POLICY service_roles_all ON afs.team_egress_rules TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS teams_guardrail_guard ON afs.teams;
DROP FUNCTION IF EXISTS afs.team_guardrail_guard();
DROP TRIGGER IF EXISTS secrets_external_system_same_team ON afs.secrets;

DROP VIEW IF EXISTS afs.agent_external_access;
ALTER TABLE afs.secrets DROP COLUMN external_system_id;
DROP TABLE IF EXISTS afs.external_system_optouts;
DROP TABLE IF EXISTS afs.external_systems;
DROP FUNCTION IF EXISTS afs.external_system_same_team();
DROP FUNCTION IF EXISTS afs.external_system_guard();
ALTER TABLE afs.teams DROP COLUMN may_add_external_systems;
DROP FUNCTION IF EXISTS afs.caller_owns_scope(text);
DROP FUNCTION IF EXISTS afs.endpoints_ok(text[]);
