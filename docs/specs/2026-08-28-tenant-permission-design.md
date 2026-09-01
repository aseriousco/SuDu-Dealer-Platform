# Tenant permissions — cross-repo design

**Status:** approved 2026-08-28
**Backlog:** item 10 — *"set permission for the tenant list, so we add this to permission manager"*
**Repos:** `sudu-dealer-api`, `sudu-dealer-web`

## Problem

A dealer admin cannot express "this role may see our tenants." There is no lever to pull, the
screen it would govern is enforced inconsistently, and the one section of the permission manager
that does touch this area is grouped by the wrong idea.

### 1. The tenant surface has no permission checks at all

`tenants`, `tenant-provisioning`, and `tenant-drafts` contain **zero** `hasPermission` calls
between them. `TenantsService.list` refuses a *platform* actor and then filters by
`ScopingService.resolveVisibleScope` — which answers *whose* tenants a role sees, never
*whether* it may open the page. Registering a tenant, saving a draft, submitting one, and
revealing a stored tenant-admin password are all ungated.

### 2. One screen, two authorities

`GET /api/dealer-clients/demo-slots` — the strip at the top of the dealer Tenants page — *does*
check, on `client:read`, and 403s without it. The list beneath it checks nothing.

### 3. `client` is enforced but unmanageable

`statement` declares `client: ['create','read','update','delete']` and both ceilings carry it,
but `PERMISSION_CATALOG` lists only `organization`, `user`, `role`, and `credit`. There is **no
way to grant or revoke any `client` action through the permission manager.** Every `client`
grant that exists got there by seeding, not by an admin's choice.

### 4. "AI Credits" groups a per-tenant act with a company-level one

The `credit` section offers View, Reload, and Request top-up together. Those are not the same
kind of thing, and `permissions.ts` already says so:

> `topup` is deliberately distinct from `reload`: requesting a top-up commits the company to a
> payment to us, while `reload` allocates already-paid credit to a client.

Reloading is something you do **to a tenant** — its route is literally
`POST /api/tenants/:tenantId/reloads`. Requesting a top-up is something you do **for the
organization's wallet**. Grouping them under one heading means an admin cannot let a junior
service tenants without also letting them commit the company to a payment.

`credit:view` compounds it: it is declared in `statement`, offered in the catalog, and
**enforced nowhere in either repo.** It is a checkbox that has never done anything.

## What already exists

Worth stating so the plans do not rebuild it:

- `hasPermission(actor, resource, action)` — `auth/actor.types.ts`, the house idiom.
- `statement` / `platformCeiling` / `dealerCeiling` / `ceilingFor` — `auth/permissions.ts`.
  **`platformCeiling` is derived from `statement`, and `dealerCeiling` spreads it**, so a new
  resource reaches both planes with no edit to either.
- `effectiveGrant` — an ADMIN-kind role always resolves to its plane's full ceiling regardless
  of stored JSON. **No ADMIN role can be affected by anything in this spec.**
- `intersectPermission` — clamps a stored grant to the ceiling on every read. This is why
  removing an action from `statement` silently revokes it, which the migration below must
  account for.
- `PermissionBuilder` + `PERMISSION_CATALOG`, and the parent-ceiling `allowed` prop.
- `MANAGEMENT_NAV_ITEMS` is filtered by `can(me, item.resource, 'read')` in `Sidebar`.

## Decisions

| Question | Decision |
|---|---|
| Which resource gates the tenant surface? | A **new `tenant`**, not a reuse of `client:read`. |
| Which actions? | `view`, `edit`, `create`, `reload`. |
| What does `tenant:view` cover? | **Viewing tenants and viewing their credit.** One grant, both screens. |
| Where do drafts sit? | Under **`create`** — a draft is part of registering a tenant, so creating, editing, deleting, and submitting one all ride on `tenant:create`. |
| What does `edit` gate today? | **Nothing.** Declared now for the live-tenant edit function that is coming, so the vocabulary need not change again when it lands. |
| Where does credit reload go? | Onto **`tenant:reload`** — the same capability as today's `credit:reload`, regrouped to where it belongs. |
| What is left of `credit`? | **`['topup']` only**, relabelled **Wallet**. |
| What happens to `credit:view`? | **Retired.** It is enforced nowhere; its intent is absorbed into `tenant:view`. |
| May `tenant:view` reveal a stored tenant-admin password? | **Yes.** Seeing a tenant includes seeing how to log into it. |
| What does a role without `tenant:view` see? | Nav entry hidden; the route answers 403 with an explanation. |
| What happens to existing CUSTOM roles? | `tenant: ['view','create']`, plus `reload` **only if they held `credit:reload`**. Never `edit`. |
| What happens to `client:*`? | The demo-slots routes move onto `tenant`. `client` is left governing only the claim path. |

### Why `edit` is declared but not granted

`tenant:edit` gates nothing on day one, so withholding it removes no capability from anyone.
Granting it in the migration would mean that the day the live-tenant edit feature ships, every
legacy CUSTOM role can already use it — a privilege nobody chose. Declaring it now and granting
it deliberately later is the fail-safe direction, and costs an admin one checkbox.

### Why the migration is load-bearing this time

Two different reasons, and the second one bites:

- **`view` and `create`:** there are no checks today, so every dealer role can already list,
  register, and draft tenants. Granting only `view` would silently remove registration.
- **`reload`:** once `reload` leaves the `credit` resource, `intersectPermission` clamps any
  stored `credit: ['reload']` straight out on the next read. **A role that can reload credit
  today loses that ability the moment this deploys unless the migration maps it to
  `tenant:reload`.** This is not tidying; it is the only thing preserving a live capability.

Roles holding `{}` — such as `JOJO ORG 1`'s `Manager` — get `['view','create']`. That role sees
an empty tenant list today for an unrelated reason (backlog item 11, on hold); this spec must
not quietly convert that into a permission denial.

## Contract

No new endpoints. The change is what each existing one requires.

Scoping is unchanged and orthogonal: `tenant:view` decides *whether* a role opens the list,
`resolveVisibleScope` still decides *which rows* it holds.

| Route | Permission today | Permission after |
|---|---|---|
| `GET /api/tenants` | — | `tenant:view` |
| `GET /api/dealer-clients/demo-slots` | `client:read` | `tenant:view` |
| `GET /api/tenant-provisioning-requests` | — | `tenant:view` |
| `GET /api/tenant-provisioning-requests/:id` | — | `tenant:view` |
| `GET /api/tenant-provisioning-requests/by-tenant/:tenantId` | — | `tenant:view` |
| `POST /api/tenant-provisioning-requests/:id/tenant-admin-password` | — | `tenant:view` |
| `GET /api/tenant-drafts` · `GET /api/tenant-drafts/:id` | — | `tenant:view` |
| `POST /api/tenant-drafts/:id/reveal-password` | — | `tenant:view` |
| `GET /api/tenants/:tenantId/reloads` | — | `tenant:view` |
| `POST /api/tenant-provisioning-requests` | — | `tenant:create` |
| `POST /api/tenant-provisioning-requests/:id/retry` | — | `tenant:create` |
| `POST /api/tenant-drafts` | — | `tenant:create` |
| `PATCH /api/tenant-drafts/:id` · `DELETE /api/tenant-drafts/:id` | — | `tenant:create` |
| `POST /api/tenant-drafts/:id/submit` | — | `tenant:create` |
| `POST /api/dealer-clients/demo-slots/request-increase` | `client:create` | `tenant:create` |
| `POST /api/tenants/:tenantId/reloads` | `credit:reload` | `tenant:reload` |
| `POST /api/wallet/topups` · `POST /api/wallet/topups/:id/cancel` | `credit:topup` | **unchanged** |
| `GET /api/dealer-clients` | — | `tenant:view` |
| `GET /api/tenants/:tenantId/consumption` · `/consumption/daily` | — | `tenant:view` |
| `GET /api/movements/recent` | — | `tenant:view` |
| `GET /api/org-consumption` | — | `tenant:view` |

### Amendment 2026-08-28 — the four rows above were missing, and the feature was bypassable without them

The table originally ended at the wallet row. A whole-branch review of the finished
implementation found four more dealer routes reading the same tenant data with **no permission
check of any kind**, which made `tenant:view` trivially bypassable: a role denied it still read
the org's tenant roster through `GET /api/dealer-clients` (`tenantId`, `label`, `status`, owner),
and still read a tenant's consumption ledger by direct URL while the reload ledger next to it
answered 403. `GET /api/movements/recent` carries `tenantId` **and** `tenantName` per entry, so
the roster is enumerable there too.

**This was an enumeration failure, not a scope question.** The rationale that governs them is
already written in this spec, in the reload-ledger note below: *a role that cannot open the tenant
list should not reach a tenant's ledger by direct URL.* The consumption ledger is that route's
structural twin — same `/api/tenants/:tenantId/` prefix, same `getOwnedOrThrow` ownership model,
same tenant-detail screen. Nothing about the intent changed; the list of routes was short.

**Why it survived every per-task review:** each task's review was correctly scoped to its own
diff, and these routes appear in no task's diff — a route nobody assigned is a route nobody
reviews. Worse, the gap was *pinned by three passing tests* asserting "no permission needed for
reads", whose comments mirrored the reasoning this spec had superseded one file away. That is the
same failure mode as the `tenantLoginHost` bug: a retired invariant asserted in a comment and a
test, so the wrong behaviour reads as intended behaviour.

Those tests were not deleted. Each carried two claims — that `reload` is not required for reads
(still true) and that no permission at all is required (now false by design) — and each was split
so the surviving half keeps its coverage.

**No existing role lost access.** The migration below grants `tenant:['view','create']` to every
pre-existing CUSTOM role, so gating these four routes changed nothing for anyone already in the
system.

**The AI Credits page needs no route of its own.** `useCreditTenants` reads
`listDealerTenants()` — the same `GET /api/tenants`. Gating that one endpoint gates the credits
screen too, which is what makes "view tenants and view credit" a single grant rather than two.

`GET /api/tenants/:tenantId/reloads` currently carries a comment saying reads "stay open to any
org member" because `getOwnedOrThrow` enforces ownership. **This spec deliberately supersedes
that**: ownership answers *which* tenant, not *whether this role reads tenants at all*, and a
role that cannot open the tenant list should not reach a tenant's ledger by direct URL. Update
the comment rather than leaving it contradicting the code.

Admin-plane tenant and wallet routes (`/admin/*`) are **out of scope** — governed by plane and
`isPlatformAdmin`, unchanged.

### Error shape

`403` naming the capability, matching the house wording at `demo-slots.controller.ts`
(*"Your role cannot read clients"*):

- read routes — `Your role cannot view tenants`
- create routes — `Your role cannot create tenants`
- reload route — `Your role cannot reload credit`

## API side

### `auth/permissions.ts`

```ts
credit: ['topup'],
tenant: ['view', 'edit', 'create', 'reload'],
```

`view` and `reload` leave `credit`; `client` is untouched. Nothing else in the file changes —
`platformCeiling` is derived from `statement` and `dealerCeiling` spreads it, so both planes
track the change automatically. Update the `topup`/`reload` comment: it explains a distinction
that is now expressed by the resources themselves.

### Checks

Add `hasPermission` guards per the contract table. Placement follows the existing split:
guard in the controller where the route is thin, in the service where one method backs several
routes. Guard **where the actor is first available and before any work**.

`credit-reload.controller.ts:17` changes resource and action, not shape.

`TenantsService.list` is the important one. Its guard goes **before** the `advanceStaleForOrg`
call — a role that may not view tenants must not trigger provisioning side-effects by
requesting the page.

### Migration

One migration over every `organizationRole` with `kind = 'CUSTOM'`, merging into the stored
`permission` JSON and preserving everything already there:

- add `tenant: ['view','create']`;
- **add `reload` to that list if — and only if — the role's stored `credit` array contained
  `reload`**;
- drop `view` and `reload` from the stored `credit` array, leaving `topup` if present.

Leave `kind = 'ADMIN'` rows alone: `effectiveGrant` derives their grant from the ceiling and
ignores stored JSON.

Not reversible. The `view`/`create` half is deliberately generous — it preserves today's access
rather than imposing a new default, so narrowing becomes an admin's deliberate act, which is
the point of the item. The `reload` half is not generosity but preservation: without it, the
clamp silently revokes a live capability.

### Tests

- `permissions.spec.ts` — `tenant` holds all four actions and `credit` holds only `topup`;
  both ceilings carry `tenant`; adding it required no ceiling edit.
- `tenants.service.spec.ts` — list refused without `tenant:view`, permitted with it, **and the
  guard fires before `advanceStaleForOrg`** (assert the provisioning collaborator is never
  called on the refused path). Scoping unchanged for a role holding the grant.
- `tenant-provisioning` / `tenant-draft` specs — each route refused without its permission and
  permitted with it; both password-reveal routes permitted on `tenant:view`.
- `credit-reload.controller.spec.ts` — reload refused without `tenant:reload`; **a role holding
  only the old `credit:reload` is refused**, which is the regression the migration exists to
  prevent.
- `demo-slots.controller.spec.ts` — now refuses on `tenant:view` / `tenant:create`.
- Migration test — a `{}` role becomes `['view','create']`; a role with `credit:['view','reload']`
  becomes `tenant:['view','create','reload']` with `credit` emptied; a role with
  `credit:['topup']` keeps it; an ADMIN row untouched; **no role gains `edit`**.

## Web side

Nothing here is a permission check — the API re-checks every request (root `CLAUDE.md`
boundary 1). This is affordance and honesty about what is grantable.

### `components/roles/constants.ts` — restructure the catalog

`credit` is relabelled and narrowed; `tenant` is added:

```ts
{
  resource: 'credit',
  label: 'Wallet',
  actions: [{ action: 'topup', label: 'Request top-up' }],
},
{
  resource: 'tenant',
  label: 'Tenants',
  actions: [
    { action: 'view', label: 'View tenants and their credit' },
    { action: 'create', label: 'Register a tenant' },
    { action: 'reload', label: 'Reload credit' },
    { action: 'edit', label: 'Edit a tenant' },
  ],
}
```

`view` names both screens, because one grant governs both. `edit` is listed last: it is the
only action that does nothing today.

**`edit` will render as a checkbox that changes no behaviour until the tenant-edit feature
ships.** Known and accepted, recorded here so it is not later filed as a bug.

The parent-ceiling mechanism needs no change — `PermissionBuilder`'s `allowed` prop already
disables anything the parent lacks, and the ceiling arrives from the API.

### Nav — `NAV_ITEMS` needs gating it does not have

`MANAGEMENT_NAV_ITEMS` is filtered by `can(me, item.resource, 'read')`, but **Tenants and AI
Credits live in `NAV_ITEMS`, which is filtered only by
`!(isPlatform(me) && item.to === '/wallet')` — no permission gating exists on the primary group
at all.**

Two things follow, both load-bearing:

1. `NavItem` gains an optional `{ resource, action }`. Primary items carrying it are filtered on
   it; items without one render exactly as now.
2. The filter must read the item's **own action**, not a hardcoded `'read'`. The management
   filter hardcodes `'read'` and would never match `tenant:view`.

`/tenants` and `/credits` both gate on `tenant:view`. `/wallet` is **not** gated — `credit:topup`
governs the top-up action, not reading your own wallet, and this spec does not change that.

### Routes

`/tenants` and `/credits` render a 403 state — *"Your role cannot view tenants. Ask an admin for
the View permission on tenants."* — rather than an empty list, so a hidden nav entry reached by
direct URL or an old bookmark explains itself. This is the shape backlog item 9 argues for: a
user who can see what they lack can ask for it, instead of an admin granting Admin to make the
problem go away.

**Not the silent-null pattern.** `DemoSlots.tsx:34` (`if (!slots) return null`) makes a 403
vanish without a word — acceptable for a supporting strip, wrong for a whole page.

### Tests

- The catalog renders Wallet with one action and Tenants with four; both disabled under a
  parent lacking them.
- Sidebar: Tenants and AI Credits hidden without `tenant:view`, shown with it; Wallet and
  Dashboard unaffected; a management item still gated as before.
- `/tenants` and `/credits` render the 403 state without the grant, and their content with it.

**Gate:** `npm run build`, never `tsc --noEmit` — it exits 0 having checked nothing.

## Non-goals

- **Item 11 is not solved here.** `resolveVisibleScope` is untouched. A role holding
  `tenant:view` still sees only its own role-subtree's tenants, so an Admin-registered tenant
  stays invisible to a Manager. This spec decides *whether* the page opens, never *what is in
  it*. Item 11 is on hold precisely because that second question is unsettled.
- **`client` is not retired.** It still governs the dealer claim path — backlog item 12.
- **Admin-plane routes are untouched.**
- **`read` vs `view` is not reconciled.** The catalog already mixes both, and `tenant` follows
  `credit`'s `view` rather than `organization`'s `read`.
