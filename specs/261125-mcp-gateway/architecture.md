# Architecture

- Decisions live in SQL once: `afs.mcp_admission` (security invoker, so RLS applies to its caller) feeds the view
  `effective_agent_mcp` (API, reconciler) and the gateway's 60 s cache. The gateway's Go policy package mirrors it.
- Guards that depend on the caller (`afs_gateway` may not approve) are SECURITY INVOKER; guards that must read rows
  the caller cannot see (slug uniqueness, scope, credential path) are SECURITY DEFINER.
- Reviews and the ledger are history: no foreign keys, append-only triggers.
