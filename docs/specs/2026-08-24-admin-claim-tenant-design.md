# Admin claims a tenant for a dealer — cross-repo design

**Status:** approved, not yet implemented
**Repos:** `sudu-dealer-api` · `sudu-dealer-web`
**Branches:** `feat/admin-claim-tenant` (all three repos), off `main`
**Plans:** api → `sudu-dealer-api/docs/superpowers/plans/…` · web → `sudu-dealer-web/docs/superpowers/plans/…` (neither written yet)

## Problem

Today, attaching a tenant to a dealer always starts with the dealer: `POST
/dealer-clients` claims a tenant for the *caller's own* organization, and the
controller explicitly refuses a platform admin (`ForbiddenException('Platform admins
do not own clients')`). Everything the admin console can do to a claim reacts to one
a dealer already started — `activate`/`reject` a `PENDING` row, `reassign` an
`ACTIVE` one.

There is no path for SuDu AI to hand a dealer a tenant that dealer never asked for —
a sales-side arrangement, a legacy account being onboarded onto the platform, a
correction where the dealer who should have claimed it never did. Today that
requires either walking the dealer through claiming it themselves, or a manual
database write.

This is the org plane. Nothing here changes the client plane's data (SaaS/BladeX) —
it only writes `dealer_client`, exactly as every existing claim transition does.

## Decisions

| | Question | Decision |
|---|---|---|
| **Q1** | Does the claim land `ACTIVE` immediately, or `PENDING` for the dealer to accept? | **`ACTIVE` immediately** |
| **Q2** | Where does the admin trigger it? | **Both** — a row action on an unclaimed tenant, and the tenant detail page |
| **Q3** | Does the demo cap apply? | **No — admin claims are exempt** |

### On Q1 — why `ACTIVE`, not a new `PENDING`-then-accept step

The admin *is* the approval authority — that is exactly what `activate()` already
does for a dealer-submitted claim. Landing this action at `PENDING` would mean the
admin approves their own creation in a second step, or would require inventing a new
dealer-side "accept an assignment" action that does not exist today. Landing at
`ACTIVE` matches how the action reads: "claim this tenant for this dealer" is a
completed instruction, not a proposal.

### On Q3 — what "exempt" costs

`DemoCountService.countForOrg` still counts every real row, so a dealer's own
`DemoSlots` reading after an admin claim is accurate, not lying. What changes is
that the cap stops being a hard ceiling: it protects *self-service* claiming only.
An admin can push a dealer over their configured demo limit with no confirmation
step and no signal to the dealer beforehand. This is accepted, not overlooked —
`reassign()`'s `force` override exists because reassign is dealer-initiated
(the *target* dealer didn't choose it either, but the cap check still runs there);
here the admin is the only actor in the loop, so gating them behind their own
override serves no one.

### On what this route does *not* verify

`create()` lands `PENDING` and requires `activate()` — that admin-approval step is
the only thing in the system today that catches a wrong or typo'd `tenantId` before
a claim becomes `ACTIVE`. `adminClaim` skips `PENDING`, per Q1, but substitutes
nothing for an *identity* check in its place — it never reads the tenant registry at
all. Q1's rationale ("the admin *is* the approval authority") is about workflow, and
is sound there; it says nothing about whether the `tenantId` given actually names the
tenant the admin thinks it does.

The consequence if it were wrong is not hypothetical: `getOwnedOrThrow()` gates
gateway AI-token operations on `{tenantId, status: 'ACTIVE'}`, so a mistyped 6-digit
id that happened to name a real, unclaimed BladeX tenant would authorize the target
dealer for token operations against a stranger's tenant.

This is accepted anyway. The only UI path passes a `tenantId` straight from a row of
the admin console's own tenants list — the drawer takes it as a prop and has no
free-text tenant input at all, so an admin cannot mistype one through the app.
Reaching the vector at all requires a direct API call by an actor who is already a
platform admin, i.e. someone who already holds the highest privilege in the system.
The action is audited (actor, target org, tenant, and the admin's stated reason),
reversible via `release`/`reassign`, and the partial unique index means the blast
radius is bounded to tenants nobody has claimed yet.

What would change the calculus: if a future UI ever accepts a hand-entered tenant id
on this route, this decision must be revisited and a registry existence check added —
fail-open when the registry is unreadable, matching every other registry read in
`DealerClientService`.

## Contract

### `POST /api/dealer-clients/admin-claim`

A new, separate route rather than extending `POST /dealer-clients` — the codebase's
existing pattern for every admin-side transition (`activate`, `reject`, `reassign`
are each their own guarded method, never folded into the dealer-authored `create()`).
Conflating dealer self-claim (`client:create` permission, demo cap enforced) and
admin-claim (`isPlatformAdmin`, cap exempt) into one method would mean branching on
actor type inside a method whose whole job today is "the caller claims for
themselves."

No `:id` in the path: unlike `activate`/`reject`/`reassign`, there is no existing
`dealer_client` row to key on — the tenant is, by definition, unclaimed.

```ts
interface AdminClaimTenantBody {
  /** BladeX tenant id — the 6-digit login code. Same shape CreateDealerClientDto uses. */
  tenantId: string;
  /** The dealer organization this tenant is claimed FOR. */
  organizationId: string;
  /** Pre-filled from the admin console's known SaaS name; editable. */
  label: string;
  /** Required. Why an admin attached a tenant a dealer did not request. */
  reason: string;
  /** Optional. Defaults to the target org's single root member node. */
  ownerMemberNodeId?: string;
}
```

Two identifiers exist for a tenant and this is the smaller one: the su-code
**snowflake** (19 digits, exposed as `AdminTenant.id`) is a different value from the
6-digit login code (`tenant_id2`) that `tenantId` means everywhere in this contract.
`tenantId` stays a `String` because leading zeros are significant — `"074730"` is a
real value, not a formatting choice.

Response: `201` · the created `DealerClient` (`status: 'ACTIVE'`, `onboardedAt: now`)
— the same shape every other claim-mutating route already returns.

### Guards, in order, reused verbatim from existing code

1. **`isPlatformAdmin(actor)`**, or `403`. Same gate as `activate`/`reject`/`reassign`
   — not `hasPermission(actor, 'client', 'create')`, which is the dealer-side rule and
   does not apply here.
2. **Master-tenant guard**: `tenantId === MASTER_TENANT_ID` → `400`. Verbatim from
   `create()`.
3. **Target org guards**, verbatim from `reassign()`:
   - unknown `organizationId` → `404`
   - `targetOrg.isDefault` (the vendor org) → `400` ("The platform organization cannot
     hold client claims")
   - `targetOrg.suspendedAt` → `400` ("A suspended dealer organization cannot receive
     a claim")
4. **`resolveTargetOwnerNode(organizationId, ownerMemberNodeId)`**, verbatim from
   `reassign()` — defaults to the org's single root member node; `409` if the org has
   zero or more than one root and none was specified.
5. **No demo cap check** (Q3).
6. **Row write**, `status: 'ACTIVE'`, `onboardedAt: new Date()` directly — there is no
   intermediate `PENDING` state to pass through (Q1).
7. **Live-claim uniqueness**: the same partial unique index every claim path relies
   on. A `P2002` here means someone else's claim landed first (dealer or admin) —
   `409` "This tenant has already been claimed", never revealing whose. Verbatim
   from `create()`.

### Audit

`@Audit('dealer_client.admin_claim', { targetType: 'dealer_client' })`. The target id
is the row this call *creates*, so — like `TenantProvisioningController.create` —
it must come from `AuditContext.set({ targetId: row.id, ... })` after the write, not
from a route param the decorator could read directly. Metadata carries
`organizationId`, `tenantId`, and `reason`.

### Errors

| Status | When |
|---|---|
| `400` | Master tenant · target org is the vendor org · target org is suspended |
| `403` | Actor is not a platform admin |
| `404` | Target organization does not exist |
| `409` | Tenant already claimed · target org has no single root member node |

## API side

New module surface within `src/dealer-client/`:

- `AdminClaimDealerClientDto` — `tenantId`, `organizationId`, `label` (`@MaxLength(200)`,
  trimmed, required — whitespace-only input is rejected rather than stored as the
  dealer-visible client name), `reason` (`@MaxLength(500)`, trimmed, matching
  `ReassignDealerClientDto`), optional `ownerMemberNodeId`.

  This deliberately diverges from `CreateDealerClientDto.label`, which is only
  `@IsString() @MaxLength(200)` — untrimmed and not required-after-trim, so `"   "` is
  a valid label on the dealer-side claim route today. Closing that gap there is
  separate follow-up work: that route is shipped and in use, and tightening it needs
  its own review.
- `DealerClientService.adminClaim(actor, dto)` — composes the guards above. Shares
  `resolveTargetOwnerNode` with `reassign()` rather than re-deriving it; no new
  helper needed for target-org validation, since `reassign()`'s inline checks are
  three lines and used exactly once elsewhere.
- `DealerClientController` gains the route, guarded by the existing `SessionGuard`
  at the controller level (unchanged).

Nothing about the demo-cap service, the SaaS registry reader, or any other claim
transition changes.

## Web side

**One drawer, two entry points** — mirrors how `ReassignTenantDrawer` is a single
component already used from `AdminTenantDetail`.

- `AdminClaimTenantDrawer` — dealer-org picker (`listOrganizations()`, excluding the
  default org and suspended orgs client-side, same as `ReassignTenantDrawer`), a
  label field pre-filled from `AdminTenant.name` and editable, a required reason
  field. No subdomain lookup: unlike the dealer's `ClaimTenantForm`, the admin is
  claiming a tenant already present in the list with full SaaS data attached.
- **Row entry point**: `AdminTenantsTable`'s unclaimed-row cell today renders a bare
  `<Badge>SuDu AI</Badge>` with no action (`AdminTenantsTable.tsx`, the
  `if (!tenant.dealer)` branch). It gains a "Claim" button beside the badge,
  parallel to the Approve/Reject pair a `PENDING` row already shows.
- **Detail entry point**: `AdminTenantDetail` gains the same action, alongside where
  `ReassignTenantDrawer` already renders for claimed tenants.
- Both entry points gate the Claim affordance on `tenantId !== '000000'` (the master
  tenant), in addition to the tenant being unclaimed — the API refuses a master-tenant
  claim unconditionally (guard #2), so offering the button there can only waste the
  admin's work. Master rows are never filtered out of the admin tenants list and are
  unclaimed by construction, so without this check the button renders on them too.
- `adminClaimDealerClient(input)` added to `services/dealer-api.ts`, following
  `reassignDealerClient`'s shape.

On success, `refetch()` the admin tenants list (same pattern `AdminTenantsView`
already uses after `activate`/`reject`), and close the drawer.

## Out of scope

- **No notification to the dealer.** The tenant simply appears in their list next
  time they look, same as any other admin-side change reaching them today.
- **No bulk claim.** One tenant per action, matching every existing claim mutation.
- **No override of the single-root-node rule.** An org with an ambiguous or missing
  root must be fixed at the org level; this feature does not add a picker UI for
  `ownerMemberNodeId` beyond what the API already accepts.
- **No demo-cap override control**, per Q3 — there is nothing to override.

## Open questions

None.
