# The admin tenants list shows a tenant's plan — cross-repo design

**Status:** draft
**Repos:** `sudu-dealer-api` · `sudu-dealer-web`
**Branches:** `feat/ui-ux-enhancement` — already cut on `sudu-dealer-web` off `origin/main`; the same name goes on `sudu-dealer-api` when implementation starts
**Plans:** api → `sudu-dealer-api/docs/superpowers/plans/…` · web → `sudu-dealer-web/docs/superpowers/plans/…` (neither written yet)

## Problem

The admin tenants list has no plan column. `GET /admin/tenants` returns
`plan: { id, label }` — the SaaS registry's `plan_package` — and the web uses it for the
Plan **filter** only. An admin can narrow the list by plan but cannot see, for any row,
what that tenant is actually entitled to.

The entitlement is not one value. A `sudu_plan` row joins three component plans, and
`GET /tenant-plans` already returns all three to the provisioning wizard:

| Component | Carries |
|---|---|
| `erp` | plan code, name, monthly fee (RM) |
| `aiCredit` | name, monthly credits, monthly price (RM) — nullable |
| `aiService` | name, WhatsApp connection limit, accounting integration — nullable |

None of it reaches the admin list. The wizard shows it once, at the moment a dealer picks
a plan ([`PlanMatrix.tsx`](../../sudu-dealer-web/src/components/tenants/create-tenant/PlanMatrix.tsx)),
and it is never shown again — not in the list, not on the admin tenant detail, which
mentions no plan at all.

This is a read-only display change. No schema, no writes, no new permission.

## The two things called "plan"

The code already warns about this collision
([`dealer-api.ts`](../../sudu-dealer-web/src/services/dealer-api.ts), above
`ProvisioningPlan`), and this feature puts both on one screen, so it has to be settled
here rather than discovered later.

| | `TenantPlan` (today's filter) | `ProvisioningPlan` (this feature) |
|---|---|---|
| Source | SaaS registry `plan_package`, read live per request | `sudu_plan` catalog joined to its component tables |
| Reached via | already on every `AdminTenant` | our own `TenantProvisioningRequest.planId` |
| Shape | `{ id, label }` | `planName` + `erp` + `aiCredit` + `aiService` |
| Truth | current | **what was requested at provisioning** |
| Coverage | every tenant | platform-provisioned tenants only |

They are not the same fact and must not be presented as one. The filter keeps matching
the SaaS package; the new columns show the components. See Q5 on the label collision.

## Decisions

| | Question | Decision |
|---|---|---|
| **Q1** | How is a tenant's three-part plan resolved? | **Through our own provisioning record only** — `TenantProvisioningRequest.tenantId` → `planId` → catalog. Never inferred from the package |
| **Q2** | What do tenants we did not provision show? | **`Not provisioned here`**, explicitly — not a blank, and never a guess |
| **Q3** | Where does each component go? | **AI credit plan into the existing AI Credits column**; **ERP + AI service into one new column**. No third column |
| **Q4** | Is a total price shown in the list? | **No.** Not in any form |
| **Q5** | Does the existing Plan filter change? | **Relabelled `Package`, behaviour untouched** |
| **Q6** | What happens when the plan catalog is unreadable? | **The list still returns**, with every plan null |
| **Q7** | Does the dealer tenants view change? | **Yes — revised 2026-08-26.** Both planes carry it |

### Q7 — revised: both planes, not admin only

This spec was written admin-only. That was wrong for a reason worth recording: the person
asking for the feature is a **dealer** admin (`plane: 'dealer'`, `roleKind: 'ADMIN'`), and
`isPlatformAdmin` gates the admin console on `plane === 'platform'` — so the whole feature
would have landed on a screen they cannot open, and could only have been verified by
borrowing a platform login.

`DealerTenant` therefore carries `provisionedPlan` too, with two differences from the admin
plane, both following from whose record it is:

- **Scoped to the caller's organization.** A tenant this org claimed rather than created
  carries someone else's provisioning record; reporting it would leak another dealer's
  commercial choice. The admin console stays unscoped, which is its purpose.
- **Not withheld for a non-ACTIVE claim**, unlike `plan`/`domain`/`saasStatus`. Those are
  withheld because they are SaaS data an unverified claim has no right to. This is the
  dealer's own record of what they asked for, and a PENDING row showing it tells them
  nothing they did not already know.

A draft row shows a dash rather than `Not provisioned here`: a draft may carry a `planId`,
but it is uncommitted until submitted — the same reason drafts drop out of the plan filter —
and it has not been provisioned at all, so the "not here" wording would be a different and
wrong claim.

### Q1 — resolved from the provisioning record, never from the package

`TenantProvisioningRequest` stores `planId` (`sudu_plan.id`) and is stamped with
`tenantId` on first sight of the job. That join is exact: it says which catalog plan this
tenant was created against, because it is the value we ourselves sent upstream.

The tempting alternative is a reverse lookup. The orchestrator assigns a tenant's package
from its plan's `tenant_package_id`
([`tenant-core.steps.ts`](../../sudu-tenant-orchestrator/src/provisioning/steps/tenant-core/tenant-core.steps.ts)),
so `AdminTenant.plan.id` should equal that value, and matching it back against the catalog
would cover far more rows — including tenants created outside this platform — and would be
live rather than historical.

**It is rejected.** The mapping is many-to-one: several `sudu_plan` rows may carry the same
`tenant_package_id`, and the orchestrator's own tests exercise plans pointing at shared
profile packages. A package therefore does not identify a plan, and a reverse lookup would
sometimes name the wrong one. Naming the wrong plan on an admin console is how a wrong
figure reaches a customer — the same failure the API already refuses to risk where it
declines to sum a plan's component prices
([`tenant-plan.controller.ts`](../../sudu-dealer-api/src/tenant-provisioning/tenant-plan.controller.ts)).

The cost is coverage. Measured against the development database: 14 provisioning requests,
11 carrying a `tenantId`, 13 carrying a `planId`, **10 with both**. The admin list holds 30
tenants. Two thirds of rows will show nothing.

`planId` is also nullable for rows written before 2026-08-20, when the orchestrator began
requiring it. Those rows resolve to null like any other miss.

### Q2 — the gap is stated, not blank

A row with no provisioning record reads `Not provisioned here`, in muted text.

This is not an apology for missing data. It is the answer to a question an admin actually
has: *did this tenant come through our platform, or was it created directly in SaaS?* On a
list that is 26/30 unclaimed, that distinction carries more information than the plan name
would.

### Q3 — where each component goes

Three separate columns were considered and rejected: the table would reach eight columns
and scroll horizontally to display dashes on most rows. Stacking all three under one column
was also rejected — it grows the row to roughly 76px for the third of rows that have data,
leaving the rest visibly ragged.

Instead each component sits with the data it governs, and the row height is unchanged:

```
TENANT        DEALER        STATUS   AI CREDITS          ERP & SERVICES    CREATED    ACTIONS
kaile         Lee Dong Hao  Testing  95,079 / 95,079     Basic ERP         Aug 25
              ACTIVE                 ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓     Basic services
                                     Basic
Nibou         SuDu AI       Live     0                   Not provisioned   Aug 18     [Claim]
              UNCLAIMED                                  here
```

**AI Credits** gains a third line: the AI credit plan's `name`, muted, below the bar.

The plan's `monthlyCredits` is deliberately **not** shown there. The column's existing
numbers are live SaaS values (`monthlyRemain / monthlyMax`); the plan's monthly allowance is
a catalog value that may legitimately differ after a flex top-up or an override. Two similar
numbers stacked in one cell, meaning different things, is a misreading waiting to happen.
The name identifies the plan; the numbers stay live.

**ERP & services** is one new column: ERP plan `name` on the first line, AI service plan
`name` muted beneath it. A plan with no `aiService` shows the ERP line alone.

Component detail — `whatsappLimit`, `accIntegration`, `monthlyFeeRm`, `monthlyPriceRm`,
`userLimit` — stays out of the list. It belongs on the admin tenant detail page, which shows
no plan today; that is follow-on work and is **not** in this spec.

### Q4 — no total, in any form

`erp.monthlyFeeRm + aiCredit.monthlyPriceRm` is not stated by the ERP to be a plan's price.
The API says so where it refuses to compute one, and `PlanMatrix` labels the figure it
derives as derived. A list column has no room for that caveat, so it shows no total at all.

### Q5 — the filter is relabelled, not rewired

The existing filter matches the SaaS package. Leaving it labelled `Plan` next to a column
showing ERP and AI service plans invites an admin to expect the two to correspond. They do
not — one is the current package, the other is the plan requested at provisioning.

The filter is relabelled **`Package`**. Its `plan` URL parameter, its option values and its
behaviour are all unchanged; only the visible label and its `aria-label` move. Nothing
deep-links `?plan=` on this route.

Filtering by ERP / AI credit / AI service plan is **not** in scope. With two thirds of rows
resolving to null, such a filter would mostly hide rows for a reason the user cannot see.
Revisit when coverage justifies it.

### Q6 — an unreadable catalog does not break the list

`SuduPlanCatalogReader.read()` performs no caching, so this join adds one ERP round-trip per
admin list request. When that read fails, `GET /tenant-plans` answers `503` — correct for a
screen whose whole purpose is picking a plan.

`GET /admin/tenants` must not adopt that behaviour. The plan is an enrichment; credits,
status, domain and dealer attribution are the screen's job. A catalog failure is logged and
every tenant resolves to `provisionedPlan: null`, rendering exactly like a tenant we did not
provision.

This means a catalog outage is indistinguishable in the UI from a genuine absence. That is
accepted: both are "we cannot tell you this tenant's plan", and the alternative is a blank
tenants console.

## The contract

`AdminTenant` gains one nullable field. Nothing existing changes shape.

```ts
/**
 * The catalog plan this tenant was PROVISIONED against — a historical record of what we
 * requested, not a live reading of what SaaS currently applies. `null` when no provisioning
 * request links to this tenant (created outside this platform, or written before `planId`
 * became required), and also when the plan catalog could not be read at all.
 *
 * NOT to be confused with `plan` above, which is the live SaaS package.
 */
provisionedPlan: null | {
  planId: string
  planCode: string
  planName: string
  erp: { name: string }
  aiCredit: { name: string } | null
  aiService: { name: string } | null
}
```

Names only. `monthlyCredits`, `monthlyPriceRm`, `monthlyFeeRm`, `whatsappLimit`,
`accIntegration` and `userLimit` are all deliberately absent — nothing in this spec renders
them, and the detail page that would is separate work. Adding a field later is a smaller
change than removing one that shipped.

`planId` and `planCode` are strings and are never parsed: `planId` is a 19-digit su-code
snowflake that loses its low digits through `Number`.

## Testing

**API** — a tenant with a provisioning request and a matching catalog plan resolves it; one
with a request whose `planId` is null resolves to null; one with no request at all resolves
to null; a catalog read that throws yields a full list with every `provisionedPlan` null and
does not propagate a `503`; the join survives a plan id present in a request but absent from
the catalog.

**Web** — the AI Credits column shows the credit plan name and still shows live remain/max;
a tenant with no `provisionedPlan` reads `Not provisioned here`; a plan with a null
`aiService` shows the ERP line alone; the filter is labelled `Package` while its `plan`
param and option values are unchanged.

The web repo's real type gate is `npm run build`; `tsc --noEmit` exits 0 having checked
nothing.

## Open questions

1. **Does the admin tenant detail page get the full component breakdown?** It shows no plan
   at all today. Assumed yes, as follow-on work — which is when the trimmed contract above
   would grow the money and limit fields.
2. **Should the API branch be `feat/ui-ux-enhancement`?** The web half already sits there,
   and matching names is the workspace rule, but that name describes a broader body of work
   than this feature.
3. **Should the catalog read be cached?** Not required here — one extra ERP call per admin
   list load is tolerable — but it becomes worth revisiting if the detail page adds a second
   caller.
