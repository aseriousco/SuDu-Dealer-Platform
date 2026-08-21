# Dealer API → Tenant Orchestrator: Deployed Environment Contract

Date: 2026-08-19 · **Updated 2026-08-21**
From: SuDu Dealer Platform (`sudu-dealer-api`)
To: `sudu-tenant-orchestrator` administrators

> **What changed on 2026-08-21.** Question 4's example body was from before your
> 2026-08-20 contract and no longer matched what we send; it is corrected below.
> Question 8 is new and is **blocking** for any tenant whose admin credentials the dealer
> sets. Questions 1-7 are unchanged — earlier answers still apply.

## Purpose

Our **deployed** dealer API needs to call the orchestrator so external resellers can
provision tenants for their customers. This is the counterpart to
[`handoff-tenant-orchestrator-jwt-access.md`](./handoff-tenant-orchestrator-jwt-access.md),
which you sent us: that document says how a caller registers. This one says what *this*
caller needs registered, what we still need you to confirm, and where each of your
answers lands in our configuration.

Local development is already working against `https://tenant-orchestrator.dev.sudu.ai`.
Nothing here is about that. Everything here is about the deployed dealer API.

## What we need from you

Numbered so you can reply "re: 3" without quoting.

### 1. Which orchestrator does the deployed dealer API call? **(blocking)**

The only base URL in your handoff is `https://tenant-orchestrator.dev.sudu.ai`, and our
own `.env.example` records "there is no prod URL yet". We need one of:

- a production orchestrator base URL, or
- explicit confirmation that the deployed dealer API should call the dev orchestrator.

This is blocking because it decides a second value we cannot guess. Tenants you
provision log in at a shared SaaS host, which we surface to the dealer as
`SAAS_TENANT_LOGIN_HOST`. That host is **paired** with the orchestrator environment —
dev orchestrator ↔ `dev.mes.sudu.ai`, production ↔ `main.mes.sudu.ai`. If we point the
deployed API at the dev orchestrator while showing dealers `main.mes.sudu.ai`, every
customer we hand over walks to a login page their tenant does not exist on.

If the answer is "dev for now", say so plainly and we will set the dev login host and
treat the deployment as a pilot. The unsafe outcome is not using dev — it is crossing
the pair.

### 2. Register a ServiceIdentity for the deployed caller

Separate from our local development identity, per your own rule ("Use separate
identities and keys for development, staging, and production", "Do not reuse a
production key in local development"). The registration block is in
[What we will send you](#what-we-will-send-you) below; we are holding it until you
answer question 1, because the service ID should name the environment it belongs to.

### 3. Approve three scopes, not two

Your worked example requests `tenant:create` and `job:read`. We need a third:

| Scope | What we call | Why |
|---|---|---|
| `tenant:create` | `POST /v1/provisioning/tenant-jobs` | Dealer submits a tenant |
| `job:read` | `GET /v1/jobs/:job_id?detail=full`, `GET /v1/jobs?request_ref=` | Status page; recovering a job id after a dropped response |
| `job:retry` | `POST /v1/jobs/:job_id/retry` | Retrying a failed job without creating a second tenant |

We are **not** requesting `provisioning_profile:read`. Your handoff suggests it as an
access check, but we never call that route in the application, and a least-privilege
registration should not carry it. Our probe defaults to a `job:read` route instead. If
you would rather we verify with `provisioning_profile:read`, add it and we will.

### 4. Which provisioning profile applies when we omit `profile_key`?

Our submit body, as of your 2026-08-20 contract:

```json
{
  "request_ref": "dealer-<uuid>",
  "tenant": { "client_name": "..." },
  "plan": { "plan_id": "<sudu_plan.id>" },
  "accounting": { "type": "SQL | ATC" },
  "customer_domain": "acme.mes.sudu.ai",
  "expire_time": "2027-01-31",
  "tenant_admin": { "username": "...", "password": "..." },
  "initial_user": { "account": "...", "name": "...", "real_name": "...", "email": "..." }
}
```

`expire_time` and `tenant_admin` are omitted entirely when the dealer does not set them —
an absent `tenant_admin` is how we ask you to skip step 21, not an empty object. We no
longer send `package`: the plan supplies it via `tenant_package_id`, per your change.

No `profile_key`, no `profile_version` — so the deployed environment's default applies.
Please confirm what that default is, and that it is not `dev_default` in whichever
environment answers question 1. If real dealer customers should be built from a
specific profile, name it and we will send it.

### 5. What is the initial-user password in production?

We send no `password_secret_ref`, so per your handoff password generation falls back to
`${account}@123!`. The account is a dealer-chosen string, which makes the first
credential of a real customer's tenant predictable from a value the dealer already knows
and may have shared.

We are not asking you to change this unilaterally — we are asking what you recommend for
production: a `password_secret_ref` we should start sending, a different generation rule,
or a forced reset on first login. This one is worth a decision before real customers land.

### 6. How long is an `Idempotency-Key` remembered, and is it scoped per identity?

Our no-double-tenant guarantee leans on your deduplication. We write the provisioning row
**before** calling you, store the key with it, and reuse the same key on every retry of
that request — so a dealer's retry must never mint a second tenant. We need to know the
retention window to size our reconcile job against it, and whether keys are scoped per
ServiceIdentity (they must not collide across callers).

### 7. Does the deployed orchestrator restrict source IPs?

Our API runs as a Coolify application. If you allowlist egress, tell us what you need and
we will supply the deployment's outbound address.

### 8. Set `TENANT_CREDENTIAL_KEY` on the orchestrator **(blocking for one path)**

On 2026-08-20 a provisioning job on the dev orchestrator failed at the last step:

```
Step update_tenant_admin_credentials failed: TENANT_CREDENTIAL_KEY is not configured
```

The tenant (332555) was created and configured; only step 21 failed, and the job is
recorded as failed. This variable appears in **none** of the three handoff documents you
have sent us, so we had no way to know it was required.

It matters because it gates the credential lifecycle your own contract documents: a
`tenant_admin` on the create body, `POST /v1/tenants/{id}/admin-credentials`, and
`POST /v1/tenants/{id}/stored-credentials` all depend on it. Until it is set, a dealer who
chooses their customer's root credentials loses the whole job at the final step.

We have reduced the blast radius on our side — we now omit `tenant_admin` unless the dealer
explicitly sets one, so the ordinary case skips step 21 entirely, and we refuse `admin`/`admin`
outright because it asks you to set the account the tenant already has. Neither helps a dealer
who genuinely wants their own credentials.

Three things, please:

1. Set it in the dev orchestrator, and in whichever environment answers question 1.
2. Tell us whether rotating it makes previously stored credentials unreadable. We keep our
   own encrypted copy (see the note below) precisely because you never return yours, and
   we would rather know now than discover it during an incident.
3. Confirm whether tenant 332555 can be repaired, or should be treated as abandoned.

## What we will send you

Once question 1 is answered, we will send exactly this over an authenticated channel —
and nothing else. The private key never leaves our secret manager.

```text
Service ID:  sudu-dealer-api-<env>
KID:         sudu-dealer-api-<env>-<YYYYMMDD>-01
Public key:  -----BEGIN PUBLIC KEY----- ... -----END PUBLIC KEY-----
Requested scopes:
  - tenant:create
  - job:read
  - job:retry
```

Please confirm back: the identity is registered under that exact service ID and KID, and
`ServiceIdentity.enabled = true`.

## Where your answers land

Every variable the deployed dealer API reads for this integration. "Ours" means we set it
without asking; "yours" means we cannot fill it in until you answer.

| Variable | Owner | Value | Notes |
|---|---|---|---|
| `TENANT_ORCHESTRATOR_BASE_URL` | **yours** | — | Question 1. Defaults to the dev orchestrator if unset, which is not a safe production default |
| `TENANT_ORCHESTRATOR_JWT_PRIVATE_KEY` | ours | *(secret)* | ES256/P-256 PEM. Never transmitted, never committed |
| `TENANT_ORCHESTRATOR_JWT_KID` | ours | `sudu-dealer-api-<env>-<date>-01` | Must match the registration character-for-character |
| `TENANT_ORCHESTRATOR_SERVICE_ID` | ours | `sudu-dealer-api-<env>` | The `sub` claim |
| `TENANT_ORCHESTRATOR_JWT_ISSUER` | **yours** | `internal-identity` | Confirm this holds for the environment in question 1 |
| `TENANT_ORCHESTRATOR_JWT_AUDIENCE` | **yours** | `tenant-provisioning-service` | Same |
| `TENANT_ORCHESTRATOR_TOKEN_TTL_SEC` | ours | `300` | 5 minutes, inside your recommended 5–15 |
| `SAAS_TENANT_LOGIN_HOST` | **yours** | — | Paired with question 1. `main.mes.sudu.ai` for production, `dev.mes.sudu.ai` for dev |
| `DEALER_CREDENTIAL_KEY` | ours | *(secret)* | 32 bytes, AES-256-GCM. Encrypts our copy of a tenant admin password at rest. Listed for completeness — nothing on your side reads it, but the deployed API refuses to accept a tenant admin password without it |

Scopes are not configured as an environment variable on our side. Each call requests the
one scope that route needs, minted per call and cached per scope.

## How we will verify

The repository carries a zero-dependency probe that mints a token exactly as the
application does and makes one non-mutating call:

```bash
node scripts/orchestrator-ping.mjs
```

It never prints the JWT or any key material. Exit codes: `0` registered and scoped, `1`
rejected, `2` could not ask. It maps your error messages to the party who fixes them:

| Response | Cause | Fixed by |
|---|---|---|
| `Unknown service identity` | `sub`/`kid` not registered, or disabled | you |
| `Invalid JWT signature` | Registered public key does not match our private key | either — usually a bad paste |
| `Invalid JWT issuer` / `Invalid JWT audience` | Our `iss`/`aud` differ from the deployment | us, once you confirm question 1 |
| `Missing required scope` | Registered identity lacks the scope | you |
| `JWT expired` | Clock skew or a stale token | us |

We will run it against the deployed environment immediately after you confirm
registration, and report the result before any dealer traffic reaches you.

## What we hold to

- The private key is generated in our secret manager and never sent to you, never
  committed, never logged, and never placed in a request body or a ticket.
- Separate key pairs and service IDs per environment. No production key in local development.
- Least privilege: we requested three scopes because we call three routes.
- Key rotation follows your sequence — new pair, new KID, second identity enabled, cut
  over, expire, disable the old one. We will initiate rotation yearly, or immediately on
  any suspected exposure.
- We never write your `steps[].result` shapes into our database; the tenant id is read
  from the job envelope's `bladex_tenant_id`.

## On our side, for the record

Not asks — just what we are doing, so a failure is diagnosable from either end.

- **The deployed API listens on `PORT=3003`** (Coolify sets it; the Dockerfile defaults to
  it). Local development uses 3001. Only the deployed value matters to you.
- **Our PEM loader does not normalize literal `\n`.** If the deployment platform stores
  the key with escaped newlines rather than real ones, signing fails before any request
  reaches you — it would surface to us as a local error, not as one of your rejections.
  Ours to handle; noted here so it is never mistaken for a registration problem.
- **An unconfigured orchestrator is refused before we write anything.** If the key is
  missing, a dealer sees "provisioning is not available yet" and no row is created — so an
  environment awaiting registration produces no stranded rows for you to clean up.
- **We keep our own encrypted copy of a tenant admin password.** Your stored credentials
  are never returned by any API — correct, and it means a dealer who sets a root password
  has no way to read it back to hand to their customer. So we store it AES-256-GCM
  encrypted, return it only through a single audited route, and refuse the request outright
  if our key is unconfigured rather than storing plaintext or silently dropping it. Yours
  remains the operative copy; ours exists to be handed over once. This is the background to
  question 8.2.
- **A submitted row is never marked failed on an indeterminate fault.** If our call to you
  times out, the row stays pending and carries its `request_ref`, and we recover the job
  through `GET /v1/jobs?request_ref=`. That is why question 6 matters.

## Reference

- [`handoff-tenant-orchestrator-jwt-access.md`](./handoff-tenant-orchestrator-jwt-access.md) — your registration process
- [`sudu-tenant-orchestrator-api-handoff-2026-08-06.md`](./sudu-tenant-orchestrator-api-handoff-2026-08-06.md) — your API map
- [`sudu-tenant-orchestrator-api-handoff-2026-08-19.md`](./sudu-tenant-orchestrator-api-handoff-2026-08-19.md) and
  [`dealer-platform-handoff-2026-08-20.md`](./dealer-platform-handoff-2026-08-20.md) — your contract changes, which question 4 now reflects
- [`specs/2026-08-11-tenant-provisioning-design.md`](./specs/2026-08-11-tenant-provisioning-design.md) — our cross-repo design
- [`specs/2026-08-20-tenant-wizard-contract-update-design.md`](./specs/2026-08-20-tenant-wizard-contract-update-design.md) — our side of the 2026-08-20 change, including §7 on the credential store
