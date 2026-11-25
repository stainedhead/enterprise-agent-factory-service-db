# Plan

1. Red: write `migrate/model_gateway_000023_test.go` covering TC-DB-01 to TC-DB-15, CD-42 and the rejected case of
   every constraint; add team B gateway rows to `seedOtherTeams`; it fails against 000022.
2. Green: `migrations/000023_model_endpoint_gateway.up.sql` in sections: helpers, providers, endpoints and models,
   credentials/federations/statements, selections and new columns, guards, CD-42 route defaults, admission and
   views, settings, usage and cost, RLS, grants, revisions and change feed.
3. Down: `000023_model_endpoint_gateway.down.sql`, restoring the 000022 bodies verbatim, keeping data.
4. Refactor: shared trigger functions, generic RLS loops, test helpers.
5. Adapt the 000021 and 000022 down tests to count from the migration list.
6. Documentation: `docs/data-model.md`, README, AGENTS.md, CHANGELOG v1.2.0, operations upgrade notes, PRD stories.
7. Quality gate: `make gate`, `make test-db`; design review checklist; PR, CI, merge.

Consumers: `-restapi` 1.2.0 pins `-db` v1.2.0 and implements the API, gateway, reconciler and billing parts.
