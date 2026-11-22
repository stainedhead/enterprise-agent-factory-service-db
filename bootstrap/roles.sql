-- Database roles for the Enterprise Agent Factory Service.
--
-- Run once per database cluster by a DBA (on RDS: the master user), before the first migration.
-- Idempotent. Roles are NOLOGIN groups; real logins are IAM-authenticated users (rds_iam) or
-- Secrets Manager-rotated users granted one of these groups. No passwords are set here.
--
--   afs_owner       owns the afs schema and runs migrations
--   afs_app         afs-api: reads and writes desired state, audit and outbox; subject to RLS
--   afs_reconciler  afs-reconciler: reads all desired state, writes status, publishes outbox
--   afs_gateway     afs-gateway: reads budgets and models, reserves/settles spend, writes usage
--   afs_billing     afs-billing: writes daily costs and reconciliations
--   afs_readonly    reporting and support: read-only, no audit before/after payloads
--   afs_edge        afs-edge (public collaboration endpoint, migration 000020): no table privilege, executes
--                   a fixed set of SECURITY DEFINER functions only

DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['afs_owner', 'afs_app', 'afs_reconciler', 'afs_gateway', 'afs_billing', 'afs_readonly', 'afs_edge']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END
$$;
