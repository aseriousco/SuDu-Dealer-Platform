# docs/

Cross-repo documentation for the SuDu dealer platform. Everything here describes
something **neither repo owns alone**.

## What goes where

| You are writing… | Put it in | Named |
|---|---|---|
| A feature spec spanning FE **and** BE — the what and why | `docs/specs/` | `YYYY-MM-DD-<feature>-design.md` |
| The FE↔BE surface for an area — endpoints, shapes, error cases | `docs/contracts/` | `<area>.md` |
| How to do a thing on this machine — boot, reset, deploy | `docs/runbooks/` | `<task>.md` |
| Shared vocabulary | `docs/glossary.md` | — |
| An implementation plan for **one** repo — the how | that repo's `docs/superpowers/plans/` | `YYYY-MM-DD-<feature>-<side>.md` |
| A design for work confined to **one** repo | that repo's `docs/superpowers/specs/` | `YYYY-MM-DD-<feature>-design.md` |

## The rule

**A feature touching both repos gets a spec here before either repo gets a plan.**

The spec fixes the contract once. The two implementation plans then reference it and
stay in their own repos, where they ship and get reviewed alongside the diff they
describe.

Skipping the parent spec is how the two halves get designed independently. That has
already happened twice: `2026-07-27-web-admin-screens.md` is a *web* plan filed in the
**API** repo, and `user-onboarding-modes` exists as two loosely-related plans
(`2026-08-05-…-api.md`, `2026-08-06-…-web.md`) with nothing above them stating the
contract they share.

Single-repo work needs no parent spec. Keep writing those plans exactly where they
already go.

## Why plans stay in their repos

A plan describes code. When it lives beside that code it appears in the pull request,
gets reviewed with the change, and moves with the branch. Pulled out into a separate
repo it becomes a document nobody opens during review, and it drifts within a sprint.

Specs are different — a spec describes the agreement between two repos, so it cannot
live inside either one without one side quietly owning it.

## Conventions

- Date-prefix specs (`YYYY-MM-DD-`) to match the existing convention in both repos.
- Link each per-repo plan back to its parent spec in the first paragraph.
- Use matching branch names across repos for the same feature (`feat/<feature>`).
- State invariants once. If a rule belongs to one repo, link to that repo's `CLAUDE.md`
  rather than restating it — a second copy is a copy that will disagree.
