# Tenant network view — SuDu AI staff see every tenant

**Status:** design agreed 2026-09-01, not yet implemented.
**Scope:** backlog item **17b**, the platform-plane half of item 17.
**Depends on:** [`2026-09-01-tenant-view-scope-design.md`](./2026-09-01-tenant-view-scope-design.md)
(item 17a), which creates the `tenant:view_all` action this reuses — which in turn depends on
[`2026-08-28-tenant-permission-design.md`](./2026-08-28-tenant-permission-design.md) (item 10).
**The queue is 10 → 17a → 17b.**

## The request

> all the role in the Sudu AI organization if view all tenant, which mean they can see all tenants
> in all organizations

Scoped, on the user's decision of 2026-09-01, to **reading**: the network list and the read-only
tenant detail behind it. Every write stays platform-admin-only.

## The bug this also fixes

A SuDu AI **staff** member's Tenants page is broken today, and has been since before item 10.

`sudu-dealer-web/src/routes/tenants.tsx` ends with:

```tsx
if (!isPlatform(me) && !can(me, 'tenant', 'view')) {
  return <PermissionDenied … />
}
return isPlatformAdmin(me) ? <AdminTenantsView /> : <DealerTenantsView />
```

A platform-plane **CUSTOM** role passes the guard (it *is* a platform actor, so item 10 correctly
declines to deny it) and then falls through the dispatch to `<DealerTenantsView />`, because it is
not a platform **admin**. That view calls `GET /tenants`, and `TenantsService.list` refuses every
platform actor outright. So vendor staff are routed to a page the API will not serve them.

Fixing the gate without fixing the dispatch would leave them exactly where they are.

## Decisions

### D1 — Reuse `tenant:view_all`; its scope is "the widest your plane allows"

No new action. One grant, two meanings, decided by the actor's plane:

| Plane | `tenant:view_all` means |
|---|---|
| dealer | the whole of the actor's own organization (17a) |
| platform | every tenant in every organization (this spec) |

This is what the request says in the user's own words, and it matches a model where the plane
already decides scope — `dealerCeiling` caps `organization` differently from `platformCeiling` for
the same reason. It leaks nothing: 17a's D3 guarantees a dealer-plane grant can never resolve past
the actor's own organization, and only a platform admin can grant anything inside the vendor org.

The alternative, a separate `tenant:view_network`, was rejected as a second string to reason about
for a distinction the plane already makes.

### D2 — Seven read routes change gate; every write keeps `isPlatformAdmin`

| Route | Enforced in | After |
|---|---|---|
| `GET /admin/tenants` | `AdminTenantsService.list` | network read |
| `GET /admin/tenant-provisioning-requests` | `TenantProvisioningService.listAll` | network read |
| `GET /admin/tenants/:tenantId/consumption` | `AdminCreditMovementController` | network read |
| `GET /admin/tenants/:tenantId/consumption/daily` | `AdminCreditMovementController` | network read |
| `GET /admin/consumption/daily` | `AdminCreditMovementController` | network read |
| `GET /admin/movements/recent` | `AdminCreditMovementController` | network read |
| `GET /admin/tenants/:tenantId/reloads` | `AdminCreditReloadController` | network read |

Unchanged, and deliberately so — all still `isPlatformAdmin`:

- `POST /admin/tenant-provisioning-requests/reconcile` and `/:id/retry`
- `POST /admin/tenants/:tenantId/reloads`, `POST /admin/credit-reloads/reconcile`
- the dealer-client admin operations: claim for a dealer, reassign, release
- the wallet surface: top-up approve / reject, dealer adjustments

Staff may look at any tenant on the network and change nothing about it.

### D3 — One predicate, not seven hand-rolled booleans

Add beside `isPlatformAdmin` in `auth/actor.types.ts`:

```ts
export function canReadTenantNetwork(actor: Actor): boolean {
  return isPlatformAdmin(actor) || (isPlatform(actor) && hasPermission(actor, 'tenant', 'view_all'));
}
```

The `isPlatformAdmin ||` half is belt-and-braces for the same reason as 17a's D4: a platform admin
holds `view_all` through the derived ceiling, but any `Actor` constructed without `permissions`
would otherwise lock the vendor superuser out of its own network view. Keeping it states no policy
— a platform admin cannot be denied the grant — and makes this change purely additive at every one
of the seven sites.

### D4 — The route dispatch stops branching on role kind

`routes/tenants.tsx` becomes, in effect:

- a **platform** actor **with** `tenant:view_all` → `<AdminTenantsView />`
- a **platform** actor **without** it → the `PermissionDenied` state item 10 already built
- a **dealer** actor → unchanged: `can(me, 'tenant', 'view')` decides between `<DealerTenantsView />`
  and `PermissionDenied`

The silent fall-through to the dealer view disappears. Note the platform-admin case still works
because `/me` reports permissions from `effectiveGrant`, which returns the ceiling for an ADMIN role.

### D5 — `AdminTenantDetail`'s write affordances get gated

Today only platform admins reach that page, so its Claim, Reassign, Release and Top-up controls are
ungated. Once staff can reach it, each must render only for `isPlatformAdmin(me)`. The API refuses
them regardless by D2 — this is so a button that would 403 is never offered, which is the same
posture the organizations screens already take.

This is the only real UI work in 17b.

## Testing

**API**

- One test per re-gated route: a platform CUSTOM actor **with** `tenant:view_all` succeeds; the
  same actor **without** it gets 403; a platform admin succeeds in both cases (proving D3's
  belt-and-braces half); a **dealer** actor with `tenant:view_all` still gets 403 — that last one
  is the boundary that keeps a dealer grant from reaching the network.
- One test per write listed as unchanged, proving a granted staff actor is still refused. These are
  the regressions the design exists to prevent, so they are not optional.

**Web**

- `routes/tenants.spec.tsx`: platform + grant renders the admin view; platform without the grant
  renders `PermissionDenied` (not the dealer view); dealer unchanged.
- `AdminTenantDetail.spec.tsx`: the four write controls are absent for a platform CUSTOM actor and
  present for a platform admin.

**Gates.** API `npm test` against real Postgres; web `npm run build`, never `tsc --noEmit`.

## Non-goals

- **Any write.** A support-desk capability — staff who may claim, reassign or release — would be a
  different action (`tenant:manage_all`) and its own item. Not designed here.
- **The rest of `/admin`.** Wallet top-ups and adjustments, partner interests and their settings,
  audit logs, credit pricing, dealer tiers: none are tenant-facing, and all keep `isPlatformAdmin`.
- **The dealer plane.** That is 17a, and this spec changes none of it.
- **A migration.** As in 17a: nothing is written to any role's stored permission.
