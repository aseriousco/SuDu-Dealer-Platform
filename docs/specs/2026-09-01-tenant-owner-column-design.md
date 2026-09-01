# The dealer tenant list, redesigned

**Item 16.** Cross-repo — [`sudu-dealer-api`](../../sudu-dealer-api) and
[`sudu-dealer-web`](../../sudu-dealer-web). Written 2026-09-01, **rewritten the same day** when the
user supplied a full-page mockup and chose to make item 16 that redesign rather than the single
column it started as.

Mockup: [`docs/design/2026-09-01-tenant-list-redesign.html`](../design/2026-09-01-tenant-list-redesign.html)
(committed verbatim, `1299745`).

Branches: `feat/tenant-owner-column` in both repos.

## How this item changed

It began as *"remove the dealer column, add the created user and role"* — one cell on
`DealerTenantsTable`. The mockup redesigns the whole page and **contains no owner, agent or role
anywhere**. Two decisions settled that on 2026-09-01, both the user's:

1. **The Owner column stays**, as its own column, added back into the redesign.
2. **Item 16 becomes the redesign.**

Everything the original spec decided about *what the Owner column contains* survives unchanged, in
[D1](#d1--the-owner-column-stays-and-names-a-person). The rest is new.

## What already exists — read this before estimating

The mockup looks like a rewrite. Most of its furniture is already on the page:

| Mockup element | Status today |
|---|---|
| Pagination, rows-per-page | **Exists** — `Pagination` + `usePagedRows`, already wired in `DealerTenantsView` |
| Filter bar | **Exists** — `FilterBar`, `FilterSelect`, `FilterDateRange`, `FilterSearch` |
| Status / plan / claim-state / date filters | **Exist** — `FILTER_DEFS` covers `status`, `claim`, `plan`, `from`, `to`, `q` |
| Counts on filter options | **Exists** — `withCounts` |
| "3 demo slots remaining" | **Exists** — `DemoSlots`, already rendered at `DealerTenantsView.tsx:250` |
| Empty state | **Exists** |
| Plan name, ERP / AI service names | **Exist** on the row — `ProvisionedPlan.planName`, `.erp.name`, `.aiCredit.name`, `.aiService.name` |
| Credit figures | **Exist** — `TenantCredits` |

Genuinely new: the stat cards, the services filter, active-filter chips, the row action menu, the
credit progress bar, seat counts, avatar initials — and the Owner column.

## Decisions

### D1 — The Owner column stays, and names a person

Its own column, as the user chose. Two lines: the owner's display name, then their role.

```
  Acme Dealer          →     Dana Agent
  Dana Agent                 Manager
```

Everything below is unchanged from this spec's first version and was verified then:

- **It shows the CURRENT OWNER and must not be labelled "created by".** `DealerClient` has no
  `createdBy` column, and `reassign` re-stamps `ownerMemberNodeId` into the target org — so after a
  cross-org reassign the creator is a person at *another dealer*, and showing them would leak a name
  across organizations. Inside an org the two are the same person: ownership still is not reassignable
  there (the closed item 11).
- **The absence is specific, not house style.** `TenantDraft`, `DealerTier`, `CreditPricing` and
  `OrganizationRole` all record `createdByUserId`. A draft knows who created it; the claim it becomes
  does not.
- **The role resolves through `member.roleId`, never `member.role`** — that column is a mirror kept
  for better-auth, and reading it would show a stale name here after a rename and nowhere else.
- **`Member.roleId` is `String?`.** Name and role degrade to `—` independently; they are different
  facts.
- **No permission of its own.** `tenant:view` decides whether the list is visible, `tenant:view_all`
  decides which rows. A third gate on a column inside a row you may already read could only produce
  rows attributed to nobody. This is also what makes 17a legible: once `view_all` shows a Manager
  tenants they do not own, the owner column is the only thing distinguishing the rows.
- **`ownerOrgName` stays on the wire.** It leaves this table's cell only; `DealerTenantDetail.tsx:94`
  and `TopUpTenantStep.tsx:132` still read it.
- **API:** `DealerTenant.agentRoleName: string | null`, resolved by turning `resolveAgentNames` into
  `resolveOwners` returning `{ name, roleName }` — one more select on a `member` row it already reads.

### D2 — "Last activity" is cut from this pass

**There is no data behind it.** No `lastActivity`, `lastLogin` or event log exists in either repo, and
the SaaS registry projection (`TENANT_REGISTRY_FIELDS`) carries `create_time` and nothing else
temporal. "18 min ago · Portal login" is a per-tenant activity feed — event capture, storage and
retention — which is a feature, not a column.

Shipping it would mean inventing the data. Shipping the page without it costs one column.

**So the column is not built, and the item that would build it is a separate one.** What it would
need, recorded so the next person does not re-derive it: either an event log we write on our side
(portal logins, reloads, provisioning transitions — all things we already observe) or a confirmed
upstream field, which would need a probe against the live registry since the projection is explicit
and the full row is not documented here.

If the column is wanted before that item lands, say so and it becomes a blocking dependency rather
than a deferral — but nothing about the rest of this page depends on it.

### D3 — "Plan & services" ships without seat counts

The badges — plan name, then ERP / AI service names — come straight off `provisionedPlan`, which the
row already carries.

The second line (`12 ERP users · 4 AI users · 2 WhatsApp`) does not. The API's plan catalog holds
`userLimit`, `whatsappLimit` and `accIntegration`, but `ProvisionedPlan` on the wire is narrowed to
names only. So seat counts are an API field addition.

**They are in scope**, because unlike D2 the data exists — this is projection, not invention. But
note what they are: the plan's **limits**, not live seat usage. The mockup's wording reads as
allowances and must not be relabelled as usage without a source for it.

**MES and WMS badges are not in scope.** `packageType: 'WMS'` exists upstream in provisioning, but
`ProvisionedPlan` models exactly three service slots (erp, aiCredit, aiService) and nothing on the
dealer row distinguishes an MES or WMS package. Adding them is a row-shape change nobody has
specified; the mockup shows them because it is a mockup.

### D4 — The stat cards derive from the list, with no new endpoint

Total tenants, Live, Testing, Need attention, AI credits used are all computable from the rows the
page already fetches. No API call is added, and the numbers cannot disagree with the table beneath
them — which they would if a separate aggregate endpoint were introduced.

Two definitions must be pinned rather than inferred from the mockup:

- **"Need attention"** = claim not `ACTIVE`, **or** provisioning incomplete, **or** monthly credit at
  or above 90% of its maximum. Any other definition is fine but must be written down; a card whose
  meaning nobody can state is worse than no card.
- **"AI credits used"** sums `monthlyMax - monthlyRemain` over `monthlyMax`, across rows whose
  `erpUnavailable` is false. Rows whose registry read failed are **excluded from both sides**, never
  counted as zero — counting a failed read as zero usage understates the figure and is exactly the
  trap `erpUnavailable` exists to prevent.

The cards render from the **unfiltered** list, like `tenantStatusOptions` already does, so narrowing
a filter never changes what the summary claims about the account.

### D5 — The services filter joins the four that exist

New, and derived the same way `planOptions` already is: from the values actually present on the
loaded rows, never a hardcoded list. It filters on the service names in `provisionedPlan`.

Follow the existing `FILTER_DEFS` shape so it is URL-synced and shareable like the others, and so a
stale link with an unknown service degrades to unfiltered rather than to an empty table — the rule
`effectiveStatus` already implements for statuses.

### D6 — Active-filter chips live in `FilterBar`, which is shared

The chips and **Clear all** go in `FilterBar`, not in `DealerTenantsView` — it is used by the
organizations, users and admin-tenants screens too, and a second copy would drift.

**That makes this the one change in item 16 that reaches beyond the tenants page.** It must be purely
additive: a screen that passes no chip data renders exactly what it renders today. Verify the other
`FilterBar` consumers visually, not only by their tests passing.

### D7 — The row action menu replaces nothing

`⋯` with Open tenant / Manage plan / Manage credits / View users, and a destructive item last
(Suspend, or Complete setup / Delete for an incomplete one).

**Row click-through stays.** The menu is an addition, and its trigger must `stopPropagation` or every
menu open also navigates — the mistake `AdminTenantsTable`'s approve/reject buttons already guard
against with `e.stopPropagation()`.

Each item routes to a surface that already exists; **no new destination is invented here.** Where the
mockup names an action with no home today, it is dropped rather than stubbed — a menu item that opens
nothing is worse than an absent one.

### D8 — Sequencing: after 17a

17a is rewriting `tenants.service.ts`'s read paths; the API half of this item edits the same file's
`list` mapper and `resolveAgentNames`. Rebase onto a `main` that has 17a first. 17b is not a blocker —
it touches `admin-tenants.service.ts`, and the admin list is out of scope here.

### D9 — The admin tenant list is untouched

`AdminTenantsTable` keeps its Dealer column and its current layout. That list spans organizations, so
the org name there is the point rather than the noise, and nothing in the mockup describes it.

## The FE↔BE contract

`GET /tenants` only. Two fields added, none removed or renamed.

| Field | Before | After |
|---|---|---|
| `ownerOrgName` | `string` | unchanged — still sent, no longer in the table cell |
| `agentName` | `string \| null` | unchanged |
| `agentRoleName` | — | **new**: `string \| null`, resolved via `member.roleId` (D1) |
| `provisionedPlan` | `{ planId, planCode, planName, erp, aiCredit, aiService }` | **widened**: each service gains its limits — ERP/AI user limits and the WhatsApp limit (D3) |

## Testing

**API**

- The owner's role is reported, resolves to `null` for a member with no role, and both fields are
  `null` when the node resolves to nobody.
- A **renamed role** reports its new name on the next read, and a **desynced `member.role` mirror**
  does not leak into the list. These two are the fence around D1.
- The widened `provisionedPlan` carries the limits, and a plan with no AI service still serialises.

**Web**

- The Owner cell shows name and role and **not** the organization name — the existing fixture already
  sets `ownerOrgName: 'Acme Dealer'`, so asserting its absence is a real assertion.
- Name and role degrade to `—` independently.
- Each stat card against a fixed row set, including a row with `erpUnavailable: true` excluded from
  the credit percentage rather than counted as zero.
- The services filter narrows the table, survives a reload via the URL, and degrades to unfiltered on
  an unknown value.
- Chips appear per active filter, Clear all empties them, and **a `FilterBar` consumer that passes no
  chips renders unchanged**.
- The action menu opens without navigating, and each item routes where it says.

`npm run build` is the real typecheck; `tsc --noEmit` exits 0 having checked nothing.

## Non-goals

- **"Last activity."** D2 — no data source exists.
- **MES / WMS service badges.** D3 — not on the dealer row shape.
- **Live seat usage.** D3 — the numbers available are plan limits.
- **The admin tenant list.** D9.
- **A creator column.** D1 — no creator is recorded, and after a cross-org reassign it would name
  someone at another dealer.
- **A new aggregate endpoint for the stat cards.** D4.
- **Removing `ownerOrgName` from the response.** D1.
