-- 000026: the OAuth connect verifier is derived, not stored (release 1.3.0; MCP gateway PRD §9 case 5, API contract CD-48).
--
-- 000024 kept the PKCE code verifier of a pending OAuth connect in Secrets Manager and its ARN in
-- afs.mcp_oauth_states.code_verifier_arn. Reading it back at the callback would make afs-api read a secret, which it
-- never does (it writes secret values only). afs-api now derives the verifier from the state with a keyed HMAC, so a
-- new state row stores no verifier and the column becomes optional. Existing rows (at most 10 minutes old) keep theirs.
--
-- Lock impact: ALTER COLUMN ... DROP NOT NULL takes a brief ACCESS EXCLUSIVE lock on mcp_oauth_states (tiny, short-lived
-- rows); no rewrite.

ALTER TABLE afs.mcp_oauth_states ALTER COLUMN code_verifier_arn DROP NOT NULL;
COMMENT ON COLUMN afs.mcp_oauth_states.code_verifier_arn IS
  'Deprecated (000026): NULL for new states; afs-api derives the PKCE verifier from the state. Never a value.';
