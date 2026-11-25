-- Reverses 000026. States without a stored verifier cannot complete under 000024, so they are removed first.
DELETE FROM afs.mcp_oauth_states WHERE code_verifier_arn IS NULL;
COMMENT ON COLUMN afs.mcp_oauth_states.code_verifier_arn IS NULL;
ALTER TABLE afs.mcp_oauth_states ALTER COLUMN code_verifier_arn SET NOT NULL;
