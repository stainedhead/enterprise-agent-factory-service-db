# Intent

## Purpose
Hold the desired state of the Enterprise Agent Factory Service in one durable, versioned, audited place
that can be backed up, restored and carried to another AWS account or cluster, and from which the whole
environment can be rebuilt.

## Where it fits
One of four children of [enterprise-agent-factory-service](https://github.com/stainedhead/enterprise-agent-factory-service).
The control plane in `enterprise-agent-factory-service-restapi` is the only code that reads and writes
this database, and it applies these migrations through the `migrate` package. The CLI and the website
never connect to the database.

## Goals
- **Source of truth for desired state.** Teams, people and roles, agents and identities, secret
  references, models and prices, budgets, delivery settings and work orders.
- **Safe by construction.** Team isolation in composite keys and row-level security; least-privilege
  roles per service; an append-only audit log; no column that can hold a secret value.
- **Real-time spend control.** Atomic reserve and settle functions the gateway uses on every model call.
- **History and recovery.** Every change recorded as a revision; schema migrations that are checksummed,
  ordered and reproducible.
- **Ready for later phases.** Ephemeral teams, lifetime budgets and work orders are in the schema now.

## Non-goals
- Business logic beyond integrity rules and the spend primitives.
- Storing secret values, AWS credentials or model prompts and outputs.
- Analytics warehousing; long-term cost analysis belongs in the enterprise data platform.
