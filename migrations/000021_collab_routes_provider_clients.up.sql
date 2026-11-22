-- 000021 collab_routes provider client ids (up)
-- Lock impact: none. Only a function is replaced; no table is touched.
-- The return type changes, so the function is dropped and created again; the grants are repeated.
-- Security finding 6: the edge accepts REST bearer tokens minted for the team IdP's own clients
-- (console client_id and CLI cli_client_id), so collab_routes() now returns both. afs_edge still
-- reads no table; the ids are public OIDC client ids, not secrets.

DROP FUNCTION afs.collab_routes();

CREATE FUNCTION afs.collab_routes() RETURNS TABLE (
    team_id text, slug text, namespace text, hostname text, team_state text, agent_id text, agent_state text,
    web_ui_enabled boolean, rest_api_enabled boolean, web_ui_effective boolean, rest_api_effective boolean,
    may_expose boolean, ready boolean, not_ready_reason text, service_name text, port integer,
    provider_id text, issuer_url text, groups_claim text, collab_client_id text, collab_client_secret_arn text,
    provider_client_id text, provider_cli_client_id text)
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, afs
AS $$
  WITH cfg AS (
    SELECT (SELECT s.value #>> '{}' FROM afs.service_settings s WHERE s.key = 'collab.base_domain' AND jsonb_typeof(s.value) = 'string') AS base_domain,
           coalesce((SELECT (s.value #>> '{}')::boolean FROM afs.service_settings s
                      WHERE s.key = 'collab.public_endpoints' AND jsonb_typeof(s.value) = 'boolean'), true) AS public_endpoints
  ), r AS (
    SELECT t.id AS tid, t.slug AS tslug, t.namespace AS tns, t.state AS tstate, t.may_expose_collaboration AS expose,
           a.id AS aid, a.state AS astate, c.web_ui_enabled AS web, c.rest_api_enabled AS rest,
           p.id AS pid, p.issuer_url AS pissuer, p.groups_claim AS pgroups, p.collab_client_id AS pclient, p.collab_client_secret_arn AS parn,
           p.client_id AS pconsole, p.cli_client_id AS pcli,
           (t.state = 'active' AND a.state = 'enabled' AND EXISTS (
              SELECT 1 FROM afs.resource_status rs
               WHERE rs.resource_kind = 'team_collaboration' AND rs.resource_id = t.id
                 AND rs.conditions @> '[{"type": "EndpointReady", "status": "True"}]'::jsonb)) AS is_ready
      FROM afs.team_collaboration c
      JOIN afs.teams t ON t.id = c.team_id
      JOIN afs.agents a ON a.team_id = c.team_id AND a.id = c.agent_id
      LEFT JOIN afs.identity_providers p
             ON p.id = coalesce(t.identity_provider_id, (SELECT d.id FROM afs.identity_providers d WHERE d.is_default))
     WHERE t.state NOT IN ('deleting', 'deleted') AND t.deleted_at IS NULL
  )
  SELECT r.tid, r.tslug, r.tns,
         CASE WHEN cfg.base_domain IS NULL THEN NULL ELSE r.tslug || '.' || cfg.base_domain END,
         r.tstate, r.aid, r.astate, r.web, r.rest,
         r.web AND r.expose AND cfg.public_endpoints AND cfg.base_domain IS NOT NULL AND r.pclient IS NOT NULL,
         r.rest AND r.expose AND cfg.public_endpoints AND cfg.base_domain IS NOT NULL,
         r.expose, r.is_ready,
         CASE WHEN r.is_ready THEN NULL
              WHEN r.tstate = 'suspended' THEN 'team_suspended'
              WHEN r.astate = 'paused' THEN 'paused'
              ELSE 'starting' END,
         'paperclip'::text, 3100, r.pid, r.pissuer, r.pgroups, r.pclient, r.parn, r.pconsole, r.pcli
    FROM r CROSS JOIN cfg
   ORDER BY r.tid
$$;

REVOKE ALL ON FUNCTION afs.collab_routes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.collab_routes() TO afs_edge;
