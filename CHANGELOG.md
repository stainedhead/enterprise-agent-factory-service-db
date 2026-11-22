# Changelog

All notable changes to this repository. Versions follow semver. `-db` and `-restapi` release in lockstep
with the same version number.

## v1.0.1 (2026-11-22)

First tagged release. Schema migrations 000001–000020.

- **000020 Paperclip team collaboration:**
  - collaboration agent role and template capabilities
  - `team_collaboration` and `agent_collaboration`
  - `secrets.managed_by` and the reserved Paperclip secret names
  - the `team_collaborator` role and the `collab.*` settings
  - the `afs_edge` role with SECURITY DEFINER functions only: routes, principals, server-side sessions and one-time handoffs, access counts
  - the reconciler key functions
  - the 30-day hostname hold
  - swarm collaboration agents
- Operators run `afs-migrate bootstrap-roles` before applying 000020, so the `afs_edge` role exists.
- 000001–000019: the feature-complete schema (teams, agents, identities, secrets, budgets and spend, usage, reports, work orders, audit, RLS).
