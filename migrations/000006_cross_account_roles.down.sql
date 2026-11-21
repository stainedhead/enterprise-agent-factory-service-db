-- Local and test use only. Production migrations are forward-only.
DROP TRIGGER IF EXISTS agents_identity_guard ON afs.agents;
DROP FUNCTION IF EXISTS afs.agent_identity_guard();

DROP TABLE IF EXISTS afs.agent_role_links;
DROP FUNCTION IF EXISTS afs.agent_role_link_guard();
DROP FUNCTION IF EXISTS afs.account_allowed(text, text);
DROP FUNCTION IF EXISTS afs.glob_like(text);
ALTER TABLE afs.teams DROP COLUMN allowed_aws_accounts;
DROP TABLE IF EXISTS afs.org_aws_accounts;

ALTER TABLE afs.agents DROP COLUMN iam_identity;
