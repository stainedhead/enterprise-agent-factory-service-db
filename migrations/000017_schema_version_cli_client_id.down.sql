-- Reverses 000017.
ALTER TABLE afs.identity_providers DROP COLUMN cli_client_id;
DROP FUNCTION afs.schema_version();
