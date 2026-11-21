-- Local and test use only. Production migrations are forward-only.
DROP TABLE IF EXISTS afs.agent_volume_snapshots;

DROP TRIGGER IF EXISTS agents_storage_guard ON afs.agents;
DROP FUNCTION IF EXISTS afs.agent_storage_guard();

ALTER TABLE afs.agents
  DROP COLUMN snapshot_retain_count,
  DROP COLUMN snapshot_schedule,
  DROP COLUMN storage_on_delete,
  DROP COLUMN storage_class,
  DROP COLUMN storage_size_gib;

DROP TABLE IF EXISTS afs.storage_classes;
