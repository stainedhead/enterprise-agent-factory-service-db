-- 000009 identity providers at service and team level; team-managed AWS account filter.
--
-- From J's answers to the PRD's open questions (2026-11-21):
--
-- Q1. Okta and Microsoft Entra ID are both supported, at the service level and per team. Okta is the
-- default. afs.identity_providers holds the OIDC settings (no secret values: a confidential client's
-- secret is a Secrets Manager ARN). A service-level provider signs people in to the whole service; a
-- team-level provider additionally signs people in for that team only, and the team's group role
-- bindings can name it. One service-level provider is the default. Only service admins change them.
--
-- Q6. Who sets a team's allowed AWS accounts depends on whether service admins let the team manage it:
-- with teams.may_manage_aws_accounts on, the team's admins set the filter; otherwise service admins do.
-- The flag itself stays a service-admin setting. afs.team_guardrail_guard (000007) is replaced.
--
-- Decision: ADR-012 in the root repository.
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.teams and afs.role_bindings to add a column (constant
-- default or nullable; no rewrite).

-- 1. Identity providers -------------------------------------------------------------------------
CREATE TABLE afs.identity_providers (
  id                 text PRIMARY KEY CHECK (afs.ulid_ok(id, 'idp')),
  -- NULL: service level. Set: an extra provider for that team's members.
  team_id            text REFERENCES afs.teams (id) ON DELETE CASCADE,
  kind               text NOT NULL CHECK (kind IN ('okta', 'entra_id')),
  name               text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  issuer_url         text NOT NULL CHECK (issuer_url ~ '^https://[^\s/]+(/[^\s]*)?$' AND length(issuer_url) <= 500),
  client_id          text NOT NULL CHECK (length(client_id) BETWEEN 1 AND 200),
  -- Confidential clients only: where the client secret lives. Never the secret itself.
  client_secret_arn  text CHECK (client_secret_arn ~ '^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$'),
  groups_claim       text NOT NULL DEFAULT 'groups' CHECK (groups_claim ~ '^[A-Za-z0-9_.:/-]{1,100}$'),
  is_default         boolean NOT NULL DEFAULT false,
  enabled            boolean NOT NULL DEFAULT true,
  version            bigint NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         text NOT NULL DEFAULT afs.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT is_default OR (team_id IS NULL AND enabled))
);

CREATE UNIQUE INDEX identity_providers_issuer_uq ON afs.identity_providers (coalesce(team_id, ''), issuer_url);
CREATE UNIQUE INDEX identity_providers_one_default ON afs.identity_providers ((true)) WHERE is_default;

-- A group binding can say which provider the group comes from (NULL: the default provider).
ALTER TABLE afs.role_bindings
  ADD COLUMN identity_provider_id text REFERENCES afs.identity_providers (id) ON DELETE CASCADE;
ALTER TABLE afs.role_bindings
  ADD CONSTRAINT role_bindings_idp_groups_only CHECK (identity_provider_id IS NULL OR subject_type = 'group');

-- A binding can only name a service-level provider or one of its own team's.
CREATE FUNCTION afs.role_binding_idp_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF NEW.identity_provider_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM afs.identity_providers p
       WHERE p.id = NEW.identity_provider_id
         AND (p.team_id IS NULL OR p.team_id IS NOT DISTINCT FROM NEW.team_id)) THEN
    RAISE EXCEPTION 'identity provider % is not available to this binding', NEW.identity_provider_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER role_bindings_idp_guard BEFORE INSERT OR UPDATE OF identity_provider_id, team_id ON afs.role_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.role_binding_idp_guard();

-- 2. Team-managed AWS account filter -------------------------------------------------------------
ALTER TABLE afs.teams
  ADD COLUMN may_manage_aws_accounts boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN afs.teams.may_manage_aws_accounts IS
  'On: the team''s admins set allowed_aws_accounts. Off: only service admins do. Set by service admins.';

CREATE OR REPLACE FUNCTION afs.team_guardrail_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin() THEN
    IF NEW.may_add_external_systems IS DISTINCT FROM OLD.may_add_external_systems
       OR NEW.may_manage_aws_accounts IS DISTINCT FROM OLD.may_manage_aws_accounts THEN
      RAISE EXCEPTION 'only service admins decide what a team may manage itself'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.allowed_aws_accounts IS DISTINCT FROM OLD.allowed_aws_accounts AND NOT OLD.may_manage_aws_accounts THEN
      RAISE EXCEPTION 'this team''s allowed AWS accounts are managed by service admins'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER teams_guardrail_guard ON afs.teams;
CREATE TRIGGER teams_guardrail_guard
  BEFORE UPDATE OF allowed_aws_accounts, may_add_external_systems, may_manage_aws_accounts ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_guardrail_guard();

-- 3. Versioning, revisions, privileges, row-level security ---------------------------------------
CREATE TRIGGER identity_providers_touch BEFORE UPDATE ON afs.identity_providers
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER identity_providers_revision AFTER INSERT OR UPDATE OR DELETE ON afs.identity_providers
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

GRANT SELECT, INSERT, UPDATE, DELETE ON afs.identity_providers TO afs_app;
GRANT SELECT ON afs.identity_providers TO afs_reconciler, afs_readonly;

-- Everyone signing in needs the service-level providers; a team's own provider is visible to that team.
-- Only service admins write any of them.
ALTER TABLE afs.identity_providers ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.identity_providers FOR SELECT TO afs_app
  USING (team_id IS NULL OR afs.caller_sees_team(team_id));
CREATE POLICY app_write ON afs.identity_providers FOR ALL TO afs_app
  USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.identity_providers TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
