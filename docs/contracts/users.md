# Contract — users

The account fields of `/api/users`, `/api/me` and the password endpoints, and the rules
the API enforces on them.

Written from the account field-limits change
([spec](../specs/2026-09-03-account-field-limits-design.md)), so it covers **field
constraints and their error shapes** — not the whole area. Extend it the next time users
changes, rather than reverse-engineering the rest in bulk (see
[`README.md`](./README.md)).

Authorization is the API's decision alone; nothing here implies the web app enforces
anything.

## Where the numbers live

`sudu-dealer-api/src/common/account-limits.ts` is the authority. The web repo mirrors it
by hand in `src/lib/account-limits.ts`. **Change the API's copy first** — a form
advertising a limit the server has not agreed to is a promise the API never made.

| constant | value |
|---|---|
| `USERNAME_MIN` / `USERNAME_MAX` | 3 / 30 |
| `USERNAME_RE` | `/^[a-zA-Z0-9_.]+$/` |
| `PASSWORD_MIN` / `PASSWORD_MAX` | 8 / 128 |
| `ACCOUNT_FIELD_MAX.displayName` | 100 |
| `ACCOUNT_FIELD_MAX.email` | 254 |
| `ACCOUNT_FIELD_MAX.phoneNumber` | 32 |
| `ACCOUNT_FIELD_MAX.notes` | 2000 |

### `username` is 3–30, matching better-auth's own defaults

Both bounds are the plugin's defaults, so our DTO and better-auth agree exactly. The rule is
still enforced on the DTO rather than left to the plugin, because a DTO violation is a clean
`400` naming the field while the plugin's refusal used to surface as a `409`.

**`username()` stays UNCONFIGURED regardless.** Its `minUsernameLength` also gates
`/sign-in/username`, which checks length **before** it looks the user up, so changing it there
affects sign-in and not just creation. See the spec's **D1**.

The minimum was briefly 5; it is 3 at the platform's request, which also means the existing
four-character accounts are ordinary rather than a documented exception.

### `email` is bounded at 254, not 320

`@IsEmail()` is the gate that fires: validator.js refuses anything over its
`defaultMaxEmailLength` of 254, so a `@MaxLength` at or above that is unreachable. 254 is
what the API enforces and what the web mirrors. (RFC 5321's 320 is not the operative
number here.)

## `POST /api/users`

Creates a user in an organization, bound to one of its roles. Caller needs
`user:create`; a dealer admin may only create within its own organization, and
`organizationId` is honoured only for a platform admin.

| field | required | constraint |
|---|---|---|
| `username` | yes | 3–30, `[a-zA-Z0-9_.]` only. Immutable after creation. Lowercased on save by better-auth; `displayUsername` keeps what was typed |
| `email` | yes | valid email, ≤ 254 |
| `roleId` | yes | non-empty; the role must belong to the target organization |
| `password` | unless `passwordSetup: 'invite'` | 8–128 |
| `passwordSetup` | no | `set` \| `invite` \| `temporary`; omitted behaves as `set` |
| `name` | no | ≤ 100. Free text, **may contain spaces** — it is not a username. Falls back to `username` when omitted |
| `phoneNumber` | no | ≤ 32. Length only — **no format rule**; see below |
| `notes` | no | ≤ 2000 |
| `organizationId` | no | platform admin only; ignored for a dealer admin |

## `PATCH /api/users/:id`

Admin-edits contact fields and/or reassigns the role. Caller needs `user:update`. Every
field optional; the constraints are **identical to create** for each shared field —
`name` ≤ 100, `email` ≤ 254, `phoneNumber` ≤ 32, `notes` ≤ 2000.

`username`, `password` and `organizationId` are **absent from the DTO by design**, so a
body mentioning any of them is a `400` from `forbidNonWhitelisted` — immutability is
enforced by shape, never by an `if`.

## `PATCH /api/me`

Self-service. A member may change **only** `email`, `phoneNumber` and `notes`, under the
same limits. `name` is deliberately **not** editable here, and `username`, `role`,
`roleId` and `organizationId` are absent from the DTO — a body carrying one is a `400`,
so self-elevation is impossible by shape.

## `POST /api/me/password`, `POST /api/me/password/initial`

`newPassword` is 8–128. `POST /api/me/password` also requires `currentPassword`, which
better-auth verifies before applying the change, so a stolen session alone cannot rotate
a password.

## `GET /api/users/:id/deletion-impact`

**Why it exists.** Four foreign keys point at a member's `member_node` with
`ON DELETE RESTRICT` — `dealer_client.owner_member_node_id`,
`tenant_provisioning_request.owner_member_node_id`, `sale_event.member_node_id`, and
`member_node.parent_member_node_id`. A member who has done anything therefore **cannot be
deleted at all**, and before this endpoint the attempt surfaced as a raw `500`.

**Ownership is never transferred to make the delete succeed.** `SaleEvent` is an
append-only attribution ledger — its own schema docblock says who-sold-what cannot be
reconstructed after the fact — so re-pointing it during a delete would destroy the record
it exists to keep. When a user owns work, the remedy is **suspend**, not delete.

```jsonc
{
  "canDelete": false,
  "blockers": {                    // omit-nothing: every key present, zeros included
    "clients": 3,                  // dealer_client.owner_member_node_id
    "provisioningRequests": 14,    // tenant_provisioning_request.owner_member_node_id
    "saleEvents": 0,               // sale_event.member_node_id
    "reports": 0                   // member_node.parent_member_node_id — direct reports
  },
  "lastAdmin": false,              // deleting them would leave the org with no admin
  "self": false                    // the caller is this user
}
```

`canDelete` is `true` only when every `blockers` count is zero **and** `lastAdmin` and
`self` are both false. The web app must not re-derive it from the parts — the API owns
that judgement, and `DELETE` enforces the same three rules independently.

**`lastAdmin` and `self` are listed beside the counts on purpose.** They are the two
refusals `DELETE` already had, and an impact response that reported only the FK blockers
would let a dialog say "nothing blocks this" about a delete the API will still refuse.

**Authorization mirrors `DELETE /api/users/:id` exactly** — same permission, same scoping,
same at-or-below-actor bound. A caller who may not delete a user must not learn what that
user owns, so this endpoint answers `403`/`404` in precisely the cases the delete does.

**Modelled on `GET /api/organizations/:id/deletion-impact`**, which shipped in
[web#49](https://github.com/aseriousco/sudu-dealer-web/pull/49) and is consumed by
`DeleteOrganizationDialog`. That endpoint is not documented here; this one is, and the
organization one should be written up the next time organizations changes.

## `POST /api/users/:id/suspend`

**Its own refusals — `deletion-impact` does not predict a `suspend` call, only a `delete`
one.** A dialog that offers "Suspend instead" as the remedy for a blocked delete needs to
know suspend can itself be refused, in two cases `DELETE` does not share:

| refusal | message |
|---|---|
| suspending yourself | `You cannot suspend yourself` |
| suspending the last admin of an organization | `Cannot suspend the last admin of the organization` |

These are exactly the two conditions `deletion-impact` already reports as `self` and
`lastAdmin` — not new information, but the coincidence only holds because both endpoints
enforce the same no-self-service and at-least-one-admin invariants independently. A caller
offering "Suspend instead" for a blocked delete must gate the button on those same two
flags, or it hands back a guaranteed `400` for the two cases the feature is most likely to
meet: a sole org admin, or the signed-in operator's own account.

## Errors the web app branches on

**`400`** — validation. The body's `message` is a class-validator **`string[]`**, one
entry per broken rule, which the web app joins into a single sentence. It is also the
status for an unknown property, because the global pipe runs with
`forbidNonWhitelisted: true`.

**`409`** — **a genuine duplicate only.** Previously every `auth.api.createUser` failure
became this status with the sentence "username or email may already be in use", including
database outages; the web drawers print `err.message` verbatim, so an outage read as a
duplicate. Non-duplicate failures now surface as `500`. When branching on a duplicate,
note that better-auth words its two cases differently — `User already exists. Use another
email.` versus `Username is already taken. Please try another.`

**`403`** — the caller lacks the permission, or is reaching outside its own organization.

**`400` on `DELETE /api/users/:id`** — the user owns work that cannot be reassigned. The
message names the counts and offers the remedy: *"This user owns 3 tenants, 14 provisioning
requests, which cannot be reassigned. Suspend the account instead."* The web app prints
`err.message` verbatim, so this sentence is the user-facing copy — change it here and in
the API together. `DELETE` keeps enforcing this even when the client has already called
`deletion-impact`; the endpoint informs the dialog, it does not authorize the delete.

**Changing the four blockers is a three-place edit, not a one-place edit.** The nouns come
from the API's own message-building array in `delete()`; `deletion-impact`'s `blockers`
object mirrors the same four keys, which the web app re-mirrors again in its
`UserDeletionImpact` type and labels a third time in `DeleteUserDialog`'s `BLOCKER_LABELS`.
Add, rename or remove a blocker and all three need the edit. The FE's
`Record<keyof Blockers, string>` only guards the last of those three — that
`BLOCKER_LABELS` stays exhaustive against whatever the mirrored type says — it does not
know whether the API's message array or the type it mirrors were updated in the first
place.

## Phone has a length, not a format

`phoneNumber` is capped at 32 and otherwise unvalidated on every account path. That is
deliberate: real phone validation needs a country, and the account forms have no country
field. 32 stays correct whatever that decision becomes — E.164 is at most 15 digits. The
public partner-interest form is the one phone field in the product that *is* format-checked;
it is not one of these endpoints.
