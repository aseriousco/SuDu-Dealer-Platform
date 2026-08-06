# Runbook — local development

Booting the dealer platform on this machine, and what to check when it won't.

## TL;DR

```bash
./scripts/dev-db.sh      # Postgres 16 on :5433 (docker)
./scripts/dev-api.sh     # NestJS on :3001, watch mode
./scripts/dev-web.sh     # Vite on :5173
```

Open **http://localhost:5173**. Each script switches itself to Node 22.

## Node 22 — the first thing to check

This machine's default `node` is **v20**. Both repos need >= 22, and the **API needs
>= 22.12** because `better-auth` is ESM-only and the compiled CommonJS `dist/` reaches it
through Node's `require(esm)`, unflagged only since 22.12.0.

```bash
nvm use          # reads .nvmrc (22) — present in the root and both repos
node -v          # expect v22.x, x >= 12
```

On Node 20 you get `ERR_REQUIRE_ESM` from the API and confusing unrelated-looking
failures from the web build. **If anything fails to start, check `node -v` before
debugging anything else.** The `scripts/` wrappers handle this; a bare `npm run dev` in a
fresh shell does not.

To stop thinking about it: `nvm alias default 22`.

## Ports

| Port | Process | Notes |
|---|---|---|
| 5173 | `sudu-dealer-web` (Vite) | **The one you open.** Proxies `/api` → 3001 |
| 3001 | `sudu-dealer-api` (NestJS) | `/health` sits outside the `/api` prefix |
| 5433 | Postgres 16 (docker) | Not 5432 — deliberately, to avoid clashing with a local Postgres |

**Always use :5173, never :3001, in a browser.** The Vite proxy keeps the browser
same-origin with the API, which is what makes better-auth's httpOnly session cookies work
without CORS config, and what puts a `TRUSTED_ORIGINS`-matching value in the `Origin`
header. Going direct to :3001 gets you `403 MISSING_OR_NULL_ORIGIN` from the CSRF guard —
this reads like an auth bug and is not one.

## First-time setup

```bash
nvm install 22
(cd sudu-dealer-api && npm ci && cp .env.example .env)
(cd sudu-dealer-web && npm ci)
./scripts/dev-db.sh
(cd sudu-dealer-api && npm run prisma:generate && npm run prisma:migrate && npm run seed)
```

Then fill in `sudu-dealer-api/.env`. The values that must be right locally:

| Variable | Local value | Why |
|---|---|---|
| `DATABASE_URL` | `postgresql://dealer:dealer@localhost:5433/sudu_dealer?schema=public` | Matches `docker-compose.yml` |
| `TEST_DATABASE_URL` | same host, DB `sudu_dealer_test` | **Must end `_test`** — see Testing |
| `PORT` | `3001` | The Vite proxy target is hardcoded to this |
| `BETTER_AUTH_SECRET` | `openssl rand -base64 32` | Yours alone; never shared with BladeX |
| `BETTER_AUTH_URL` | `http://localhost:3001` | |
| `TRUSTED_ORIGINS` | `http://localhost:5173` | Must contain `DEALER_WEB_URL`'s origin |
| `DEALER_WEB_URL` | `http://localhost:5173` | Builds invite/reset links; the API fails fast if its origin isn't trusted |

`SMTP_*` can stay empty in development — the mailer falls back to console output when
`NODE_ENV=development`. `GATEWAY_*` is a reserved seam and is not needed yet.

**`sudu-dealer-web` needs no `.env`.** It talks to `/api` as a same-origin relative path
in both dev and prod, so there is no client-side API base URL to configure. Add a
`VITE_*` var only when code actually reads it — and remember every `VITE_*` value is
compiled into the public bundle.

## Regenerating Prisma

Always through the npm script, never bare `prisma generate`:

```bash
cd sudu-dealer-api && npm run prisma:generate
```

The script runs `scripts/fix-prisma-esm.js`, which writes `{ "type": "commonjs" }` into
`src/generated/prisma/package.json`. Without it the built `dist/` dies on its first line
with `ReferenceError: exports is not defined in ES module scope`. Full explanation, and
the reason `sudu-chat-gateway`'s `{ "type": "module" }` must **not** be copied here, is in
[`sudu-dealer-api/CLAUDE.md`](../../sudu-dealer-api/CLAUDE.md) → Known Issues.

## Testing

```bash
cd sudu-dealer-api && npm test      # jest, integration tests hit real Postgres
cd sudu-dealer-web && npm test      # vitest
```

The API's integration tests need `./scripts/dev-db.sh` running. They run with
`maxWorkers: 1` because they share one schema and truncate between cases.

**`resetDb()` TRUNCATEs every table** and refuses to run unless `DATABASE_URL` names a
database ending in `_test`. Never weaken that guard, and never point the tests at the dev
database. A database has been destroyed this way before.

### Typechecking the web repo

```bash
cd sudu-dealer-web && npm run build     # the real gate — tsc -b && vite build
```

`npx tsc --noEmit` **exits 0 having checked nothing** — the root `tsconfig.json` uses
project references with `files: []`. Never report "types pass" on the strength of it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERR_REQUIRE_ESM` on API boot | Node < 22.12 | `nvm use` |
| `403 MISSING_OR_NULL_ORIGIN` | Browser hit :3001 directly | Use http://localhost:5173 |
| `ReferenceError: exports is not defined` | Bare `prisma generate` | `npm run prisma:generate` |
| API exits complaining about `DEALER_WEB_URL` | Its origin isn't in `TRUSTED_ORIGINS` | Align the two in `.env` |
| Web typecheck "passes" but the build fails | Used `tsc --noEmit` | `npm run build` |
| Postgres won't come up | Port 5433 taken, or Docker down | `docker compose -f sudu-dealer-api/docker-compose.yml logs postgres` |
| Login succeeds then immediately drops | Session cookie not same-origin | Check the Vite proxy in `vite.config.ts` |

### Resetting the database

Destructive — drops all local dealer data:

```bash
cd sudu-dealer-api
docker compose down -v && docker compose up -d
npm run prisma:migrate && npm run seed
```

`docker compose down -v` is in the `deny` list in
[`.claude/settings.json`](../../.claude/settings.json), so an agent cannot run this
without you doing it yourself. That's deliberate.

## Working across both repos with Claude Code

Start Claude Code from the workspace root (`SuDu-Dealer-Platform/`), not from inside
either repo — a session rooted in one repo cannot see the other, which makes any
cross-repo feature impossible to reason about.

`.claude/launch.json` defines `dealer-web` and `dealer-api` so Claude Code can boot them
itself. Postgres is not one of them; start it with `./scripts/dev-db.sh` first.

Conventions for cross-repo work are in [`../README.md`](../README.md).
