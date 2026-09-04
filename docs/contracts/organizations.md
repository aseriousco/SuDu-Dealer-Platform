# Contract — organizations

The account fields of `/api/organizations` and the rules the API enforces on them.

Written from the account field-limits change
([spec](../specs/2026-09-03-account-field-limits-design.md)), so it covers **field
constraints and their error shapes** — not the whole area (limits, suspension, deletion
impact and the tenant relationship are not described here). Extend it the next time
organizations changes, rather than reverse-engineering the rest in bulk (see
[`README.md`](./README.md)).

Authorization is the API's decision alone; nothing here implies the web app enforces
anything.

## Where the numbers live

`sudu-dealer-api/src/common/account-limits.ts`, the same authority
[`users.md`](./users.md) names, mirrored by hand in the web repo's
`src/lib/account-limits.ts`. **Change the API's copy first.**

| constant | value |
|---|---|
| `ACCOUNT_FIELD_MAX.orgName` | 200 |
| `ACCOUNT_FIELD_MAX.email` | 254 |
| `ACCOUNT_FIELD_MAX.billingAddress` | 500 |
| `ACCOUNT_FIELD_MAX.invoiceNotes` | 2000 |

The nested admin's fields are the user constants — see [`users.md`](./users.md), which is
also where the deliberate 5-vs-3 username gap and the 254-not-320 email bound are
explained.

## Create and update now enforce identical rules

They did not before this change, and the divergence was one-directional: **create was the
weaker of the two.** `contactEmail` was bounded on update and unbounded on create; `name`
rejected a whitespace-only rename but accepted a whitespace-only *create*, so `'   '`
could be introduced and then never edited to anything else. Both paths now read the same
constants.

This matters to the web app specifically because the client trims before sending, which
hid the `name` case entirely. A client-side trim is not the rule — the API is.

## `POST /api/organizations`

Creates an organization and auto-provisions its dealer admin, in one call. Caller needs
`organization:create` (platform plane).

| field | required | constraint |
|---|---|---|
| `name` | yes | non-blank (**not** merely non-empty — `'   '` is rejected), ≤ 200 |
| `billingAddress` | yes | non-empty, ≤ 500 |
| `contactEmail` | yes | valid email, ≤ 254 |
| `invoiceNotes` | no | ≤ 2000 |
| `admin` | yes | the nested object below |

### `admin` — the auto-provisioned dealer admin

| field | required | constraint |
|---|---|---|
| `username` | yes | 5–30, `[a-zA-Z0-9_.]` only. Immutable after creation |
| `email` | yes | valid email, ≤ 254 |
| `password` | unless `passwordSetup: 'invite'` | 8–128 |
| `passwordSetup` | no | `set` \| `invite` \| `temporary`; omitted behaves as `set` |
| `name` | no | ≤ 100. Free text, may contain spaces. Falls back to `username` |
| `phoneNumber` | no | ≤ 32, length only — no format rule |

An unknown property on the nested `admin` is a `400`, same as at the top level.

## `PATCH /api/organizations/:id`

Caller needs `organization:update`; a dealer holding it edits **its own** organization.
Every field optional, and each constraint is identical to create: `name` non-blank ≤ 200,
`contactEmail` ≤ 254, `billingAddress` non-empty ≤ 500, `invoiceNotes` ≤ 2000.

`slug` is **not** editable and never will be — it is assigned once at creation, and a
rename that moved it would silently repoint anything holding the old value. A body
carrying it is a `400`.

## Errors the web app branches on

**`400`** — validation; `message` is a class-validator **`string[]`** the web app joins
into one sentence. Also the status for an unknown property (`forbidNonWhitelisted: true`).

**`409`** — a genuine duplicate only, raised while minting the admin user. As on
`POST /api/users`, non-duplicate `createUser` failures now surface as `500` rather than
borrowing the duplicate's wording, which the create-organization drawer prints verbatim.

**`403`** — the caller lacks the permission, or is editing an organization other than its
own without the platform-plane right to do so.

## Related

`DELETE` is `POST /api/organizations/:id/delete`, and its `confirmName` must equal the
organization's `name` exactly. It shares `ACCOUNT_FIELD_MAX.orgName` for that reason: were
the two capped independently, raising the name limit would leave a long-named organization
unable to be confirmed, and so undeletable.
