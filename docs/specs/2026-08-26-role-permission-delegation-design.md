# Bounded permission delegation — cross-repo design

**Status:** draft
**Repos:** `sudu-dealer-api` · `sudu-dealer-web`
**Branches:** `feat/role-permission-delegation` (both), off `main`
**Plans:** api → `sudu-dealer-api/docs/superpowers/plans/…` · web → `sudu-dealer-web/docs/superpowers/plans/…` (neither written yet)
**Parent:** [`sudu-dealer-api/docs/superpowers/specs/2026-07-24-org-user-role-management-design.md`](../../sudu-dealer-api/docs/superpowers/specs/2026-07-24-org-user-role-management-design.md) — this amends its delegation model

## Problem

Roles other than ADMIN should be able to manage organizations, users, and roles, with two
guarantees: a role's grant is **inherited from its parent and can never exceed it**, and the
ADMIN role's grant is **full and unchangeable**.

The role tree already enforces the second guarantee and half of the first. Three things stop the
requirement from being met, and the first of them is what makes the other two dangerous.

### 1. `organization` is not permission-gated at all

Every write in `OrganizationService` — `create`, `update`, `delete`, `suspend`, `unsuspend`,
`updateLimits` — gates on `isPlatformAdmin(actor)`, not on the actor's permissions. A role holding
`organization:update` is refused anyway. The permission is decorative: it is grantable, it is
containment-checked, and it does nothing.

`user` and `role` are already permission-gated, so this is `organization` alone.

### 2. Containment binds the role, but not the actor

`RoleService.create` checks `dto.permission ⊆ parent.permission` — and lets the caller choose **any**
parent in the org, including the ADMIN root. So an actor holding nothing but `role:create` can mint
a child of ADMIN carrying the full permission set. `update` is worse: with `role:update` the actor
can re-parent **their own role** under ADMIN and widen it to match.

Nothing anywhere compares a requested grant against what the *acting* role holds. The containment
lattice is sound; the actor simply is not standing in it.

### 3. The same hole in user management

`UserService.create` accepts any `roleId` in the target org — ADMIN included — and the caller
supplies the password (`passwordSetup: 'set'`). An actor with `user:create` therefore mints an
admin account whose credentials they know: a one-call takeover. `update` reaches the same end by
promoting an existing user.

Gaps 2 and 3 are latent only because non-admins rarely hold these permissions today. Requirement 1
is precisely what puts them in reach, so all three are one change.

This spans both planes. The **platform plane** gains delegable org management; the **org plane**
gains bounded self-service. Nothing here touches the client plane.

## What already exists

Most of requirement 2 and all of requirement 3 are built. Worth stating so the plans do not
rebuild them:

- `RoleTreeService.assertContained` / `isContained` — the child ⊆ parent lattice.
- `RoleService.create` / `update` — containment on create, on permission edits, and on re-parent;
  `assertNoCycle`; and a `409` when narrowing a role would strand its children.
- `RoleService.effectivePermission` — an ADMIN role's grant is **derived** from `statement`, never
  read from its stored JSON, so it cannot go stale when the vocabulary widens.
- `update` refuses any permission or parent change on `kind === 'ADMIN'`; `delete` refuses it
  outright; `create` always writes `kind: 'CUSTOM'`, with the
  `organization_role_one_admin_per_org` index as the backstop.

## Decisions

| Question | Decision |
|---|---|
| How far does the permission gate replace `isPlatformAdmin` on `organization`? | Fully. A dealer's grant is capped at info editing; SuDu keeps the whole lifecycle. |
| How is the dealer cap expressed? | A **dealer admin does not hold full `organization`** — its ceiling is `['read', 'update']`. |
| What bounds an actor managing roles and users? | The actor's own subtree, **strictly below** its own role. |
| What about stored grants that exceed the new ceiling? | Clamp on read (fail closed) **and** migrate the stored JSON to match. |

## Contract

No new endpoints. The change is in who each existing one accepts, and in one widened body.

### Authorization, per route

`✔` = permitted when the actor's role grants it. Cross-org reach is unchanged: the platform plane
sees every org, the dealer plane only its own.

| Route | Permission | Platform ADMIN | Platform CUSTOM | Dealer ADMIN | Dealer CUSTOM |
|---|---|---|---|---|---|
| `POST /api/organizations` | `organization:create` | ✔ | ✔ | ✖ never | ✖ never |
| `PATCH /api/organizations/:id` | `organization:update` | ✔ | ✔ | ✔ own org | ✔ own org |
| `POST /api/organizations/:id/suspend` · `/unsuspend` | `organization:suspend` | ✔ | ✔ | ✖ never | ✖ never |
| `DELETE /api/organizations/:id` | `organization:delete` | ✔ | ✔ | ✖ never | ✖ never |
| `PATCH /api/organizations/:id/limits` | — | ✔ | ✖ never | ✖ never | ✖ never |

"✖ never" is not a gate in the service — it falls out of the ceiling. A dealer role's grant cannot
contain `organization:delete`, because its ADMIN ancestor does not hold it to give.

`updateLimits` stays `isPlatformAdmin`-only and stays out of `statement`. Tier, discount, headroom,
and demo slots are our commercial terms; they are not delegable to a vendor staff role either.

### `PATCH /api/organizations/:id` — widened body

```jsonc
{
  "name":           "string, 1..200",     // NEW — was immutable
  "contactEmail":   "string, email",      // NEW — was immutable
  "billingAddress": "string, 1..500",
  "invoiceNotes":   "string, 0..2000"
}
```

All four optional; an empty body is a no-op `200`, as today.

**`slug` does not follow `name`.** It is a stable unique identifier assigned once at creation by
`resolveUniqueSlug`; a rename that moved it would silently repoint anything holding the old value.
Renaming changes the display name only.

`UpdateOrganizationDto` currently enforces `name`/`contactEmail` immutability *by its shape* —
`forbidNonWhitelisted` rejects a request that even mentions them. Adding the fields removes that
guard, so the DTO gains explicit validators in its place.

### Error cases

| Condition | Status | Body message |
|---|---|---|
| Actor lacks the permission | `403` | `You do not have permission to …` (existing wording) |
| Target role is not strictly below the actor's | `403` | `You may only manage roles beneath your own` |
| Target user holds a role above the actor's | `403` | `You may only manage users at or beneath your own role` |
| New role's parent is not the actor's role or a descendant | `400` | `Parent role not found` — deliberately identical to the existing out-of-scope-parent message, so an unreachable branch is never confirmed |
| Assigning a user a role not strictly below the actor's | `400` | `Role not found in the target organization` — same reasoning |
| Grant exceeds the parent's | `403` | `Role exceeds its parent: "<resource>:<action>" …` (existing) |
| Editing an ADMIN role's permission or parent | `400` | existing wording, unchanged |

The `400`-not-`403` choice on parent and role selection is the codebase's existing discipline: a
role the actor may not reach is reported as if it does not exist.

### `GET /api/me`

Shape unchanged. `permissions` is now the **clamped** grant, so a dealer whose stored JSON still
carries `organization:delete` stops seeing it. The web reads no ceiling of its own — the API sends
the effective grant and that is the only copy the client trusts.

## API side

### Plane-scoped ceilings — `auth/permissions.ts`

`statement` is untouched. What splits is the full set:

```ts
platformCeiling  // every resource, every action — today's adminPermissions, derived from statement
dealerCeiling    // identical, except organization: ['read', 'update']

ceilingFor(plane: 'platform' | 'dealer'): Permission
```

Both stay **derived** from `statement`, never hand-listed, so a newly added action still widens the
platform admin automatically. `dealerCeiling` overrides exactly one key; every future resource
reaches the dealer plane by default, which is the safer direction to fail.

One exported function replaces the two open-coded copies:

```ts
effectiveGrant(role: { kind, permission }, plane): Permission
//  ADMIN  → ceilingFor(plane)
//  CUSTOM → intersect(parse(role.permission), ceilingFor(plane))
```

`ActorService` ([actor.service.ts:89](../../sudu-dealer-api/src/auth/actor.service.ts)) and
`RoleService.effectivePermission` both call it. That is the single point at which a ceiling is
applied, which is what makes the clamp trustworthy: there is no read path that skips it.

Requirement 3 holds on both planes. An ADMIN role's grant is still derived, still un-editable, and
still the top of its plane's lattice — a dealer admin is *full for its plane*.

Containment then caps the dealer plane for free. `assertContained` already refuses to grant a child
what its parent lacks, and a dealer admin now lacks `organization:delete`, so no dealer role at any
depth can be given it. No second gate, no plane check inside `OrganizationService`.

### The actor bound — `RoleTreeService`

```ts
assertBelowActor(actor, targetRoleId): Promise<void>
```

True when `targetRoleId` is in `subtreeRoleIds(actor.roleId)` **and** is not `actor.roleId` itself.
Reuses the existing recursive CTE. `isPlatformAdmin(actor)` short-circuits it — the vendor
superuser is the root of every tree it can reach.

Two strengths, deliberately different:

- **`assertBelowActor`** — strictly below. Used for mutations of the role *tree*.
- **`assertAtOrBelowActor`** — the actor's own role, or below. Used for operations on *user
  records* and for handing out a role.

The split exists because a dealer admin holds their org's ADMIN role. Under a pure strictly-below
rule they could never create a second admin — ADMIN is not *below* them, it *is* them — so admin
succession would become a platform-admin-only act, which the org's own last-admin guard already
assumes is not the case. Handing someone a role you already hold introduces no privilege that was
not already in the system, so at-or-below is safe there; **editing the tree above yourself is
escalation**, so that stays strict.

| Service · method | Added check | Strength |
|---|---|---|
| `RoleService.create` | `dto.parentRoleId` is the actor's role or below | at or below |
| `RoleService.update` | target below; a re-parent target is the actor's role or below | **strictly below** |
| `RoleService.delete` | target below | **strictly below** |
| `UserService.create` | `dto.roleId` is the actor's role or below | at or below |
| `UserService.update` | the member's current role **and** any new `roleId` | at or below |
| `UserService.suspend` · `unsuspend` · `delete` | the member's role | at or below |

The guarantee that matters survives intact: **no actor can hand out, or move a role to, a
position above its own.**

`RoleService.list` and `get` are unchanged — reading the whole org tree is how a manager picks a
parent, and the tree is not sensitive. `UserService.list` is likewise unchanged; hiding peers from
a list is a different feature, and doing it here would break the org-wide member counts the Users
screen shows.

An explicit `assertContained(requested, actor.permissions)` runs alongside the subtree check on
`role.create` and `role.update`. It is redundant — a descendant's grant is already ⊆ the actor's by
the tree invariant — but it makes the guarantee local to read, and it is the check that still holds
if the invariant is ever violated by a bad migration.

**Consequences, stated plainly:** nobody edits their own role or a peer's *role definition*;
nobody promotes a user above their own role; a dealer admin still does everything inside its org,
because it is that tree's root — including minting a second admin and editing that co-admin's
record. What a dealer admin loses is the ability to **rename their own ADMIN role**, which becomes
a platform-admin act. That is a real regression against today's behaviour, accepted because
self-edit is the escalation path and a role name is cosmetic.

### `OrganizationService`

Each `isPlatformAdmin` gate becomes `hasPermission(actor, 'organization', <action>)`. What does
**not** change: `orgScopeMismatch`-style reach (a non-platform-admin still resolves only its own
org, and any other id is `404`), the default-org guards on delete and suspend, the
still-owns-dealer-data `409` on delete, and `updateLimits`.

`update` gains `name` and `contactEmail` writes. Both are plain column updates; `contactEmail` has
no verification round-trip today and gains none here.

### Migration

One migration, after the clamp is in place and therefore not load-bearing:

- Rewrite `organizationRole.permission` for every `kind = 'CUSTOM'` role in a **non-default** org,
  intersecting the stored JSON with `dealerCeiling`.
- Leave `kind = 'ADMIN'` rows alone — their stored JSON has been ignored since the derived-grant
  change and rewriting it would imply otherwise.

In practice this removes `organization` actions other than `read`/`update` from dealer custom roles.
It is not reversible, which is why the runtime clamp is the actual guarantee.

### Tests

- `permissions.spec.ts` — `dealerCeiling` omits exactly `create`/`delete`/`suspend` on
  `organization` and matches `platformCeiling` everywhere else; adding a resource to `statement`
  widens both.
- `effectiveGrant` — ADMIN by plane; CUSTOM clamped; malformed JSON still degrades to `{}`.
- `role-tree.service.spec.ts` — `assertBelowActor`: descendant passes, self fails, ancestor fails,
  sibling fails, platform admin bypasses.
- `role.service.spec.ts` — the escalation regressions, written as attacks: create a child of ADMIN
  (refused), re-parent own role under ADMIN (refused), widen a peer's role (refused).
- `user.service.spec.ts` — assigning ADMIN with a known password (refused); promoting a peer
  (refused); the last-admin guard still fires where it did.
- `organization.service.spec.ts` — each write permitted by grant, refused without it; a dealer role
  cannot be granted `organization:delete` at all; `updateLimits` still platform-admin-only; a
  rename leaves `slug` untouched.

## Web side

Both surfaces. Nothing here is a permission check — the API re-checks every request
(root `CLAUDE.md` boundary 2); this is affordance and honesty about what is grantable.

### `components/roles/constants.ts` — widen `PERMISSION_CATALOG`

Today it lists **`credit` only**, so the role editor cannot express org/user/role management at all.
This is the largest single blocker to requirement 1 on the web side. It gains `organization`,
`user`, and `role` with their actions, labelled for humans ("Suspend a dealer", not
`organization:suspend`).

The parent-role ceiling already drives the checkboxes — `PermissionBuilder`'s `allowed` prop
disables anything the parent lacks. A dealer admin's editor therefore shows `organization` with
only View and Edit enabled, with no plane logic in the client: the ceiling arrives as the parent's
permission from the API.

### `RoleFormDrawer`

The parent picker is currently every role in the org. It narrows to the caller's own role and its
descendants, matching the API's new `400`. The admin-root freeze is unchanged.

### `UsersView` / the create + edit drawers

The role picker narrows the same way — the assignable set is the caller's subtree, strictly below.
`useRoles()` returns the flat org list, so the subtree filter needs the tree walked client-side
from `me.roleId` via `parentRoleId`, which the list already carries.

### `OrganizationsView`

`canManage = isPlatformAdmin(me)` becomes per-action `can(me, 'organization', …)`, so a vendor staff
role granted org management sees the buttons, and a **dealer** admin gains an Edit affordance for
its own org that it has never had. `EditOrganizationDrawer` gains the `name` and `contactEmail`
fields.

### Nav

`MANAGEMENT_NAV_ITEMS` is already gated per item on `can(me, resource, 'read')` and needs no change.
That gate starts mattering the moment non-admin roles can actually hold these permissions.

### Tests

Component tests for: the widened catalog rendering under a parent ceiling; the parent and role
pickers excluding self, ancestors, and siblings; org action buttons appearing by grant rather than
by `isPlatformAdmin`; a dealer admin seeing Edit but not Delete or Suspend.

**Gate:** `npm run build`, never `tsc --noEmit` — it exits 0 having checked nothing (root
`CLAUDE.md`, Known Issue 2).

## Out of scope

- **Splitting `organization` into two resources.** Considered, and the plane ceiling does the same
  work without a vocabulary change or a grant migration for every existing role.
- **Hiding peers and superiors from the Users and Roles *lists*.** Managers need the whole tree to
  pick a parent, and the Users screen's counts are org-wide. This change bounds writes, not reads.
- **Letting an actor edit its own role.** Ruled out by the strictly-below rule.
- **Delegating `updateLimits`, tiers, or wallet operations.** Commercial terms stay ours.
- **Session revocation on a grant change.** A narrowed role takes effect on the actor's next
  request, since `ActorService` re-resolves per request. Live sessions are not killed — the same
  behaviour org suspension already has.
- **`contactEmail` verification.** No round-trip today, none added.

## Open questions

None.
