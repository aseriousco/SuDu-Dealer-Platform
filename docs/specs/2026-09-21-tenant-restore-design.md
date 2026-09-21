# Undoing a suspension: tenant restore

**Date:** 2026-09-21 · **Status:** design, approved in session · **Backlog:** item 38

**Parents.** Upstream's `POST /v1/tenants/{bladex_tenant_id}/restore`, which has **no handoff
document** — see [`docs/orchestrator/README.md`](../orchestrator/README.md), "The restore API has
no handoff document". Our outbound asks about it are question 9 in
[`handoff-dealer-api-orchestrator-env-contract.md`](../orchestrator/handoff-dealer-api-orchestrator-env-contract.md).

**Plans.** [`sudu-dealer-api`](../../sudu-dealer-api/docs/superpowers/plans/2026-09-21-tenant-restore-api.md)
· [`sudu-dealer-web`](../../sudu-dealer-web/docs/superpowers/plans/2026-09-21-tenant-restore-web.md).
Both resolve only from the `feat/tenant-restore` branch.

---

## 1. Why

A dealer can suspend a tenant and cannot undo it. `TenantSuspendController`'s own docblock says so:

> ONE WAY. There is no unsuspend API anywhere upstream (spec D8), so there is no inverse route
> here and nothing on the response hints at one. Reversing a suspension means someone editing the
> row in SuDu ERP directly.

That was true when it was written. On **2026-09-17** the orchestrator team merged `150e101`,
"feat(unsuspended): add api for reverse suspended customers", and it stopped being true. A dealer
who suspends the wrong tenant — a six-digit id, one mistyped digit — currently needs a human at
SuDu to edit a billing row. This closes that.

## 2. What upstream actually promises

**Read from their source on 2026-09-21, not from a contract.** Both documents they sent us on
2026-09-07 predate the route and state that it does not exist. Everything in this section is
therefore **provisional** and is exactly what question 9 asks them to confirm.

| | |
|---|---|
| Route | `POST /v1/tenants/{bladex_tenant_id}/restore` |
| Scope | **`tenant:restore`** — deliberately not `tenant:recycle` |
| Body | optional `expected_tenant_name` plus the common job fields; `.strict()`, so `customer_status` and `is_suspended` are 400s |
| Headers | `Idempotency-Key`, as every job-creating route |
| Effect | the tenant leaves BladeX's recycle bin; `sudu_customer.is_suspended` → numeric `0`; `customer_status` untouched |
| Job / step | `RESTORE_TENANT` / `restore_tenant`, phase `tenant_lifecycle`; **not** in `REPAIRABLE_STEP_IDS`, matching `recycle_tenant` |

**Why the scope is split, in their words:** "the two are opposite powers, and a caller trusted to
delete is not automatically one trusted to bring a deleted tenant and its billing back to life."

**The mechanism matters because it produces two of our failure cases.** BladeX has no un-recycle
endpoint. Restore submits `status: 1` through the same `/tenant/submit` save-or-update the domain
and details steps use, addressed by the surrogate `blade_tenant.id` resolved by lookup. A submit
with no `id` would **insert a new tenant**, which is why a row without one fails closed as
`bladex_tenant_row_id_missing` rather than proceeding.

**Failure codes.** `bladex_tenant_not_found`, `bladex_tenant_row_id_missing`, `tenant_not_restored`,
`tenant_submit_clobbered_row`, `tenant_permanently_deleted`, `tenant_name_mismatch`,
`sudu_customer_suspension_not_cleared`. Customer-block outcomes: `reinstated`, `already_active`,
`no_billing_customer`.

**Two behaviours that are successes, not errors.** Only the recycle bin is reversible: a
permanently deleted tenant (`is_deleted = 1`) is refused as `tenant_permanently_deleted` with
nothing written. An already-active tenant whose billing is still suspended reconciles the billing
half alone rather than erroring — which is also how a restore that failed after the tenant was
already back is retried.

**Blocked until they act.** `tenant:restore` is not granted on our registered `ServiceIdentity`,
so a real call 403s today; their `20260917120000_add_restore_tenant_job_type` migration must be
applied on the environment we call. Neither is a code change on our side. **This design can be
built and unit-tested in full without either** — what it cannot do is run end-to-end.

## 3. Requirements

Numbered so the two plans can cite them.

**Permission**

- **R1** `restore` is a new action on `tenant` in `permissions.ts`'s `statement`, mirroring
  upstream's split. It is **not** a corner of `suspend` — the power to bring a retired tenant and
  its billing back is not implied by the power to retire one.
- **R2** **There is no grant migration, and that is the decision, not an omission.** The
  2026-09-15 `suspend` migration granted `suspend` to every role holding `create` because
  suspending *had been* gated on `create`: it preserved access that already existed. `restore` has
  no predecessor — nobody could restore anything yesterday — so the same migration would not
  preserve access, it would **widen** it, silently, on every custom role in the database. An
  unwanted restore brings a deliberately retired tenant back and starts billing it again, which is
  why upstream split the scope and called recycle "the only destructive scope — grant it
  narrowly". `restore` is therefore granted by an admin, deliberately, in the permission manager.
  ADMIN roles get it for free: their stored permission is ignored and `effectiveGrant` reads the
  plane's ceiling, which is derived from `statement`.
  **Consequence to state in the release note:** a dealer holding `suspend` cannot undo their own
  suspension until an admin grants them `restore`. That is one toggle, and it is the safe
  direction to fail.
- **R3** `restore` reaches the **dealer** plane, and that is deliberate. `dealerCeiling` spreads
  `platformCeiling` and overrides only `organization`, so every `tenant` action already reaches
  dealers, `suspend` included. A dealer undoing their own mistyped suspend is the motivating case
  for this whole item, so the cap that `permissions.ts` warns about — "a forgotten dealer cap is a
  privilege hole" — is considered here and deliberately not applied. Say so in the code, or the
  next reader will assume it was forgotten.
- **R4** `tenant:view_all` is not sufficient, for the reason `suspend` records: the widest READ
  grant is not permission to change a tenant's lifecycle.

**Authorization and ownership**

- **R5** Ownership is the live **ACTIVE** `DealerClient` claim, resolved server-side through the
  same `resolveActScope` path `suspend()` uses. Not the provisioning row. Not a check in the
  browser.
- **R6** A tenant the actor does not own is **404**, never 403 — a distinguishable status would
  confirm the tenant belongs to somebody.

**When restore is allowed**

- **R7** Restore requires an existing `TenantSuspension` row whose `suspensionOutcome()` is
  `SUSPENDED`. Everything else is a **409** with a sentence saying which case it is:
  no row ("This tenant is not suspended"), `PENDING` ("still being suspended — wait for it to
  finish"), `NOT_SUSPENDED` (the recycle failed and left the tenant alive; there is nothing to
  restore, and the reason already on screen is the reason).
- **R8** A restore already in flight is a **409**, not a second job.

**The row — ruling 1**

- **R9** A **successful** restore **deletes** the `TenantSuspension` row.
- **R10** While a restore is in flight the row **stays**, carrying its own idempotency key and job
  id in new nullable columns. The badge keeps reading Suspended, which is true: the tenant is in
  the bin until the job succeeds.
- **R11** A **failed** restore keeps the row and records the failure, so the dealer is told why and
  a repeat replays the same key rather than minting a second job.
- **R12** `sudu_customer_suspension_not_cleared` **counts as a successful restore** and deletes the
  row. The tenant is out of the bin and can log in; only upstream's billing flag lagged. This is
  the exact mirror of `RECYCLED_DESPITE_FAILURE` in
  [`suspension-outcome.ts`](../../sudu-dealer-api/src/tenant-provisioning/suspension-outcome.ts),
  and deciding it the other way would leave a destructive badge on a working tenant — the bug
  api#61 has just finished removing.
- **R13** Because R12 deletes the row, the restore job id must survive it: it goes in the audit
  metadata and in an `error`-level log line naming the tenant and the job, because finishing the
  billing half is a retry of **that job id** upstream and nothing else records it.

**The wire**

- **R14** `restoreTenant()` sends `profile_key` when configured, by the same conditional spread
  `recycleTenant()` uses. This is not optional politeness: the orchestrator resolves
  `profile_key ?? 'dev_default'`, and omitting it is what made a PROD recycle run against the DEV
  profile — accepted, then failed in the background (api#60).
- **R15** `expected_tenant_name` is read from the stored row, never from the caller and never
  recomputed. It was chosen once, alongside the suspend key, for reasons `chooseExpectedTenantName`
  documents at length.
- **R16** `rejectionIsRefusal: true`, as recycle sets it: a 400/409 on this call is
  refused-before-write, so the caller settles rather than polls a job that does not exist.
- **R17** On an `OrchestratorRefusedError`, the restore columns are cleared (key and job id back to
  null) so a corrected attempt can mint a fresh key. The **suspension row itself is not deleted** —
  the tenant is still suspended, and that fact is not in doubt.

**Polling**

- **R18** `advanceRestore()` mirrors `advanceSuspension()`: it settles a restore job's outcome from
  `GET /v1/jobs/:id` and **never retries**. It is called from the same two places
  `advanceSuspension` is — the org sweep that keeps a list current, and the per-tenant read the
  dialog polls.
- **R19** Nothing is ever retried automatically. Their codes distinguish opposite situations and a
  blind retry can make one of them worse.

**Web**

- **R20** Restore is offered on the tenant detail surface, beside Suspend, mounted from
  [`DealerTenantDetail.tsx`](../../sudu-dealer-web/src/components/tenants/DealerTenantDetail.tsx) —
  the same place `SuspendTenantDialog` is mounted. **Not** on the list row.
- **R21** `showRestore = active && canRestore && suspended && !restoring`, with
  `canRestore = isPlatform(me) || can(me, 'tenant', 'restore')` — a UX affordance mirroring the
  API's gate, never a substitute for it.
- **R22** The restore dialog **does not** make the dealer type the tenant name. Typing the name is
  the guard on an irreversible destroy; restore is the reversal, and a confirmation ceremony
  borrowed from the destructive direction reads as a warning that does not apply. A plain confirm
  naming the tenant is the whole dialog.
- **R23** A failed restore gets the same treatment `suspendFailed` gets today: a sentence on the
  page saying it did not take, and why, rather than a button that silently does nothing.
- **R24** The `Suspended` badge is driven by `suspensionOutcome` and nothing else — it already is,
  and R9 means it disappears on its own when the row goes.

## 4. What this deliberately does not do

**It does not unblock a failed recycle.** `showSuspend` excludes `suspendFailed`, and its comment
is right about why: "the API replays the stored idempotency key, so a second press recovers the
SAME failed job rather than starting a new recycle." Restore does not change that — a failed
recycle left the tenant **alive**, so there is nothing to restore, and R7 refuses it. Overloading
Restore into "clear the stuck row so I can suspend again" would send a pointless upstream call to
achieve a local delete, and would put a button labelled Restore on a tenant that was never
suspended. **If clearing a stuck suspension is wanted, it is its own item** with its own name.

**It does not add a restore path for platform admins beyond `isPlatform(me)`**, which R21 already
gives. No new admin screen.

**It does not do bulk.** One tenant, one job.

**It does not touch `customer_status`.** Upstream does not, and historical `live suspended` /
`testing suspended` strings stay forever by their own contract.

## 5. Questions this does not answer

1. **Does a restored tenant count against the demo cap again?**
   [`demo-tenant.ts`](../../sudu-dealer-api/src/dealer-client/demo-tenant.ts) decides the cap from
   customer status, and its comment records that suspension moved to `sudu_customer.is_suspended`
   while the historical status strings remain. A restored tenant should count again.
   **This is an upstream behaviour question, not one either plan can settle** — nothing we write
   changes what `customer_status` reads after their restore, and deleting our own suspension row
   does not feed the cap. Check it the first time a restore runs end-to-end, which cannot happen
   before the scope grant. If the cap does not recover, it is a defect this item found, not a
   feature it owes.
2. **Is a failed restore retried by job id or by a fresh request?** Their README tells us to retry
   the same failed job for a recycle's billing failure, and `restore_tenant` is not repairable —
   same as `recycle_tenant`. Asked as part of question 9. Until answered, R11's "repeat replays the
   same key" is the conservative reading and is safe either way.
3. **Does the deployed dev orchestrator have the route?** Their `main` does. The deployed dev
   environment has not reliably matched their `main`, which is a known hazard on this integration.

## 6. Surfaces

**API.** `tenant-suspend.controller.ts` (**renamed** — see below), `tenant-provisioning.service.ts`
(`restore`, `advanceRestore`, and the existing suspend poll's call sites),
`orchestrator.client.ts` (`restoreTenant`, modelled line for line on `recycleTenant`),
`suspension-outcome.ts` (the restore-side code sets), `permissions.ts`, `prisma/schema.prisma`
(`TenantSuspension`), and the org sweep in `tenants.service.ts`.

**The controller is renamed to `TenantLifecycleController`**, file
`tenant-lifecycle.controller.ts`. Its existing docblock argues for a second controller on the
`tenants` base path on the grounds that it owns the destructive, audited, orchestrator-calling
writes over `TenantSuspension` — an argument that covers restore exactly. What does not survive is
the name and the "ONE WAY" paragraph. A `TenantSuspendController.restore()` is a small lie in a
file whose comments are otherwise load-bearing.

**Web.** `DealerTenantDetail.tsx`, a new `RestoreTenantDialog.tsx` beside
`SuspendTenantDialog.tsx`, `dealer-api.ts` (`restoreTenant`, `RestoreReceipt`, and the
`suspensionOutcome` types already there), and `tenant-row-view.ts` only if the list needs to know
— it should not, per R20.

**The FE↔BE surface belongs in [`docs/contracts/`](../contracts/).** Note that
`docs/contracts/tenants.md` does **not** resolve from `main` today: it is stranded on the unpushed
root branch `feat/create-tenant-validation`. Land that branch before adding to it, or the addition
compounds the problem.

## 7. Testing

**API.** The two rulings are the two tests that matter, and neither is about a happy path:

1. **Suspend → restore → suspend again mints a NEW idempotency key.** This is the whole reason R9
   exists. Without it the second suspend replays the first recycle's key, the orchestrator returns
   the original `SUCCEEDED` job, the badge lights up, and the tenant is never recycled. Assert the
   key differs, and assert `recycleTenant` was called a second time.
2. **`sudu_customer_suspension_not_cleared` deletes the row** (R12) and **logs the job id** (R13).
   Its neighbour `tenant_not_restored` must keep the row.

Plus: each 409 branch of R7 by name; the 404 of R6; the refusal path of R17 clearing the columns
without deleting the row; and `profile_key` present on the wire (R14) — that one is a one-line
assertion guarding a production incident that already happened once.

**Web.** `showRestore` across the four outcome states; the dialog confirming without a typed name
(R22); the failed-restore sentence (R23); and the badge disappearing when the API stops sending an
outcome (R24).

## 8. Order

The API half ships first and alone. The web half is unusable without it, and the API half is
independently testable and independently correct — a restore route with no button is a supported
state, a button with no route is not.

Within the API half, the schema and the permission come before the route: R9–R11 change the table
the route writes to, and R1–R3 decide whether the route is reachable at all.
