-- 000012 swarms and pools; ephemeral teams and teardown; CVE work orders; viewer kubectl; CUR tag status.
--
-- J, 2026-11-21: implementation targets feature-complete, so the items once marked phase 2 and 3 are
-- built in full (TEAM-7, BUD-8, AGT-8, ACC-5, TAG-7, WO-1, WO-2).
--
-- Ephemeral teams (TEAM-7, BUD-8). An ephemeral team has an expiry no further out than service setting
-- teams.ephemeral_max_days, a lifetime budget that blocks at the cap, and a teardown rule:
-- at_expiry, at_cap_or_expiry, or at_work_complete (its work order is done, or expiry, whichever
-- first). Teardown stops agents and pools, revokes IAM and deletes the namespace; the team row,
-- configuration and audit are kept (state 'deleted', torn_down_at, teardown_reason). A team's kind
-- cannot change after creation.
--
-- Swarms and pools (AGT-8). A swarm is an ephemeral team. Besides agents (one identity, one pod), it
-- holds pools: one definition with its own identity (ServiceAccount, IAM role, GitHub identity), its
-- own secrets and configuration, and a worker count. Workers share the pool's identity. Pools may be
-- grouped into ordered stages and hand work to named pools. Storage per pool: a scratch volume per
-- worker, plus optionally one shared EFS volume for the pool; workers get no persistent volume. A pool
-- may use one shared named role in one or many organization accounts (pool_role_links), inside the
-- team's allowed accounts. Usage, activity, traffic and audit carry the pool and the worker pod.
-- Agent and pool names share one namespace per team, because both name pods and secret paths.
--
-- Work orders (WO-1, WO-2). Security operators (a new service-level role) create work orders by API,
-- or by EventBridge through the reconciler (deduplicated by the event id). A work order names a swarm
-- template and a cap; AFS creates the remediation team from the template, tracks a pull request per
-- affected repository, and notifies each owning team once per event kind, including an SLA warning
-- work_orders.sla_warning_hours before the due time. Service-level API keys may hold this role so
-- security tooling can call the API.
--
-- Viewer kubectl (ACC-5). Service admins may grant a team's viewers read-only kubectl on its namespace
-- (EKS access entry; no secrets, exec or port-forward).
--
-- CUR tag status (TAG-7). The billing job records which tag keys the CUR has seen and whether they
-- are active as cost allocation tags in AWS Billing.
--
-- Lock impact: brief ACCESS EXCLUSIVE on teams, secrets, api_keys, role_bindings, agent_identities,
-- external_system_optouts, audit_log, work_orders and the four fact tables for catalog changes
-- (nullable columns or constant defaults, no rewrites). The primary keys of agent_activity and
-- external_traffic become unique indexes, and cost_daily's unique index is rebuilt; these scan the
-- tables, which are empty before the first release. Work orders drop three unused columns and require
-- afs.work_orders to be empty (guard below).

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM afs.work_orders) THEN
    RAISE EXCEPTION '000012 requires afs.work_orders to be empty (its repository and result columns move to tables)'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END $$;

-- 1. Settings -------------------------------------------------------------------------------------
ALTER TABLE afs.service_settings ADD CONSTRAINT service_settings_swarm_check
  CHECK ((key <> 'teams.ephemeral_max_days'
          OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 1 AND 365))
     AND (key <> 'work_orders.sla_warning_hours'
          OR (jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric BETWEEN 1 AND 720))
     AND (key <> 'billing.tag_activation_acknowledged' OR jsonb_typeof(value) = 'boolean')
     AND (key <> 'work_orders.notification_channel_id'
          OR jsonb_typeof(value) = 'null'
          OR (jsonb_typeof(value) = 'string' AND afs.ulid_ok(value #>> '{}', 'nch'))));
INSERT INTO afs.service_settings (key, value, description) VALUES
  ('teams.ephemeral_max_days', '90', 'Longest expiry an ephemeral team may have, in days from now.'),
  ('work_orders.sla_warning_hours', '48', 'Owning teams are warned this many hours before a work order''s SLA is due.'),
  ('billing.tag_activation_acknowledged', 'false',
   'Set once a service admin has activated the AFS tag keys as cost allocation tags in AWS Billing.'),
  ('work_orders.notification_channel_id', 'null',
   'Service-level email channel used to notify work order owners outside AFS. Null: outside contacts are not notified.')
ON CONFLICT (key) DO NOTHING;

-- The outside-contact channel must be an existing, service-level email channel (D22).
CREATE FUNCTION afs.work_order_channel_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF NEW.key = 'work_orders.notification_channel_id' AND jsonb_typeof(NEW.value) = 'string'
     AND afs.ulid_ok(NEW.value #>> '{}', 'nch')
     AND NOT EXISTS (SELECT 1 FROM afs.notification_channels c
                     WHERE c.id = NEW.value #>> '{}' AND c.team_id IS NULL AND c.kind = 'email') THEN
    RAISE EXCEPTION 'work_orders.notification_channel_id must name a service-level email channel'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER service_settings_work_order_channel
  BEFORE INSERT OR UPDATE ON afs.service_settings
  FOR EACH ROW EXECUTE FUNCTION afs.work_order_channel_guard();

-- 2. Ephemeral teams ------------------------------------------------------------------------------
ALTER TABLE afs.teams
  ADD COLUMN teardown_rule text
    CONSTRAINT teams_teardown_rule_check CHECK (teardown_rule IN ('at_expiry', 'at_cap_or_expiry', 'at_work_complete')),
  ADD COLUMN torn_down_at timestamptz,
  ADD COLUMN teardown_reason text
    CONSTRAINT teams_teardown_reason_check CHECK (teardown_reason IN ('expired', 'cap_reached', 'work_complete', 'manual')),
  ADD COLUMN viewer_kubectl boolean NOT NULL DEFAULT false;
UPDATE afs.teams SET teardown_rule = 'at_cap_or_expiry' WHERE kind = 'ephemeral' AND teardown_rule IS NULL;
ALTER TABLE afs.teams
  ADD CONSTRAINT teams_teardown_rule_required CHECK ((kind = 'ephemeral') = (teardown_rule IS NOT NULL)),
  ADD CONSTRAINT teams_teardown_recorded CHECK ((torn_down_at IS NULL) = (teardown_reason IS NULL)),
  ADD CONSTRAINT teams_teardown_ephemeral CHECK (torn_down_at IS NULL OR kind = 'ephemeral');
COMMENT ON COLUMN afs.teams.viewer_kubectl IS
  'Service admins only: team viewers get read-only kubectl on the namespace (no secrets, exec or port-forward).';

CREATE FUNCTION afs.team_lifecycle_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
DECLARE
  v_max numeric;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.kind IS DISTINCT FROM OLD.kind THEN
    RAISE EXCEPTION 'a team''s kind cannot change; create a new team' USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF NEW.kind = 'ephemeral' AND NEW.state NOT IN ('deleting', 'deleted')
     AND (TG_OP = 'INSERT' OR NEW.expires_at IS DISTINCT FROM OLD.expires_at) THEN
    SELECT (value #>> '{}')::numeric INTO v_max FROM afs.service_settings WHERE key = 'teams.ephemeral_max_days';
    IF NEW.expires_at > now() + make_interval(days => coalesce(v_max, 90)::int) THEN
      RAISE EXCEPTION 'an ephemeral team expires at most % days from now', coalesce(v_max, 90)
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF current_user = 'afs_app' AND NOT afs.caller_is_service_admin()
     AND (TG_OP = 'INSERT' AND NEW.viewer_kubectl
          OR TG_OP = 'UPDATE' AND NEW.viewer_kubectl IS DISTINCT FROM OLD.viewer_kubectl) THEN
    RAISE EXCEPTION 'only service admins grant viewers kubectl access' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER teams_lifecycle_guard BEFORE INSERT OR UPDATE OF kind, expires_at, viewer_kubectl ON afs.teams
  FOR EACH ROW EXECUTE FUNCTION afs.team_lifecycle_guard();

-- An ephemeral team has a lifetime budget that blocks at the cap. Checked at commit, so the API can
-- insert the team and its budget in one transaction in either order.
CREATE FUNCTION afs.ephemeral_budget_check() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
DECLARE
  v_team text := coalesce(to_jsonb(NEW) ->> CASE TG_TABLE_NAME WHEN 'teams' THEN 'id' ELSE 'team_id' END,
                          to_jsonb(OLD) ->> CASE TG_TABLE_NAME WHEN 'teams' THEN 'id' ELSE 'team_id' END);
BEGIN
  IF EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = v_team AND t.kind = 'ephemeral' AND t.state NOT IN ('deleting', 'deleted'))
     AND NOT EXISTS (SELECT 1 FROM afs.budgets b
                     WHERE b.team_id = v_team AND b.period = 'lifetime' AND b.on_exhaust = 'block') THEN
    RAISE EXCEPTION 'ephemeral team % needs a lifetime budget that blocks at the cap', v_team
      USING ERRCODE = 'check_violation', CONSTRAINT = 'ephemeral_team_lifetime_budget';
  END IF;
  RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER teams_ephemeral_budget AFTER INSERT ON afs.teams
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.ephemeral_budget_check();
CREATE CONSTRAINT TRIGGER budgets_ephemeral_kept AFTER UPDATE OR DELETE ON afs.budgets
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION afs.ephemeral_budget_check();

-- Teams due for teardown, for the reconciler.
CREATE VIEW afs.teams_due_for_teardown WITH (security_invoker = true) AS
SELECT t.id AS team_id, t.teardown_rule,
       CASE
         WHEN t.expires_at <= now() THEN 'expired'
         WHEN t.teardown_rule = 'at_cap_or_expiry' AND p.spent_usd >= p.limit_usd THEN 'cap_reached'
         WHEN t.teardown_rule = 'at_work_complete'
              AND EXISTS (SELECT 1 FROM afs.work_orders w WHERE w.team_id = t.id AND w.status IN ('done', 'cancelled'))
              AND NOT EXISTS (SELECT 1 FROM afs.work_orders w WHERE w.team_id = t.id
                              AND w.status NOT IN ('done', 'failed', 'cancelled')) THEN 'work_complete'
       END AS reason
FROM afs.teams t
LEFT JOIN afs.team_budget_position p ON p.team_id = t.id
WHERE t.kind = 'ephemeral' AND t.state = 'active';

-- 3. Stages and pools -----------------------------------------------------------------------------
CREATE TABLE afs.swarm_stages (
  id          text PRIMARY KEY CHECK (afs.ulid_ok(id, 'stg')),
  team_id     text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (name ~ '^[a-z][a-z0-9-]{0,38}[a-z0-9]$'),
  position    smallint NOT NULL CHECK (position BETWEEN 1 AND 50),
  description text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  version     bigint NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text NOT NULL DEFAULT afs.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, name),
  UNIQUE (team_id, position),
  UNIQUE (team_id, id)
);

CREATE TABLE afs.agent_pools (
  id                 text PRIMARY KEY CHECK (afs.ulid_ok(id, 'pool')),
  team_id            text NOT NULL REFERENCES afs.teams (id) ON DELETE CASCADE,
  name               text NOT NULL CHECK (name ~ '^[a-z][a-z0-9-]{0,38}[a-z0-9]$'),
  description        text NOT NULL DEFAULT '',
  stage_id           text,
  template           text NOT NULL,
  image              text NOT NULL CHECK (image LIKE '%@sha256:%'),
  persona            text NOT NULL DEFAULT '',
  model_id           text NOT NULL,
  -- Desired worker count. 0 keeps the pool defined with no pods.
  workers            integer NOT NULL DEFAULT 1 CHECK (workers BETWEEN 0 AND 200),
  resources          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(resources) = 'object'),
  -- Per-worker ephemeral scratch volume, deleted with the worker.
  scratch_size_gib   integer NOT NULL DEFAULT 20 CHECK (scratch_size_gib BETWEEN 1 AND 500),
  -- Optional shared read-write volume for the whole pool.
  shared_volume      text NOT NULL DEFAULT 'none' CHECK (shared_volume IN ('none', 'efs')),
  state              text NOT NULL DEFAULT 'enabled' CHECK (state IN ('enabled', 'paused', 'deleting', 'deleted')),
  generation         bigint NOT NULL DEFAULT 1,
  version            bigint NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         text NOT NULL DEFAULT afs.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  UNIQUE (team_id, id),
  FOREIGN KEY (team_id, model_id) REFERENCES afs.team_models (team_id, model_id),
  FOREIGN KEY (team_id, stage_id) REFERENCES afs.swarm_stages (team_id, id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX agent_pools_team_name_uq ON afs.agent_pools (team_id, name) WHERE deleted_at IS NULL;
COMMENT ON TABLE afs.agent_pools IS
  'Swarm pools: one identity, N workers that share it. Only in ephemeral teams. Agent and pool names share a namespace.';

CREATE TABLE afs.pool_handoffs (
  team_id      text NOT NULL,
  from_pool_id text NOT NULL,
  to_pool_id   text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (from_pool_id, to_pool_id),
  CHECK (from_pool_id <> to_pool_id),
  FOREIGN KEY (team_id, from_pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE,
  FOREIGN KEY (team_id, to_pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);

-- Pools only in ephemeral teams; pool and agent names never clash; name and team are immutable.
CREATE FUNCTION afs.pool_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.name IS DISTINCT FROM OLD.name OR NEW.team_id IS DISTINCT FROM OLD.team_id THEN
      RAISE EXCEPTION 'a pool''s name and team cannot change (they name its identity and secret paths)'
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM afs.teams WHERE id = NEW.team_id AND kind = 'ephemeral') THEN
    RAISE EXCEPTION 'pools run only in ephemeral teams (swarms)' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM afs.agents WHERE team_id = NEW.team_id AND name = NEW.name AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'an agent named % already exists in this team', NEW.name USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER agent_pools_guard BEFORE INSERT OR UPDATE OF name, team_id ON afs.agent_pools
  FOR EACH ROW EXECUTE FUNCTION afs.pool_guard();

CREATE FUNCTION afs.agent_name_free_of_pools() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM afs.agent_pools WHERE team_id = NEW.team_id AND name = NEW.name AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'a pool named % already exists in this team', NEW.name USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER agents_name_free_of_pools BEFORE INSERT ON afs.agents
  FOR EACH ROW EXECUTE FUNCTION afs.agent_name_free_of_pools();

-- 4. Pool identity, secrets, configuration, external systems, roles ----------------------------------
ALTER TABLE afs.agent_identities
  ADD COLUMN pool_id text,
  ADD CONSTRAINT agent_identities_pool_fk FOREIGN KEY (team_id, pool_id)
    REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE,
  ADD CONSTRAINT agent_identities_one_owner CHECK (num_nonnulls(agent_id, pool_id) <= 1);
DROP INDEX afs.agent_identities_kind_uq;
CREATE UNIQUE INDEX agent_identities_kind_uq
  ON afs.agent_identities (team_id, agent_id, pool_id, kind) NULLS NOT DISTINCT;

ALTER TABLE afs.secrets
  ADD COLUMN pool_id text,
  ADD CONSTRAINT secrets_pool_fk FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT secrets_one_owner CHECK (num_nonnulls(agent_id, pool_id) <= 1);
COMMENT ON COLUMN afs.secrets.pool_id IS 'Set: the only pool that may be bound to it. Path segment is the pool name.';

-- Path: <prefix>/<namespace>/<agent or pool name, or _shared>/<secret-name>.
CREATE FUNCTION afs.secret_path(p_team_id text, p_agent_id text, p_pool_id text, p_name text) RETURNS text
  LANGUAGE plpgsql STABLE SET search_path = pg_catalog, afs AS $$
DECLARE
  v_owner text;
BEGIN
  IF p_pool_id IS NULL THEN
    RETURN afs.secret_path(p_team_id, p_agent_id, p_name);
  END IF;
  SELECT name INTO v_owner FROM afs.agent_pools WHERE team_id = p_team_id AND id = p_pool_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'pool % not found in team %', p_pool_id, p_team_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN regexp_replace(afs.secret_path(p_team_id, NULL, p_name), '/_shared/', '/' || v_owner || '/');
END;
$$;

CREATE OR REPLACE FUNCTION afs.secrets_managed_path() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.path := afs.secret_path(NEW.team_id, NEW.agent_id, NEW.pool_id, NEW.name);
  ELSIF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
     OR NEW.pool_id IS DISTINCT FROM OLD.pool_id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.path IS DISTINCT FROM OLD.path
     OR NEW.secrets_manager_arn IS DISTINCT FROM OLD.secrets_manager_arn THEN
    RAISE EXCEPTION 'a secret''s team, scope, name, path and ARN cannot change; create a new secret'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;

-- An agent binding may not use a pool's secret (and the 000003 rule for other agents' secrets stays).
CREATE OR REPLACE FUNCTION afs.binding_respects_scope() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
DECLARE
  v_agent text;
  v_pool  text;
BEGIN
  SELECT agent_id, pool_id INTO v_agent, v_pool FROM afs.secrets WHERE team_id = NEW.team_id AND id = NEW.secret_id;
  IF TG_TABLE_NAME = 'agent_secret_bindings' THEN
    IF v_pool IS NOT NULL OR (v_agent IS NOT NULL AND v_agent <> to_jsonb(NEW) ->> 'agent_id') THEN
      RAISE EXCEPTION 'secret % belongs to another agent or a pool and cannot be bound here', NEW.secret_id
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF v_agent IS NOT NULL OR (v_pool IS NOT NULL AND v_pool <> to_jsonb(NEW) ->> 'pool_id') THEN
    RAISE EXCEPTION 'secret % belongs to an agent or another pool and cannot be bound here', NEW.secret_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE afs.pool_secret_bindings (
  team_id    text NOT NULL,
  pool_id    text NOT NULL,
  secret_id  text NOT NULL,
  delivery   text NOT NULL CHECK (delivery IN ('env', 'file')),
  target     text NOT NULL CHECK (
               (delivery = 'env' AND target ~ '^[A-Z_][A-Z0-9_]{0,127}$')
            OR (delivery = 'file' AND target ~ '^/[A-Za-z0-9._/-]{1,255}$')),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL DEFAULT afs.current_actor(),
  PRIMARY KEY (pool_id, target),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE,
  FOREIGN KEY (team_id, secret_id) REFERENCES afs.secrets (team_id, id) ON DELETE RESTRICT
);
CREATE TRIGGER pool_secret_bindings_scope BEFORE INSERT OR UPDATE ON afs.pool_secret_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.binding_respects_scope();

CREATE TABLE afs.pool_config_values (
  id           text PRIMARY KEY CHECK (afs.ulid_ok(id, 'pcv')),
  team_id      text NOT NULL,
  pool_id      text NOT NULL,
  name         text NOT NULL CHECK (afs.config_name_ok(name)),
  source       text NOT NULL CHECK (source IN ('literal', 'namespace')),
  config_value text CHECK (length(config_value) <= 4096),
  version      bigint NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text NOT NULL DEFAULT afs.current_actor(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CHECK ((source = 'literal') = (config_value IS NOT NULL)),
  UNIQUE (pool_id, name),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);
CREATE INDEX pool_config_values_ns_idx ON afs.pool_config_values (team_id, name) WHERE source = 'namespace';

CREATE VIEW afs.pool_config_resolved WITH (security_invoker = true) AS
SELECT p.team_id, p.pool_id, p.name, p.source,
       CASE p.source WHEN 'literal' THEN p.config_value ELSE n.config_value END AS resolved_value,
       n.id AS namespace_value_id
FROM afs.pool_config_values p
LEFT JOIN afs.namespace_config_values n
       ON p.source = 'namespace' AND n.team_id = p.team_id AND n.name = p.name;

-- Same rules as agents: a namespace link must exist; config and secret env vars never share a name.
CREATE FUNCTION afs.pool_config_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF TG_TABLE_NAME = 'pool_config_values' THEN
    IF NEW.source = 'namespace' AND NOT EXISTS (
         SELECT 1 FROM afs.namespace_config_values n WHERE n.team_id = NEW.team_id AND n.name = NEW.name) THEN
      RAISE EXCEPTION 'no namespace value named % in this team', NEW.name USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM afs.pool_secret_bindings b
               WHERE b.pool_id = NEW.pool_id AND b.delivery = 'env' AND b.target = NEW.name) THEN
      RAISE EXCEPTION '% is already delivered to this pool as a secret', NEW.name USING ERRCODE = 'unique_violation';
    END IF;
  ELSIF (to_jsonb(NEW) ->> 'delivery') = 'env' AND EXISTS (
       SELECT 1 FROM afs.pool_config_values v
       WHERE v.pool_id = to_jsonb(NEW) ->> 'pool_id' AND v.name = to_jsonb(NEW) ->> 'target') THEN
    RAISE EXCEPTION '% is already a configuration value of this pool', to_jsonb(NEW) ->> 'target'
      USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER pool_config_values_guard BEFORE INSERT OR UPDATE ON afs.pool_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.pool_config_guard();
CREATE TRIGGER pool_secret_bindings_config_clash BEFORE INSERT OR UPDATE ON afs.pool_secret_bindings
  FOR EACH ROW EXECUTE FUNCTION afs.pool_config_guard();

CREATE OR REPLACE FUNCTION afs.namespace_config_in_use() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = pg_catalog, afs
AS $$
BEGIN
  IF (TG_OP = 'DELETE' OR NEW.name IS DISTINCT FROM OLD.name)
     AND (EXISTS (SELECT 1 FROM afs.agent_config_values a
                  WHERE a.source = 'namespace' AND a.team_id = OLD.team_id AND a.name = OLD.name)
          OR EXISTS (SELECT 1 FROM afs.pool_config_values p
                     WHERE p.source = 'namespace' AND p.team_id = OLD.team_id AND p.name = OLD.name))
     AND EXISTS (SELECT 1 FROM afs.teams t WHERE t.id = OLD.team_id) THEN
    RAISE EXCEPTION 'namespace value % is used by agents or pools; switch them to their own value first', OLD.name
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

ALTER TABLE afs.external_system_optouts
  ADD COLUMN pool_id text,
  ADD CONSTRAINT external_system_optouts_pool_fk FOREIGN KEY (team_id, pool_id)
    REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE,
  ADD CONSTRAINT external_system_optouts_one_owner CHECK (num_nonnulls(agent_id, pool_id) <= 1),
  DROP CONSTRAINT external_system_optouts_team_id_agent_id_system_id_key,
  ADD CONSTRAINT external_system_optouts_owner_system_key UNIQUE NULLS NOT DISTINCT (team_id, agent_id, pool_id, system_id);

CREATE VIEW afs.pool_external_access WITH (security_invoker = true) AS
SELECT p.team_id, p.id AS pool_id, s.id AS system_id, s.slug, s.name, s.category, s.endpoints,
       s.team_id IS NOT NULL AS team_declared,
       CASE
         WHEN NOT s.enabled THEN CASE WHEN s.team_id IS NULL THEN 'service' ELSE 'team' END
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.team_id = p.team_id AND o.agent_id IS NULL AND o.pool_id IS NULL AND o.system_id = s.id) THEN 'team'
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.pool_id = p.id AND o.system_id = s.id) THEN 'pool'
       END AS disabled_at
FROM afs.agent_pools p
JOIN afs.external_systems s ON s.team_id IS NULL OR s.team_id = p.team_id;

-- The 000007 view treated any opt-out with agent_id NULL as team-wide; pool opt-outs are not.
CREATE OR REPLACE VIEW afs.agent_external_access WITH (security_invoker = true) AS
SELECT a.team_id, a.id AS agent_id, s.id AS system_id, s.slug, s.name, s.category, s.endpoints,
       s.team_id IS NOT NULL AS team_declared,
       CASE
         WHEN NOT s.enabled THEN CASE WHEN s.team_id IS NULL THEN 'service' ELSE 'team' END
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.team_id = a.team_id AND o.agent_id IS NULL AND o.pool_id IS NULL AND o.system_id = s.id) THEN 'team'
         WHEN EXISTS (SELECT 1 FROM afs.external_system_optouts o
                      WHERE o.agent_id = a.id AND o.system_id = s.id) THEN 'agent'
       END AS disabled_at
FROM afs.agents a
JOIN afs.external_systems s ON s.team_id IS NULL OR s.team_id = a.team_id;

-- One shared named role (the same role name in every account) per pool, one link per account.
CREATE TABLE afs.pool_role_links (
  id                  text PRIMARY KEY CHECK (afs.ulid_ok(id, 'prl')),
  team_id             text NOT NULL,
  pool_id             text NOT NULL,
  account_id          text NOT NULL REFERENCES afs.org_aws_accounts (id) ON DELETE RESTRICT,
  role_name           text NOT NULL CHECK (role_name ~ '^[A-Za-z0-9+=,.@_-]{1,64}$'),
  role_arn            text GENERATED ALWAYS AS ('arn:aws:iam::' || account_id || ':role/' || role_name) STORED,
  profile_name        text NOT NULL CHECK (profile_name ~ '^[a-z][a-z0-9-]{0,62}$'),
  external_id         text NOT NULL UNIQUE CHECK (external_id ~ '^afs-[A-Za-z0-9]{20,64}$'),
  max_session_seconds integer NOT NULL DEFAULT 3600 CHECK (max_session_seconds BETWEEN 900 AND 43200),
  status              text NOT NULL DEFAULT 'pending_trust'
                        CHECK (status IN ('pending_trust', 'verified', 'failed', 'disabled')),
  last_verified_at    timestamptz,
  last_error          text,
  version             bigint NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          text NOT NULL DEFAULT afs.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pool_id, account_id),
  UNIQUE (pool_id, profile_name),
  FOREIGN KEY (team_id, pool_id) REFERENCES afs.agent_pools (team_id, id) ON DELETE CASCADE
);

CREATE FUNCTION afs.pool_role_link_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, afs AS $$
BEGIN
  IF NOT afs.account_allowed(NEW.team_id, NEW.account_id) THEN
    RAISE EXCEPTION 'account % is not in this team''s allowed accounts', NEW.account_id USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM afs.pool_role_links l
             WHERE l.pool_id = NEW.pool_id AND l.id <> NEW.id AND l.role_name <> NEW.role_name) THEN
    RAISE EXCEPTION 'a pool uses one shared role name in every account' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.role_name IS DISTINCT FROM OLD.role_name OR NEW.external_id IS DISTINCT FROM OLD.external_id
                           OR NEW.pool_id IS DISTINCT FROM OLD.pool_id OR NEW.account_id IS DISTINCT FROM OLD.account_id) THEN
    RAISE EXCEPTION 'a link''s pool, account, role and external ID cannot change; create a new link'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER pool_role_links_guard BEFORE INSERT OR UPDATE OF pool_id, account_id, role_name, external_id, team_id
  ON afs.pool_role_links FOR EACH ROW EXECUTE FUNCTION afs.pool_role_link_guard();

-- 5. Attribution to pools and worker pods ---------------------------------------------------------
-- A worker pod name is <pool name>-<suffix> as Kubernetes generates it.
CREATE FUNCTION afs.worker_pod_ok(p text) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  RETURN p ~ '^[a-z0-9]([a-z0-9-]{0,251}[a-z0-9])?$';

ALTER TABLE afs.usage_events
  ADD COLUMN pool_id text,
  ADD COLUMN worker_pod text CONSTRAINT usage_events_worker_pod_check CHECK (afs.worker_pod_ok(worker_pod)),
  ADD CONSTRAINT usage_events_subject_check
    CHECK ((pool_id IS NULL) = (worker_pod IS NULL) AND NOT (agent_id IS NOT NULL AND pool_id IS NOT NULL));

ALTER TABLE afs.cost_daily ADD COLUMN pool_id text,
  ADD CONSTRAINT cost_daily_subject_check CHECK (NOT (agent_id IS NOT NULL AND pool_id IS NOT NULL));
DROP INDEX afs.cost_daily_uq;
CREATE UNIQUE INDEX cost_daily_uq
  ON afs.cost_daily (team_id, day, source, agent_id, pool_id, model_id, tag_set_id) NULLS NOT DISTINCT;

ALTER TABLE afs.agent_activity
  DROP CONSTRAINT agent_activity_pkey,
  ALTER COLUMN agent_id DROP NOT NULL,
  ADD COLUMN pool_id text,
  ADD COLUMN worker_pod text CONSTRAINT agent_activity_worker_pod_check CHECK (afs.worker_pod_ok(worker_pod)),
  ADD CONSTRAINT agent_activity_subject_check
    CHECK ((agent_id IS NOT NULL AND pool_id IS NULL AND worker_pod IS NULL)
        OR (agent_id IS NULL AND pool_id IS NOT NULL AND worker_pod IS NOT NULL));
CREATE UNIQUE INDEX agent_activity_subject_uq
  ON afs.agent_activity (bucket_start, agent_id, pool_id, worker_pod) NULLS NOT DISTINCT;
CREATE INDEX agent_activity_pool_time_idx ON afs.agent_activity (pool_id, bucket_start) WHERE pool_id IS NOT NULL;

ALTER TABLE afs.external_traffic
  DROP CONSTRAINT external_traffic_pkey,
  ALTER COLUMN agent_id DROP NOT NULL,
  ADD COLUMN pool_id text,
  ADD COLUMN worker_pod text CONSTRAINT external_traffic_worker_pod_check CHECK (afs.worker_pod_ok(worker_pod)),
  ADD CONSTRAINT external_traffic_subject_check
    CHECK ((agent_id IS NOT NULL AND pool_id IS NULL AND worker_pod IS NULL)
        OR (agent_id IS NULL AND pool_id IS NOT NULL AND worker_pod IS NOT NULL)),
  DROP CONSTRAINT external_traffic_denied_reason_check,
  ADD CONSTRAINT external_traffic_denied_reason_check
    CHECK (denied_reason IN ('system_off_service', 'system_off_team', 'system_off_agent', 'system_off_pool', 'not_in_catalog'));
CREATE UNIQUE INDEX external_traffic_subject_uq
  ON afs.external_traffic (bucket_start, agent_id, pool_id, worker_pod, host, port, verdict) NULLS NOT DISTINCT;

-- Daily views gain pool_id (agent rows keep pool_id NULL, pool rows keep agent_id NULL).
CREATE OR REPLACE VIEW afs.agent_activity_daily WITH (security_invoker = true) AS
SELECT team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date AS day,
       count(*) FILTER (WHERE state = 'working') * 300 AS working_seconds,
       count(*) FILTER (WHERE state = 'idle') * 300 AS idle_seconds,
       count(*) FILTER (WHERE state IN ('paused', 'stopped')) * 300 AS off_seconds,
       count(*) FILTER (WHERE state IN ('unhealthy', 'blocked_budget')) * 300 AS impaired_seconds,
       sum(active_seconds) AS active_seconds,
       sum(model_calls) AS model_calls,
       sum(input_tokens) AS input_tokens,
       sum(output_tokens) AS output_tokens,
       sum(cost_usd) AS cost_usd,
       round(100.0 * count(*) FILTER (WHERE state = 'working')
             / nullif(count(*) FILTER (WHERE state IN ('working', 'idle')), 0), 1) AS utilization_pct,
       pool_id,
       count(DISTINCT worker_pod) AS workers
FROM afs.agent_activity
GROUP BY team_id, agent_id, pool_id, (bucket_start AT TIME ZONE 'UTC')::date;

CREATE OR REPLACE VIEW afs.external_traffic_daily WITH (security_invoker = true) AS
SELECT team_id, agent_id, (bucket_start AT TIME ZONE 'UTC')::date AS day, system_id,
       CASE WHEN system_id IS NULL THEN host END AS unmatched_host,
       sum(connections) FILTER (WHERE verdict = 'allowed') AS connections,
       sum(requests) FILTER (WHERE verdict = 'allowed') AS requests,
       sum(errors) FILTER (WHERE verdict = 'allowed') AS errors,
       sum(bytes_out) AS bytes_out,
       sum(bytes_in) AS bytes_in,
       coalesce(sum(connections) FILTER (WHERE verdict = 'denied'), 0) AS denied_connections,
       array_agg(DISTINCT denied_reason) FILTER (WHERE denied_reason IS NOT NULL) AS denied_reasons,
       pool_id
FROM afs.external_traffic
GROUP BY team_id, agent_id, pool_id, (bucket_start AT TIME ZONE 'UTC')::date, system_id,
         CASE WHEN system_id IS NULL THEN host END;

-- Workers per pool in their latest five-minute window, by state.
CREATE VIEW afs.pool_workers_current WITH (security_invoker = true) AS
SELECT p.team_id, p.id AS pool_id, p.workers AS desired_workers, l.bucket_start AS last_sample_at,
       count(l.worker_pod) AS reporting_workers,
       count(l.worker_pod) FILTER (WHERE l.state = 'working') AS working_workers,
       count(l.worker_pod) FILTER (WHERE l.state = 'idle') AS idle_workers,
       count(l.worker_pod) FILTER (WHERE l.state IN ('unhealthy', 'blocked_budget')) AS impaired_workers
FROM afs.agent_pools p
LEFT JOIN LATERAL (
  SELECT s.bucket_start, s.worker_pod, s.state FROM afs.agent_activity s
  WHERE s.pool_id = p.id
    AND s.bucket_start = (SELECT max(m.bucket_start) FROM afs.agent_activity m WHERE m.pool_id = p.id)) l ON true
GROUP BY p.team_id, p.id, p.workers, l.bucket_start;

ALTER TABLE afs.audit_log
  ADD COLUMN pool_id text,
  ADD COLUMN worker_pod text CONSTRAINT audit_log_worker_pod_check CHECK (afs.worker_pod_ok(worker_pod)),
  DROP CONSTRAINT audit_log_actor_type_check,
  ADD CONSTRAINT audit_log_actor_type_check CHECK (actor_type IN ('user', 'api_key', 'system', 'agent', 'pool'));
GRANT SELECT (pool_id, worker_pod) ON afs.audit_log TO afs_readonly;

-- 6. Security operators ---------------------------------------------------------------------------
ALTER TABLE afs.role_bindings
  DROP CONSTRAINT role_bindings_role_check,
  ADD CONSTRAINT role_bindings_role_check
    CHECK (role IN ('service_admin', 'security_operator', 'team_admin', 'team_viewer')),
  DROP CONSTRAINT role_bindings_check,
  ADD CONSTRAINT role_bindings_check CHECK ((role IN ('service_admin', 'security_operator')) = (team_id IS NULL));

-- Service-level API keys carry the security_operator role (for security tooling); team keys unchanged.
ALTER TABLE afs.api_keys
  ALTER COLUMN team_id DROP NOT NULL,
  DROP CONSTRAINT api_keys_role_check,
  ADD CONSTRAINT api_keys_role_check CHECK (role IN ('team_admin', 'team_viewer', 'security_operator')),
  ADD CONSTRAINT api_keys_scope_check CHECK ((role = 'security_operator') = (team_id IS NULL));

CREATE FUNCTION afs.caller_is_security_operator() RETURNS boolean
  LANGUAGE sql STABLE
  RETURN coalesce(current_setting('afs.security_operator', true), 'off') = 'on';

-- 7. Swarm templates and work orders -----------------------------------------------------------------
CREATE TABLE afs.swarm_templates (
  id            text PRIMARY KEY CHECK (afs.ulid_ok(id, 'swt')),
  name          text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9-]{1,38}[a-z0-9]$'),
  description   text NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
  kind          text NOT NULL CHECK (kind IN ('general', 'cve_remediation')),
  -- Stages, pools (template, image, model, workers, storage, role name), handoffs, secrets to create
  -- empty, configuration values. Validated by the API against the OpenAPI schema SwarmTemplateSpec.
  spec          jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object' AND spec ? 'pools'),
  budget_usd    numeric(12, 2) NOT NULL CHECK (budget_usd > 0),
  ttl_hours     integer NOT NULL CHECK (ttl_hours BETWEEN 1 AND 8760),
  teardown_rule text NOT NULL DEFAULT 'at_work_complete'
                  CHECK (teardown_rule IN ('at_expiry', 'at_cap_or_expiry', 'at_work_complete')),
  enabled       boolean NOT NULL DEFAULT true,
  version       bigint NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text NOT NULL DEFAULT afs.current_actor(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE afs.work_orders
  DROP COLUMN target_repos,
  DROP COLUMN owning_team,
  DROP COLUMN results,
  ADD COLUMN severity text NOT NULL DEFAULT 'high'
    CONSTRAINT work_orders_severity_check CHECK (severity IN ('critical', 'high', 'medium', 'low')),
  ADD COLUMN source text NOT NULL DEFAULT 'api' CONSTRAINT work_orders_source_check CHECK (source IN ('api', 'eventbridge')),
  ADD COLUMN source_event_id text,
  ADD COLUMN template_id text REFERENCES afs.swarm_templates (id) ON DELETE RESTRICT,
  ADD COLUMN budget_usd numeric(12, 2) CONSTRAINT work_orders_budget_check CHECK (budget_usd > 0),
  ADD COLUMN assigned_at timestamptz,
  ADD COLUMN completed_at timestamptz,
  ADD CONSTRAINT work_orders_event_once UNIQUE (source, source_event_id),
  ADD CONSTRAINT work_orders_event_id_check CHECK ((source = 'eventbridge') = (source_event_id IS NOT NULL)),
  ADD CONSTRAINT work_orders_assigned_check CHECK (status IN ('open', 'cancelled') OR team_id IS NOT NULL),
  ADD CONSTRAINT work_orders_template_check CHECK (kind <> 'cve_remediation' OR template_id IS NOT NULL);
CREATE UNIQUE INDEX work_orders_open_cve_uq ON afs.work_orders (external_ref)
  WHERE kind = 'cve_remediation' AND status NOT IN ('done', 'failed', 'cancelled');
CREATE TRIGGER swarm_templates_touch BEFORE UPDATE ON afs.swarm_templates
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER swarm_templates_revision AFTER INSERT OR UPDATE OR DELETE ON afs.swarm_templates
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

CREATE TABLE afs.work_order_repos (
  work_order_id  text NOT NULL REFERENCES afs.work_orders (id) ON DELETE CASCADE,
  repo           text NOT NULL CHECK (repo ~ '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'),
  host           text NOT NULL DEFAULT 'github.com'
                   CHECK (host ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  -- Who owns the repository: an AFS team, or a contact outside AFS (email), or both.
  owning_team_id text REFERENCES afs.teams (id) ON DELETE SET NULL,
  owning_contact text CHECK (owning_contact ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(owning_contact) <= 254),
  status         text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'in_progress', 'pr_opened', 'merged', 'not_affected', 'failed', 'skipped')),
  pr_url         text CHECK (pr_url ~ '^https://' AND length(pr_url) <= 500),
  pr_number      integer CHECK (pr_number > 0),
  detail         text CHECK (length(detail) <= 1000),
  version        bigint NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  merged_at      timestamptz,
  PRIMARY KEY (work_order_id, host, repo),
  CHECK (num_nonnulls(owning_team_id, owning_contact) >= 1),
  CHECK (status NOT IN ('pr_opened', 'merged') OR pr_url IS NOT NULL),
  CHECK ((status = 'merged') = (merged_at IS NOT NULL))
);
CREATE INDEX work_order_repos_owner_idx ON afs.work_order_repos (owning_team_id) WHERE owning_team_id IS NOT NULL;
CREATE TRIGGER work_order_repos_touch BEFORE UPDATE ON afs.work_order_repos
  FOR EACH ROW EXECUTE FUNCTION afs.touch_row();

-- Each notification is sent once per work order, repository and kind.
CREATE TABLE afs.work_order_notifications (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  work_order_id text NOT NULL REFERENCES afs.work_orders (id) ON DELETE CASCADE,
  host          text,
  repo          text,
  kind          text NOT NULL CHECK (kind IN ('assigned', 'pr_opened', 'merged', 'sla_warning', 'sla_breached', 'completed')),
  recipient     text NOT NULL CHECK (length(recipient) <= 254),
  channel_id    text REFERENCES afs.notification_channels (id) ON DELETE SET NULL,
  sent_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((host IS NULL) = (repo IS NULL)),
  UNIQUE NULLS NOT DISTINCT (work_order_id, host, repo, kind, recipient),
  FOREIGN KEY (work_order_id, host, repo) REFERENCES afs.work_order_repos (work_order_id, host, repo) ON DELETE CASCADE
);

-- Progress and SLA state per work order.
CREATE VIEW afs.work_order_progress WITH (security_invoker = true) AS
SELECT w.id AS work_order_id, w.kind, w.external_ref, w.severity, w.status, w.team_id, w.sla_due_at,
       count(r.repo) AS repos,
       count(r.repo) FILTER (WHERE r.status = 'pr_opened') AS prs_open,
       count(r.repo) FILTER (WHERE r.status = 'merged') AS prs_merged,
       count(r.repo) FILTER (WHERE r.status = 'not_affected') AS not_affected,
       count(r.repo) FILTER (WHERE r.status IN ('failed', 'skipped')) AS failed_or_skipped,
       count(r.repo) FILTER (WHERE r.status IN ('pending', 'in_progress')) AS remaining,
       CASE
         WHEN w.sla_due_at IS NULL THEN NULL
         WHEN w.status IN ('done', 'cancelled') THEN CASE WHEN coalesce(w.completed_at, now()) <= w.sla_due_at THEN 'met' ELSE 'missed' END
         WHEN now() > w.sla_due_at THEN 'breached'
         WHEN now() > w.sla_due_at - make_interval(hours => coalesce(
                (SELECT (value #>> '{}')::int FROM afs.service_settings WHERE key = 'work_orders.sla_warning_hours'), 48))
           THEN 'due_soon'
         ELSE 'on_track'
       END AS sla_state
FROM afs.work_orders w
LEFT JOIN afs.work_order_repos r ON r.work_order_id = w.id
GROUP BY w.id;

-- 8. CUR tag status ---------------------------------------------------------------------------------
CREATE TABLE afs.cost_allocation_tag_status (
  key           text PRIMARY KEY CHECK (key ~ '^[A-Za-z0-9 _.:/=+@-]{1,128}$'),
  seen_in_cur   boolean NOT NULL DEFAULT false,
  first_seen_at timestamptz,
  last_seen_at  timestamptz,
  aws_status    text NOT NULL DEFAULT 'unknown' CHECK (aws_status IN ('active', 'inactive', 'unknown')),
  checked_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (seen_in_cur = (first_seen_at IS NOT NULL))
);

-- 9. Revisions, privileges, row-level security ------------------------------------------------------
CREATE TRIGGER swarm_stages_touch BEFORE UPDATE ON afs.swarm_stages FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER swarm_stages_revision AFTER INSERT OR UPDATE OR DELETE ON afs.swarm_stages
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER agent_pools_touch BEFORE UPDATE ON afs.agent_pools FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER agent_pools_revision AFTER INSERT OR UPDATE OR DELETE ON afs.agent_pools
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER pool_config_values_touch BEFORE UPDATE ON afs.pool_config_values FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER pool_config_values_revision AFTER INSERT OR UPDATE OR DELETE ON afs.pool_config_values
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();
CREATE TRIGGER pool_role_links_touch BEFORE UPDATE ON afs.pool_role_links FOR EACH ROW EXECUTE FUNCTION afs.touch_row();
CREATE TRIGGER pool_role_links_revision AFTER INSERT OR UPDATE OR DELETE ON afs.pool_role_links
  FOR EACH ROW EXECUTE FUNCTION afs.record_revision();

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['swarm_stages', 'agent_pools', 'pool_handoffs', 'pool_secret_bindings',
                           'pool_config_values', 'pool_role_links']
  LOOP
    EXECUTE format('ALTER TABLE afs.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY app_team_scope ON afs.%I TO afs_app USING (afs.caller_sees_team(team_id)) WITH CHECK (afs.caller_sees_team(team_id))', t);
    EXECUTE format('CREATE POLICY service_roles_all ON afs.%I TO afs_reconciler, afs_gateway, afs_billing, afs_readonly USING (true) WITH CHECK (true)', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON afs.%I TO afs_app', t);
    EXECUTE format('GRANT SELECT ON afs.%I TO afs_reconciler, afs_billing, afs_readonly', t);
  END LOOP;
END
$$;
GRANT SELECT ON afs.agent_pools TO afs_gateway;
GRANT UPDATE (status, last_verified_at, last_error) ON afs.pool_role_links TO afs_reconciler;
GRANT SELECT ON afs.pool_config_resolved, afs.pool_external_access, afs.pool_workers_current, afs.teams_due_for_teardown
  TO afs_app, afs_reconciler, afs_readonly;
GRANT UPDATE (state, torn_down_at, teardown_reason) ON afs.teams TO afs_reconciler;

-- Work orders: security operators and service admins see and change all; a team sees work orders
-- assigned to it and those touching repositories it owns.
-- The two policies look each other up through SECURITY DEFINER helpers, so neither recurses into the
-- other's policy.
CREATE FUNCTION afs.work_order_team(p_work_order_id text) RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, afs
  RETURN (SELECT team_id FROM afs.work_orders WHERE id = p_work_order_id);
CREATE FUNCTION afs.caller_owns_work_order_repo(p_work_order_id text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, afs
  RETURN EXISTS (SELECT 1 FROM afs.work_order_repos r
                 WHERE r.work_order_id = p_work_order_id AND r.owning_team_id IS NOT NULL
                   AND afs.caller_sees_team(r.owning_team_id));
REVOKE EXECUTE ON FUNCTION afs.work_order_team(text), afs.caller_owns_work_order_repo(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION afs.work_order_team(text), afs.caller_owns_work_order_repo(text) TO afs_app;

DROP POLICY app_team_scope ON afs.work_orders;
CREATE POLICY app_scope ON afs.work_orders TO afs_app
  USING (afs.caller_is_security_operator() OR afs.caller_sees_team(team_id) OR afs.caller_owns_work_order_repo(id))
  WITH CHECK (afs.caller_is_security_operator() OR afs.caller_is_service_admin() OR afs.caller_sees_team(team_id));

ALTER TABLE afs.work_order_repos ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_scope ON afs.work_order_repos TO afs_app
  USING (afs.caller_is_security_operator() OR afs.caller_sees_team(owning_team_id)
         OR afs.caller_sees_team(afs.work_order_team(work_order_id)))
  WITH CHECK (afs.caller_is_security_operator() OR afs.caller_is_service_admin()
              OR afs.caller_sees_team(afs.work_order_team(work_order_id)));
CREATE POLICY service_roles_all ON afs.work_order_repos TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

ALTER TABLE afs.work_order_notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_scope ON afs.work_order_notifications FOR SELECT TO afs_app
  USING (afs.caller_is_security_operator() OR afs.caller_sees_team(afs.work_order_team(work_order_id))
         OR afs.caller_owns_work_order_repo(work_order_id));
CREATE POLICY service_roles_all ON afs.work_order_notifications TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

ALTER TABLE afs.swarm_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.swarm_templates FOR SELECT TO afs_app USING (true);
CREATE POLICY app_write ON afs.swarm_templates FOR ALL TO afs_app
  USING (afs.caller_is_service_admin()) WITH CHECK (afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.swarm_templates TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

ALTER TABLE afs.cost_allocation_tag_status ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_read ON afs.cost_allocation_tag_status FOR SELECT TO afs_app USING (afs.caller_is_service_admin());
CREATE POLICY service_roles_all ON afs.cost_allocation_tag_status TO afs_reconciler, afs_gateway, afs_billing, afs_readonly
  USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON afs.swarm_templates TO afs_app;
GRANT SELECT, INSERT, UPDATE ON afs.work_order_repos TO afs_app;
GRANT SELECT ON afs.work_order_notifications, afs.work_order_progress, afs.cost_allocation_tag_status TO afs_app;
GRANT SELECT ON afs.swarm_templates, afs.work_order_repos, afs.work_order_notifications, afs.work_order_progress,
  afs.cost_allocation_tag_status TO afs_reconciler, afs_readonly;
-- The reconciler takes EventBridge work orders, assigns teams and records repository progress and
-- notifications.
GRANT INSERT, UPDATE (status, team_id, assigned_at, completed_at) ON afs.work_orders TO afs_reconciler;
GRANT INSERT, UPDATE (status, pr_url, pr_number, detail, merged_at) ON afs.work_order_repos TO afs_reconciler;
GRANT INSERT ON afs.work_order_notifications TO afs_reconciler;
GRANT SELECT, INSERT, UPDATE ON afs.cost_allocation_tag_status TO afs_billing;
