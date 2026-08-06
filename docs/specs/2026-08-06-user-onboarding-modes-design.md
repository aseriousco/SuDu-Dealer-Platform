# User Onboarding Modes — cross-repo design

**Status:** approved — backfilled after the fact. API implemented; web not started.
**Repos:** sudu-dealer-api · sudu-dealer-web
**Branches:** `feat/user-onboarding-modes` (api) · `feat/user-onboarding-web` (web)
**Plans:** api → `sudu-dealer-api/docs/superpowers/plans/2026-08-05-user-onboarding-modes-api.md` · web → `sudu-dealer-web/docs/superpowers/plans/2026-08-06-user-onboarding-modes-web.md`

> **Backfilled 2026-08-06.** Both halves were designed independently and shipped a plan
> each with nothing above them stating the contract they share — the case named in
> [`../README.md`](../README.md). This document is written *from the merged API code*, not
> from either plan, so where a plan and the code disagree the code wins and the difference
> is recorded under [Drift found while backfilling](#drift-found-while-backfilling).

## Problem

An admin creating a user had exactly one option: type a password and hand it over
out-of-band. That forces the admin to invent, transmit, and remember a credential for
someone else, and the user never gets a password only they know.

Three modes are wanted at creation time:

| Mode | Who picks the password | Delivery |
|---|---|---|
| `set` | the admin | out-of-band, by the admin (today's behaviour) |
| `invite` | the **new user** | emailed set-password link |
| `temporary` | the admin, as a throwaway | out-of-band, then the user is pushed to change it on first login |

Affected planes: **org** and **platform** — both a dealer admin creating a user in its own
org and a platform admin creating one in a target org go through the same endpoint. No
client-plane (BladeX tenant) involvement.

## Contract

The web app reaches the API same-origin through Vite's `/api` proxy (see the root
[`CLAUDE.md`](../../CLAUDE.md) — always :5173, never :3001). The API's global prefix is
`api`, so the paths below are what the browser calls verbatim.

### `POST /api/users` — create a user

Request body gains one discriminator and relaxes one field:

```jsonc
{
  "username": "nia",
  "email": "nia@example.com",
  "roleId": "role_…",
  "passwordSetup": "set" | "invite" | "temporary",  // optional; omitted → "set"
  "password": "…"                                    // required for set/temporary; MUST be omitted for invite
  // name, phoneNumber, notes, organizationId — unchanged
}
```

- `passwordSetup` is validated with `IsIn(['set','invite','temporary'])`. **Omitted is legal**
  and means `set`, so every pre-existing caller keeps working unchanged.
- `password` is `@ValidateIf(passwordSetup !== 'invite')`, `MinLength(8)`, `MaxLength(128)`.
  For `invite` the field is **ignored** — the server mints its own random credential. The web
  side must not send one anyway (see [Web side](#web-side)).
- Response is the unchanged `UserView`. **`UserView` does not and will not carry
  `mustResetPassword`** — the flag is only ever the user's own, read from `/me`. An admin
  never sees another user's flag.

Per-mode server behaviour:

| `passwordSetup` | Password stored | Email sent | `mustResetPassword` after create |
|---|---|---|---|
| `set` (or omitted) | the admin's | none | `false` |
| `invite` | a random `base64url` credential the user never learns | **distinct invite copy**, via better-auth's reset flow | `false` |
| `temporary` | the admin's | none | **`true`** |

Errors the web app branches on:

| Status | When |
|---|---|
| `400` | `passwordSetup` not one of the three; `password` missing/short/long for `set`/`temporary`; `Role not found in the target organization` |
| `403` | caller lacks `user:create` |
| `409` | username or email already in use |

An `invite` whose email fails to send is **still a `201`** — the user exists and is
provisioned; the send failure is logged server-side and the admin re-invites or the user
uses forgot-password. The web app gets no signal and must not imply delivery succeeded.

### `GET /api/me` — the flag the gate reads

`MeView` gains one field:

```jsonc
{ "…": "unchanged", "mustResetPassword": true }
```

**The API always sends it, always as a `boolean`** — `MeService` coerces the nullable column
with `?? false`, so it is never absent and never `null`.

### Clearing the flag — two routes, and why there are two

| Route | Body | Who calls it |
|---|---|---|
| `POST /api/me/password` | `{ currentPassword, newPassword }` | the Profile screen, any ordinary password change |
| `POST /api/me/password/initial` | `{ newPassword }` | **only** the forced first-login screen |

New password is 8–128 on both. A wrong current password on the first is a `400`
`"Current password is incorrect"`. On success either route clears `mustResetPassword` itself,
so the web app learns the new state by **re-reading `/me`**, never by assuming it locally. The
emailed reset route (better-auth's `onPasswordReset`) clears it too, so a `temporary` user who
uses the link instead of the in-app screen is also unblocked.

**`/initial` omits `currentPassword` deliberately, and that is only safe because of its gate.**
The user typed the temporary password to reach the screen seconds earlier, so asking again is
friction without assurance. But `currentPassword` on the ordinary route exists to stop a stolen
session rotating the password, so `/initial` must never be reachable outside the first-login
state. It therefore:

- refuses with `400` unless the caller's `mustResetPassword` is true,
- reads that flag from the **database**, not from the actor — the flag is the entire
  authorisation for skipping the credential check, so it is never taken from a value that
  arrived on the request,
- clears it on success, making the route single-use.

Widen that gate and it becomes "rotate any password holding only a session". Accepted tradeoff:
during the first-login window, a stolen session can take the account permanently.

### The one rule both sides must agree on

**`mustResetPassword` enforcement is frontend UX, not authorization.** The API authenticates
a flagged user completely normally and blocks nothing. The web app renders a blocking screen
as a hygiene nudge. Neither side may describe it, document it, or rely on it as a security
boundary — the invariant is stated once in
[`sudu-dealer-api/CLAUDE.md`](../../sudu-dealer-api/CLAUDE.md) and is not restated here.

This is also why the flag is declared `input: false` in better-auth's `additionalFields`: no
DTO, no auth input, and no client can ever set it.

## API side

**Status: implemented** on `feat/user-onboarding-modes`.

- `CreateUserDto.passwordSetup` + conditional `password` (`src/user/dto/create-user.dto.ts`).
- `UserService.create` branches on the mode: `invite` mints `randomBytes(24).toString('base64url')`
  so a credential account exists for better-auth to own; `temporary` writes the flag via Prisma
  *after* provisioning succeeds.
- `invite` reuses better-auth's own `requestPasswordReset` — better-auth keeps ownership of the
  token and the `/reset-password` route. A transient module-level **invite-intent mark** on the
  address makes the single `sendResetPassword` callback render invite copy instead of
  forgot-password copy. The `reset-password:<token>` value is never hand-minted.
- New env var **`DEALER_WEB_URL`** (dev `http://localhost:5173`), used as the invite link's
  `redirectTo`. Its origin must also appear in `TRUSTED_ORIGINS` outside tests, or better-auth's
  origin check rejects the reset request; the API fails fast at boot if it does not.
- `mustResetPassword` cleared in two places: `MeService.changePassword` (in-app) and
  better-auth's `onPasswordReset` hook (emailed link).

## Web side

**Status: not started.** Plan written and committed; zero of its 20 steps done.

Dealer surface (`/`) and vendor surface (`/admin/*`) alike — this is shared-component work, not
a fork.

- **Create User drawer** (`src/components/users/CreateUserDrawer.tsx`): a radio group above the
  password field, defaulting to `set`. `invite` **hides the field, skips the length validation,
  and prunes `password` from the payload** — so a password typed before switching to `invite` is
  never transmitted. `temporary` relabels the field and explains the forced change.
- **Forced first-login screen** (`src/components/auth/ForcedPasswordReset.tsx`): new + confirm —
  **no current-password field** — posting to `/me/password/initial`. Composed from the same
  primitives the reset-password screen uses, and it has **no route of its own**. A log-out escape
  means a user who has lost the temporary password is never trapped.
- **The gate** (`src/components/auth/ForcedPasswordResetGate.tsx`): a layout route between
  `ProtectedRoute` (auth) and `DashboardLayout` (shell), wrapping the catch-all too, so there is
  no URL a flagged user can navigate around to. It reads `useMe()`:
  `isPending` → spinner; **`error` → fail open** (a transient `/me` failure must never lock
  someone out over a hygiene flag); `mustResetPassword === true` → the forced screen; otherwise
  `<Outlet />`. Unlocking is a `/me` refetch after a successful change — no reload, no
  client-side assumption.

## Drift found while backfilling

Recorded rather than silently fixed; each is a one-line change when the web plan is executed.

1. **`Me.mustResetPassword` optionality.** The API always sends a `boolean`. The web *design*
   types it `mustResetPassword: boolean`; the web *plan* types it `mustResetPassword?: boolean`.
   Either compiles and both work, because the gate tests `=== true`. The plan's optional form is
   the tolerant-reader choice and is fine — but the contract above, not the plan, is what the
   API guarantees.
2. **`onDone` wiring.** The web design writes `<ForcedPasswordReset onDone={refetch} />`; the
   plan writes `onDone={() => void refetch()}`. Cosmetic; the plan's form is correct if `refetch`
   returns a promise.

## Out of scope

- Any change to the authorization model, `resolveVisibleScope()`, or the `/me` shape beyond the
  one added field.
- Admin-facing display of another user's `mustResetPassword` — deliberately kept off `UserView`.
- "Invitation sent" toast feedback: the web app has no toast system, and the API cannot promise
  delivery anyway (see the `201`-on-send-failure note above).
- A shared `MeProvider` to dedupe the gate's and the Sidebar's `/me` fetches.

## Open questions

None. Both halves are settled; the web half is unimplemented, not undecided.
