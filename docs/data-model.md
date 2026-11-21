# Data model

Schema `afs`, PostgreSQL 17. Source: `migrations/`. Keep this file in step with every migration.

## Entity overview

```mermaid
erDiagram
    teams ||--o{ role_bindings : "grants"
    users ||--o{ role_bindings : "holds"
    teams ||--o{ api_keys : ""
    teams ||--o{ agents : ""
    teams ||--o{ secrets : ""
    teams ||--o{ team_models : "enables"
    models ||--o{ team_models : ""
    models ||--o{ model_prices : "priced by"
    agents ||--o{ agent_secret_bindings : ""
    agents ||--o{ agent_volume_snapshots : ""
    agents ||--o{ agent_config_values : ""
    agents ||--o{ agent_role_links : ""
    org_aws_accounts ||--o{ agent_role_links : ""
    teams ||--o{ namespace_config_values : ""
    storage_classes ||--o{ agents : ""
    secrets ||--o{ agent_secret_bindings : ""
    teams ||--o{ agent_identities : ""
    agents ||--o{ agent_identities : ""
    teams ||--o{ external_systems : "declares"
    external_systems ||--o{ external_system_optouts : ""
    agents ||--o{ external_system_optouts : ""
    external_systems ||--o{ secrets : "credential for"
    teams ||--|| budgets : "has"
    budgets ||--o{ spend_counters : "per period"
    budgets ||--o{ budget_threshold_events : ""
    teams ||--o{ usage_events : ""
    teams ||--o{ cost_daily : ""
    agents ||--o{ agent_activity : "samples"
    agents ||--o{ external_traffic : "flows"
    teams ||--o{ cost_reconciliations : ""
    teams ||--o{ log_destinations : ""
    teams ||--o{ notification_channels : ""
    teams ||--o{ work_orders : ""
    teams ||--o{ resource_status : ""
```

## Tables

| Table | Purpose | Key columns and rules |
|---|---|---|
| `service_settings` | Service-wide settings (key → JSON) | Service admins only |
| `users` | People, provisioned just-in-time from OIDC | Unique `(oidc_issuer, oidc_subject)`, unique `lower(email)` |
| `teams` | A software factory; one namespace | `slug` fixes `namespace = afs-t-<slug>`; `kind` persistent/ephemeral (ephemeral requires `expires_at`); `max_budget_usd` ceiling; `state` active/suspended/deleting/deleted; `allowed_aws_accounts` glob patterns over organization account ids and names (`*` = all) that bound cross-account role links, set by service admins; `may_add_external_systems` lets the team declare its own external systems and `may_manage_aws_accounts` lets its team-admins set `allowed_aws_accounts` (000009), both set by service admins (guarded by trigger for `afs_app` callers who are not service admins); `identity_provider_id` the service-level provider the team's people sign in with (NULL = the service default; must be enabled), chosen when the team is created or managed (000010) |
| `role_bindings` | Who holds which role where | `service_admin` ⇔ `team_id IS NULL`; subject is a user or an IdP group |
| `api_keys` | Team-scoped keys for pipelines | SHA-256 only, shown once, `expires_at ≤ created_at + 90 days` |
| `models` | Bedrock models in the catalog | `id` is the Bedrock model id |
| `model_prices` | Effective-dated prices per million tokens | PK `(model_id, effective_from)` |
| `team_models` | Models enabled per team | `inference_profile_arn` written by the reconciler |
| `secrets` | Secrets Manager **references** | Scope `agent_id` (NULL = team shared); `path` set by the database as `<prefix>/<namespace>/<agent-name or _shared>/<name>`, never by users; ARN must end in that path; origin `managed` only; team, scope, name, path and ARN immutable; optional `external_system_id` names the system it is a credential for (service-level or own team's); **no value column** |
| `agents` | Agent definitions (desired state) | One agent is one pod (no replica count); `iam_identity` team_shared or dedicated (cannot go back to shared while it has cross-account links); name immutable; image pinned by digest; model must be in `team_models` (composite FK); persistent volume settings: `storage_size_gib` (1–1000, grow only), `storage_class` (immutable, must be enabled), `storage_on_delete`, `snapshot_schedule`, `snapshot_retain_count` |
| `namespace_config_values` | Non-secret configuration values for a team's namespace, set by team-admins | `UPPER_SNAKE` names, credential-like names rejected; cannot be deleted or renamed while an agent links to it |
| `agent_config_values` | An agent's configuration values | `source` literal (own value) or namespace (link to the namespace value of the same name, which must exist); names cannot clash with the agent's secret env vars; replaces the old `agents.env` |
| `agent_config_resolved` (view) | Effective value per agent entry and where it came from | `security_invoker`, so RLS applies |
| `org_aws_accounts` | Mirror of the AWS Organizations account list (reconciler-written) | Used to resolve account names and refuse suspended accounts |
| `agent_role_links` | Roles in linked accounts an agent may assume | Agent must have `iam_identity = 'dedicated'`; account active and allowed by the team's filter (`afs.account_allowed`); role ARN must be in that account; AFS-generated unique `external_id`; `status` pending_trust/verified/failed/disabled written by the reconciler; role and external ID immutable |
| `storage_classes` | Storage classes a service admin offers for agent volumes | EBS `gp3` or `io2`; seeded with `gp3` |
| `agent_volume_snapshots` | EBS snapshot history per agent volume | Reconciler-written; `afs_app` may only insert `manual` requests for its own team; rows kept as history; referenced by export bundles |
| `agent_secret_bindings` | How a secret reaches an agent | env var or file target; composite FKs keep agent and secret in the same team; an agent secret binds only to its own agent (trigger) |
| `agent_identities` | ServiceAccount, IAM role, GitHub App, external | One per `(team, agent, kind)`; credentials as `secret_id` |
| `identity_providers` | OIDC providers (Okta, Microsoft Entra ID), service level only (000010 removed the team-level providers of 000009) | One default (Okta by convention), which must stay enabled; unique HTTPS issuer; client secret as a Secrets Manager ARN only; service admins write, every caller reads; cannot be disabled while a team uses it; service-level group `role_bindings` may name one (`identity_provider_id`), team bindings use the team's provider and name none |
| `service_tags` | Cost-allocation tag keys defined by service admins | `mode` fixed (one `value` for every team) or required (every team gives a value, optionally from `allowed_values`; `default_value` covers teams that predate the key); keys follow AWS tag rules, case-insensitively unique, never `aws:`/`afs-`/`afs:` or credential-like; cannot become fixed while teams set the key |
| `team_tags` | A team's values for required keys plus its own optional tags | Cannot set a fixed key or a value outside `allowed_values`; at most 45 tags with the service's; a new team must give every required key without a default in its creating transaction, and cannot remove one later (deferred constraint triggers) |
| `team_effective_tags` (view) | Every tag a team carries and its `source` | system (`afs-team-id`), service (fixed), team, service_default, or missing (required key with no value: `value` NULL) |
| `agent_effective_tags` (view) | Tags on an agent's AWS resources, pod (`/etc/afs/tags`) and Bedrock calls | The team's tags with values, plus system tag `afs-agent-id`; read by the reconciler and the gateway |
| `cost_daily_by_tag`, `agent_activity_daily_by_tag`, `external_traffic_daily_by_tag` (views) | Reporting rollups by tag key and value | Attribute each team's daily figures to its current tags; system keys left out; `tag_value` NULL = untagged; RLS applies |
| `external_systems` | Catalog of outside services agents may reach | `team_id` NULL = service catalog (service admins write it; every team reads it), set = declared by that team (needs `teams.may_add_external_systems`; `owner` and `purpose` required; cannot reuse a catalog slug); `endpoints` hosts or `*.domain` with optional port, rendered into each agent's egress policy; `enabled` off switches it off at and below its level; `builtin` entries (Atlassian, GitHub, Outlook, Microsoft Teams, Azure, Google, Slack, Okta, OpenAI, OpenRouter) cannot be deleted; category `llm` = non-Bedrock model provider, not metered or capped, seeded off. Replaces `team_egress_rules` (000007) |
| `external_system_optouts` | Switches a system off for a whole team (`agent_id` NULL) or one agent | Default on; a row only narrows; unique per (team, agent, system) |
| `agent_external_access` (view) | Effective access per agent and system | `disabled_at` service/team/agent, or NULL when allowed; read by the reconciler and the API |
| `agent_activity` | One sample per agent per five-minute window (partitioned by month, written by the reconciler's activity collector) | `state` working/idle/paused/stopped/unhealthy/blocked_budget; working = a model call, the agent reporting busy, or CPU above the idle threshold; `active_seconds`, calls, tokens, cost, CPU and memory averages, optional `activity_note`; windows aligned to 5 minutes; non-working windows have no active seconds or calls |
| `agent_activity_daily` (view) | Time in each state, calls, tokens and cost per agent and day | `utilization_pct` = working ÷ (working + idle) |
| `agent_activity_current` (view) | Latest state per agent | `idle_since` = end of the last working window when the agent is idle |
| `external_traffic` | Connections from each agent to outside hosts per five-minute window (partitioned by month, from Cilium flow logs) | `system_id` the catalog or team system matched (NULL when none); `verdict` allowed/denied with `denied_reason` system_off_service/team/agent or not_in_catalog; bytes each way; `requests` and `errors` only where an egress proxy sees HTTP |
| `external_traffic_daily` (view) | Daily traffic per agent and system (or unmatched host) | Allowed connections, requests, errors, bytes, denied connections and reasons |
| `team_budget_position` (view) | Current-period budget, spent, reserved and % used per team | Reads the latest `spend_counters` row |
| `budgets` | One budget per team | `amount_usd ≤ teams.max_budget_usd` (trigger); `period` monthly/lifetime; thresholds; `on_exhaust` block/notify |
| `spend_counters` | Real-time spend per budget period | `limit_usd`, `spent_usd`, `reserved_usd`; changed only via `reserve_spend` / `settle_spend` |
| `budget_threshold_events` | Thresholds already crossed per period | PK makes alerts fire once |
| `usage_events` | Per-request ledger from the gateway | Partitioned monthly by `occurred_at`; `ensure_usage_partition(month)` |
| `cost_daily` | Daily cost by team/agent/model and source | Sources: gateway, cur_bedrock, cur_eks, cur_other; `calls` counts model calls for gateway rows (000008) |
| `cost_reconciliations` | Gateway estimate vs billed, per team-day | `variance_pct` generated; `over_threshold` when beyond setting `billing.variance_alert_pct` (default 5) |
| `model_price_proposals` | New model prices the billing job reads from the AWS Price List (setting `pricing.price_list_sync`) | One pending per model; only service admins approve or reject, only the billing job supersedes; approval writes a `model_prices` row (source `aws_price_list`) effective no earlier than the approval |
| `log_destinations` | Per-team log delivery | Non-secret config JSON; tokens via `secret_id` |
| `notification_channels` | Slack, email, webhook, Jira, EventBridge | `team_id NULL` = service-level |
| `work_orders` | Phase 2/3 jobs, incl. CVE remediation | CVE id format and SLA required for `cve_remediation` |
| `resource_status` | Reconciler's view: phase, conditions, observed generation | Written by `afs_reconciler` |
| `outbox_events` | Transactional outbox → EventBridge | Unpublished index; `published_at` set by the publisher |
| `config_revisions` | Snapshot of every desired-state row change | Written only by trigger (SECURITY DEFINER) |
| `audit_log` | Every mutation, denial and drift correction | Append-only (trigger blocks UPDATE/DELETE/TRUNCATE) |
| `export_bundles` | Export/import runs | Checksum, S3 location, dry-run flag |

## Functions

| Function | Used by | Purpose |
|---|---|---|
| `afs.secret_path(team_id, agent_id, name) → text` | api (before `CreateSecret`), secrets insert trigger | Managed Secrets Manager name from setting `secrets.path_prefix` (default `afs`), team namespace and agent name |
| `afs.reserve_spend(budget, period_start, amount) → boolean` | gateway | Atomically reserve if `spent + reserved + amount ≤ limit` |
| `afs.settle_spend(budget, period_start, reserved, actual)` | gateway | Release reservation, add actual cost |
| `afs.ensure_usage_partition(month) → text` | reconciler | Create next month's `usage_events` partition |
| `afs.caller_sees_team(team_id) → boolean` | RLS | True for service admins or teams in `afs.team_ids` |
| `afs.current_actor() → text` | defaults, triggers | `afs.actor` setting or `system:<session_user>` |
| `afs.tag_key_ok(key)`, `afs.tag_value_ok(value)`, `afs.tag_values_ok(values)` | tag checks | AWS tag character rules; reserved and credential-like keys refused |
| `afs.team_missing_required_tags(team_id, key) → text` | required-tag triggers, API | Required keys without a default that the team has not set |

## Roles and session settings

| Role | Used by | Access |
|---|---|---|
| `afs_owner` | migrations | Owns schema |
| `afs_app` | afs-api | Desired state read/write, audit and outbox insert; **row-level security applies** |
| `afs_reconciler` | afs-reconciler | Read all; write status, lifecycle columns, inference profile ARNs, outbox publication |
| `afs_gateway` | afs-gateway | Read budgets/models/prices; reserve and settle spend; insert usage |
| `afs_billing` | afs-billing | Write daily costs and reconciliations |
| `afs_readonly` | reporting, support | Read all except API key hashes and audit payloads |

`afs-api` sets, per transaction: `SET LOCAL afs.actor = '<principal>'`, `SET LOCAL afs.service_admin =
'on'|'off'`, `SET LOCAL afs.team_ids = '<comma-separated team ids>'`.
