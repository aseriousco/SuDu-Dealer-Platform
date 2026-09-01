# The tenant list's Owner column names a person and their role

**Item 16.** Cross-repo — [`sudu-dealer-api`](../../sudu-dealer-api) and
[`sudu-dealer-web`](../../sudu-dealer-web). Written 2026-09-01.

Branches: `feat/tenant-owner-column` in both repos.

## The request

> "in dealer organization's tenant list, remove the dealer column, add the created user and role in
> all organization"

Clarified by the user on 2026-09-01: *"this actually still the tenant list, i mean all user in all
organization can see the owner for the tenant."*

So **"in all organization" is about the audience, not about which table.** One list — the dealer
tenant list — and the owner is visible to every user in every organization, not gated behind a role.
The admin list at `/admin/tenants` is not in scope.

## Why this matters more now than when it was raised

[Item 17a](./2026-09-01-tenant-view-scope-design.md) adds `tenant:view_all`, so a Manager granted it
sees tenants **they do not own**. Before that grant, a dealer's list was mostly their own work and
the owner was implicit. After it, the list is the organization's whole book and the owner is the only
thing distinguishing one row from another. This column is what makes 17a legible rather than
confusing — which is why D5 refuses to put it behind a permission of its own.

## What exists today

**Web.** [`DealerTenantsTable.tsx:81`](../../sudu-dealer-web/src/components/tenants/DealerTenantsTable.tsx)
renders the **Owner** cell as two stacked lines: `ownerOrgName` above `agentName ?? '—'`. Inside one
dealer's own list every row belongs to that same dealer, so the first line is **identical on every
row** — the noise already logged as finding B3 under item 6. That is "the dealer column" the request
asks to remove.

**API.** `DealerTenant` carries `ownerOrgName`, `agentName` and `ownerMemberNodeId`. There is no role
on the row. [`resolveAgentNames`](../../sudu-dealer-api/src/tenants/tenants.service.ts:245) already
walks `memberNode → member → user.name` in two queries, so the member row the role hangs off is
already being read.

## Decisions

### D1 — The dealer list only; the admin list is untouched

`AdminTenantsTable`'s **Dealer** column shows `dealer.organizationName` and a claim status, and it is
load-bearing: that list spans every organization, so removing the org would leave an operator unable
to tell whose tenant a row is. `AdminTenant.dealer` also carries no person at all, so putting one
there is a second row-shape change nobody asked for.

The redundancy the request names is specific to the dealer plane, where the org is constant. Fixing
it there fixes it everywhere it exists.

### D2 — The column names the CURRENT OWNER, and must not say "created by"

**There is no creator on record.** `DealerClient` has `ownerMemberNodeId` and `createdAt` — and no
`createdBy` column, in the model or in any migration that ever touched `dealer_client`.

That absence is specific, not a house style: `TenantDraft`, `CreditPricing`, `DealerTier` and
`OrganizationRole` all carry `createdByUserId`. **A draft knows who created it; the claim it becomes
does not** — there is no column to carry it into, so the attribution is dropped at exactly the moment
the tenant becomes real. Worth knowing if creator attribution is ever wanted: the data exists one
table upstream, for tenants that came through the wizard, and not at all for claimed ones.

And the creator is not merely unrecorded, it is actively overwritten: `DealerClientService.reassign` calls `resolveTargetOwnerNode(...)` and
**re-stamps `ownerMemberNodeId` to a node in the target organization**, so once a claim moves between
dealers the original creator is gone from the row entirely.

Three consequences, in order of importance:

1. **Labelling this "created by" would be false** for any reassigned claim, and there is no way to
   tell from the row whether it has been reassigned.
2. **Showing a real creator would leak across organizations.** After a cross-org reassign the creator
   is a person at a *different dealer*; the new dealer's whole staff would see their name.
3. **For every row that has not moved between dealers, the two are the same person anyway** —
   ownership is still not reassignable inside an organization (the closed item 11), so the owner is
   whoever registered it.

Recording a real creator is therefore a migration plus a cross-org display rule, for a distinction
that is invisible on almost every row. Not in scope; if it is ever wanted, it is a new item.

The column keeps its existing header, **Owner**. It is already the honest word.

### D3 — The org line goes, the person is promoted, the role is added

```
  Acme Dealer          →     Dana Agent
  Dana Agent                 Manager
```

Line one is the person's display name, line two their role. Both degrade to `—` independently: an
owner whose member node no longer resolves, and a member with no role, are different facts and are
shown as such rather than collapsing the cell.

### D4 — The role resolves through `roleId`, never through `member.role`

`member.role` is a **mirror** maintained for better-auth's own use; `member.roleId` is the
authoritative link. The codebase already states this rule — `UserView` documents `roleName`/`roleKind`
as "resolved by `member.roleId`, never the name" — and the role-rename cascade exists precisely
because the mirror can lag.

Reading the mirror here would make a renamed role show its old name on the tenant list and nowhere
else, which is the least debuggable kind of wrong.

**`Member.roleId` is `String?`.** A member with no role is representable, so `agentRoleName` is
nullable and the cell must survive it. Do not assume a role exists because one usually does.

### D5 — No permission of its own; every role that sees the list sees the owner

This is the user's explicit requirement, and it is also the right design. `tenant:view` already
governs whether the list is visible at all (item 10) and `tenant:view_all` governs *which rows*
appear (17a). A third gate on *a column within a row you are already allowed to see* would add a
permission that can only ever produce a confusing half-view: rows you may read, attributed to nobody.

Nothing about the owner is more sensitive than the tenant row that surrounds it — the owner is a
colleague in the reader's own organization, since the dealer list never spans orgs.

### D6 — `ownerOrgName` stays on the wire

It is dropped from **this table's cell**, not from the payload. Two other consumers read it:
[`DealerTenantDetail.tsx:94`](../../sudu-dealer-web/src/components/tenants/DealerTenantDetail.tsx)
("Owner org") and
[`TopUpTenantStep.tsx:132`](../../sudu-dealer-web/src/components/tenants/TopUpTenantStep.tsx).
Removing the field to tidy the response would break both for no benefit — the request is about a
column, not about a field.

(`DraftTableRow.tsx:37` also reads `ownerOrgName`, but from `TenantDraft` — a different type, not
affected either way.)

### D7 — `resolveAgentNames` becomes `resolveOwners`

It already reads the `member` row that the role hangs off, so this is one more `select` and one more
lookup, not a new query per row:

```ts
private async resolveOwners(
  memberNodeIds: string[],
): Promise<Map<string, { name: string; roleName: string | null }>>
```

The `member` select grows `roleId`, a third query resolves those ids to `organizationRole.role`, and
the returned map carries both. The existing "drop entries with an empty name" filter stays — a node
that resolves to no user is still absent from the map, and the caller's `?? null` still applies.

**Renaming the method is deliberate.** It no longer returns names, and a method called
`resolveAgentNames` that returns objects is the kind of drift that makes a file harder to read every
time someone touches it.

### D8 — This lands after 17a

17a is editing `tenants.service.ts`'s read paths right now and has one task left; item 16 edits the
same file's `list` mapper and `resolveAgentNames`. Starting before 17a merges buys a rebase through
the exact function both are changing. **Wait for it.** 17b touches `admin-tenants.service.ts`, which
D1 keeps out of scope, so 17b is not a blocker.

## The FE↔BE contract

`GET /tenants` only. One field added; nothing removed, nothing renamed.

| Field | Before | After |
|---|---|---|
| `ownerOrgName` | `string` | unchanged — still sent, no longer rendered in the table |
| `agentName` | `string \| null` | unchanged |
| `agentRoleName` | — | **new**: `string \| null` — the owner's role name, resolved via `member.roleId` |

`agentRoleName` sits beside `agentName` rather than restructuring both into an `owner` object: three
web consumers and their fixtures read the flat fields today, and reshaping them is churn the request
does not ask for.

## Testing

**API** — `src/tenants/tenants.service.spec.ts`

- A tenant owned by a member with a role reports that role's **current** name.
- Renaming the role changes what the list reports on the next read — the test that proves D4, and
  the one that fails if someone reads `member.role`.
- A member with `roleId: null` reports `agentRoleName: null` while still reporting `agentName`.
- An owner node that resolves to no user still reports both as `null`, unchanged from today.

**Web** — `src/components/tenants/DealerTenantsTable.spec.tsx`

- The Owner cell shows the person and their role, and **does not** show the organization name. The
  existing fixture at `:13` already sets `ownerOrgName: 'Acme Dealer'` and `agentName: 'Dana Agent'`,
  so asserting the org name is absent is a real assertion, not a vacuous one.
- A null role shows `—` on the second line while the name still renders.
- A null name shows `—` on the first line independently.

`npm run build` is the real typecheck in the web repo.

## Non-goals

- **The admin tenant list.** D1.
- **A `createdBy` column, or creator attribution of any kind.** D2 — a migration and a cross-org
  display rule for a distinction invisible on almost every row.
- **Removing `ownerOrgName` from the response.** D6.
- **Reshaping `agentName`/`agentRoleName` into an `owner` object.** Churn across three consumers.
- **The rest of item 6's finding B3.** This closes the tenants-table half of it; whatever else that
  finding covers stays where it is.
