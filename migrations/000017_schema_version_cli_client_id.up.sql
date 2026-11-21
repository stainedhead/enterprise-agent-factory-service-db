-- 000017: afs.schema_version() for services that do not own the schema (restapi X-DB-7), and a separate
-- public CLI client id on identity providers (root D48, contract CD-9).
--
-- The database contract §1 has every service check the schema version at startup. The tracking table
-- public.afs_schema_migrations is owned by the migrating role, and afs_reconciler, afs_gateway,
-- afs_billing and afs_readonly cannot read it. This SECURITY DEFINER function returns the highest
-- applied version and nothing else.
--
-- identity_providers.client_id stays the console's client id; cli_client_id is the public client the
-- afs CLI uses for the device authorization grant. It is not a secret (public OIDC clients have none).
-- Lock impact: brief ACCESS EXCLUSIVE on identity_providers (a few rows) to add a nullable column; the
-- function touches no table.

CREATE FUNCTION afs.schema_version() RETURNS bigint
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
  RETURN (SELECT coalesce(max(version), 0) FROM public.afs_schema_migrations);

REVOKE EXECUTE ON FUNCTION afs.schema_version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.schema_version()
  TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;

ALTER TABLE afs.identity_providers
  ADD COLUMN cli_client_id text CHECK (length(cli_client_id) BETWEEN 1 AND 200);
COMMENT ON COLUMN afs.identity_providers.cli_client_id IS
  'Public OIDC client id for the afs CLI device grant (D48); client_id is the console client. Not a secret.';
