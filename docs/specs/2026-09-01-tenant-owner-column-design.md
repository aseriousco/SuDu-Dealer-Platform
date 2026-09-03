# The dealer tenant list, redesigned

**Item 16.** Cross-repo — [`sudu-dealer-api`](../../sudu-dealer-api) and
[`sudu-dealer-web`](../../sudu-dealer-web). Written 2026-09-01, **rewritten the same day** when the
user supplied a full-page mockup and chose to make item 16 that redesign rather than the single
column it started as.

Mockup: [`docs/design/2026-09-01-tenant-list-redesign.html`](../design/2026-09-01-tenant-list-redesign.html)
(committed verbatim, `1299745`).

Branches: `feat/tenant-owner-column` in both repos.

## How this item changed

**Amended again 2026-09-02**, after a prototype was run against the live database: the Owner column
got a decided placement (D1), the admin list came into scope (D9, reversing itself), and D4's credit
formula was corrected — it produced -15182% as written. Those three are the user's decisions or the
prototype's findings, not redesigns of the item.

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

**Placement: its own column, second — immediately after Tenant / Client, before Status.**
Settled 2026-09-02 by prototype, not on paper. Three placements were built on the real route over
real data (own column second; own column far right after Claimed; no column, folded into the tenant
cell as a third line) and the user chose the first. The prototype is the primary source, parked on
`proto/tenant-list-owner-placement` in the web repo (`31beee7`); `main` and this feature branch
carry none of it.

On the platform plane the Dealer column comes first and Owner second — see [D9](#d9--both-planes-get-the-redesign).

**The column needs owners that differ, and today they do not.** Every one of JOJO ORG 1's eight
tenants had the same owner, so the column printed the same two lines on every row — finding B3
relocated rather than fixed. Three owners across two roles were seeded into the dev database on
2026-09-02 so the column has something to distinguish. This is worth stating because it is the
column's whole justification: it earns its width exactly when a dealer's tenants have **different**
owners, which is the `view_all` case, and nothing in the seed data exercised it before.

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
- **API, platform plane:** `AdminTenant` carries **no person at all** — only `dealer.organizationName`.
  So D9's reversal needs `agentName` **and** `agentRoleName` added there too, from the same
  `ownerMemberNodeId` join. This is work beyond the widening above, which touches `DealerTenant`
  alone, and it was not in the original three API tasks.

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

**One plan-level number ships, not the mockup's three — and the reason is narrower than it looked**
(established 2026-09-02, during implementation). The per-component numbers are not missing:
`ERP_FIELDS` and `SERVICE_FIELDS` in `sudu-plan-catalog.reader.ts` **both already request
`tenant_user_limit`**, and the fixtures copied verbatim from dev carry ERP `30` and AI-service `2`.
Our own projection drops them — `toErp`/`toService` never read the field.

What is genuinely missing is a verified MEANING. Dev returns `30` on the ERP row and `30` on the plan
row, which reads equally as "30 ERP seats" and as a denormalised copy of the plan total. Showing
`30 ERP users · 2 AI users` when the truth is `30 users total` invents a distinction in a customer's
entitlements — worse than one honest number. **Settling it needs a probe against the live catalog**,
the same kind D2 describes. Until then the row reads `20 users · 3 WhatsApp`.

**MES and WMS badges are not in scope.** `packageType: 'WMS'` exists upstream in provisioning, but
`ProvisionedPlan` models exactly three service slots (erp, aiCredit, aiService) and nothing on the
dealer row distinguishes an MES or WMS package. Adding them is a row-shape change nobody has
specified; the mockup shows them because it is a mockup.

### D4 — The stat cards derive from the list, with no new endpoint

Total tenants, Live, Testing, Need attention, AI credits used are all computable from the rows the
page already fetches. No API call is added, and the numbers cannot disagree with the table beneath
them — which they would if a separate aggregate endpoint were introduced.

Two definitions must be pinned rather than inferred from the mockup:

- **"Need attention"** = the claim is unsettled, **or** monthly credit is at or above 90% of its
  maximum. "Unsettled" means not `ACTIVE` on the dealer plane, and neither `ACTIVE` nor `UNCLAIMED`
  on the platform plane — a tenant SuDu AI holds directly is a normal state, not a problem, and
  counting those made a prototype's card read 30 of 37, which is noise rather than signal.

  **"Provisioning incomplete" was a third reason here until 2026-09-03, and it was removed because it
  is not computable.** It was to be read off `provisionedPlan === null`, but that field's own contract
  says null conflates four causes — a tenant created outside this platform, a request predating
  required `planId`, **a tenant this org claimed rather than provisioned**, and an unreadable plan
  catalog — and that they are "indistinguishable here on purpose: they all mean *we cannot tell
  you*". The row already renders that state honestly as **"Not provisioned here"**; a card calling the
  same rows "needs attention" would contradict the row beneath it, flag every row during an ERP
  outage, and be permanently unclearable for a dealer who claimed rather than provisioned. Restoring
  the reason needs a real provisioning-state field on the wire, not this null.

  Any other definition is fine but must be written down; a card whose meaning nobody can state is
  worse than no card.
- **"AI credits used"** sums per-row usage over `monthlyMax`, across rows whose `erpUnavailable` is
  false. Rows whose registry read failed are **excluded from both sides**, never counted as zero —
  counting a failed read as zero usage understates the figure and is exactly the trap
  `erpUnavailable` exists to prevent.

  **Corrected 2026-09-02.** This originally read "sums `monthlyMax - monthlyRemain`", and the
  prototype rendered that as **-15182%** against the live network. Two cases break it, both real
  and neither rare:

  - **`monthlyMax <= 0` — no cap on record.** 7 of 37 tenants, one of which ("A Serious AI") holds
    999,854,637 credits against a max of 0. A row with no denominator cannot contribute to a
    percentage: **exclude it from both sides**, never zero it. Report the count, the way the
    unreadable rows are reported.
  - **`monthlyRemain > monthlyMax` — topped up above the cap.** 4 of 37. Negative usage is not a
    thing, so per-row usage **clamps into `[0, monthlyMax]`**.

  Both are projection bugs, not data bugs — the numbers are real and the arithmetic was wrong. The
  same clamp applies to the per-row credit bar, which otherwise renders a negative width.

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

### D9 — Both planes get the redesign

**Reversed 2026-09-02 by the user.** This decision previously read "the admin tenant list is
untouched", on the reasoning that the mockup describes only the dealer list. The user's instruction
was the opposite: *"in platform admin also need to change, the different is only add one more for
dealer org column."*

So the platform-admin list gets the same redesign, plus **one** column: **Dealer**, first, in the
slot `AdminTenantsTable` already gives it. Everything else — stat cards, chips, the Owner column,
plan badges, the credit bar, the row menu — is identical to the dealer plane.

That also answers item 16's open *"in all organization — both planes?"* question, and it answers it
without the blinding the backlog entry feared: the Dealer column **stays** on the admin list, because
that list spans organizations and the org name there is the point rather than the noise.

**Build it as one row shape with a flag, not two tables.** The two lists having drifted apart is what
produced the near-duplicate cells they carry today; a second copy of the redesigned row would repeat
that. The prototype does this with one `showDealer` boolean and one set of cells.

**Open, and caused by this reversal:** the admin list's Approve / Reject / Claim buttons are one click
today. Folding them into the row menu makes them two. The prototype keeps them wired inside the menu
so the list stays usable, but whether a primary admin workflow belongs behind `⋯` is a decision
nobody has made — see [D7](#d7--the-row-action-menu-replaces-nothing).

## The FE↔BE contract

**Two endpoints, not one** — `GET /admin/tenants` joined the change when D9 reversed. No field is
removed or renamed on either.

### `GET /tenants` (dealer plane)

| Field | Before | After |
|---|---|---|
| `ownerOrgName` | `string` | unchanged — still sent, no longer in the table cell |
| `agentName` | `string \| null` | unchanged |
| `agentRoleName` | — | **new**: `string \| null`, resolved via `member.roleId` (D1) |
| `provisionedPlan` | `{ planId, planCode, planName, erp, aiCredit, aiService }` | **widened**: one plan-level `userLimit`, plus the AI service's `whatsappLimit` and `accIntegration` (D3). **Not** per-component ERP/AI user limits — this row promised them until 2026-09-02; see D3 for why they are withheld. |

### `GET /admin/tenants` (platform plane) — new, from D9

| Field | Before | After |
|---|---|---|
| `dealer.organizationName` | `string` | unchanged — still the Dealer column, which stays (D9) |
| `agentName` | — | **new**: `string \| null`. The admin row carries no person today. |
| `agentRoleName` | — | **new**: `string \| null`, same `member.roleId` resolution as the dealer plane (D1) |
| `provisionedPlan` | as above | **widened** identically (D3) |

Both planes resolve the owner from the same `ownerMemberNodeId` → `memberNode` → `member` → `user`
join `resolveAgentNames` already walks, so this is one resolver serving two callers, not two.

## Testing

**API**

- The owner's role is reported, resolves to `null` for a member with no role, and both fields are
  `null` when the node resolves to nobody. **On both planes** — the admin list resolves the same
  fields from the same join (D9).
- A **renamed role** reports its new name on the next read, and a **desynced `member.role` mirror**
  does not leak into the list. These two are the fence around D1.
- The widened `provisionedPlan` carries the limits, and a plan with no AI service still serialises.

**Web**

- The Owner cell shows name and role and **not** the organization name — the existing fixture already
  sets `ownerOrgName: 'Acme Dealer'`, so asserting its absence is a real assertion.
- Name and role degrade to `—` independently.
- Each stat card against a fixed row set, including **all three** exclusion cases the credit
  percentage has (D4), each of which the prototype hit on live data:
  - `erpUnavailable: true` — excluded from both sides, not counted as zero.
  - `monthlyMax === 0` — excluded from both sides. Use a real shape: 999,854,637 remaining against a
    max of 0, which is what rendered -15182%.
  - `monthlyRemain > monthlyMax` — contributes 0 used, not a negative. The per-row bar clamps too.
- **The Owner column tells rows apart.** Assert two rows with different owners render different
  cells — a fixture where every row shares one owner passes every other assertion here while
  reproducing the exact noise (finding B3) this column exists to remove.
- **The platform plane is the dealer layout plus one column**: Dealer first, then Owner, then the
  rest identical. A `showDealer`-style flag, one row shape — not a second table (D9).
- **The admin list's real actions survive** the move into the row menu: Claim on an unclaimed
  tenant, Approve and Reject on a PENDING one, and never Claim on the master tenant.
- The services filter narrows the table, survives a reload via the URL, and degrades to unfiltered on
  an unknown value.
- Chips appear per active filter, Clear all empties them, and **a `FilterBar` consumer that passes no
  chips renders unchanged**.
- The action menu opens without navigating, and each item routes where it says.

`npm run build` is the real typecheck; `tsc --noEmit` exits 0 having checked nothing.

## Open — raised by the mockup, decided by nobody

Neither blocks the build, and both are one-line decisions that change what ships.

- **The credit cell flips meaning.** Today's table leads with credits *remaining* (`2,938`); the
  mockup leads with credits *used* (`7,062 / 10,000 · 71%`) and demotes remaining to a subtitle. D4
  pins the meaning of the stat *card* and says nothing about the *cell*. The prototype follows the
  mockup. If that flip was not intended, this is the moment to say so — every row is affected.
- **Approve / Reject behind the row menu.** D9's reversal puts the admin list's primary workflow one
  click further away. See D9.

## Non-goals

- **"Last activity."** D2 — no data source exists.
- **MES / WMS service badges.** D3 — not on the dealer row shape.
- **Live seat usage.** D3 — the numbers available are plan limits.
- **A creator column.** D1 — no creator is recorded, and after a cross-org reassign it would name
  someone at another dealer.
- **A new aggregate endpoint for the stat cards.** D4.
- **Removing `ownerOrgName` from the response.** D1.
