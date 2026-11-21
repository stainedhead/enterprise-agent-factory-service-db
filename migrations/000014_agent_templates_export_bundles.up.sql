-- 000014: agent template catalog (root PRD AGT-11, D54) and export/import bundle changes (D49).
--
-- Agent templates (AGT-11). afs.agent_templates is a service-level desired-state table: service admins
-- curate the Agentic Teammates templates teams may use, each with its allowed image digests and one
-- marked current. agents and agent_pools get a nullable template_id; the free-text template column
-- stays, so nothing existing changes. A trigger refuses a NEW agent or pool, or a change of its
-- template_id or image, when the template is disabled or the image digest is not on the template's
-- allowed list (23514). Disabling a template or removing a digest never touches existing rows: the
-- reconciler flags them (condition TemplateRetired) without restarting them. The digest of an agent or
-- pool is the part of its image after '@' (agents.image, agent_pools.image). Rows with a NULL
-- template_id (all rows today) are not guarded.
--
-- The change feed needs no new function: afs.notify_desired_state() (000013) already yields
-- 'agent_templates::<id>' for a table without team_id, because it prints an empty team part.
--
-- Export and import bundles (D49). An import has no S3 object, so export_bundles.s3_uri becomes
-- nullable; the pre-signed link and the size get columns. The checksum of an export is known only when
-- the reconciler has built the bundle, so sha256 becomes nullable too (an import still records the
-- checksum the API computed). A succeeded export must have s3_uri and sha256. download_url is a
-- pre-signed link that expires, not a secret value. The reconciler may update the columns it fills in.
--
-- Lock impact: brief ACCESS EXCLUSIVE on agents, agent_pools and export_bundles for ADD COLUMN
-- (nullable, no rewrite), the NOT VALID constraints (validated afterwards under SHARE UPDATE
-- EXCLUSIVE, which does not block writes) and the new indexes and triggers. agent_templates is new.

-- 1. Agent templates ------------------------------------------------------------------------------
-- The digests a template allows: at least one, each sha256:<64 hex>.
CREATE FUNCTION afs.image_digests_ok(p_digests text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p_digests IS NOT NULL AND cardinality(p_digests) >= 1
     AND NOT EXISTS (SELECT 1 FROM unnest(p_digests) AS d WHERE d IS NULL OR d !~ '^sha256:[0-9a-f]{64}$');

CREATE TABLE afs.agent_templates (
  id                   text PRIMARY KEY CHECK (afs.ulid_ok(id, 'tpl')),
  name                 text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9-]{1,38}[a-z0-9]$'),
  description          text NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
  -- The Agentic Teammates harness the template runs. The list belongs to that project, so the
  -- database checks the shape (kebab-case), not a closed set.
  harness              text NOT NULL CHECK (harness ~ '^[a-z][a-z0-9-]{0,38}[a-z0-9]$'),
  default_resources    jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(default_resources) = 'object'),
  allowed_image_digests text[] NOT NULL CHECK (afs.image_digests_ok(allowed_image_digests)),
  current_image_digest text NOT NULL,
  enabled              boolean NOT NULL DEFAULT true,
  version              bigint NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  created_by           text NOT NULL DEFAULT afs.current_actor(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_templates_current_allowed_check
    CHECK (current_image_digest = ANY (allowed_image_digests))
);
COMMENT ON TABLE afs.agent_templates IS
  'Agent template catalog (AGT-11): service admins curate templates and allowed image digests. Disabling a template or removing a digest blocks new agents and pools, never existing ones.';

CREATE TRIGGER agent_templates_touch BEFORE UPDATE ON afs.agent_templates
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER agent_templates_revision AFTER INSERT OR UPDATE OR DELETE ON afs.agent_templates
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER agent_templates_notify AFTER INSERT OR UPDATE OR DELETE ON afs.agent_templates
  FOR EACH ROW EXECUTE FUNCTION afs.notify_desired_state();

ALTER TABLE afs.agent_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.agent_templates FOR SELECT TO afs_app USING (true);
CREATE POLICY app_write ON afs.agent_templates FOR ALL TO afs_app
  USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.agent_templates TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON afs.agent_templates TO afs_app;
GRANT SELECT ON afs.agent_templates TO afs_reconciler, afs_readonly;

-- 2. Agents and pools reference a template --------------------------------------------------------
ALTER TABLE afs.agents ADD COLUMN template_id text;
ALTER TABLE afs.agent_pools ADD COLUMN template_id text;
ALTER TABLE afs.agents ADD CONSTRAINT agents_template_id_fkey
  FOREIGN KEY (template_id) REFERENCES afs.agent_templates (id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE afs.agent_pools ADD CONSTRAINT agent_pools_template_id_fkey
  FOREIGN KEY (template_id) REFERENCES afs.agent_templates (id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE afs.agents VALIDATE CONSTRAINT agents_template_id_fkey;
ALTER TABLE afs.agent_pools VALIDATE CONSTRAINT agent_pools_template_id_fkey;
CREATE INDEX agents_template_idx ON afs.agents (template_id) WHERE template_id IS NOT NULL;
CREATE INDEX agent_pools_template_idx ON afs.agent_pools (template_id) WHERE template_id IS NOT NULL;
COMMENT ON COLUMN afs.agents.template_id IS
  'Catalog template (AGT-11). NULL for agents created before the catalog; the free-text template column stays.';
COMMENT ON COLUMN afs.agent_pools.template_id IS
  'Catalog template (AGT-11). NULL for pools created before the catalog; the free-text template column stays.';

-- A new agent or pool, or a changed template_id or image, needs an enabled template and an allowed
-- digest. The template row is share-locked so a concurrent disable waits for this transaction.
CREATE FUNCTION afs.template_use_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
DECLARE
  t afs.agent_templates;
  v_digest text;
BEGIN
  IF NEW.template_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.template_id IS NOT DISTINCT FROM OLD.template_id
     AND NEW.image IS NOT DISTINCT FROM OLD.image THEN
    RETURN NEW;
  END IF;
  SELECT * INTO t FROM afs.agent_templates WHERE id = NEW.template_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no agent template %', NEW.template_id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = TG_TABLE_NAME || '_template_id_fkey';
  END IF;
  IF NOT t.enabled THEN
    RAISE EXCEPTION 'agent template % is disabled', t.name
      USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_template_enabled';
  END IF;
  v_digest := substring(NEW.image FROM '@(sha256:[0-9a-f]{64})$');
  IF v_digest IS NULL OR NOT (v_digest = ANY (t.allowed_image_digests)) THEN
    RAISE EXCEPTION 'image digest % is not allowed for agent template %', coalesce(v_digest, '(none)'), t.name
      USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_template_digest';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER agents_template_guard BEFORE INSERT OR UPDATE OF template_id, image ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.template_use_guard();
CREATE TRIGGER agent_pools_template_guard BEFORE INSERT OR UPDATE OF template_id, image ON afs.agent_pools
  FOR EACH ROW EXECUTE FUNCTION afs.template_use_guard();

-- 3. Export and import bundles (D49) --------------------------------------------------------------
ALTER TABLE afs.export_bundles
  ALTER COLUMN s3_uri DROP NOT NULL,
  ALTER COLUMN sha256 DROP NOT NULL,
  ADD COLUMN download_url        text,
  ADD COLUMN download_expires_at timestamptz,
  ADD COLUMN size_bytes          bigint;
ALTER TABLE afs.export_bundles
  ADD CONSTRAINT export_bundles_size_check CHECK (size_bytes >= 0) NOT VALID,
  ADD CONSTRAINT export_bundles_succeeded_check
    CHECK (status <> 'succeeded' OR sha256 IS NOT NULL) NOT VALID,
  ADD CONSTRAINT export_bundles_export_succeeded_check
    CHECK (direction <> 'export' OR status <> 'succeeded' OR s3_uri IS NOT NULL) NOT VALID;
ALTER TABLE afs.export_bundles VALIDATE CONSTRAINT export_bundles_size_check;
ALTER TABLE afs.export_bundles VALIDATE CONSTRAINT export_bundles_succeeded_check;
ALTER TABLE afs.export_bundles VALIDATE CONSTRAINT export_bundles_export_succeeded_check;
COMMENT ON COLUMN afs.export_bundles.download_url IS
  'Pre-signed S3 link (valid 7 days), written by the reconciler. Not a secret value; it expires.';

-- Exports and imports are service-admin operations (admin:export, admin:import). Until now any afs_app
-- caller could read and write the table; row-level security limits it to service admins.
ALTER TABLE afs.export_bundles ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_admin_all ON afs.export_bundles FOR ALL TO afs_app
  USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.export_bundles TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

-- The reconciler builds the bundle and records the outcome.
GRANT UPDATE (status, summary, finished_at, s3_uri, sha256, download_url, download_expires_at, size_bytes)
  ON afs.export_bundles TO afs_reconciler;

-- 4. Repository owners from team configuration (D38, revised by J) --------------------------------
-- A team declares the repositories it owns in its namespace configuration value AFS_OWNED_REPOS:
-- entries separated by commas or whitespace, each host/owner/repo or host/owner/* (case-insensitive).
-- afs-api resolves a work order repository given without an explicit owner through this function:
-- exact entries win over wildcards; it returns every team at the best match, so the API can refuse an
-- ambiguous owner. Teams being deleted or deleted are skipped. SECURITY DEFINER because a security
-- operator cannot read other teams' configuration through row-level security; it returns team ids only.
CREATE FUNCTION afs.resolve_repo_owners(p_host text, p_repo text) RETURNS SETOF text
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, afs AS $$
  WITH entries AS (
    SELECT v.team_id, lower(e) AS entry
      FROM afs.namespace_config_values v
      JOIN afs.teams t ON t.id = v.team_id AND t.state IN ('active', 'suspended'),
           regexp_split_to_table(btrim(v.config_value), '[\s,]+') AS e
     WHERE v.name = 'AFS_OWNED_REPOS' AND e <> ''
  ), matches AS (
    SELECT team_id, CASE WHEN entry = lower(p_host || '/' || p_repo) THEN 2 ELSE 1 END AS rank
      FROM entries
     WHERE entry = lower(p_host || '/' || p_repo)
        OR entry = lower(p_host || '/' || split_part(p_repo, '/', 1) || '/*')
  )
  SELECT DISTINCT team_id FROM matches WHERE rank = (SELECT max(rank) FROM matches) ORDER BY team_id
$$;
REVOKE EXECUTE ON FUNCTION afs.resolve_repo_owners(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.resolve_repo_owners(text, text) TO afs_app, afs_reconciler;
