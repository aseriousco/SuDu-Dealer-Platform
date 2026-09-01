# Tenant view scope — `tenant:view_all` on the dealer plane

**Status:** design agreed 2026-09-01, not yet implemented.
**Scope:** backlog item **17a**. Item 17b (SuDu AI staff seeing the whole network) is deliberately
excluded — see [Non-goals](#non-goals).
**Depends on:** [`2026-08-28-tenant-permission-design.md`](./2026-08-28-tenant-permission-design.md)
(item 10), which introduces the `tenant` resource this adds an action to. **That must merge first.**

## The request

> change the view tenant permission to view all / view own role or below tenant only

and, on the vendor side (deferred to 17b):

> all the role in the Sudu AI organization if view all tenant, which mean they can see all tenants
> in all organizations

## Why this is a separate change from item 10

Item 10's spec says so itself, under its own Non-goals:

> **Item 11 is not solved here.** `resolveVisibleScope` is untouched. A role holding `tenant:view`
> still sees only its own role-subtree's tenants … This spec decides *whether* the page opens,
> never *what is in it*.

Item 10 decides whether the page opens. This decides what is in it. They are the same surface and
adjacent in time, but they are not the same change, and item 10 is thirteen commits deep and
unmerged in both repos — folding this in would rewrite work already done.

## What exists today

`ScopingService.resolveVisibleScope(actor)` is the single visibility rule for every
`dealer_client`-shaped query:

| Actor | Scope returned |
|---|---|
| platform admin (`isPlatformAdmin`) | `{}` — everything, cross-org |
| dealer-org role of kind `ADMIN` | `{ organizationId }` — the whole org |
| any other role | `{ organizationId, ownerMemberNodeId: { in: [...subtree] } }` |

So the two levels the request asks for **already exist as behaviour**. They are welded to
`roleKind`, and the request is to make them a **grant** instead, so a non-Admin role can be given
the wide view without being made an Admin.

## Decisions

### D1 — One new action: `tenant:view_all`

```ts
tenant: ['view', 'view_all', 'edit', 'create', 'reload'],
```

`view` keeps its item-10 meaning (may the Tenants surface open at all) and additionally means "see
my own role subtree". `view_all` widens that to the whole organization. Two actions, not one action
carrying a scope value, because `permission` is `Record<string, string[]>` — a scope value has
nowhere to live without changing the stored shape.

### D2 — No migration, and that is a property of the design rather than an omission

`platformCeiling` and `dealerCeiling` are derived from `statement`, and `effectiveGrant` returns
the ceiling for an `ADMIN` role rather than its stored JSON. So:

- every ADMIN role holds `view_all` the moment it is added to `statement` — it keeps the org-wide
  view it has today, with nothing written to the database;
- no CUSTOM role holds it, so every non-admin role keeps exactly the subtree view it has today.

Behaviour is therefore preserved for every existing role, and the wide view is opt-in from the
permission manager. Contrast item 10, which needed a migration precisely because it was *removing*
access that had never been gated.

### D3 — On the dealer plane, `view_all` is organization-bounded and can never widen further

Only `isPlatformAdmin` returns the unbounded `{}`, and that stays exactly as it is. `view_all`
always resolves to `{ organizationId: actor.organizationId }`. Cross-organization visibility
remains a property of *which plane you are on*, never of a grant a dealer admin can hand out.

A platform-plane CUSTOM role holding `view_all` therefore resolves to the vendor organization —
which holds no `dealer_client` rows — so the grant is inert there, exactly as item 10 already notes
`tenant:view` is inert on a platform role. **17b is where that becomes meaningful**, and it does so
by re-gating the admin routes, not by changing this rule.

### D4 — The scope resolver splits by intent, and the old name is deleted

**`resolveVisibleScope` is not a read-only helper.** Among its twelve real call sites are
`revealTenantAdminPassword`, `withdraw`, `retryAsDealer`, `getAndAdvance` (which calls `advance()`
— a mutation, despite the name) and `resolveOwnerMemberNodeId`. Widening that one function would
have made "view all tenants" also mean *reveal every tenant's admin password* and *withdraw any
claim in the org*.

`ScopingService` therefore exposes two methods and **no longer exposes `resolveVisibleScope`**:

```ts
/** Reading. Honours `tenant:view_all`, which widens to the actor's own organization. */
resolveReadScope(actor: Actor): Promise<ClientScope>

/** Acting on a record. Today's rule exactly: ADMIN -> own org, everyone else -> own subtree. */
resolveActScope(actor: Actor): Promise<ClientScope>
```

Deleting the old name is the point, not a side effect: every call site fails to compile until
somebody states which one it is. A defaulted parameter would let a site inherit the wrong intent
silently, and the wrong intent here is a privilege escalation.

### D5 — How the twelve call sites classify

Named by method rather than line, because item 10 will move the lines.

| Service | Method | Intent |
|---|---|---|
| `TenantsService` | `list` | read |
| `DealerClientService` | `list` | read |
| `DealerClientService` | `getOwnedOrThrow` | **both — see D6** |
| `DealerClientService` | `resolveOwnerMemberNodeId` | act |
| `DealerClientService` | `withdraw` | act |
| `TenantProvisioningService` | `listForActor` | read |
| `TenantProvisioningService` | `getByTenantId` | read |
| `TenantProvisioningService` | `revealTenantAdminPassword` | act |
| `TenantProvisioningService` | `getAndAdvance` | act |
| `TenantProvisioningService` | `retryAsDealer` | act |
| `CreditMovementService` | `listDailyForOrg` | read |
| `CreditMovementService` | `listRecentMovements` | read |

`revealTenantAdminPassword` is classed **act** deliberately. It performs no write, but it hands
over a credential, and a permission named "view" must not be the thing that unlocks it.

### D6 — `getOwnedOrThrow` takes an explicit intent

It is documented as *"the ownership gate — every token operation calls this before touching the
gateway"*, and it serves both sides:

| Caller | Intent |
|---|---|
| `CreditMovementService.listConsumption` | read |
| `CreditMovementService.listDailyForTenant` | read |
| `CreditReloadService` — the reload path and its two ledger guards | act |

The reload path **spends money**. Signature becomes
`getOwnedOrThrow(actor, tenantId, intent: 'read' | 'act')`, no default. This is the single sharpest
reason D4 splits the function instead of adding a branch to it.

### D7 — One checkbox on the web, worded as sight rather than power

`PERMISSION_CATALOG`'s `tenant` group (added by item 10) gains one action, after `view`:

```ts
{ action: 'view_all', label: 'View every tenant in the organization' },
```

Wording matters here: the label must not suggest it grants anything *over* those tenants, because
by D4 it does not. No other web change — the tenants and credits screens read whatever the API
returns.

## The FE↔BE contract

Nothing changes shape. The only new item on the surface is the action string `view_all` under the
`tenant` resource in a role's `permission` map, which both sides already treat as an open
vocabulary validated by `assertKnownPermissions` against `statement`.

`docs/contracts/` needs no change: no route, request or response shape moves, and that directory
carries no per-route permission table (item 10's contract table lives inside item 10's own spec).

## Testing

**API**

- `scoping.service.spec.ts`: a CUSTOM role **with** `tenant:view_all` resolves to
  `{ organizationId }` with no `ownerMemberNodeId`; **without** it, to the subtree scope. An ADMIN
  role still resolves org-wide (now via the ceiling, not via `roleKind`). A platform admin still
  resolves `{}`. A **platform CUSTOM** role holding `view_all` resolves to the vendor org, not `{}`
  — this is the test that pins D3 and stops 17b arriving by accident.
- The existing test *"a leaf role (junior) sees only its own members, not its parent senior"* must
  still pass unchanged. It is the design record for the narrow case, and this change must not move
  it.
- One test per **act** site proving `view_all` does **not** widen it — at minimum
  `revealTenantAdminPassword`, `withdraw`, and the credit-reload path through `getOwnedOrThrow`.
  These are the regressions this whole design exists to prevent, so they are not optional.

**Web**

- `PermissionBuilder.spec.tsx`: the `tenant` group offers the new action, and it is hidden when the
  org ceiling lacks it (the existing ceiling-filter behaviour, exercised on the new entry).

**Gates.** API: `npm test` against real Postgres. Web: `npm run build` — never `tsc --noEmit`,
which exits 0 having checked nothing.

## Non-goals

- **17b — SuDu AI staff seeing the whole network.** Not a scoping change: `TenantsService.list`
  refuses every platform actor, and the cross-org list is `GET /admin/tenants`, gated on
  `isPlatformAdmin`. Granting it to vendor staff means re-gating the admin surface from role kind
  to grant, and deciding how far the read reaches — the list alone leaves rows that 403 when
  clicked. Its own brainstorm.
- **Item 11's *ownership should be assignable* reading.** Granting `view_all` makes an
  Admin-registered tenant visible to a Manager, which resolves item 11's reported symptom. It does
  not decide whether ownership can be reassigned, and does not add a "register on behalf of"
  picker.
- **Tenant drafts.** `TenantDraftService` deliberately scopes by plain `organizationId` and never
  calls the scope resolver, so drafts are already org-wide. Untouched.
- **A migration.** See D2.
- **`read` vs `view` naming.** The catalog already mixes both; `view_all` follows `view`, as item 10
  chose. Reconciling them is neither this change's job nor item 10's.
