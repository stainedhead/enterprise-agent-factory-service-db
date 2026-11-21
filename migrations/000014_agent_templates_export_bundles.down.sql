-- Reverses 000014. Step 3 fails if an import row or an unfinished export (no s3_uri or sha256) exists;
-- remove such rows first. Down migrations are for local use and tests.

-- 3. Export and import bundles
DROP POLICY service_roles_all ON afs.export_bundles;
DROP POLICY app_admin_all ON afs.export_bundles;
ALTER TABLE afs.export_bundles DISABLE ROW LEVEL SECURITY;
REVOKE UPDATE (status, summary, finished_at, s3_uri, sha256, download_url, download_expires_at, size_bytes)
  ON afs.export_bundles FROM afs_reconciler;
ALTER TABLE afs.export_bundles
  DROP CONSTRAINT export_bundles_export_succeeded_check,
  DROP CONSTRAINT export_bundles_succeeded_check,
  DROP CONSTRAINT export_bundles_size_check,
  DROP COLUMN size_bytes,
  DROP COLUMN download_expires_at,
  DROP COLUMN download_url,
  ALTER COLUMN sha256 SET NOT NULL,
  ALTER COLUMN s3_uri SET NOT NULL;

-- 2. Agents and pools
DROP TRIGGER agent_pools_template_guard ON afs.agent_pools;
DROP TRIGGER agents_template_guard ON afs.agents;
DROP FUNCTION afs.template_use_guard();
DROP INDEX afs.agent_pools_template_idx;
DROP INDEX afs.agents_template_idx;
ALTER TABLE afs.agent_pools DROP CONSTRAINT agent_pools_template_id_fkey, DROP COLUMN template_id;
ALTER TABLE afs.agents DROP CONSTRAINT agents_template_id_fkey, DROP COLUMN template_id;

-- 1. Agent templates
DROP TABLE afs.agent_templates;
DROP FUNCTION afs.image_digests_ok(text[]);
