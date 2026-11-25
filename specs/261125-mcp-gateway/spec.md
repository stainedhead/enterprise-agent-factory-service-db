# Spec: MCP gateway, database part (-db 1.3.0)

Source: root `mcp-gateway-PRD.md` (approved by J, 2026-11-25), Appendix E.2 (MCP-DB-1 to MCP-DB-7), and root
`docs/contracts/database-contract.md` section 7.5 (contract v1.6.0, decisions CD-50 to CD-52). This spec refines
nothing; it records how the -db part was built and verified.

## Goals

- Migration 000024 on top of 1.2.0's 000023: the MCP catalog, inventory and pinning, opt-in and narrowing, policy,
  credential references, OAuth state, reviews, federation state, query capture, per-agent federated identities, the
  call ledger and its rollup.
- `afs.mcp_admission` as the single decision shared by the API, the reconciler and the gateway (CD-51).
- The gateway can hold a changed definition but never approve it, except a compatible change under
  `auto_approve_compatible` (CD-52). Query text only inside a capture window (CD-50).

## Non-goals

- Gateway, API, reconciler and console code (in `-restapi`, `-website`, `-cli`).
- Real AWS testing (no environment yet; recorded in the root release checklist).

## Acceptance

| Criterion | Test |
|---|---|
| MCP-DB-1 catalog: slug rules, enums, URL and digest pin, team/enterprise slug never shared | `TestMcpServers/*` |
| MCP-DB-2 primitives: unique names, digests, transition guard, the gateway cannot approve, 2,000 limit | `TestMcpPrimitives/*` |
| MCP-DB-3 opt-in default off, defaults for new teams, read-only mode, a block at any level wins, specificity | `TestMcpServers/a_team_switches_on…`, `…/default_servers…`, `TestMcpAdmission/*` |
| MCP-DB-4 credentials ARN only and at the managed path, OAuth single use, reviews append-only, federated identities | `TestMcpCredentials/*`, `TestFederatedIdentities/*`, existing secret-column test |
| MCP-DB-5 ledger append-only, own team only, partitions, rollup, retention | `TestMcpEvents/*` |
| MCP-DB-6 isolation and change feed | `TestCrossTeamWritesChangeNothing`, `TestEveryRevisionTableAnnouncesChanges`, `TestEveryTeamTableHasRowLevelSecurity` |
| MCP-DB-7 release: data model, up/down/up, changelog | `TestUpDownUp`, `docs/data-model.md`, `CHANGELOG.md` |
