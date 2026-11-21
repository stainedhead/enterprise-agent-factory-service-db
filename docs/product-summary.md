# Product summary

The desired-state database for the Enterprise Agent Factory Service (AFS): RDS PostgreSQL 17, schema
`afs`, migrations 000001–000015 (feature complete). It holds every team, person, agent, pool, secret
reference, budget, price, report fact, work order, revision and audit row, and it is the only place that
schema changes.

What it guarantees at the data layer, behind the API's own checks:

- **Team isolation.** Row-level security limits `afs-api` (`afs_app`) to the teams in the transaction's
  `afs.team_ids`; a missing `WHERE` cannot read or change another team's rows, and a transaction that sets
  nothing sees nothing.
- **No secret values.** Secrets are Secrets Manager ARNs on managed paths; configuration and tag names that
  look like credentials are refused.
- **Spend control.** Atomic reserve and settle on one counter row per budget period; concurrent calls
  cannot reserve past the limit; held reservations of a dead gateway are released.
- **Guardrails.** Budget ceilings, quotas, isolation tier, account filters, template images and ephemeral
  team lifetimes are guarded by constraints and triggers that only service admins can get past.
- **History.** Every desired-state change bumps a version, writes a revision and is announced on the
  `afs_desired_state` channel; the audit log is append-only.
- **Safe migrations.** One advisory-locked runner with checksums and a per-migration lock timeout, used by
  `afs-api` at startup and by the `afs-migrate` command.

Users: `-restapi` developers (the only code consumer, through the Go module), the four AFS services at
runtime, operators and DBAs, security and audit. Tables, functions and roles:
[data-model.md](data-model.md). Requirements: [the PRD](../enterprise-agent-factory-service-db-PRD.md).
Operator guides: [user-docs/](../user-docs/README.md).
