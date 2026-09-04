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
| `USERNAME_MIN` / `USERNAME_MAX` | 5 / 30 |
| `USERNAME_RE` | `/^[a-zA-Z0-9_.]+$/` |
| `PASSWORD_MIN` / `PASSWORD_MAX` | 8 / 128 |
| `ACCOUNT_FIELD_MAX.displayName` | 100 |
| `ACCOUNT_FIELD_MAX.email` | 254 |
| `ACCOUNT_FIELD_MAX.phoneNumber` | 32 |
| `ACCOUNT_FIELD_MAX.notes` | 2000 |

### `username` is 5–30 at our DTO but 3–30 at better-auth, and the difference is deliberate

Raising better-auth's `minUsernameLength` to match would break `/sign-in/username`, which
checks length **before** it looks the user up — two existing accounts are four characters
and could no longer sign in. The minimum therefore lives on the create DTOs, which is
complete because `disableSignUp: true` makes them the only path that mints a user. See the
spec's **D1**. Do not close this gap by configuring the `username()` plugin.

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
| `username` | yes | 5–30, `[a-zA-Z0-9_.]` only. Immutable after creation. Lowercased on save by better-auth; `displayUsername` keeps what was typed |
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

## Phone has a length, not a format

`phoneNumber` is capped at 32 and otherwise unvalidated on every account path. That is
deliberate: real phone validation needs a country, and the account forms have no country
field. 32 stays correct whatever that decision becomes — E.164 is at most 15 digits. The
public partner-interest form is the one phone field in the product that *is* format-checked;
it is not one of these endpoints.
