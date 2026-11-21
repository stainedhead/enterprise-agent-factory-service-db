-- 000004 persistent storage per agent.
--
-- Every agent gets one persistent volume (an EBS volume through a StatefulSet volumeClaimTemplate)
-- for its memory, configuration and work in progress, so that data survives restarts and reschedules.
-- The agent definition carries the volume's size, storage class, what happens to the volume when the
-- agent is deleted, and its snapshot backup schedule. The reconciler records EBS snapshots in
-- afs.agent_volume_snapshots, which export bundles reference.
--
-- Decision: ADR-007 in the root repository (J's PRD review, 2026-11-21).
--
-- Lock impact: brief ACCESS EXCLUSIVE on afs.agents. The new columns have constant defaults, so no
-- rewrite (PostgreSQL 11+). The foreign key to afs.storage_classes is validated by a scan of
-- afs.agents, which is small (one row per agent).

-- 1. Storage classes a service admin offers -------------------------------------------------------
CREATE TABLE afs.storage_classes (
  -- Kubernetes StorageClass name the reconciler uses, e.g. gp3.
  id            text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9-]{0,62}$'),
  description   text NOT NULL DEFAULT '',
  -- EBS volume type behind the class; only block storage is offered to single-pod agents.
  volume_type   text NOT NULL CHECK (volume_type IN ('gp3', 'io2')),
  enabled       boolean NOT NULL DEFAULT true,
  version       bigint NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text NOT NULL DEFAULT afs.current_actor(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO afs.storage_classes (id, description, volume_type)
VALUES ('gp3', 'General purpose SSD, encrypted with the environment KMS key', 'gp3');

CREATE TRIGGER storage_classes_touch BEFORE UPDATE ON afs.storage_classes
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER storage_classes_revision AFTER INSERT OR UPDATE OR DELETE ON afs.storage_classes
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

-- 2. Volume settings on the agent -----------------------------------------------------------------
ALTER TABLE afs.agents
  ADD COLUMN storage_size_gib integer NOT NULL DEFAULT 20
    CONSTRAINT agents_storage_size_gib_check CHECK (storage_size_gib BETWEEN 1 AND 1000),
  ADD COLUMN storage_class text NOT NULL DEFAULT 'gp3'
    CONSTRAINT agents_storage_class_fk REFERENCES afs.storage_classes (id),
  -- delete: volume removed with the agent; retain: volume kept for a service admin to recover;
  -- snapshot_then_delete: final snapshot taken, then the volume removed.
  ADD COLUMN storage_on_delete text NOT NULL DEFAULT 'snapshot_then_delete'
    CONSTRAINT agents_storage_on_delete_check
    CHECK (storage_on_delete IN ('delete', 'retain', 'snapshot_then_delete')),
  ADD COLUMN snapshot_schedule text NOT NULL DEFAULT 'daily'
    CONSTRAINT agents_snapshot_schedule_check CHECK (snapshot_schedule IN ('off', 'daily', 'weekly')),
  ADD COLUMN snapshot_retain_count integer NOT NULL DEFAULT 7
    CONSTRAINT agents_snapshot_retain_count_check CHECK (snapshot_retain_count BETWEEN 1 AND 90);

COMMENT ON COLUMN afs.agents.storage_size_gib IS 'Persistent volume size. Can grow, never shrink (EBS cannot shrink).';
COMMENT ON COLUMN afs.agents.storage_class IS 'Set at creation; changing it would need a data migration, so it is immutable.';

CREATE FUNCTION afs.agent_storage_guard() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.storage_size_gib < OLD.storage_size_gib THEN
      RAISE EXCEPTION 'an agent''s volume can grow but not shrink (% GiB to % GiB)',
        OLD.storage_size_gib, NEW.storage_size_gib
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF NEW.storage_class IS DISTINCT FROM OLD.storage_class THEN
      RAISE EXCEPTION 'an agent''s storage class cannot change after creation'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM afs.storage_classes WHERE id = NEW.storage_class AND enabled) THEN
    RAISE EXCEPTION 'storage class % is not enabled', NEW.storage_class
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agents_storage_guard BEFORE INSERT OR UPDATE OF storage_size_gib, storage_class ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.agent_storage_guard();

-- 3. Snapshots of agent volumes -------------------------------------------------------------------
-- Rows are history: the reconciler marks pruned snapshots 'deleted' rather than removing the row.
CREATE TABLE afs.agent_volume_snapshots (
  id              text PRIMARY KEY CHECK (afs.ulid_ok(id, 'vsnap')),
  team_id         text NOT NULL,
  agent_id        text NOT NULL,
  -- scheduled: from snapshot_schedule; manual: requested by a team-admin; pre_delete: final snapshot
  -- before the volume is removed; pre_change: before an expansion.
  reason          text NOT NULL CHECK (reason IN ('scheduled', 'manual', 'pre_delete', 'pre_change')),
  state           text NOT NULL DEFAULT 'requested'
                    CHECK (state IN ('requested', 'pending', 'completed', 'failed', 'deleted')),
  -- Filled by the reconciler once AWS accepts the request.
  ebs_snapshot_id text CHECK (ebs_snapshot_id ~ '^snap-[0-9a-f]{8,17}$'),
  size_gib        integer CHECK (size_gib BETWEEN 1 AND 1000),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  requested_by    text NOT NULL DEFAULT afs.current_actor(),
  completed_at    timestamptz,
  CHECK (state IN ('requested', 'failed') OR ebs_snapshot_id IS NOT NULL),
  FOREIGN KEY (team_id, agent_id) REFERENCES afs.agents (team_id, id) ON DELETE RESTRICT
);

CREATE INDEX agent_volume_snapshots_agent_idx ON afs.agent_volume_snapshots (agent_id, requested_at DESC);

-- 4. Privileges and row-level security -------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON afs.storage_classes TO afs_app;
GRANT SELECT ON afs.storage_classes TO afs_reconciler, afs_readonly;

-- afs_app may only request a manual snapshot and read history; the reconciler does the rest.
GRANT SELECT, INSERT (id, team_id, agent_id, reason) ON afs.agent_volume_snapshots TO afs_app;
GRANT SELECT, INSERT ON afs.agent_volume_snapshots TO afs_reconciler;
GRANT UPDATE (state, ebs_snapshot_id, size_gib, completed_at) ON afs.agent_volume_snapshots TO afs_reconciler;
GRANT SELECT ON afs.agent_volume_snapshots TO afs_readonly;

ALTER TABLE afs.agent_volume_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_team_scope ON afs.agent_volume_snapshots TO afs_app
  USING (afs.caller_sees_team(team_id))
  WITH CHECK (afs.caller_sees_team(team_id) AND reason = 'manual');
CREATE POLICY service_roles_all ON afs.agent_volume_snapshots
  TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);
