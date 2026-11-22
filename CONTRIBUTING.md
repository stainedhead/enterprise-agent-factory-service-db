# Contributing to enterprise-agent-factory-service-db

Start with the product-wide
[contributing guide](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/CONTRIBUTING.md);
this file adds what is specific to the database. The full rules are in [AGENTS.md](AGENTS.md).

## Before you start

- Read the [database contract](https://github.com/stainedhead/enterprise-agent-factory-service/blob/main/docs/contracts/database-contract.md),
  [docs/data-model.md](docs/data-model.md) and this repository's [PRD](enterprise-agent-factory-service-db-PRD.md).
- Plan the tables, constraints, policies and grants you will touch, and which `-restapi` code reads them.
- Create or update a spec in `specs/YYMMDD-<feature>/` and keep its `status.md` current.

## Make the change

1. **Red.** Write an integration test that fails against the current schema: a missing table, a constraint
   that is not enforced, a role that can read across teams.
2. **Green.** Add a **new** migration pair `migrations/NNNNNN_name.up.sql` / `.down.sql`, numbered after the
   last one. Never edit a merged migration; the runner refuses a changed checksum.
3. **Refactor**, then update [docs/data-model.md](docs/data-model.md) in the same change.

Checklist for every migration:

- [ ] Contiguous, transactional and online-safe; lock impact noted in the header for large tables
- [ ] `.down.sql` reverses it cleanly (the up/down/up test passes)
- [ ] Team-owned table: `team_id`, composite foreign keys, RLS policy, grants per role, rows in
      `seedOtherTeams` so `TestCrossTeamWritesChangeNothing` covers it
- [ ] No column can hold a secret value
- [ ] Every constraint has a test that proves the rejected case

## Run the gate

```bash
make gate      # tidy, fmt-check, vet, golangci-lint, race tests, build afs-migrate
make db-up     # postgres:17 in Docker
make test-db   # integration tests: up/down/up, constraints, RLS, change feed
```

## Open a pull request

Branch from `main`, reference the spec directory in your commits, and describe the schema change, its lock
impact and the tests that prove it. A merged migration becomes a minor release; tell `-restapi` the tag to
adopt.
