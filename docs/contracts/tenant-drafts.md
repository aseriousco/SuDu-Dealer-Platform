# Contract — tenant drafts

`/api/tenant-drafts` — a dealer's saved, incomplete tenant registrations. Written from the
draft feature itself ([spec](../specs/2026-08-21-tenant-draft-design.md)) and updated for
the customer block and organization tree the wizard rework added
([spec](../specs/2026-09-09-tenant-creation-wizard-design.md)), so it covers **the body
shape, the PATCH semantics, and where a draft's validation is weaker than submit's** — not
every field's format rule; those are the API's own DTOs
(`sudu-dealer-api/src/tenant-draft/dto/tenant-draft.dto.ts`). Extend it the next time this
area changes, rather than reverse-engineering the rest in bulk (see
[`README.md`](./README.md)).

Authorization is the API's decision alone; nothing here implies the web app enforces
anything. `SessionGuard` only — every route is scoped to the caller's `organizationId`,
and any dealer member may read or resume a colleague's draft (see the spec's Q1).

## The absent / null / value rule — applies to every field on this route

`PATCH /api/tenant-drafts/:id` (and, equivalently, what `POST` writes on create) treats
every field in the body the same three ways:

| The body | Means |
|---|---|
| key **absent** | leave the stored value untouched |
| key present, value **`null`** | clear the stored value |
| key present, a **value** | replace the stored value |

This is not a per-field rule with exceptions — it is the whole of `PATCH`'s contract on
this route, for a scalar field (`slug`, `planId`, `tenantAdmin.password`, …), for the
**customer block**, and for the **organization tree**, with no field-by-field carve-out.
A caller that omits a key is never read as "clear this," on any field.

**The customer block is granular at the sub-field level.** `customer` itself being absent,
`customer: null`, or `customer` present but missing one of its six values all leave every
corresponding column untouched — a PATCH may set `customer.userLimit` alone and leave the
other five as they were. Clearing is done per field: sending `customer.userLimit: null`
clears only that one column, and there is no way to clear the whole block in one key,
because a wizard that has not reached that step must not be able to wipe it by accident.

That per-field `null` is the third case in full, on all six, and **`waAbleRead` is not an
exception**. `waAbleRead: 0` means "no WhatsApp AI Read"; `waAbleRead: null` means the
dealer has not decided. They are stored differently and read back differently — a client
must not send `null` meaning `0`, or `0` meaning "not answered".

**The organization tree is one clearable value, not six.** There is no "tree minus one
organization" partial-write case — `organizationSetup` absent leaves the whole stored tree
untouched, `organizationSetup: null` clears the whole tree, and any other value replaces
it whole. A caller that means to remove one organization from the tree resends the entire
tree without it; it does not omit the key.

**Do not build a client that resends the whole form on every save and calls that "the same
as omission."** That was tried here: an earlier version of the API cleared
`organizationSetup` whenever the key was absent, reasoning that the one caller at the time
always either resent the whole tree or left the key out entirely. It was wrong the moment
a second caller (or a smaller PATCH from the same caller — editing just `clientName`, say)
disagreed, and it destroyed a saved organization tree silently, under an `@Audit`ed route
that logs it as an ordinary update. The rule above is the API's actual contract, not a
description of what today's caller happens to send.

An empty string on a text field (`slug`, `email`, …) is normalized to `null` on write —
the wizard clears an input by emptying it, not by removing the key, so `''` has to mean
the same thing `null` does.

## Body — `POST /api/tenant-drafts` and `PATCH /api/tenant-drafts/:id`

Both routes take the same shape. `clientName` is the only required field, and it is
required on **create** only — a `PATCH` may omit it too, per the rule above.

```ts
interface TenantDraftBody {
  clientName: string;
  slug?: string | null;
  account?: string | null;
  name?: string | null;
  realName?: string | null;
  email?: string | null;
  expireTime?: string | null;        // YYYY-MM-DD
  planId?: string | null;
  accountingType?: 'SQL' | 'ATC' | null;
  tenantAdmin?: { username?: string | null; password?: string | null };
  customer?: {
    organizationLimit?: number | null;
    userLimit?: number | null;
    waNumberLimit?: number | null;
    waAbleRead?: 0 | 1 | null;        // null is "not decided", NOT 0
    totalPricePerMonth?: string | null;  // decimal string, never a JS number
    status?: 'Demo' | 'Pre-Live' | null;
  } | null;
  organizationSetup?: {
    default?: { departments?: { deptName?: string }[] };
    additional?: {
      organizationName?: string;
      accounting?: { type?: 'SQL' | 'ATC' };
      departments?: { deptName?: string }[];
    }[];
  } | null;
}
```

## A draft accepts a partial organization; submit does not

Every field under `customer` and `organizationSetup` is optional on a draft, down to the
individual department. An organization with no `departments`, one with `departments: []`,
an organization name that is one character long (mid-typing), and an organization or plant
name that is the **empty string** are all **legal on a draft save**. Saving is an explicit
action — a dealer clicks Save, this is not autosave — so refusing a half-typed organization
here would lose the dealer's work over content they had not finished typing. See the design
spec: *"Refusing a draft for being incomplete would defeat the feature."*

`''` on a name is the same rule as `''` on any other text field above: the wizard clears an
input by emptying it, so an emptied name is **not yet filled**, not an invalid name. The
character-set rule below is skipped for that one value and applies to every other.

**None of that applies to `POST /api/tenant-drafts/:id/submit`.** Submit's body is the
ordinary provisioning create body (`CreateProvisioningRequestDto`), with the real rules:
`customer`'s five values are all required, every organization needs a non-empty
`departments` array and an `accounting.type`, organization and plant names may not be
empty, and organization names have a minimum length. The same tree that saved cleanly as a
draft is refused at submit if it is still incomplete — that gap is the point of having a
separate, permissive draft shape rather than reusing the submit DTO for both.

Shape rules that are **not** about completeness — an organization name's character set, no
two departments in one organization sharing a name — apply on the draft too, because those
are true regardless of whether the dealer is finished. A name that is *absent or empty* is
about completeness and is therefore a submit-only rule.

## `TenantDraftView` — the customer block and organization tree, on read

```ts
interface TenantDraftView {
  // …the fields already documented in the design spec, plus:
  customer: {
    organizationLimit: number | null;
    userLimit: number | null;
    waNumberLimit: number | null;
    waAbleRead: boolean | null;
    totalPricePerMonth: string | null;  // ALWAYS a string
    status: string | null;
  };
  organizationSetup: unknown;
}
```

`customer` is six **independently** nullable fields, not one block that is either fully
real or entirely absent — unlike `ProvisioningRequestView.customer` on a submitted
request, a draft is genuinely partial by nature and there is no "all or nothing"
invariant to enforce on it.

`organizationSetup` comes back **verbatim**, typed `unknown` — the same treatment the
audit trail gives arbitrary metadata. It is read back whole to reseed the wizard's form
and is never re-validated or re-interpreted by the API on the way out.

## Related

[`docs/specs/2026-08-21-tenant-draft-design.md`](../specs/2026-08-21-tenant-draft-design.md)
is the original design — routes, status codes, the password-handling rules (Q2), and the
submit-handoff guarantee. This file only adds the customer block, the organization tree,
and the absent/null/value rule those two additions made worth writing down explicitly.
