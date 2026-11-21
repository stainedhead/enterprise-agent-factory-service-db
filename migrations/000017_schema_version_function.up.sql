-- 000017: afs.schema_version() for services that do not own the schema (restapi X-DB-7).
--
-- The database contract §1 has every service check the schema version at startup. The tracking table
-- public.afs_schema_migrations is owned by the migrating role, and afs_reconciler, afs_gateway,
-- afs_billing and afs_readonly cannot read it. This SECURITY DEFINER function returns the highest
-- applied version and nothing else.
-- Lock impact: none (creates one function; no table is touched).

CREATE FUNCTION afs.schema_version() RETURNS bigint
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
  RETURN (SELECT coalesce(max(version), 0) FROM public.afs_schema_migrations);

REVOKE EXECUTE ON FUNCTION afs.schema_version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.schema_version()
  TO afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;
