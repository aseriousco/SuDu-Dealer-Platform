# docs/specs/

Cross-repo feature specs. One file per feature that touches **both**
`sudu-dealer-api` and `sudu-dealer-web`.

Naming: `YYYY-MM-DD-<feature>-design.md`

A spec here answers **what and why**, and fixes the contract between the two sides. It
does not describe how either side is built — that's the per-repo implementation plan's
job, and those live in each repo's `docs/superpowers/plans/`.

Write the spec first. Then each repo's plan links back to it.

## Template

```markdown
# <Feature> — cross-repo design

**Status:** draft | approved | implemented
**Repos:** sudu-dealer-api · sudu-dealer-web
**Branches:** feat/<feature> (both)
**Plans:** api → `sudu-dealer-api/docs/superpowers/plans/…` · web → `sudu-dealer-web/docs/superpowers/plans/…`

## Problem

What's broken or missing, for whom. Which plane (platform / org / client) is affected.

## Contract

The surface between the two repos — endpoints, request/response shapes, error cases,
status codes. This is the part neither repo can decide alone, and the reason this file
exists.

Check against the invariants before writing shapes: `tenantId` is a string, money is a
string, authorization is the API's job alone. See `../glossary.md`.

## API side

What the backend owns. New tables, migrations, `resolveVisibleScope()` implications,
authorization changes.

## Web side

What the frontend owns. Routes, and whether this is a dealer surface (`/`) or vendor
surface (`/admin/*`) change — or both.

## Out of scope

What this deliberately does not do.

## Open questions

Anything unresolved. Empty by the time the status is `approved`.
```

## Backfill candidates

Two features shipped without a parent spec and could use one written after the fact:

- **`user-onboarding-modes`** — plans exist on both sides
  (`2026-08-05-…-api.md`, `2026-08-06-…-web.md`) with no document stating the contract
  they share.
- **`web-admin-screens`** — `2026-07-27-web-admin-screens.md` is a *web* plan currently
  filed in the **API** repo.

Neither is urgent. Worth doing the next time either area is touched.
