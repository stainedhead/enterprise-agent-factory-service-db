# Implementation notes: paperclip-collaboration

2026-11-22. Updated as work proceeds: decisions, edge cases, deviations, lessons.

## Environment

PostgreSQL 17 could not be installed: the PGDG apt repository is blocked by the sandbox proxy (HTTP 403) and Docker is
not available. The local run used PostgreSQL 16.15 from the Ubuntu archive (`initdb` in a scratch directory, port 55432,
password `postgres`, matching the Makefile `PG_URL`). Nothing newer than PostgreSQL 16 syntax is used, which is a subset of 17. **CI's `postgres:17` is the authoritative run.**

## Technical decisions

(filled during implementation)

## Edge cases and solutions

(filled during implementation)

## Deviations from plan

(none yet)

## Root contract follow-ups

(none yet)

## Parked

| Item | Why | Owner |
|---|---|---|
| Run against `postgres:17` | Not available locally; CI | CI |
| Load figures (p99 targets) | Need the M3 load test and a `db.r7g.large` | `-restapi` |

## Lessons learned

(at the end)
