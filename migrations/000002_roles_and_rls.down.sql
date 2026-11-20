-- Local and test use only. Production migrations are forward-only.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname = 'afs'
  LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'afs' AND c.relkind IN ('r', 'p') AND c.relrowsecurity
  LOOP
    EXECUTE format('ALTER TABLE afs.%I DISABLE ROW LEVEL SECURITY', r.relname);
  END LOOP;
END
$$;
DROP FUNCTION IF EXISTS afs.caller_sees_team(text);
DROP FUNCTION IF EXISTS afs.caller_is_service_admin();
REVOKE ALL ON ALL TABLES IN SCHEMA afs FROM afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA afs FROM afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA afs FROM afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;
REVOKE USAGE ON SCHEMA afs FROM afs_app, afs_reconciler, afs_gateway, afs_billing, afs_readonly;
