# Claiming a tenant becomes a platform-admin act

**Item 12.** Cross-repo — [`sudu-dealer-api`](../../sudu-dealer-api) and
[`sudu-dealer-web`](../../sudu-dealer-web). Written 2026-09-01.

Branches: `feat/dealer-claim-removal` in both repos.

## The request

> "dealer cannot claim tenant anymore, claiming is only for platform admin"

This settles the question item 12 was parked on. Item 5 decided *"dealer have no permission to claim
a tenant"* and removed the dealer-facing UI; it could not make the statement true, because the web
repo never decides authorization. This makes it true.

## What is actually still there

**The endpoint accepts it.** `POST /dealer-clients`
([`dealer-client.controller.ts:52`](../../sudu-dealer-api/src/dealer-client/dealer-client.controller.ts))
refuses only a *platform* actor, then calls `DealerClientService.create`, which stamps
`ownerMemberNodeId` from the caller and lands the row `PENDING`. A direct API call still claims
successfully today.

**Every dealer admin holds the permission.** `statement.client` is
`['create', 'read', 'update', 'delete']`, and `dealerCeiling` inherits it. Because
`effectiveGrant` hands an ADMIN role its plane's **ceiling**, every dealer admin holds `client:create`
whatever their stored JSON says.

**And the rest of the resource gates nothing at all.** `hasPermission(actor, 'client', …)` appears
**once** in the whole API — the `client:create` check at
[`dealer-client.service.ts:76`](../../sudu-dealer-api/src/dealer-client/dealer-client.service.ts).
`client:read`, `client:update` and `client:delete` are granted to every admin on both planes and
checked nowhere. The web permission builder does not list `client` at all, so no admin can even see
them.

## Decisions

### D1 — Delete the dealer claim path; do not re-gate it

`POST /dealer-clients`, `DealerClientService.create` and `CreateDealerClientDto` go.

The alternative — keep the route and require a platform admin — was rejected because that route
already exists: `POST /dealer-clients/admin-claim` is the platform-admin claim, and it lands `ACTIVE`
immediately because the vendor asserting ownership *is* the verification. A second admin-claim route
landing `PENDING` would mean two ways to do one thing, differing in a way nobody could remember.

The dealer claim's whole design — land `PENDING`, wait for an admin to activate — exists because
*"a dealer's claim on a tenant is NOT self-certifying"*. Once dealers cannot claim, the mechanism has
nothing to certify.

### D2 — Remove `client` from `statement` entirely, not just `create`

```diff
-  client: ['create', 'read', 'update', 'delete'],
```

**No migration.** `effectiveGrant` gives an ADMIN role the ceiling, and clamps a CUSTOM role's stored
grant to it via `intersectPermission`, which skips any resource the ceiling does not hold
(`const allowed = ceiling[resource]; if (!allowed) continue;`). So a stored `client: [...]` key stops
being held the moment the vocabulary loses it — the same no-migration property 17a relies on, running
in the opposite direction.

**Removing only `create` would repeat this exact bug.** Three permissions every dealer admin holds
that gate nothing, invisible in the builder, waiting for someone to add a `client:read` check and
silently grant it to every dealer on the platform. That is precisely how `client:create` came to be
held by people the product says do not have it.

Nothing in either repo reads `client` after D1. `dynamicAccessControl` validates submitted role JSON
against `ac.statements`, so a request carrying `client` becomes a 400 — correct, and unreachable from
the builder, which never offered the resource.

### D3 — Re-home the ownership tests BEFORE deleting `create`

**This is the part that is easy to get wrong.** `resolveOwnerMemberNodeId` **survives** — it is called
by [`tenant-provisioning.service.ts:173`](../../sudu-dealer-api/src/tenant-provisioning/tenant-provisioning.service.ts),
the live registration path. It decides which member owns a tenant, which decides through scoping who
can see it, so it is a security control.

Its only test coverage is the `describe('create')` block in `dealer-client.service.spec.ts`, which
exercises it through the method being deleted:

- defaults ownership to the acting member
- a non-admin may assign to a descendant-role member, inside its subtree
- a non-admin may **not** assign to a sibling role, outside its subtree
- an org admin may assign anywhere within its own org
- an org admin may **not** assign to another organization's node
- an unknown `ownerMemberNodeId` is refused

Deleting that block deletes the only tests for a live security control. Those six cases move to the
provisioning path first, and only then does `create` go.

The other tests in that block — the master-tenant guard, the duplicate-tenant 409s, the demo cap —
pin behaviours of `create` itself. Before deleting each one, check whether `adminClaim` has its own
equivalent; where it does not and the behaviour still matters on the admin path, the test moves rather
than dies.

### D4 — `PENDING` stays, and so does every approval path

Do not treat `PENDING` as dead vocabulary. Two reasons, both concrete:

1. **`resolveLandingStatus` is a documented seam that can return it.**
   [`landing-status.ts`](../../sudu-dealer-api/src/tenant-provisioning/landing-status.ts) says so in
   as many words: Spec A always returns `ACTIVE`; *"Spec B (quota + approval) replaces this body with
   the quota verdict: within the dealer's allowance lands ACTIVE, over it lands PENDING for admin
   approval."* The approve/reject path is that feature's other half, not legacy handling.
2. **There are live `PENDING` rows.** The local database holds 8 `ACTIVE` and **2 `PENDING`**
   `dealer_client` rows right now.

So `activate`, `reject` and `withdraw` stay; the dealer list keeps its `PENDING` filter option; and
`DealerAwaitingPanel` keeps its **Withdraw request** button. A dealer who cannot create a pending
claim can still hold one.

### D5 — The web change is deleting two dead exports

`createDealerClient()` and `CreateDealerClientInput` in
[`services/dealer-api.ts`](../../sudu-dealer-web/src/services/dealer-api.ts) have **no callers** —
item 5 removed the UI and left the client behind on purpose, because the endpoint still existed. It
does not any more.

Nothing else on the web changes. The permission builder never listed `client`, and no component
checks a `client` permission.

### D6 — This lands after 17a

`resolveOwnerMemberNodeId` calls the scope resolver, and 17a renamed it: on that branch the call is
`resolveActScope`, deliberately — nominating an owner is an **act**, so granting `tenant:view_all`
must never widen who a member may assign ownership to. D3's re-homed tests must be written against
the post-17a name, and one of them should pin that property directly.

## The FE↔BE contract

| Surface | Before | After |
|---|---|---|
| `POST /dealer-clients` | dealer claims a tenant, lands `PENDING` | **gone** — 404 |
| `POST /dealer-clients/admin-claim` | platform admin claims, lands `ACTIVE` | unchanged |
| `POST /dealer-clients/:id/activate` · `/reject` · `/withdraw` | approval paths | unchanged (D4) |
| `statement.client` | `['create','read','update','delete']` | **removed** |
| web `createDealerClient()` / `CreateDealerClientInput` | exported, no callers | **gone** |

No response shape changes. No migration.

## Testing

**API**

- The six ownership cases from D3, re-homed onto the provisioning path and passing **before** the
  deletion lands.
- One of them asserts the act-scope property from D6: a member holding `tenant:view_all` still cannot
  nominate an owner outside its own downline.
- After the deletion: `POST /dealer-clients` returns 404, asserted at the controller/e2e level rather
  than inferred from the route being absent.
- A role whose stored JSON still carries `client: ['create']` resolves to an effective grant with no
  `client` key at all — the test that proves D2 needs no migration.
- The whole suite passes with **no `client` references left**: `grep -rn "'client'" src` returns only
  the reserved-subdomain list, which is an unrelated string.

**Web**

- `npm run build` after the deletion. The two exports have no callers, so a clean build is the whole
  proof; there is no behaviour to test.

## Non-goals

- **Removing `PENDING`, the status filter, or the approve/reject/withdraw paths.** D4.
- **Touching `admin-claim`, `reassign` or `release`.** They are already platform-admin-only and are
  what "claiming is only for platform admin" now rests on.
- **Touching the registration path.** `tenant-provisioning.service.ts` creates its own `dealer_client`
  row and never went through `DealerClientService.create`. Registration is unaffected.
- **A migration to rewrite stored role JSON.** D2 — the clamp makes it unnecessary. Rewriting the rows
  is harmless but pointless, and a migration that changes nothing observable is a liability.
