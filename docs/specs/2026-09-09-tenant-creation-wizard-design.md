# Tenant creation wizard: the plan decides, the form enforces — cross-repo design

**Status:** draft
**Revised:** 2026-09-09, three times.
**(1)** The dealer creates `Demo` or `Pre-Live` only; `Live` is a SuDu-admin transition —
[C5](#c5--the-dealer-creates-demo-or-pre-live-live-is-an-admin-transition).
**(2)** Add-on rates are read from SuDu ERP, not hardcoded — [C7](#c7--the-add-on-rate-card).
**(3)** A suspend action, from the `recycle-suspension-2026-09-09` handoff pulled the same day —
[C8](#c8--suspending-a-tenant-is-recycle).
**(4)** Caught up with prototype requirements 56-68: lengths refuse instead of truncating
([V1](#v1--tenant-and-initial-user-step-1)); names take letters, digits and spaces
([V3](#v3--organizations-and-plants-step-3)); errors follow the value rather than the button and
the step indicator is no longer a control ([W5](#w5--validation-and-where-it-appears)); the field
is *Workspace domain* and there are three domain values, not one ([D6](#d6--three-domain-values-and-only-one-of-them-is-shown));
and what the prototype's own bugs say about building this ([W8](#w8--what-the-prototypes-own-bugs-say-about-the-implementation)).
**Repos:** `sudu-dealer-api` · `sudu-dealer-web`
**Branches:** `feat/tenant-creation-wizard` (both)
**Plans:** api → [`2026-09-09-tenant-creation-wizard-api.md`](../../sudu-dealer-api/docs/superpowers/plans/2026-09-09-tenant-creation-wizard-api.md) (10 tasks) · web → [`2026-09-09-tenant-creation-wizard-web.md`](../../sudu-dealer-web/docs/superpowers/plans/2026-09-09-tenant-creation-wizard-web.md) (10 tasks)
**Item:** [1](../task-backlog.md#1-change-the-create-tenant-flow) · 68 requirements
**Prototype:** [Tenant Creation Flow](https://claude.ai/code/artifact/6c20f027-436e-454d-b48b-e46fce4f9c14) ·
[the plan step's own page](https://claude.ai/code/artifact/4ad5043c-ff84-43a5-8a58-b501464f4dab)

---

## Problem

The register-a-new-tenant wizard sends seven fields. The orchestrator accepts far more, and the
dealer needs most of them: how many organizations and users the tenant is entitled to, whether the
WhatsApp agent may read messages, what the tenant is billed monthly, and which extra organizations
and plants to create. **None of that is collected today, so every provisioned tenant lands on a
billing row with no limits and no price**, and every organization past the first is created by hand
afterwards.

Sixty-eight requirements were worked out against a prototype rather than in prose. This spec is what
that prototype settled, checked against the code and against
[the orchestrator field reference](../../../sudu-contracts/contracts/orchestrator/dealer-handoff-2026-09-08/tenant-orchestrator-field-reference-2026-09-07.md)
and the
[recycle-suspension handoff](../../../sudu-contracts/contracts/orchestrator/recycle-suspension-2026-09-09/recycle-suspension-handoff.md),
both at `9b38c10` — pulled 2026-09-09, and **newer than the version this spec was first written
against.** Three upstream changes landed in that pull and each one moved something here:

| Upstream change | Status | What it moved |
|---|---|---|
| `codex/fix-recycle-suspension` | pending deployment | [C8](#c8--suspending-a-tenant-is-recycle) — the suspend action, and `is_suspended` as a field of its own |
| `codex/feat-flexible-customer-status` | pending deployment | [C5](#c5--the-dealer-creates-demo-or-pre-live-live-is-an-admin-transition) — `customer_status` stopped being an enum |
| `codex/feat-no-accounting-integration` | pending deployment | [V4](#v4--accountingtype-is-required-sql-or-atc-at-the-top-level-too) — unchanged, still pending |

**None of the three is deployed.** Every rule below that depends on one says so.

Plane: **client plane**. A dealer provisioning for their own customer, on the dealer surface (`/`).
No vendor-console change — but see [open question 8](#open-questions), which asks whether the
suspend control belongs there instead.

---

## Decisions taken

Four questions shaped this and were answered on 2026-09-09:

| Decision | Answer | Consequence |
|---|---|---|
| ~~Where the four add-on rates live~~ | ~~Hardcoded in the web app~~ | **Superseded 2026-09-09.** They are read from SuDu ERP — see [C7](#c7--the-add-on-rate-card). |
| Where the add-on rates live | **SuDu ERP, collection `2095749825506906113`** | A rate change is a data change. The API can now check the add-on half of the total. See [C7](#c7--the-add-on-rate-card). |
| The two missing plan attributes | **Added to the catalog** | A **SuDu ERP request** — see [D1](#d1--the-plan-catalog-is-another-teams-data). |
| Dealer adjustment of the monthly price | **No — always calculated** | `total_price_per_month` is plan + add-ons, with no override field. |
| Scope | **The whole prototype** | Four steps, one spec, two plans. |
| The tenant's starting status | **`Demo` or `Pre-Live` only** — `Live` is a SuDu-admin transition | Two choices in the wizard, three values in the dictionary. Suspension is its own field. See [C5](#c5--the-dealer-creates-demo-or-pre-live-live-is-an-admin-transition). |
| Suspending a tenant | **A recycle call, one-way** | Upstream ships no unsuspend. See [C8](#c8--suspending-a-tenant-is-recycle) and [D8](#d8--suspend-has-no-undo). |

---

## What exists today

Verified against the code on 2026-09-09.

### The request we send

`CreateProvisioningRequestInput` (`sudu-dealer-web/src/services/dealer-api.ts:1472`) carries
`clientName`, `planId`, `customerDomain`, `accountingType`, `expireTime?`, `tenantAdmin?` and
`initialUser`. `SubmitTenantDraftInput` extends it, so the draft flow inherits every field.

`OrchestratorClient.create` (`sudu-dealer-api/src/tenant-orchestrator/orchestrator.client.ts:237`)
maps that onto the orchestrator body and sends
`customer: { customer_status: NEW_TENANT_CUSTOMER_STATUS }` — **the only customer field we send, and
it is a constant.**

### The plan catalog

`GET /tenant-plans` → `TenantPlanView[]`
(`sudu-dealer-api/src/tenant-provisioning/tenant-plan.controller.ts:12`), read by
`SuduPlanCatalogReader` from **SuDu ERP's su-code list pages**, not from our Postgres. It already
carries more than the wizard uses:

| The wizard needs | On `TenantPlanView` today? |
|---|---|
| User limit | **yes** — `userLimit` |
| WhatsApp number limit | **yes** — `aiService.whatsappLimit` |
| Accounting software included | **yes** — `aiService.accIntegration` |
| Organization limit | **no** |
| WhatsApp AI Read included | **no** |

`accIntegration` existing is worth stating plainly: **the rule that a plan without accounting
software cannot record an integration needs no new field.** Only two attributes are missing.

### Three constants that are about to become variables

- **`NEW_TENANT_CUSTOMER_STATUS = 'Testing'`** — every tenant this wizard provisions starts as
  Testing, deliberately, *"explicitly rather than inheriting a default that means the opposite."*
  The web mirrors it as `NEW_TENANT_STATUS` and renders it read-only. **The value itself is also
  changing**: the dictionary now reads `Live` / `Pre-Live` / `Demo` — see
  [C5](#c5--the-dealer-creates-demo-or-pre-live-live-is-an-admin-transition).
- **`tenantAdmin` is optional**, and omitting it means BladeX's defaults.
- **`derivedMonthlyRm()`** (`create-tenant/data.ts:11`) is labelled *derived by us, not stated by
  the ERP*, and shown as such.

Each of the three is loosened by this spec. [Consequences](#consequences-worth-a-decision) says what
that costs.

---

## Contract

The surface neither repo can decide alone. Repo invariants apply: **`planId` and `tenantId` are
strings, money is a string, authorization is the API's job.**

### C1 · `TenantPlanView` gains two fields

```ts
export interface TenantPlanView {
  planId: string
  planCode: string
  planName: string
  planDesc: string | null
  userLimit: number
  /** NEW. `sudu_plan.tenant_organization_limit`. The cap the wizard enforces on step 3. */
  organizationLimit: number | null
  erp: { planId: string; code: string; name: string; monthlyFeeRm: string }
  aiCredit: { planId: string; name: string; monthlyCredits: number; monthlyPriceRm: string } | null
  aiService: {
    planId: string
    name: string
    whatsappLimit: number
    accIntegration: boolean
    /** NEW. `sudu_ai_service_plan.wa_read_included`. Read is bundled, not an add-on. */
    waReadIncluded: boolean | null
  } | null
}
```

Both are **nullable, and null means "the ERP has not published this yet"** — not zero, and not false.
The reader must not invent a value; the fallbacks in [D1](#d1--the-plan-catalog-is-another-teams-data)
are the web side's job and are visible as such.

### C2 · `CreateProvisioningRequestInput` gains the customer block and the organization tree

```ts
/**
 * The SaaS `customer_status` values we recognise, 2026-09-09. `Live` is in the dictionary but
 * NOT creatable from this route — a dealer creates a Demo or a Pre-Live, and SuDu admin makes
 * it Live. See C5.
 *
 * Suspension is not a status any more. It is `sudu_customer.is_suspended`, numeric, written
 * only by a recycle call — see C8. Historical rows still carry `Live Suspended` and
 * `Testing Suspended` and are never rewritten, so anything READING a status must still know
 * those strings.
 */
export type TenantCustomerStatus = 'Live' | 'Pre-Live' | 'Demo'
/** What this route will actually accept. */
export type CreatableCustomerStatus = Extract<TenantCustomerStatus, 'Demo' | 'Pre-Live'>

export interface CreateProvisioningRequestInput {
  // …unchanged: clientName, planId, customerDomain, accountingType,
  //   expireTime?, tenantAdmin?, initialUser

  /**
   * NEW, and REQUIRED. All five together — a partial block is how a tenant ends up on a
   * billing row with a price and no limits. The three counts are EFFECTIVE values: the
   * plan's own entitlement plus whatever was bought as an add-on, already summed by the web.
   */
  customer: {
    organizationLimit: number      // integer >= 0
    userLimit: number              // integer >= 0
    waNumberLimit: number          // integer >= 0
    waAbleRead: 0 | 1              // numeric, not boolean — the orchestrator's shape
    totalPricePerMonth: string     // money is a STRING on this wire. See C3.
    /** Absent means `Demo`. NEVER absent on the wire to the orchestrator — see C5. */
    status?: CreatableCustomerStatus
  }

  /** NEW. Omit entirely for a tenant with only its default organization. */
  organizationSetup?: {
    default?: { departments: { deptName: string }[] }
    additional?: {
      organizationName: string
      accounting: { type: 'SQL' | 'ATC' }
      departments: { deptName: string }[]
    }[]
  }
}
```

**`organizationSetup` is omitted, never sent empty.** The field reference is explicit that omission
leaves a caller field out of the payload rather than writing a blank, and that
`default.departments` **replaces** the automatic HQ rather than adding to it — so an empty array is
a tenant with no departments, which is not what an empty form means.

### C3 · Money crosses the boundary as a string and reaches the orchestrator as a number

`total_price_per_month` is *"number ≥ 0, decimals allowed"* upstream, and this repo's invariant is
that money on our own wire is a string. **The conversion happens once, in the API, at the
orchestrator boundary** — the same place `customer_domain` is composed. Neither side does it twice,
and the web never parses a price to send it.

### C4 · The API checks the add-on half of the total

With the rates served rather than hardcoded ([C7](#c7--the-add-on-rate-card)), the API knows what
the add-ons cost and can verify that part of the figure it is given:

```
totalPricePerMonth − derivedPlanPrice(planId) == Σ(add-on count × rate)
```

It cannot verify the whole number, because `derivedPlanPrice` is itself derived — see
[D4](#d4--a-derived-total-becomes-a-stored-billing-figure). So the check is on the **difference**,
and a mismatch is a 400 rather than a silent correction: if the two sides disagree, one of them is
wrong and quietly picking a winner is how a customer gets a price nobody quoted.

A dealer running a stale bundle after a rate change now **fails loudly at submit** instead of
writing the old price to a live billing row. That is the whole reason this decision was reversed.

### C5 · The dealer creates Demo or Pre-Live; Live is an admin transition

Two changes landed together, and the second one inverts a default.

**The wizard offers two of the three values.**

| Value | Created by the wizard? |
|---|---|
| `Demo` | **yes** |
| `Pre-Live` | **yes** |
| `Live` | **no** — a SuDu admin moves a tenant to Live |

A dealer cannot mint a paying customer. The type control shows two options, the DTO's
`CreatableCustomerStatus` admits two, and the API rejects `Live` from this route with a 400 that
says who can set it. `Live` stays in `TenantCustomerStatus` because everything that *reads* a
tenant still meets it.

**Upstream, `customer_status` stopped being an enum — and omitting it now means `Live`.**
`codex/feat-flexible-customer-status` (pending deployment) replaces the fixed enum with
*"Optional `T`: any trimmed, non-empty string; case preserved; downstream acceptance still
required."* Two consequences, in order of how much trouble they can cause:

1. **Omission is no longer safe.** *"When omitted, the selected profile's creation default
   applies (seeded `Live`)."* An absent status therefore produces the one value this route
   refuses to let a dealer choose. **The API must always send an explicit `customer_status`** —
   which is exactly what `orchestrator.client.ts` already does, and exactly what its comment gave
   as the reason: *"explicitly rather than inheriting a default that means the opposite."* That
   comment is now literally true. `status` stays optional on **our** wire, defaulting to `Demo`,
   and the API resolves it before the orchestrator ever sees the request.
2. **The vocabulary is now ours to police.** The orchestrator will accept `Trial`, `demo`, or a
   typo. **We are the only enum left**, and *"orchestrator acceptance does not prove downstream
   acceptance"* — su-code may still reject a value the orchestrator took.

**Suspension is not a status.** `Live Suspended` and `Testing Suspended` are not written any
more; a suspended tenant is a `Demo` / `Pre-Live` / `Live` tenant with
`sudu_customer.is_suspended = 1` ([C8](#c8--suspending-a-tenant-is-recycle)). But the handoff is
explicit that *"existing values, including historical statuses containing Suspended, remain
exactly as they are"* — so the two strings are **historical data, not dead code**, and every
reader keeps them.

The `customer` block as a whole is **required** — see [C2](#c2--createprovisioningrequestinput-gains-the-customer-block-and-the-organization-tree).
`status` is the one field inside it that is not, because it is the one that changes what a tenant
*is* rather than what is recorded about it. **Absent means `Demo`**: the state that consumes a demo
slot rather than silently skipping the cap, and the one a dealer is upgraded out of rather than
walked back from.

**A draft saved before this ships has no `customer` block.** Opening it recomputes the three counts
from its stored plan, prices them at the current rates, and defaults the status to `Demo`.

### C6 · Errors

| Case | Status | Body |
|---|---|---|
| Any customer field negative, or a non-integer limit | 400 | field-named message |
| `totalPricePerMonth` not a non-negative decimal string | 400 | field-named message |
| `customer.status` outside `Demo` \| `Pre-Live` | 400 | field-named message; `Live` gets its own text saying a SuDu admin sets it |
| `customer.totalPricePerMonth` disagrees with the rate card by more than the plan price | 400 | field-named message. See [C7](#c7--the-add-on-rate-card) |
| An additional organization without `SQL` or `ATC` | 400 | field-named message, **ours, before the orchestrator's** |
| Organization or department name rules ([V3](#v3--organizations-and-plants-step-3)) | 400 | field-named message |
| A repeated organization name ([V5](#v5--repeated-organization-names-are-allowed-through-and-reported)) | 400 | field-named message — **the web deliberately does not pre-empt this one** |
| Plan id no longer resolves | 502 passthrough | the orchestrator's own `plan_not_found` |

**The API validates the organization rules itself rather than relying on the orchestrator**, because
the orchestrator's slug limitations are documented as *"current planner limitations, not fully
implemented API validation rules"* — it may accept a body the planner then mishandles. See
[V3](#v3--organizations-and-plants-step-3).

### C7 · The add-on rate card

`GET /tenant-add-on-rates` → `AddOnRateView[]`, session-guarded and org-agnostic, read from **SuDu
ERP collection `2095749825506906113`** the same way the plan catalog is read.

```ts
export interface AddOnRateView {
  /** `add_on_code`. The join key, and the value the web matches on. */
  addOnCode: string
  /** `add_on_name`. Display only — never matched on. */
  addOnName: string
  /** `price_per_month`, decimal(65,2). Money is a STRING. */
  pricePerMonth: string
}
```

Five rows exist today, and **the wizard prices four of them**:

| `add_on_code` | RM / month | Used by the wizard |
|---|---|---|
| `User` | 59.00 | raises `customer.userLimit` |
| `WhatsApp Number` | 89.00 | raises `customer.waNumberLimit` |
| `Organization` | 149.00 | raises `customer.organizationLimit` |
| `WhatsApp AI Read` | 500.00 | sets `customer.waAbleRead` |
| `WhatsApp Signature` | 50.00 | **nothing** — no customer field carries it. See [open question 7](#open-questions) |

**`add_on_code` is a human label, not a code.** `WhatsApp AI Read` is the key *and* the display
string, which is the same fragile shape as `customer_status` — and that one is renaming as this
ships ([D7](#d7--renaming-testing-to-demo-turns-the-demo-cap-off)). So:

- the **web** matches on `addOnCode` against four named constants and treats a missing row as
  fatal for that add-on: the control is hidden and the reason logged, rather than priced at zero;
- the **API** returns whatever the collection holds, including the fifth row, and never filters to
  a list it keeps in its head — a rate card that silently drops a row is worse than one with a row
  nobody uses.

An empty or unreadable collection is a **503**, matching `GET /tenant-plans` — the catalog is
unusable, not the request. **The wizard cannot price a plan without it**, so the plan step surfaces
the failure rather than showing a total of the plan price alone.

### C8 · Suspending a tenant is `/recycle`

From the
[recycle-suspension handoff](../../../sudu-contracts/contracts/orchestrator/recycle-suspension-2026-09-09/recycle-suspension-handoff.md),
**pending deployment** on `codex/fix-recycle-suspension`.

```
POST {orchestrator}/v1/tenants/{bladex_tenant_id}/recycle
Authorization: Bearer <internal service JWT>          scope: tenant:recycle
Idempotency-Key: <unique per operation>
{ "expected_tenant_name": "Acme Demo", "request_ref": "dealer-suspend-<id>" }
```

It soft-recycles the BladeX tenant and writes **only** `sudu_customer.is_suspended = 1`, numeric.
`customer_status` is left exactly as it was.

**Three fields are forbidden or absent, and each one is a 400 if sent:**

| Field | Why |
|---|---|
| `customer_status` | *"Forbidden on NEW recycle submissions."* The worker no longer maps status at all. |
| `is_suspended` | Not an input. *"The worker always writes numeric `1`."* |
| any replacement body on retry | *"Retry does not accept a replacement recycle payload."* |

Our own route:

```
POST /tenants/:tenantId/suspend      →  { requestId, jobId, status }
```

`tenantId` is ours; the API resolves the downstream `bladex_tenant_id` and never accepts it from
the browser. `expected_tenant_name` is filled by the **API** from the tenant it resolved, not by
the client — a name guard the caller supplies guards nothing.

Outcomes come back on the job's `customer` block: `retired`, `already_retired`, or
`no_billing_customer`. **`no_billing_customer` is a success**, not an error: *"Allowed, reported as
`no_billing_customer`; no suspension flag can be reported for a nonexistent row."*

Failure handling is the existing job machinery: poll `GET /v1/jobs/{job_id}?detail=true`
(`job:read`), and on FAILED use `POST /v1/jobs/{job_id}/retry` (`job:retry`) with no body. **Retry
is the only recovery** — a partial failure leaves a tenant recycled in BladeX with its billing row
un-flagged, and the handoff is explicit that this is *"an existing recycled tenant awaiting billing
completion, not permission to create a replacement tenant."*

---

## API side

### A1 · Extend the catalog reader

Add `tenant_organization_limit` to `PLAN_FIELDS` and `wa_read_included` to `SERVICE_FIELDS` in
`saas-pricing/sudu-plan-catalog.reader.ts`, parse both through the existing `toCountInt` / `flag`
helpers, and surface them on `SuduPlan` → `TenantPlanView`. **Absent column → `null`**, which the
reader must distinguish from `0` and `false`; `toCountInt` currently cannot, so it needs a nullable
sibling.

This work is inert until [D1](#d1--the-plan-catalog-is-another-teams-data) lands. It is written
first anyway, because it is what makes the fallback removable.

### A2 · Extend the provisioning DTO and the orchestrator mapping

`CreateProvisioningRequestDto` gains the `customer` block and `organizationSetup`, with
`class-validator` rules matching [C6](#c6--errors). `OrchestratorClient.create` maps them onto
`customer` (all five fields plus the status) and `organization_setup`, converting the price to a
number and omitting `organization_setup` when there is nothing to send.

The `customer` object is currently built inline at `orchestrator.client.ts:237`. It becomes a named
mapper with its own tests, because it is now the only place five business values become a wire shape.

### A3 · Persist what we send

`ProvisioningRequest` records `planId`, `customerDomain`, `accountingType` and the initial user
today, so a dealer can see what was submitted. The five customer fields and the organization tree
must be persisted the same way, or the review screen after submit shows less than the review screen
before it. This is a Prisma migration on **our** Postgres — the only one this spec needs.

### A4 · The draft flow inherits everything

`SubmitTenantDraftInput extends CreateProvisioningRequestInput`. The handoff warns that adding
fields means updating **draft persistence, validation, edit, reveal and submit**, or one entry path
silently loses them. This spec adds six top-level fields and a nested array; all five paths are in
scope, and the web plan's task list must name them individually.

### A5 · The add-on rate reader

A `SuduAddOnRateReader` beside `SuduPlanCatalogReader`, reading through the same
`SucodeListClient`, with `addOnRateCollectionId` in `saas.config.ts` — env
`SAAS_ADD_ON_RATE_COLLECTION_ID`, default **`2095749825506906113`**, following the pattern of the
four collection ids already there. Fields `add_on_code,add_on_name,price_per_month`; add
`is_active` to the projection and the `where` **only if the collection carries it**, matching the
plan reader's convention.

`price_per_month` is `decimal(65,2)` and becomes a `Prisma.Decimal`, then a string at the view
boundary — never a JS number, the same rule the plan's `monthlyFeeRm` follows.

Cached like the plan catalog and invalidated the same way. The verification in
[C4](#c4--the-api-checks-the-add-on-half-of-the-total) reads from this reader, so a create request
and the wizard that built it price against the same rows.

### A6 · The suspend route

`POST /tenants/:tenantId/suspend`, guarded by the session **and** by tenant ownership —
`ScopingService.resolveActScope(actor)` produces the `where` clause that decides whether this
dealer may touch this tenant — the same one `revealTenantAdminPassword` uses — behind
`hasPermission(actor, 'tenant', 'create')`. The answer is the API's alone. The handoff says it plainly: *"The Dealer API must enforce its own tenant ownership
and operator permissions; keep service signing credentials out of the browser."*

The route mints the `Idempotency-Key`, fills `expected_tenant_name` from the resolved tenant, and
records the returned `jobId` against the tenant so the result is pollable after a reload. **A
timeout is not a failure**: *"repeat the same request with the same key to recover its receipt, not
a new key."*

`tenant:recycle` must be in both the signed JWT and the enabled ServiceIdentity allow-list —
*"`tenant:create` alone is not sufficient."* **This is the one thing in this spec that needs a
scope we do not have today**, and it is a deployment task, not a code task.

### A7 · Teach the demo reader both vocabularies

`readDemo` recognises `Demo` **and** `Testing` as a demo, and `Live` / `Pre-Live` alongside the
retired `Live Suspended` / `Testing Suspended` as definitely-not. The two old strings are removed
only when the ERP has no rows carrying them. `DemoCountService` already logs the raw value, so the
migration's progress is visible without new instrumentation.

Whether **Pre-Live** is a demo for cap purposes is [open question 4](#open-questions); until it is
answered it is classified as **not** a demo, which matches `Live` and is the behaviour the cap has
today for anything that is not `Testing`.

**`Live Suspended` and `Testing Suspended` stay in `NON_DEMO_STATUSES` permanently.** The handoff
is explicit that historical statuses containing *Suspended* are never rewritten, so those rows
outlive the rename. Suspension is read from `is_suspended` for new rows and from the status suffix
for old ones — **the one place this spec allows inferring suspension from a status**, and only
because those rows can never be updated to carry the flag.

**Ordered before the wizard ships** — see [D7](#d7--renaming-testing-to-demo-turns-the-demo-cap-off).

### A8 · The admin-account pre-flight

A new dealer-API route that answers whether a derived admin username already exists in the SuDu ERP
— `table_id 1789995126399348746`, field `account`. Session-guarded, org-agnostic, read-only,
rate-limited. It is **advisory**: the answer can go stale before the job runs, so submit still has
to survive a collision, and the route says so in its own response rather than only in the UI.

**Not a blocker for the rest of the spec.** If it slips, the wizard loses a warning and keeps
working.

---

## Web side

Dealer surface (`/`), route `tenant-register`, components under
`components/tenants/create-tenant/`.

### W0 · Tenant type is the customer status, and it decides the step count

Step 1 opens with a three-way choice that maps one-to-one onto
[`customer.status`](#c5--the-dealer-creates-demo-or-pre-live-live-is-an-admin-transition). It is not a separate concept
with a translation layer; the label the dealer picks is the string SuDuAI ERP stores, so a dealer
who goes looking in the ERP finds the same word. That rule already governs today's read-only
status field and this spec keeps it.

| Tenant type | `customer.status` | Plan step | Steps |
|---|---|---|---|
| **Demo** | `Demo` | no | 3 |
| **Pre-Live** | `Pre-Live` | **yes** | 4 |

**There is no Live option**, and it is not shown disabled either — a dealer never moves a tenant to
Live, so the control has nothing to say about it. The repo's own rule decides this: hide the
permanently impossible, disable the contingent. Where the wizard explains what happens next, it
says a SuDu admin makes the tenant Live.

**Pre-Live takes the plan step**, which is an assumption rather than something the dictionary
settles — see [open question 3](#open-questions). The reasoning: the limits and the monthly price
are recorded metadata, and a tenant that is about to go live has already been sold something. If
Pre-Live skipped the plan step, going live would mean re-entering every commercial value on a
screen that does not exist yet.

The plan step does not exist on the Demo path — it is not skipped — so the numbering closes up
behind it rather than leaving a gap. Switching the type while standing on the plan step moves the
dealer off it rather than stranding them on a panel that is now hidden.

### W1 · The plan step

`PlanMatrix` gains search, bounds and a comparison view. Two matching rules, not one:

- **names and codes** match on substring;
- **descriptions** match on **whole words**.

A prefix rule was tried and rejected: searching `MES` matched *messaging* in a plan description and
put the wrong plan at the top.

Bounds are minimum organizations, users and WhatsApp numbers. `0` and an empty box both mean *no
bound*, so deleting back to nothing never hides every plan.

**`planDesc` is nullable and the panel must say so** rather than collapsing to nothing — the catalog
really does ship plans with no description.

### W2 · Add-ons and the monthly total

Four add-ons above the plan's own entitlements. **The `add_on_code` is the contract; the rate is
whatever the ERP says today.**

| Control | Matched on `add_on_code` | Field it raises | RM/mo on 2026-09-09 |
|---|---|---|---|
| Additional user | `User` | `customer.userLimit` | 59.00 |
| Additional WhatsApp number | `WhatsApp Number` | `customer.waNumberLimit` | 89.00 |
| Additional organization | `Organization` | `customer.organizationLimit` | 149.00 |
| WhatsApp AI Read | `WhatsApp AI Read` | `customer.waAbleRead` | 500.00 |

The right-hand column is an observation, not a value this spec fixes — it is here so a reviewer can
recognise a wrong reading, and nothing in either repo should encode it.

**The rates are fetched, not held.** `GET /tenant-add-on-rates` ([C7](#c7--the-add-on-rate-card))
is loaded alongside `GET /tenant-plans` on entering the wizard. `create-tenant/rates.ts` keeps only
the four `add_on_code` constants used to match rows, and the total function — **no number.** A rate
that cannot be matched hides its control and logs, rather than pricing it at zero.

The plan step cannot open until both requests resolve. Losing the catalog is already a blocking
error there; losing the rate card is the same kind of failure and gets the same treatment, because
a total assembled from a partial rate card is a wrong quote that looks right.

`totalPricePerMonth = planPrice + Σ(add-on count × rate)`, where `planPrice` is
`derivedMonthlyRm()`. It is **read-only and never typed** — `readOnly`, not `disabled`, so the
figure stays selectable and copyable; this is the number a dealer reads out to their client, and a
`disabled` input leaves both the tab order and the mouse-event stream.

**WhatsApp Read is standard on Standard, Pro and Max.** On those plans the switch is on, free, and
not a choice — disabled, not hidden, because it is contingent on the plan rather than permanently
impossible.

### W3 · Organizations and plants

The default organization is named after the client and is not editable. Additional organizations
each carry a name, an accounting type and at least one department; HQ is fixed.

Two rules come from the plan, not from this step:

- **The cap.** `+ Organization` disables at `organizationLimit + purchased organizations`, and the
  hint says how to raise it. **If it is not enforced here it is not enforced anywhere** — the field
  reference states there is *"no comparison against `customer.organization_limit`"* upstream.
- **The accounting rule.** A plan with `accIntegration: false` forces every organization to `-` and
  disables the choice. The value is *forced*, not merely blocked, and forced **when the plan
  changes**, not when the step is next opened.

Neither rule may delete a dealer's work. Going back and choosing a smaller plan leaves the
organizations intact, over the cap, with the mismatch stated and both ways out offered.

Two rules belong to this step itself. **Names take letters, digits and spaces**, stripped as they
are typed and stated once under the step heading ([V3](#v3--organizations-and-plants-step-3)). And
**a repeated name does not block** — it is reported at the end
([V5](#v5--repeated-organization-names-are-allowed-through-and-reported)).

**A row that has just been added is unfinished, not invalid.** It carries no error until it is typed
into, and Continue marks every row before asking, so nothing can be walked past — the one place
where [W5](#w5--validation-and-where-it-appears)'s live rule is deliberately delayed.

### W4 · Derived credentials

`{workspace}_main` and `{Workspace}@serious69`, first character capitalised, with no input of their
own. The admin step disappears.

### W5 · Validation, and where it appears

**Continue is never disabled.** Pressing it on an invalid step marks the fields and stays put.

**Errors follow the value, not the button.** A field says so on the keystroke that makes it invalid
and clears on the one that fixes it. Three things wait, and in each case nothing invalid has been
typed yet: the **plan choice**, which is missing rather than wrong; a **new organization row**,
which is unfinished until it is typed into or Continue is pressed; and the email's **format**, which
is invalid on nearly every keystroke of a valid address and so waits for the field to be left. The
email's *length* is live, because that is definite at any moment.

Each field has **one** error channel: a red ring plus a message beneath it. Guidance hints
(*Available*, *Looks like an address*) never turn red — two channels for one problem is how a form
starts contradicting itself.

**The step indicator is not a control.** It says where you are; **Back and Continue are the only
way through**, which makes them the only paths that can run a step's validation on the way out. A
clickable indicator meant every forward jump had to be gated separately — two paths to guard where
one will do.

The **Edit** links on the review are the exception, and deliberately so: they always go backwards,
and going back has never needed a gate.

### W6 · The review

One card per step — tenant and initial user, plan, organizations and plants, derived admin account —
each with an Edit link to the step that owns its values. The admin card's Edit goes to **step 1**,
because the credentials derive from the workspace and have no field of their own.

Three values appear here and nowhere else in the flow: **the initial user's password**
(`{account}@123!` — a settled value, not a hint), **the plant total** across all organizations, and
the step count. The plan ID and `customer_status` are deliberately **not** on the cards; they are
wire values, and the payload below is where wire values belong.

The demo path shows no plan card at all. A card whose only content is *this step did not happen*
reviews nothing.

### W7 · The suspend action

**Not part of the wizard.** It belongs to a tenant that already exists, so it lives on the tenant
detail surface, next to the other lifecycle controls — not on any step of creation.

A destructive-action confirmation, which the handoff requires us to keep. It states, in this order:

1. **what happens** — the BladeX tenant is retired and the billing row is flagged suspended;
2. **what does not** — no data is deleted, no provisioning is rolled back, no scheduler is stopped;
3. **that it cannot be undone from here.** [D8](#d8--suspend-has-no-undo).

The dealer types the tenant's name to confirm. That mirrors `expected_tenant_name`, which the API
fills from the tenant it resolved — the typed name gates the button, the resolved name guards the
write, and they are deliberately not the same value.

After submit the button becomes a job status, polled like provisioning. **A failed job offers
Retry, not Suspend again** — the two are different operations and the second would mint a new
idempotency key for work that is already half done.

**Status and suspension are displayed separately**, on this screen and everywhere else the platform
shows a customer record. The handoff asks for exactly this: *"Display customer status and
suspension separately… Do not infer suspension from a status suffix."* A suspended Pre-Live tenant
reads as **Pre-Live · Suspended**, two facts, because that is what it now is.

### W8 · What the prototype's own bugs say about the implementation

Sixty-eight rounds produced eight rendering bugs, and they fall into exactly two families. Both are
artefacts of building this by hand, and **a component-rendered implementation avoids every one of
them by construction** — which is the strongest single argument this prototype makes about how to
build the real thing.

**Family one: rebuilding a container destroys the control inside it.** It appeared four times — the
price field ate typed characters, the steppers froze their highlights, the bounds fields reversed
`12` into `21`, and typing an organization name dropped focus on every keystroke. Each fix was the
same: remember the focused element's id and caret, restore both after the rebuild. **The danger for
the real implementation is not writing this bug — React will not — but re-introducing it via a
hand-rolled "don't re-render while focused" optimisation.**

The `12` → `21` case is worth carrying as a specific warning: it only happened because the input was
`type="number"`, which reports `selectionStart` as `null`, so the caret could not be restored and
every keystroke landed at position 0. **A numeric field that re-renders needs `type="text"` with
`inputmode="numeric"`.**

**Family two: a flex container turns every child into a layout box, bare text included.** It
appeared three times — a `<code>` inside an error message broke onto its own line, an error badge
became a flex item, and the required star drifted into the middle of its label row. The rule: **any
container that mixes prose with inline markup must group the prose first.**

Two smaller ones, both about a component inheriting from the page around it: the page's bare `th`
rule rendered plan names as *LITE, BASIC*, and its bare `p` rule added a bottom margin the card's
own padding already provided. **This component needs its own reset, not case-by-case patches.**

---

## Validation rules

Every rule below is from the field reference except the four marked **ours**. Both repos implement
the same set; the web's job is to be kind about it, the API's is to be the gate.

### V1 · Tenant and initial user (step 1)

| Rule | Source |
|---|---|
| `client_name` required, ≤ 20 characters, trimmed | *"Required `S`… send a trimmed name of at most 20 characters"* |
| Workspace required, ≥ 3, no leading/trailing hyphen, not all-digit, not reserved | existing `tenant-lookup` policy |
| `account` required, 1–45 | *"Required string, 1–45"* |
| `account` ≠ `admin`, after trim and case folding | *"Must not equal `admin` after trim + case folding"* |
| `account` ≠ the effective admin username, ignoring case and surrounding spaces | *"The server checks both merged values before accepting the job"* |
| `name` required 1–20; `real_name` required 1–10 | *"Required string"* both |
| Email required, 0–45; `""` allowed | *"Required string, 0-45"* |
| Email format | **ours** — the reference says *"no email-format validator"* |

`real_name` is **10**, not 20 and not 100. The reference flags it explicitly: *"validate separately
in the dealer UI."*

**Every length is a refusal, never a truncation.** No field carries `maxlength`. A dealer typing
*Kenhin Timber Industries Sdn Bhd* keeps all 32 characters, the counter reads `32 / 20` in red, and
Continue refuses with *Client name is 32 characters. The limit is 20 — remove 12.* A field that
silently eats the end of a name is how a tenant gets provisioned as *Kenhin Timber Indust* and
nobody notices until the ERP shows it.

### V2 · Plan (step 2)

`plan.plan_id` is required with no default, and *"must resolve to a non-deleted billing plan with a
package and usable permissions **at execution**"* — so a plan that vanishes between selection and
submit fails inside the job, not in the form. The catalog refresh clears a selection that no longer
resolves and says why.

### V3 · Organizations and plants (step 3)

| Rule | Source |
|---|---|
| Organization and plant names take **letters, digits and spaces only** | **ours** — see below |
| Additional organization name ≥ 2 characters | **ours** |
| Slug not `default`, at least one ASCII letter or digit | *"Avoid a slug of `default`… or names with no ASCII letter/digit"* |
| ~~Names unique within the request, and never equal to `client_name`~~ | *"unique within the request and not equal `tenant.client_name`"* — **the wizard no longer blocks this.** See [V5](#v5--repeated-organization-names-are-allowed-through-and-reported) |
| ~~No duplicate slugs~~ | *"duplicate slugs such as `A B`/`A-B`"* — same, and for the same reason |
| Department names unique within their organization | *"unique within their organization"* |
| Each additional organization: `accounting.type` of `SQL` or `ATC`, and ≥ 1 department | *"Required… required"* |
| Organizations within the recorded limit | **ours** — nothing upstream compares them |

**The character rule is ours, and it is deliberately narrower than the contract.** The reference
only requires a name to contain an ASCII letter or digit. This restricts organization and plant
names to **letters, digits and spaces**, stripped as they are typed rather than reported afterwards
— refusing a character the field could simply not have accepted is an error message doing a
keyboard's job. It is stated once under the step heading, because a hyphen is plausible enough in a
real company name that silently dropping it would otherwise read as a bug.

**Hyphens are excluded for now and are expected to be allowed later.** One flag decides the
character class and the sentence that describes it. **Before it is flipped:** `slug()` turns a
hyphen and a space into the same separator, so `A-B` and `A B` collide from the day hyphens are
permitted — the case [V5](#v5--repeated-organization-names-are-allowed-through-and-reported)
already reports, which will start firing for names a dealer considers obviously different.

**Uniqueness is checked on `slug(name)`, not on the name** — see V5 for why the wizard reports it
rather than blocking. `A B` and `A-B` are visibly different names that collide on the internal slug,
and the reference files this as a planner limitation rather than API validation, meaning **the
server may not reject them; the planner just breaks.** Both repos use one `slug()` implementation,
specified here so they cannot drift:

```
slug(n) = n.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
```

### V4 · `accounting.type` is required `SQL` or `ATC` at the top level too

Not only for additional organizations. The reference's `accounting.type` row reads *"Required `SQL`
or `ATC` — Type for the default organization."* **A `-` anywhere is a 400.**

`-` is nevertheless offered in the UI, because it was asked for ahead of an orchestrator change. It
does not block moving through the wizard; it is listed on the review as something the orchestrator
will reject today, and the API rejects it with a field-named 400 rather than passing it upstream.
**When the orchestrator change lands, the API's rule is the one line that has to move.**

**One combination is unsubmittable however it is filled in.** A plan with `accIntegration: false`
forces every organization to `-` ([W3](#w3--organizations-and-plants)), and an additional
organization must carry `SQL` or `ATC`. The two rules leave no legal value, so such a plan can
provision a tenant with its default organization only. The step says that as an impossibility rather
than as two warnings that happen to share a screen. **No plan on today's rate card has
`accIntegration: false`**, so this is reachable only if the catalog changes — which is exactly why
the rule is data-driven rather than a plan-code list.

### V5 · Repeated organization names are allowed through, and reported

**Decided 2026-09-09, against the contract.** The field reference is unambiguous — *"Organization
names must be unique within the request and not equal `tenant.client_name`, trimmed and
case-insensitive"* — and the orchestrator returns a 400. The wizard nevertheless accepts a repeated
name and lets the dealer continue.

This is the shape requirement 10 already established for `-` accounting, and it is applied here for
consistency rather than invented:

| Layer | Behaviour |
|---|---|
| Web | **Does not block.** The name is accepted and the step continues. |
| Preview | Lists it under *things the orchestrator will reject today*, naming which two names clash and why. |
| API | **Still rejects it**, with a field-named 400 — a known-bad body does not go upstream. |

**The wording matters more than the check.** The first version of this message read *"This collides
with 'care' — both slug to `care`"*, which explains a mechanism nobody asked about and never says
the plain thing. Two clashes, two sentences:

| What happened | What it says |
|---|---|
| Two organizations with the same name | *Another organization is already called "Care". Every organization in this request needs a different name, compared with spaces trimmed and capitals ignored.* |
| Different names, one internal name | *"Ca-re" and "Ca re" are stored under the same internal name, `ca-re`. Spacing and hyphens are dropped when it is made, so the two have to differ by more than those.* |

**The slug is named only when it is the reason** — the case the dealer cannot otherwise work out,
because the two names look different on screen. The same split applies to a clash with the client
name, whose organization is the default one.

**The real resolution is an orchestrator change request**, exactly as with `-` accounting: relaxing
the uniqueness rule is theirs to decide, not something the dealer platform can grant. Until then the
API's rule is the one line that moves. [Open question 10](#open-questions).

---

## Consequences worth a decision

These are not open questions — the decisions are made. They are recorded because each one loosens
something the code currently holds tight on purpose.

### D1 · The plan catalog is another team's data

`SuduPlanCatalogReader` reads `sudu_plan` from **SuDu ERP's su-code list pages**. Adding
`organizationLimit` and `waReadIncluded` is **a request to the ERP team, not a migration we can
run** — the same shape of dependency as the orchestrator's `NO` accounting change.

Until both columns exist, the web app falls back, in one named module with the removal condition in
its doc comment:

| Field | Fallback | Why that one |
|---|---|---|
| `organizationLimit: null` | **no cap** | A wrong cap blocks a legitimate dealer. The limit is not enforced anywhere downstream, so no cap is exactly today's behaviour — a regression to nothing, not to something wrong. |
| `waReadIncluded: null` | a plan-code map, `GO-STD` / `GO-PRO` / `GO-MAX` → true | Defaulting to `false` would offer a RM500 add-on that is already included, and **bill the customer twice.** An unknown plan code logs and defaults to `false`. |

The map is the one piece of this spec that goes stale silently, and it is the first thing deleted
when the column lands.

### D2 · Deriving `tenant_admin` changes behaviour, not just the UI

Today both halves are optional and blank means BladeX's defaults; the contract forwards
`tenant_admin` *"only if supplied."* Deriving them means **we always supply it**, so every tenant
created after this ships is on a SuDu-set credential. That is a change to what is provisioned, not
to what is asked.

### D3 · The initial password is predictable from a value the dealer types

`{account}@123!` is the orchestrator's own rule when `password_secret_ref` is omitted — this spec
does not invent it, it surfaces it. But surfacing it means anyone who knows the login account knows
the password. **The review screen showing it is a feature for the dealer and a risk if that screen
is ever shared.** No mitigation is in scope here; it is recorded so it is not discovered later.

### D4 · A derived total becomes a stored billing figure

`tenant-plan.controller.ts` refuses to compute a plan total on purpose:

> *"nothing in the ERP states that a plan's price is the sum of its parts. Presenting a derived
> figure as authoritative is how a wrong quote reaches a customer; the client shows the components
> and labels any total it derives."*

`total_price_per_month` is that derived figure, plus add-ons, written to a billing row. The
labelling that made it safe on a display screen does not travel with the number.

**Half of this is now fixed.** Moving the rates to the ERP ([C7](#c7--the-add-on-rate-card)) means
the add-on half is stated data the API can check. What remains is the plan's own price, still
`erp.monthlyFeeRm + aiCredit.monthlyPriceRm` and still nobody's stated total. **The remaining fix
is a `monthly_price_rm` on `sudu_plan` itself** — the same ERP request as
[D1](#d1--the-plan-catalog-is-another-teams-data), and worth adding to it while that conversation
is open.

### D5 · Pre-Live is a tenant the demo cap never sees

Every tenant this wizard provisions is a demo today, and `demo-count.service.ts` counts exactly
that status against the dealer's demo cap. Restricting the dealer to `Demo` and `Pre-Live`
([C5](#c5--the-dealer-creates-demo-or-pre-live-live-is-an-admin-transition)) keeps a dealer from
minting a paying customer — but it does **not** close the cap:

| Creatable type | Counts against the demo cap? |
|---|---|
| Demo | yes |
| Pre-Live | **no** — `readDemo` has never seen this value at all |

So the cap still has a way around it, and the way is one click on step 1. Whether **Pre-Live**
should count is a real product question, not a mapping detail: a pre-live tenant is using the
platform without paying for it, which is what the cap exists to bound. It is
[open question 4](#open-questions), and it matters more now than when `Live` was also on the menu —
**Pre-Live is the only escape left, which makes it the one people will find.**

### D6 · Three domain values, and only one of them is shown

The field is labelled **Workspace domain**, not *Subdomain*, and the form says what it is for: the
address the client uses to reach SuDu ERP. Three related values are in play and they are not
interchangeable:

| Value | Shape | Who sees it |
|---|---|---|
| What the wizard sends | `kenhin.mes.sudu.ai` — the bare host | the payload |
| What the API composes for `customer_domain` | `https://kenhin.mes.sudu.ai/login` (`loginUrlForHost`) | the orchestrator |
| What the dealer is shown | `https://kenhin.mes.sudu.ai` | the form |

**The `/login` path is not decoration.** BladeX matches `blade_tenant.domain_url` *whole*, and
sending a bare host once made every provisioned tenant unfindable by `TenantLookupService` — so the
register wizard offered subdomains that were already taken. The composed value keeps the path; the
displayed one drops it, because that is the address a dealer reads out.

Separately, `ProvisioningRequest.loginHost` is a **shared** SaaS host and carries a comment that
provisioned tenants have no per-tenant subdomain. **It must never be rendered as
`{slug}.mes.sudu.ai`.** Three values, three audiences; conflating any two of them has already
caused one outage-shaped bug.

### D7 · Renaming `Testing` to `Demo` turns the demo cap off

`demo-tenant.ts` names this exact failure in a comment, written before it happened:

> *"renaming the label in the SaaS dictionary changes the key, and this comparison would stop
> matching. It fails in the safe direction — an unrecognised status reads as UNKNOWABLE, so the cap
> stops enforcing rather than starting to refuse wrongly."*

`DEMO_STATUS = 'testing'` and `NON_DEMO_STATUSES = {'live', 'live suspended', 'testing suspended'}`
are string comparisons against the old dictionary. After the rename:

- **`Demo` matches nothing**, so every demo tenant reads as `null` — unknowable. The count returns
  `used: null`, the reassign guard lets moves through, and the UI shows "—". **The cap stops
  enforcing.** It fails safe, as designed, but it fails.
- **`Pre-Live` matches nothing either**, for the same reason, and needs a deliberate classification
  rather than falling into the unknowable bucket by accident.
- The two `… Suspended` entries become dead code once suspension is its own field.

**Both vocabularies will be live at once.** The comment records real counts from 2026-08-19 —
*dev: 16 Live, 2 Live Suspended, 1 Testing; prod: 27 Live* — so existing rows carry the old strings
while new ones carry the new. `readDemo` must recognise **both** for as long as any unmigrated row
exists, and the pair must be deleted together with the ERP's own migration, not before.

This is the one piece of work in this spec that touches a **security-adjacent control** and is
not part of the wizard at all. It belongs in the API plan, ordered **before** the wizard ships —
a cap that silently stops enforcing is worse than one that was never built.

### D8 · Suspend has no undo

The handoff's own scope section puts *"restore/unsuspend API"* first among the things it does not
include. There is **no endpoint that sets `is_suspended` back to `0`**, and no status-only update
API either. A dealer who suspends a tenant cannot reverse it from the dealer platform; someone
changes the row in SuDu ERP directly.

That is what makes the confirmation in [W7](#w7--the-suspend-action) a real gate rather than
ceremony, and it is why the copy says *cannot be undone from here* rather than the softer thing.

Two further limits worth stating before anyone reads more into the button than is there. Recycling
is *"a destructive soft-recycle, not a rollback"*: it does not undo provisioning, delete tenant-owned
data, or stop schedulers. And a **partial failure leaves a real intermediate state** — the BladeX
tenant retired, the billing row unflagged. The only exit is retrying that job. Creating a
replacement tenant in that state is called out in the handoff as the wrong move, so the UI must not
offer it as one.

---

## Out of scope

- **Schedulers.** Not required for ordinary onboarding.
- ~~**The elevated `ServiceIdentity` contract.**~~ **Now in scope.** `/recycle` requires
  `tenant:recycle` *"in both the signed JWT and the enabled ServiceIdentity allow-list"*, and
  *"`tenant:create` alone is not sufficient"* — so [C8](#c8--suspending-a-tenant-is-recycle) cannot
  ship without it. Deployment work, not code.
- **`step_overrides`.** Twenty-one recognized keys, none needed here.
- **Phone format validation.** Deferred with item 27.
- **Unsuspending.** There is no upstream API for it — [D8](#d8--suspend-has-no-undo). Nothing here
  builds a local workaround, and the UI must not imply one exists.
- **`WhatsApp Signature`, the fifth rate-card row.** Priced at RM50/month in the ERP with no
  customer field to record it against. [Open question 7](#open-questions).
- **Rewriting historical `… Suspended` statuses.** The handoff excludes *"automatic historical-status
  conversion"* and so does this. Old rows keep their strings and readers keep understanding them.
- **The `scope_key` drop.** `GET /v1/jobs/{job_id}?detail=true` returns per-organization step
  progress and our mapping discards `scope_key`, the step UUID, substeps and `runtime_context`. Real,
  recorded, and a change to the **provisioning status** surface rather than to creation. It becomes
  more valuable the moment this spec ships multi-organization tenants — but it is its own spec.
- **A cross-check between the plan's organization limit and the organizations actually configured,
  shown on the plan step.** The cap on step 3 covers the forward case; the review states the
  retroactive one. A warning on step 2 needs wizard-wide state and earns its own decision.

---

## Open questions

1. **Is `customer.wa_able_read` the same switch as the published WhatsApp AI Read add-on?** The
   prototype prices them as one thing — RM500/month, on the plans that do not include it. If the
   field is really a capability flag the ERP sets from the subscription rather than something a
   dealer buys at creation, [W2](#w2--add-ons-and-the-monthly-total) is wrong and the switch should
   be read-only.
2. **Does the ERP team accept `tenant_organization_limit` and `wa_read_included`?**
   [D1](#d1--the-plan-catalog-is-another-teams-data) is written as though yes. If not, the plan-code
   map stops being interim and needs an owner and a review cadence.
3. **Does Pre-Live take the plan step?** [W0](#w0--tenant-type-is-the-customer-status-and-it-decides-the-step-count)
   assumes yes, on the reasoning that a tenant about to go live has already been sold something and
   should not have to have its commercial values re-entered later. If Pre-Live is really a
   configuration state with no commercial commitment, it joins Demo on the three-step path and the
   `customer` block becomes conditional rather than required.
4. **Should Pre-Live count against the dealer's demo cap?** [D5](#d5--pre-live-is-a-tenant-the-demo-cap-never-sees)
   classifies it as not-a-demo, matching `Live`. But a pre-live tenant uses the platform without
   paying for it, which is the thing the cap exists to bound. This is the answer `readDemo` needs
   before [A7](#a7--teach-the-demo-reader-both-vocabularies) is written.
5. **When does the ERP's own `Testing` → `Demo` migration run, relative to this?**
   [D7](#d7--renaming-testing-to-demo-turns-the-demo-cap-off) assumes an overlap window and makes
   the reader accept both. If the rename is instantaneous and complete, the dual reading is
   unnecessary — but writing it costs one `Set` and removes a whole class of timing risk.
6. ~~**Should the API recompute the total once the rates are known to it?**~~ **Answered by
   [C7](#c7--the-add-on-rate-card).** It now checks the add-on half. The plan half needs a stated
   price on `sudu_plan` — folded into [D1](#d1--the-plan-catalog-is-another-teams-data)'s ERP request.
7. **What is `WhatsApp Signature` for?** It is on the rate card at RM50/month and **no customer
   field records it**, so the wizard cannot sell it. Either a field is missing from the five, or it
   is bought outside tenant creation. Until that is answered the wizard ignores the row and the API
   still returns it.
8. **Who can suspend, and from where?** [C8](#c8--suspending-a-tenant-is-recycle) assumes any dealer
   who owns the tenant, gated by `resolveActScope`. Given [D8](#d8--suspend-has-no-undo) — no
   undo, anywhere — a vendor-admin-only control is a defensible alternative, and it is cheaper to
   decide now than to take the button away later.
9. **Should the orchestrator relax organization-name uniqueness?**
   [V5](#v5--repeated-organization-names-are-allowed-through-and-reported) lets the dealer enter a
   repeated name because that was asked for, but the contract rejects it and the API still refuses
   to forward it — so today the choice only moves *where* the dealer learns it failed. **This needs
   the same kind of handoff `-` accounting got**, or the wizard is accepting input it can never
   submit. Note the planner's own limitation is separate: duplicate *slugs* are documented as
   something it mishandles, not merely something the validator rejects.
10. **Is `Pre-Live` an accepted value downstream?** The orchestrator now takes any non-empty string,
   but *"su-code may still enforce its own allowed values"*, and `Pre-Live` has never been sent.
   **This needs one live check before the wizard offers it**, not after.

---

## References

- [`docs/task-backlog.md`](../task-backlog.md) — item 1, requirements 1–68, and what each one cost
- [Orchestrator field reference](../../../sudu-contracts/contracts/orchestrator/dealer-handoff-2026-09-08/tenant-orchestrator-field-reference-2026-09-07.md) — sections 2–3 are the authority for every rule above
- [`docs/glossary.md`](../glossary.md) — planes, `tenantId`, `roleKind`
- `sudu-dealer-api/src/tenant-provisioning/tenant-plan.controller.ts` — the catalog view, and D4's warning
- `sudu-dealer-api/src/saas-pricing/sudu-plan-catalog.reader.ts` — where the catalog actually comes from
- `sudu-dealer-api/src/tenant-orchestrator/orchestrator.client.ts` — the mapping this spec extends
- `sudu-dealer-web/src/components/tenants/create-tenant/` — the wizard as it stands
