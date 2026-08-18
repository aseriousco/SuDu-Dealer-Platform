# Tenant Provisioning — cross-repo design

**Status:** draft · **amended 2026-08-18** — see [Submit outcomes](#submit-outcomes)
**Repos:** sudu-dealer-api · sudu-dealer-web
**Branches:** `feat/tenant-management` (both) · `docs/tenant-management-cross-repo-spec` (workspace root)
**Plans:** api → [`sudu-dealer-api/docs/superpowers/plans/2026-08-11-tenant-provisioning-api.md`](../../sudu-dealer-api/docs/superpowers/plans/2026-08-11-tenant-provisioning-api.md) · web → [`sudu-dealer-web/docs/superpowers/plans/2026-08-11-tenant-provisioning-web.md`](../../sudu-dealer-web/docs/superpowers/plans/2026-08-11-tenant-provisioning-web.md)
**Upstream contract:** [`../sudu-tenant-orchestrator-api-handoff-2026-08-06.md`](../sudu-tenant-orchestrator-api-handoff-2026-08-06.md)

> **First of three.** "Tenant management" as scoped on 2026-08-11 covers five subsystems.
> This spec is **A — provisioning** only. B (tenant mode, quota, approval policy) and C
> (reassign tenant ↔ dealer) get their own specs. See [Out of scope](#out-of-scope).

> **Amended 2026-08-18 — the submit response.** The original contract returned `201` on
> success and let an orchestrator fault propagate as a `502`, which told the caller "nothing
> happened" at the one moment that was untrue: the row had already been written. Both open
> PRs — [`sudu-dealer-api#18`](https://github.com/aseriousco/sudu-dealer-api/pull/18) and
> [`sudu-dealer-web#19`](https://github.com/aseriousco/sudu-dealer-web/pull/19) — implement
> the **original** contract, and the web PR carries a client-side workaround for it.
> [Submit outcomes](#submit-outcomes) is the replacement and is **not yet implemented**.

## Problem

A dealer cannot create a tenant. They can only *claim* one that already exists in BladeX —
`POST /api/dealer-clients`, which asserts a relationship that a platform admin must then
verify.

The web app has shipped a complete 4-step "register a new tenant" wizard since the
`feat/dealer-tenants` work, and it is **deliberately dead**:
`sudu-dealer-web/src/components/tenants/CreateTenantForm.tsx` renders "Provisioning coming
soon" instead of submitting, because no provisioning API existed. Its own doc comment says
the final create is gated so it does not "write a claim pointing at a nonexistent tenant".

That API now exists: `sudu-tenant-orchestrator`, deployed at
`https://tenant-orchestrator.dev.sudu.ai`. This spec wires the two together.

Affected planes: **org** (a dealer provisions a tenant) and **client** (a BladeX tenant is
created). The **platform** plane gains read visibility and two recovery actions.

### Why the orchestrator is reachable when `blade-system` was not

`feat/tenant-directory-merge` was abandoned on 2026-07-27 because `blade-system` does
stateful token validation and rejects the dealer-api's self-minted vendor token. That does
not apply here. The orchestrator accepts **neither** a BladeX login token **nor** a minted
su-code vendor token — it takes a signed ES256 JWT whose public key we register with it.
Different mechanism, different failure mode.

## Assumptions

Every one of these is **not true today**. Each is a thing that can break this feature if it
changes, so each is written down rather than absorbed silently.

| # | Assumption | Confirmed by | Consequence if wrong |
|---|---|---|---|
| 1 | The orchestrator will create the `sudu_customer` registry row automatically | user, 2026-08-11 — "not implemented, but in the future yes" | Provisioned tenants are invisible in `/api/admin/tenants` (see below). Interim: rows created by hand in SaaS |
| 2 | Provisioned tenants have **no** per-tenant subdomain | user, 2026-08-11 — "it doesn't yet" | `dealer_client.slug` is `null`; no UI may promise a `{slug}.mes.sudu.ai` URL |
| 3 | Initial passwords are **fixed**, told to the dealer, changed by the end user in SaaS | user, 2026-08-11 | A predictable initial credential is an accepted risk window |
| 4 | We are issued a registered `ServiceIdentity` with scopes `tenant:create`, `job:read`, `job:retry` | **unconfirmed — ops dependency** | Nothing works. There is no public API to self-register; see [Operational prerequisites](#operational-prerequisites) |
| 5 | A successfully provisioned tenant's claim lands **`ACTIVE`** | user, 2026-08-11 | Spec B makes this policy-driven rather than constant; see below |

### On assumption 1 — the visibility asymmetry

The two tenant-list endpoints read from opposite ends, and it matters here:

- `TenantsService.list` (dealer) starts from `dealer_client` and *enriches* from the SaaS
  registry. A provisioned tenant **appears** in the dealer's list immediately, with the
  local `label` as its name, blank `saasStatus`, and zero credits.
- `AdminTenantsService.list` (platform) starts from the SaaS registry and left-joins
  claims. A tenant with no `sudu_customer` row is **invisible to the platform admin**,
  even though a `dealer_client` row exists.

So until assumption 1 holds, a dealer can create a tenant that the admin who is meant to
govern it cannot see. `GET /api/admin/tenant-provisioning-requests` exists in this spec
specifically to close that hole from the local side — it reads our own table, not the
registry, so it is correct regardless of assumption 1.

### On assumption 5 — why `ACTIVE`, and why it must not be a constant

`getOwnedOrThrow()` filters on `status: 'ACTIVE'`, and its comment is explicit that this
is part of the security control rather than a filter convenience. A `PENDING` claim cannot
be used. So a dealer whose provisioned tenant lands `PENDING` has paid for infrastructure
they cannot touch until an admin acts.

`PENDING` exists to verify an *assertion* — "this pre-existing tenant is mine". Provisioning
makes no assertion: our own API created the tenant on the dealer's behalf, so ownership is
established by construction and there is nothing for an admin to verify. With no policy
engine in this spec, `ACTIVE` is the only state that makes the feature work standalone.

**Spec B turns this into a decision.** Confirmed 2026-08-11: once quota and approval config
exist, the landing status is computed from the dealer's remaining tenant allowance — within
allowance lands `ACTIVE`, over it lands `PENDING` for admin approval. That is the soft-block
in concrete terms: exceeding the limit does not refuse the request, it downgrades the
outcome. So the quota check runs *before* provisioning, but its verdict is applied *after*,
as the claim status.

The implementation consequence is load-bearing for this spec, not just B's: **the landing
status must be one resolved value at a single seam, never a `status: 'ACTIVE'` literal
inline in the completion write.** Spec A resolves it to a constant `ACTIVE`; spec B replaces
that resolution with a policy call and touches nothing else. Hardcoding it means B has to
unpick the completion path — which is the part that must stay correct, because it is what
writes the ownership record.

## Contract

The browser reaches the API same-origin through Vite's `/api` proxy (root
[`CLAUDE.md`](../../CLAUDE.md) — always :5173, never :3001). The API's global prefix is
`api`, so these paths are what the browser calls verbatim.

Bodies are camelCase both ways. The orchestrator's own contract is snake_case; that
translation is the API's job and never leaks to the browser.

### `POST /api/tenant-provisioning-requests` — submit

Org actors only. A platform actor gets `403` (they do not own clients — same rule as
`POST /api/dealer-clients`).

```jsonc
{
  "clientName": "Example Manufacturing Sdn Bhd",  // required, 1..200
  "packageType": "WMS",                           // required: WMS | AI | MES
  "accountingType": "SQL",                        // required: SQL | ATC
  "initialUser": {
    "account": "exampleteam",                     // required
    "name": "Example HQ",                         // required
    "realName": "Example HQ",                     // required
    "email": "ops@example.com"                    // required; "" is legal upstream
  },
  "ownerMemberNodeId": "…"                        // optional; defaults to the acting member
}
```

Every field is `forbidNonWhitelisted` — the orchestrator rejects unknown fields, and we
reject them earlier so a typo is a `400` here rather than a confusing failure three services
away.

#### Submit outcomes

The row is written **before** the orchestrator is called, so "the call failed" and "nothing
was created" are different facts. The response distinguishes them, and one guarantee falls
out of it:

> **If the row was written, the caller gets a 2xx carrying its id. Any error status means
> nothing was written.**

| Response | When | Body |
|---|---|---|
| `201 Created` | Row written, orchestrator acknowledged, `jobId` persisted | resource, `handoff: "ACCEPTED"` |
| `202 Accepted` | Row written, orchestrator call failed indeterminately | resource, `handoff: "UNCONFIRMED"`, `jobId` still null |
| `503 Service Unavailable` | Orchestrator not configured — nothing sent, **nothing written** | error only |
| `4xx` | Validation, authorization, or a definite upstream refusal | error only |

`202` is not a softened error; it is what actually happened. We accepted the request and
durably recorded it, and the job's fate is genuinely unknown — which is the same state the
row is in after any indeterminate failure, and which advance-on-read and `reconcile` already
resolve. Returning `502` instead forces every client to encode the knowledge that *this
endpoint's* `502` is special, and the alternative — assuming a `5xx` means nothing was
created — is a double-provision.

**`503` when unconfigured is a separate case on purpose.** With no ES256 key nothing is
sent upstream at all, so the request is not indeterminate: we know it never left. The
configuration check therefore runs **before** the row is written, so an unconfigured
environment strands nothing for `reconcile` to chase. This also makes the pre-launch state
(see [Operational prerequisites](#operational-prerequisites)) behave sanely rather than
minting a `PENDING` row per attempt.

**The cost, stated plainly:** an orchestrator outage now returns `2xx`, so it no longer
shows up in HTTP error-rate metrics. The service layer must emit a structured
error log naming the request `id` and `requestRef` on every `UNCONFIRMED` handoff, and
alerting keys off that rather than off the status code.

**Deploy order is API first.** A new web against an old API would read the old `502` as a
definite refusal and re-enable the submit button — the exact double-provision this exists to
prevent. The reverse is safe: an old web reads `.id` off a `2xx` and never notices.

**`clientName` is truncated to 20 characters by BladeX** for `tenantName`/`linkman`. We do
not truncate — we warn in the UI, because silently sending a different name than the dealer
typed is worse than telling them.

### `GET /api/tenant-provisioning-requests` — list own

Scoped through `resolveVisibleScope()`. Returns this actor's visible requests, newest first.
**Advances stale `PENDING` rows for this org as a side effect** — see
[Closing the orphan window](#closing-the-orphan-window).

### `GET /api/tenant-provisioning-requests/:id` — status

Scoped. **This read has a side effect**: if the row is `PENDING`, it polls the orchestrator
and advances the row before responding. See [Data flow](#data-flow).

### The provisioning-request resource

```jsonc
{
  "id": "uuid",
  "status": "PENDING",              // PENDING | SUCCEEDED | FAILED
  "handoff": "ACCEPTED",            // ACCEPTED | UNCONFIRMED — derived, see below
  "clientName": "Example Manufacturing Sdn Bhd",
  "packageType": "WMS",
  "accountingType": "SQL",
  "initialUserAccount": "exampleteam",
  "tenantId": null,                 // string once known — often while still PENDING
  "dealerClientId": null,           // set with SUCCEEDED
  "failureReason": null,
  "loginHost": "main.mes.sudu.ai",  // from config; see below
  "createdAt": "2026-08-11T…",
  "completedAt": null
}
```

`handoff` is **derived, never stored**: `jobId === null ? 'UNCONFIRMED' : 'ACCEPTED'`. No
column, no migration. It appears on every view rather than only on the submit response,
which buys a second use for free — once `reconcile` or advance-on-read recovers the job id
through `findJobIdByRequestRef`, the field flips to `ACCEPTED` on its own, so the status
page can say "still confirming this reached the provisioner" and then stop saying it without
anyone writing state to make that true.

It is the dealer-safe projection of "do we hold a job id". `jobId`, `requestRef`, and
`idempotencyKey` are **internal orchestration handles and are not exposed on the dealer
resource.** The admin resource adds `jobId` and `requestRef` for support. Nothing exposes
`idempotencyKey`.

`tenantId` is a **string**, always. BladeX ids exceed `Number.MAX_SAFE_INTEGER`.

### `loginHost` and the absent subdomain

Assumption 2 means a provisioned tenant has no subdomain of its own. It is reached at the
shared SaaS host and identified there by its BladeX tenant id — which
`DealerClient.tenantId`'s schema comment already describes as "the 6-digit login code…
the id a tenant types to log into the mobile app / AI chat web".

So:

- `dealer_client.slug` stays **`null`**. Truthful: there is no per-tenant subdomain.
- The host is config, not data: `SAAS_TENANT_LOGIN_HOST`, default `main.mes.sudu.ai`.
- The UI renders the instruction the dealer actually needs to pass on:
  *"Log in at `main.mes.sudu.ai` with Tenant ID `668171`."*

**`main` must not be written into `slug`.** It is on the reserved list
(`src/common/reserved-subdomains.ts`, the infrastructure/DNS group), and
`DealerClientService.create` rejects reserved slugs outright — a tenant at a reserved slug
is by definition internal and no dealer claim may attach to it. Writing `main` there would
put a value in the database that our own validator refuses, and would break what the column
means: `slug` is a *per-tenant* label that `login.sudu.ai` resolves back to one tenant.
N tenants sharing `main` makes that resolution impossible.

When the orchestrator does start assigning subdomains, `slug` starts carrying a real value
and the UI switches to it. No migration to undo.

### Platform-plane endpoints

| Endpoint | Purpose |
|---|---|
| `GET /api/admin/tenant-provisioning-requests` | Every request, any org. Closes the assumption-1 visibility hole |
| `POST /api/admin/tenant-provisioning-requests/reconcile?olderThanMinutes=15` | Sweep stale `PENDING` rows |
| `POST /api/admin/tenant-provisioning-requests/:id/retry` | Orchestrator retry-in-place for a `FAILED` row |

All three are `isPlatformAdmin` only.

Retry is deliberately **admin-only, not dealer-facing**. The orchestrator's own guidance is
that retry is only correct once the root cause is corrected — credentials, configuration,
downstream availability. A dealer cannot assess that, and a retry button they can mash is
a way to hammer a broken downstream.

## API side

### New table

A provisioning request is **its own entity, not a `dealer_client` in an unusual state.** It
has to be: `dealer_client.tenantId` is non-null and `@unique`, and there is no tenant id
until the orchestrator returns one. This table is also where spec B's quota and approval
states will live.

```prisma
model TenantProvisioningRequest {
  id                  String   @id @default(uuid())
  organizationId      String   @map("organization_id")
  ownerMemberNodeId   String   @map("owner_member_node_id")
  /// Plain String, no relation — `User` is a better-auth model (see the no-relations
  /// invariant). Same treatment as CreditReload.actorUserId.
  actorUserId         String   @map("actor_user_id")

  /// Sent upstream as `request_ref`. Unique, and the recovery handle: if we crash between
  /// POSTing and persisting jobId, `GET /v1/jobs?request_ref=` still finds our job.
  requestRef          String   @unique @map("request_ref")
  /// Sent upstream as the `Idempotency-Key` header. Same role as
  /// CreditReload.idempotencyKey: a retry can never double-provision.
  idempotencyKey      String   @unique @map("idempotency_key")
  /// Null only between our POST and its response.
  jobId               String?  @unique @map("job_id")

  // Immutable snapshot of what was asked for. Kept locally so audit and the UI never
  // depend on the orchestrator being reachable.
  clientName          String   @map("client_name")
  packageType         ProvisioningPackage    @map("package_type")
  accountingType      ProvisioningAccounting @map("accounting_type")
  initialUserAccount  String   @map("initial_user_account")
  initialUserName     String   @map("initial_user_name")
  initialUserRealName String   @map("initial_user_real_name")
  initialUserEmail    String   @map("initial_user_email")

  status              TenantProvisioningStatus @default(PENDING)
  /// Recorded on FIRST sight. The orchestrator populates `bladex_tenant_id` at the job
  /// envelope while the job is still `running`, because create_tenant is step 1 of 17.
  /// ALWAYS a String — never parsed, cast, or coerced.
  tenantId            String?  @map("tenant_id")
  dealerClientId      String?  @unique @map("dealer_client_id")
  failureReason       String?  @map("failure_reason")
  lastPolledAt        DateTime? @map("last_polled_at")
  createdAt           DateTime @default(now()) @map("created_at")
  completedAt         DateTime? @map("completed_at")

  ownerMemberNode MemberNode    @relation(fields: [ownerMemberNodeId], references: [id], onDelete: Restrict)
  dealerClient    DealerClient? @relation(fields: [dealerClientId],   references: [id], onDelete: Restrict)

  @@index([organizationId, createdAt])
  @@index([status])
  @@map("tenant_provisioning_request")
}

enum ProvisioningPackage {
  WMS
  AI
  MES

  @@map("provisioning_package")
}

enum ProvisioningAccounting {
  SQL
  ATC

  @@map("provisioning_accounting")
}

enum TenantProvisioningStatus {
  /// Queued or running upstream. We do not distinguish: indeterminate is indeterminate.
  PENDING
  /// The job succeeded AND the dealer_client row exists. Both, or neither.
  SUCCEEDED
  /// Terminal upstream failure, reason recorded.
  FAILED

  @@map("tenant_provisioning_status")
}
```

`DealerClient` gains the back-relation `provisioningRequest TenantProvisioningRequest?`.

Three choices worth defending:

**The row is written before the orchestrator is called.** Straight from `CreditReload`. If
the POST times out we still hold `requestRef` and `idempotencyKey`, so the job is findable
and a retry cannot double-provision. The reverse order loses the request on a network blip
— and a lost request means a BladeX tenant nobody knows we asked for.

**`PENDING` covers both `queued` and `running`.** Mirroring the orchestrator's four
statuses would give us a second vocabulary to keep in sync for no decision it changes: our
code branches on terminal-vs-not.

**`SUCCEEDED` asserts two facts.** If the job succeeds but the `dealer_client` write fails,
the row stays `PENDING` with `tenantId` recorded — which is precisely what reconcile then
repairs. That is why `tenantId` and `dealerClientId` are separate nullable columns rather
than one flag.

### New modules

Mirroring the existing `src/saas/` shape, which solves the same problem for su-code:

```
src/tenant-orchestrator/
  orchestrator.config.ts          # env-backed config, validated at boot
  orchestrator-token.provider.ts  # mints short-lived ES256 JWTs
  orchestrator.client.ts          # submitTenantJob / getJob / retryJob
src/tenant-provisioning/
  tenant-provisioning.controller.ts        # dealer plane
  admin-tenant-provisioning.controller.ts  # platform plane
  tenant-provisioning.service.ts
  dto/create-provisioning-request.dto.ts
```

### The fourth secret

[`sudu-dealer-api/CLAUDE.md`](../../sudu-dealer-api/CLAUDE.md) states that exactly three
secrets exist and stay separate: the dealer session secret, the gateway service credential,
and BladeX's key. **The orchestrator's ES256 private key is a fourth.** That invariant must
be amended in the same change — a stale "there are exactly three" is how the fourth ends up
folded into one of the others.

New config:

| Var | Purpose |
|---|---|
| `TENANT_ORCHESTRATOR_BASE_URL` | `https://tenant-orchestrator.dev.sudu.ai` |
| `TENANT_ORCHESTRATOR_JWT_PRIVATE_KEY` | ES256 private key, PEM. **The fourth secret** |
| `TENANT_ORCHESTRATOR_JWT_KID` | `kid` identifying our registered `ServiceIdentity` |
| `TENANT_ORCHESTRATOR_SERVICE_ID` | the `sub` claim |
| `TENANT_ORCHESTRATOR_JWT_ISSUER` | default `internal-identity` |
| `TENANT_ORCHESTRATOR_JWT_AUDIENCE` | default `tenant-provisioning-service` |
| `SAAS_TENANT_LOGIN_HOST` | default `main.mes.sudu.ai` |

Token minting: `alg: ES256`, plus `kid`, `iss`, `aud`, `sub`, `iat`, `exp`, `jti`, and a
space-delimited `scope`. Short-lived (5 minutes), minted per call, with only the scope that
call needs — `tenant:create` for submit, `job:read` for polling, `job:retry` for retry.

**Caching this token in a singleton is safe** and is not a violation of the
never-process-cache-per-organization rule. That rule is about *per-dealer* data leaking
across requests; this is a service credential with no tenant or org dimension. Said
explicitly because the invariant is easy to over-apply.

Prefer a CommonJS-compatible signer (e.g. `jsonwebtoken`). Known Issue 1b already documents
what one ESM-only dependency cost this repo; there is no reason to add a second when the
CJS option supports ES256.

### Authorization

- Dealer endpoints: org actor. Platform actor → `403`, same rule as claim creation.
- `ownerMemberNodeId` defaults to the acting member. If supplied, it is bound to the
  actor's own organization, and a non-`ADMIN` actor may only assign within its own role
  subtree — **identical logic to `DealerClientService.create`**, which exists because
  `MemberNode.id` is globally unique and unbounded assignment corrupts the attribution the
  commission engine keys off. Reuse it; do not re-derive it.
- Reads scoped by `resolveVisibleScope()`. No ad-hoc `where`.
- Admin endpoints: `isPlatformAdmin`, checked **before** any orchestrator call.

### Audit

`@Audit('tenant_provisioning.submit')` on submit; `tenant_provisioning.reconcile` and
`tenant_provisioning.retry` on the admin actions. Platform reads use the established
fail-open `recordIfPlatform` pattern — a read that already succeeded must never 500 because
the audit write hiccuped.

## Data flow

### Submit

1. Validate the DTO. Resolve and authorize `ownerMemberNodeId`.
2. **Check the orchestrator is configured.** If not, `503` and stop — before step 4, so
   nothing is written for a call that cannot happen.
3. Generate `requestRef` (`dealer-<uuid>`) and `idempotencyKey` (uuid).
4. **Write the request row `PENDING`.** Before any network call.
5. `POST /v1/provisioning/tenant-jobs` with `Idempotency-Key`.
6. Persist `jobId` from the receipt.
7. Return `201` with the resource.

If step 5 or 6 throws, the row stays `PENDING` with `jobId` null, and the response is `202`
with that same resource — the caller gets the id either way. The row is **never** marked
`FAILED` on an indeterminate error: the job may well be running, and reconcile owns it.

The ordering of steps 2 and 4 is the whole point. Reversed, an unconfigured environment
writes one `PENDING` row per attempt for jobs that were never sent, and hands every one of
them to `reconcile`.

### Poll and complete

`GET /api/tenant-provisioning-requests/:id` on a `PENDING` row:

1. `GET /v1/jobs/{jobId}?detail=full`. If `jobId` is null, find it first via
   `GET /v1/jobs?request_ref={requestRef}`.
2. Read `bladex_tenant_id` from the **job envelope**, not from `steps[].result.tenant_id`.
   The handoff doc is explicit that step `result` shapes are step-specific and only the
   envelope fields are stable. Record it as soon as it is non-null, even while `running`.
3. Stamp `lastPolledAt`.
4. On `succeeded` → in one transaction: create the `dealer_client`, then set the request
   `SUCCEEDED` with `dealerClientId` and `completedAt`.
5. On `failed` → `FAILED`, `failureReason` from the first failed step's `error`.
6. Otherwise leave `PENDING`.

The `dealer_client` written on success:

```
organizationId    ← request.organizationId
tenantId          ← job envelope bladex_tenant_id   (string)
slug              ← null                            (assumption 2)
ownerMemberNodeId ← request.ownerMemberNodeId
label             ← request.clientName
status            ← resolveLandingStatus(request)   (assumption 5 — see below)
onboardedAt       ← now when ACTIVE, null when PENDING
```

`resolveLandingStatus()` is a named seam, not decoration. In this spec its whole body
returns `ACTIVE`. Spec B replaces that body with the quota verdict and changes nothing else
in the completion path. `onboardedAt` follows from it: `DealerClientService.activate` sets
that timestamp at the moment of approval, so a claim landing `PENDING` must leave it null
or the two paths disagree about what "onboarded" means.

If that insert hits the `tenantId` unique constraint, the tenant is already claimed. Do not
create a duplicate: if the existing row belongs to the same org, link it and mark
`SUCCEEDED`; otherwise mark `FAILED` with a reason naming the conflict. Rare, but silent
divergence here would mean two orgs believing they own one tenant.

### Closing the orphan window

A 17-step job runs for minutes. Dealers will submit and navigate away. Three mechanisms,
in order of how often each will actually fire:

1. **Foreground poll.** The web app polls while the dealer watches.
2. **Advance on any read.** `GET /api/tenants` and
   `GET /api/tenant-provisioning-requests` advance that org's stale `PENDING` rows as a
   side effect. A dealer who closed the tab resolves their own job simply by coming back
   to the tenant list. This is what makes a scheduler unnecessary.
3. **Admin reconcile.** `POST /api/admin/tenant-provisioning-requests/reconcile` sweeps
   every stale `PENDING` row across all orgs — the backstop for a dealer who never returns.
   Mirrors `POST /api/admin/credit-reloads/reconcile`, including its `olderThanMinutes`
   parameter, default 15.

Because `bladex_tenant_id` is readable while the job is still `running`, the window in
which a tenant exists with no record on our side is one poll interval, not seventeen steps.

**Deliberately not a background scheduler.** The API has no scheduler today — no
`@nestjs/schedule`, no BullMQ, no `@Cron` anywhere. Adding one for this would introduce a
dependency, a new operational surface, and a multi-instance correctness problem (two API
processes both completing the same job and both writing `dealer_client`) in exchange for
covering only the case where *no one from that org ever loads a page again*. Reconcile
covers that case at a fraction of the cost.

## Error handling

Upstream failures never surface raw. Mapping:

| Upstream | Meaning | Our response |
|---|---|---|
| `400` | Bad request or missing idempotency key | `502` — our bug, not the dealer's. Logged loudly |
| `401` | JWT invalid or unknown identity | `502`, logged as a configuration fault |
| `403` | Missing scope | `502`, logged as a configuration fault |
| `409` on submit | Idempotency key reused with a different body | `500` — impossible unless we generated a duplicate key |
| `409` on retry | Job is not in `failed` state | Unreachable in normal operation — we reject a non-`FAILED` row with our own `409` *before* calling upstream. If it still occurs, our state and the orchestrator's disagree, so it is a `502` |
| `404` on poll | Unknown job | Row → `FAILED`, reason records the lost job |
| timeout / network | Indeterminate | Row **stays `PENDING`**. Never `FAILED` |
| *not configured* | Nothing was sent | `503`, and **no row is written** — see [Submit outcomes](#submit-outcomes) |

On **submit** specifically, the mapping above describes how we classify and log the
upstream fault, not what the caller receives. Every fault reached *after* the request row is
written — that is every submit-path row in this table, including the `409` and its `500` —
is returned to the caller as `202` with the row's id. The fault is unchanged and still
logged at `error`; what changes is that the dealer is handed the id of the thing we created
instead of an error implying we created nothing.

Reads and retries keep their statuses exactly as listed — no row is at stake there. And the
`503` row is the one submit-path fault that is genuinely reached *before* the write, which
is why it alone stays an error status.

The handoff doc notes that schema-validation errors are *not* normalized through a shared
filter. So error parsing must tolerate an unknown body shape and fall back to the status
code — never pattern-match a `message` field and assume it is there.

A failed job records `failureReason` from the first `failed` step, including its `step_id`,
so an operator can tell "SM2 encryption unavailable" from "MySQL gateway unreachable"
without opening the orchestrator.

## Web side

Dealer surface (`/`) only. No `/admin/*` UI in this spec beyond what the API exposes.

### Trim the wizard to the real contract

`CreateTenantForm.tsx` collects fields the orchestrator does not accept. Every one of them
is removed rather than quietly dropped at the API boundary — a form that collects data
nothing acts on is a promise the product cannot keep.

| Field | Fate |
|---|---|
| `company`, `name` | → one `clientName`, with the 20-char BladeX truncation warned inline |
| `slug` + `useSubdomainLookup` | **Removed from the create path.** Assumption 2 |
| `region`, `industry`, `phone` | Removed — no upstream field |
| ERP plan + AI plan (two pickers) | → one `packageType`: `WMS` / `AI` / `MES` |
| — | **New:** `accountingType` — `SQL` / `ATC` |
| — | **New:** initial user — account, name, real name, email |
| `delivery`, `mode` (`ready`/`demo`) | Removed. Demo/live is spec B |

`ClaimTenantForm` **keeps** its subdomain lookup untouched — claiming an existing tenant
still resolves a real slug. Only the create path loses it.

### New: submission and status

On submit the wizard navigates to a status view for that request id, which polls
`GET /api/tenant-provisioning-requests/:id` until terminal. It must be safe to close and
reopen — the request id is in the URL, and the API advances the row on any read, so
returning later resumes rather than restarts.

Because of the guarantee in [Submit outcomes](#submit-outcomes), the client's whole
classification is three branches and none of them encodes anything endpoint-specific:

| The client got | It means | It does |
|---|---|---|
| Any `2xx` | The row exists and its id is in hand | Navigate to the status view. `201` and `202` are not distinguished |
| A network error — no response at all | Indeterminate, and no body to read | Try to recover the row from the list endpoint; if that finds nothing, say so and **disable** submit |
| Any HTTP error status | Nothing was written | Show the server's message; submit stays live, because retrying is safe |

A `handoff` of `UNCONFIRMED` is a display concern only: the status view says the job is
still being confirmed rather than implying a clean handoff. It never gates navigation.

The no-response branch cannot be removed by any server change — if the connection dies,
there is no body — but it shrinks from "every 5xx" to "the socket dropped", which retires
the client-name correlation as the routine path.

Terminal states show:

- **Succeeded** — the tenant id, and the login instruction assembled from `loginHost` +
  `tenantId`, plus the fixed initial-password rule so the dealer can pass it to their
  customer, with the instruction to change it in SaaS on first login.
- **Failed** — `failureReason`, and the fact that recovery is a platform-admin action.
  No dealer-facing retry button.

`DealerTenantsView` needs no polling logic of its own; the API's advance-on-read behaviour
means a provisioned tenant materialises in the list on the next load.

## Testing

TDD, failing test first. Integration tests hit real Postgres; `resetDb()`'s test-database
guard is never weakened. The orchestrator is mocked at the client boundary — no test makes
a real call. No real dealer or customer data in fixtures.

Assertions that must exist, because each pins a decision this spec argues for:

- The request row is written **before** the orchestrator client is called (spy on call
  order). This is the whole recovery story.
- An indeterminate submit error leaves the row `PENDING`, never `FAILED`.
- An indeterminate submit error returns **`202` carrying the row's id**, not a `5xx`. The
  assertion is on the id being present in the body — that is the guarantee the client's
  whole classification rests on.
- `handoff` is `UNCONFIRMED` on that `202`, `ACCEPTED` on a `201`, and **flips to
  `ACCEPTED`** on a later read once reconcile recovers the job id. The third case is the one
  worth writing: it proves the field is derived rather than a stored flag nobody updates.
- With the orchestrator unconfigured, submit returns `503` and **`tenantProvisioningRequest`
  row count is unchanged**. Asserting the status alone would pass against the old
  write-then-fail ordering.
- Web: a `202` and a `201` produce the same navigation. A test that only covers `201`
  cannot tell the two branches apart.
- Web: an HTTP error of *any* status leaves submit enabled, and a transport-level failure
  with no response does not. This is the pair that stops a double-provision, so neither
  case is optional.
- `tenantId` is recorded from a job whose status is still `running`.
- `tenantId` is read from the **envelope**, and a job whose `steps[].result.tenant_id`
  disagrees with the envelope still yields the envelope value.
- No `dealer_client` row exists until the job reports `succeeded`.
- `tenantId` survives as a string end to end — a 16-digit id must not lose precision.
- Reconcile finds a job by `request_ref` when `jobId` is null.
- A `dealer_client` unique-constraint conflict does not create a duplicate and does not
  silently succeed.
- Scoping: one org cannot read another's request (and gets the same response shape as a
  genuinely missing id).
- A platform actor is rejected from the dealer submit endpoint.
- Retry rejects a non-`FAILED` row.

Web: `npm run build` is the gate, **not** `tsc --noEmit` — it exits 0 having checked
nothing (root `CLAUDE.md`, Known Issue 2).

## Operational prerequisites

Not code, and this feature cannot be verified end-to-end without them:

1. A `ServiceIdentity` registered with the orchestrator, its public key installed, and
   scopes `tenant:create`, `job:read`, `job:retry` granted. There is no public API for
   this — it goes through the controlled bootstrap process.
2. Our ES256 private key placed in the API's environment. Never in the repo.
3. A `connected` profile test passing before any live job. A failed SM2 check is blocking,
   because BladeX passwords must be SM2-encrypted.
4. A production orchestrator base URL. Everything documented so far is `dev`.

## Out of scope

Named explicitly so the boundary is reviewable:

- **Spec B — tenant mode, quota, approval policy.** Demo/test vs live; go-live conversion;
  per-dealer creation limits; the soft-block "Tenant Creation Limit Passed" state; approval
  toggles for create and for go-live; admin bypass and limit raising. It also takes over
  `resolveLandingStatus()`, which this spec leaves as a constant `ACTIVE`.
- **Spec C — reassign tenant ↔ dealer.** Moving a tenant between orgs. Non-trivial because
  `sale_event` is append-only and FK'd to `dealer_client`, so past attribution follows the
  row unless designed against.
- Individual orchestrator tenant APIs (departments, roles, storage, prefixes…) and repair
  jobs. Only the full flow, plus retry, is wired here.
- Provisioning-profile management. We use the active `dev_default`.
- Any `/admin/*` UI. The platform endpoints exist; screens for them are not in this spec.

## Open questions

1. **Typical successful job duration.** Unknown, and it sets both the web poll interval and
   the reconcile staleness cutoff. 15 minutes is inherited from `CreditReload` and is a
   guess here. Measure against dev before fixing it.
2. **Which fixed initial passwords, and how are they configured?** Assumption 3 settles the
   policy but not the mechanism: the orchestrator's default is `{account}@123!`, whereas
   `password_secret_ref` requires an env var to already exist on the *orchestrator's
   worker*. If the fixed passwords come from secret refs, someone must set them there, and
   this spec needs their names.
3. **Prod base URL** (also prerequisite 4).
