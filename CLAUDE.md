# CLAUDE.md — SuDu Dealer Platform (workspace root)

Guidance for Claude Code / agents working across **both** dealer platform repos.

**This file is deliberately thin.** It carries only what neither repo can know on its
own: that the other exists, how they boot together, and where cross-repo work is
written down. Each repo's own `CLAUDE.md` is canonical for its boundaries, invariants,
and gotchas — read it before touching that side, and never restate it here.

## What This Is

A workspace root, not an application. It exists so one session can see both sides of a
feature that spans the frontend and the backend.

| Folder | Repo | Stack | Canonical guidance |
|---|---|---|---|
| `sudu-dealer-api/` | [`aseriousco/sudu-dealer-api`](https://github.com/aseriousco/sudu-dealer-api) | NestJS 11 + Prisma 7 + Postgres + better-auth | [`sudu-dealer-api/CLAUDE.md`](./sudu-dealer-api/CLAUDE.md) |
| `sudu-dealer-web/` | [`aseriousco/sudu-dealer-web`](https://github.com/aseriousco/sudu-dealer-web) | React 19 + Vite 8 + Tailwind 4 | [`sudu-dealer-web/CLAUDE.md`](./sudu-dealer-web/CLAUDE.md) |

Both are **independent git repos with their own remotes and their own branches**. This
root tracks only its own files — `.gitignore` excludes both. See
[Working across two repos](#working-across-two-repos).

The product serves two audiences from one platform: **external resellers** (dealers) and
the vendor's own admin console. Domain vocabulary — the platform / org / client planes,
why `tenantId` is a string, what `roleKind` means — lives in
[`docs/glossary.md`](./docs/glossary.md).

## Node 22 is mandatory — check this first

Both repos need Node >= 22; the **API needs >= 22.12** specifically, because
`better-auth` ships ESM-only and the compiled CommonJS `dist/` reaches it via Node's
`require(esm)`, which only landed unflagged in 22.12.0.

This machine's default `node` is **v20**. Nothing switches automatically unless you ask
it to. A `.nvmrc` (`22`) now sits in this root and in both repos:

```bash
nvm use
```

On Node 20 the API dies at boot with `ERR_REQUIRE_ESM` and the web build fails in
confusing, unrelated-looking ways. **If either app fails to start, check `node -v`
before debugging anything else.** The dev scripts in `scripts/` handle the switch for
you; a bare `npm run dev` in a fresh shell does not.

## Booting

Three processes, in this order. Each script switches to Node 22 itself.

```bash
./scripts/dev-db.sh      # Postgres 16 on :5433 (docker)
./scripts/dev-api.sh     # NestJS on :3001, watch mode
./scripts/dev-web.sh     # Vite on :5173
```

Then open http://localhost:5173.

**Always reach the app through :5173, never :3001 directly.** Vite proxies `/api` to the
API so the browser is same-origin: httpOnly session cookies work with no CORS config,
and the `Origin` header matches the API's `TRUSTED_ORIGINS`. Hitting :3001 from a
browser gets you cross-origin cookies and better-auth's CSRF guard returning
`403 MISSING_OR_NULL_ORIGIN` — which reads like an auth bug and is not one.

Claude Code can start these itself via `.claude/launch.json` (`dealer-web`,
`dealer-api`). Postgres must already be up; start it with `dev-db.sh` first.

Full setup, env vars, DB reset, and troubleshooting:
[`docs/runbooks/local-development.md`](./docs/runbooks/local-development.md).

## Working across two repos

**A feature that touches both sides gets a shared spec here, before either repo gets a
plan.** Without it the two halves are designed independently and the contract between
them is never written down — which is how a web implementation plan ended up filed in
the API repo, and how `user-onboarding-modes` came to exist as two loosely-related
documents with no parent.

| Document | Lives in | Why |
|---|---|---|
| Cross-repo feature spec — the *what and why* spanning FE + BE | `docs/specs/YYYY-MM-DD-<feature>-design.md` | One contract, one place, neither repo owns it |
| Implementation plan — the *how* for one side | that repo's `docs/superpowers/plans/` | Ships and is reviewed with the diff it describes |
| The FE↔BE surface | `docs/contracts/` | Changing it is a two-repo change by definition |

Each per-repo plan links back to its parent spec. Single-repo work needs no parent
spec — keep writing those plans exactly where they already go.

Branch names should match across repos for the same feature (`feat/<feature>` on both),
so the two halves are findable from each other.

## Hard Boundaries — do not cross

1. **Never commit to `sudu-dealer-api/` or `sudu-dealer-web/` from this root's git
   context.** They are separate repos with separate remotes. `cd` into the repo, or use
   `git -C <repo>`. A commit made from the wrong working directory silently lands on the
   wrong branch of the wrong repo.
2. **Never edit one side to paper over a bug on the other.** If the API returns the
   wrong shape, fix the API — do not reshape it in the client. If a list looks unscoped,
   that is an API authorization bug and must be reported, not filtered client-side.
3. **Respect each repo's own `CLAUDE.md`.** This file does not override them, and where
   it appears to, they win.

## Known Issues

### 1. The foundation spec reference is dangling

Both repos' `CLAUDE.md` files cite
`sudu-docs/docs/superpowers/specs/2026-07-16-dealer-platform-foundation-design.md`.
**No such path exists on this machine**, and there is no `sudu-docs` checkout anywhere
under `~/SUMES`. Treat any claim sourced to it as unverified.

If you have that document, drop it in `docs/specs/` and repoint both references. Until
then, the closest thing to a foundation record is the invariants section of
[`sudu-dealer-api/CLAUDE.md`](./sudu-dealer-api/CLAUDE.md).

### 2. `tsc --noEmit` is a false-green in the web repo

It exits 0 having checked nothing. The real gate is `npm run build`. This is documented
in the web repo's `CLAUDE.md`, and it is repeated here only because it is the single
easiest way to report "types pass" when they do not.

## Reference

- [`docs/glossary.md`](./docs/glossary.md) — domain vocabulary shared by both repos
- [`docs/runbooks/local-development.md`](./docs/runbooks/local-development.md) — setup and troubleshooting
- [`docs/specs/`](./docs/specs/) — cross-repo feature specs
- [`docs/contracts/`](./docs/contracts/) — the FE↔BE surface
