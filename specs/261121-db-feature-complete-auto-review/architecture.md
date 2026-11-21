# Architecture: db-feature-complete-auto-review

**Date:** 2026-11-21 · **Status:** Draft

## Architecture Overview
No structural change. Option validation moves to the start of `Up`/`Down`.

## Component Architecture
`migrate.resolve` returns an error; `Up`/`Down` return it before `withLock`.

## Layer Responsibilities
Unchanged.

## Data Flow
Unchanged.

## Sequence Diagrams
Not needed.

## Integration Points
`-restapi` callers unaffected unless they pass a negative timeout.

## Architectural Decisions
See implementation-notes.md.
