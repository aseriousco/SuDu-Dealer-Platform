# Add-organization: how the first admin gets its account

**Item 14.** Cross-repo — [`sudu-dealer-api`](../../sudu-dealer-api) and
[`sudu-dealer-web`](../../sudu-dealer-web). Written 2026-09-01.

Branches: `feat/org-admin-account-setup` in both repos. This spec is the contract between them;
each repo's plan is the authority on how its half is built.

## The request

> "change the add new organization, add the confirm password, how user get the password, display
> name"

Three fields on [`CreateOrganizationDrawer.tsx`](../../sudu-dealer-web/src/components/organizations/CreateOrganizationDrawer.tsx),
which today asks for the org (Name, Contact email, Billing address, Invoice notes) and then its
first admin: **Username, Password, Email, Phone** — and nothing else.

**Item 15 is deliberately not in scope** (the user's call, 2026-09-01). It regroups the *user*
form and is web-only; this spec is written so that stays true — see [Non-goals](#non-goals).

## Why this is not a three-field change

Two of the three asks need the API, and the reason is the same for both: **there are two
independent create-a-user paths, and only one of them ever learned anything.**

| | `UserService.create` | `OrganizationService.createAdminUser` |
|---|---|---|
| Password modes | all three | none — one literal password |
| Display name | `dto.name?.trim() \|\| dto.username` | hardcoded `name: admin.username` |
| Invite email | `markInviteIntent` → `requestPasswordReset` | — |
| `mustResetPassword` | written for `temporary` | — |

[`organization.service.ts:507`](../../sudu-dealer-api/src/organization/organization.service.ts:507)
is a fifteen-line copy that predates the password-mode work. So "give the org form the selector the
user form already has" is not a UI change with a DTO field bolted on; it is a decision about which
of those two paths owns the rule.

## What exists today

**API.** `CreateOrgAdminDto` declares exactly `username`, `password` (required, min 8), `email`,
`phoneNumber?`. There is no `passwordSetup` and no `name`. `OrganizationService.create` mints the
admin **before** its transaction, so the `catch` can `prisma.user.delete(...)` and let a retry with
the same username succeed — that ordering is load-bearing and this design keeps it.

`UserService.create` handles the modes across three places:
[`:99`](../../sudu-dealer-api/src/user/user.service.ts:99) mints a random password for `invite`;
[`:123`](../../sudu-dealer-api/src/user/user.service.ts:123) writes `mustResetPassword` for
`temporary`; [`:136`](../../sudu-dealer-api/src/user/user.service.ts:136) marks invite intent and
fires better-auth's reset flow. The invite path is wired end to end —
`markInviteIntent` → `requestPasswordReset` → `sendResetPassword`
([`auth.ts:210`](../../sudu-dealer-api/src/auth/auth.ts:210)) → `sendInviteEmail`. It reads SMTP
from the environment and depends on **no** database settings row, unlike the partner-interest
notification that fails locally.

**Web.** `CreateUserDrawer` already has the selector
([`:45`](../../sudu-dealer-web/src/components/users/CreateUserDrawer.tsx:46)) and hides the
password field entirely in `invite` mode. Confirm-password exists only on the two auth screens —
[`ForcedPasswordReset.tsx:29`](../../sudu-dealer-web/src/components/auth/ForcedPasswordReset.tsx:29)
and `routes/reset-password.tsx` — never on a create path.

## Decisions

### D1 — The org admin gets all three modes, and the selector is the user form's

`set` / `invite` / `temporary`, same values, same labels, same descriptions. Not a subset.

A narrower set was considered — dropping `set` so a platform admin can never hold a dealer admin's
standing password. Rejected because it makes two selectors that look alike and behave differently,
and the copy would have to explain why. `invite` is the mode this screen most wants (you are
creating another company's admin; relaying a password you chose is the weak option), and offering
it is what matters — not forbidding the others.

### D2 — The password-mode rule moves into one module; nothing is copied

New: `sudu-dealer-api/src/auth/password-setup.ts`.

```ts
export type PasswordSetupMode = 'set' | 'invite' | 'temporary';
export function passwordForMode(mode: PasswordSetupMode, typed: string | undefined): string;
export function mustResetPasswordFor(mode: PasswordSetupMode): boolean;
export function sendInviteIfNeeded(mode: PasswordSetupMode, email: string): Promise<void>;
```

`UserService.create` is refactored to call these; `OrganizationService.create` calls the same three.
The split follows the ordering the existing comments already spell out — one function before the
account is minted, one rule about a column, one side effect after the account is durable.

**`sendInviteIfNeeded` is the point of the extraction.** It owns the whole handshake: mark, request,
and `consumeInviteIntent` in the `catch` so a failed send cannot leave a mark behind to change the
copy of some later, unrelated reset email. That is the part that breaks silently if it is ever
maintained in two places, and after this change it exists once.

`mustResetPasswordFor` is a one-line predicate and looks like overkill. It is there so the rule is
named rather than restated as `mode === 'temporary'` in two services — see D3, where the two
callers apply it in genuinely different places.

Copying the logic into `OrganizationService` was the third option, and is the one the backlog
already warns against: it produces exactly the drift that split these two forms in the first place.

### D3 — In the org path the `temporary` flag joins the transaction

`UserService.create` has no transaction, so its `mustResetPassword` write stays exactly where it is —
a separate update after `provisionMember`, deliberately not caught. Only its condition changes, from
an inline `mode === 'temporary'` to `mustResetPasswordFor(mode)`.

`OrganizationService.create` does have one, and the admin's user row already exists before it opens.
So the flag is written **inside** it:

```ts
if (mustResetPasswordFor(mode)) {
  await tx.user.update({ where: { id: adminUserId }, data: { mustResetPassword: true } });
}
```

This is strictly better than mirroring the user path here. A failure rolls the whole create back and
the existing `catch` deletes the orphaned admin, so there is no state in which an organization exists
whose admin was asked for a temporary password and never got the flag. Putting the write after the
commit instead would produce that state, and putting it after the commit but *inside* the existing
`try` would be worse still: the `catch` deletes the admin user, and the organization has already
committed — leaving an org with no admin at all.

### D4 — The invite email is sent after the organization is durable, and a failed send stays non-fatal

`sendInviteIfNeeded` runs **after** the transaction commits and **outside** the cleanup `try`, for
the reason D3 gives: nothing in that `catch` may run once the org exists.

A failed send is logged, not thrown — the same choice `UserService.create` already documents. The
account and the organization are real by then; the admin can be re-invited, or use forgot-password.
Throwing would report a failed org creation for an org that exists, which is the worse lie.

**Consequence to state plainly:** in `invite` mode a successful `POST /organizations` does not prove
an email was sent. That is already true of `POST /users` and is not made worse here.

### D5 — Display name mirrors the username until it is edited, and falls back to it server-side

`CreateOrgAdminDto` gains `name?: string` (`@IsOptional @IsString @MaxLength(100)`), mirroring
`CreateUserDto.name` exactly. The hardcoded
[`name: admin.username`](../../sudu-dealer-api/src/organization/organization.service.ts:513) becomes
`name: admin.name?.trim() || admin.username` — the same expression `createAuthUser` already uses on
the user path.

The fallback therefore lives server-side, and the web only has to *say* so: an optional field whose
hint reads the way the user form's already does. **This is why item 15 stays web-only** — its
"Display Name (show the default value)" is asking for the placeholder, and the behaviour behind it
will already exist.

**Amended 2026-09-01, after implementation, at the user's request.** The paragraph above reads
"show the default value" as a *placeholder*. It is not — what was asked for is a real mirrored
value:

> "show the default display name as the username, but if user change the username, you have to
> change the display name also, but if user change the username and display name, then you no need
> to change the display name"

So `CreateOrganizationDrawer` fills the display name with the username as it is typed, carries it
along when the username is corrected, and **stops the moment the admin edits the display name** —
after which no username change touches it again. Implemented as a `adminNameTouched` flag rather
than an `adminName === adminUsername` comparison: clearing the field, or typing the username into it
by hand, both end the mirroring, because the rule is never to overwrite what a person typed.

Two consequences:

1. **The web now sends `name` on nearly every create**, where before it sent one only if someone
   typed it. The API contract is unchanged and the stored row is identical — the server already
   resolved `name || username` to the same string. Cleared and left empty, no `name` is sent and the
   server-side fallback below still applies, so it remains the single source of the rule.
2. **Item 15 inherits a stronger behaviour than this section originally promised.** It is still
   web-only, but "the behaviour behind it will already exist" now means the mirroring pattern too —
   `CreateUserDrawer` should mirror the same way, or the two forms drift, which is the thing
   splitting 14 and 15 was warned about.

### D6 — Confirm password is a web-only field, and only in `set` mode

The API never sees it; there is nothing to add to any DTO. It renders for `set` only.

**Amended 2026-09-01, after implementation, at the user's request** ("for temporary password, no
need to confirm password"). This section originally said the field renders for `set` **and**
`temporary`. It does not: a `temporary` password is one the admin is forced to replace on first
login, so confirming a throwaway value is friction with nothing to protect, and the field's own
reveal toggle already covers checking it for a typo. `invite` is unchanged and never had it — no
password is typed there, so there is nothing to confirm.

**The risk this accepts:** a mistyped temporary password is handed out as if it worked. Whoever
creates the organization relays a value the account does not have, and the admin cannot sign in to
reach the forced reset. The recovery is the same as any bad password — reset or re-invite.

The rule is the one the auth screens already use: the mismatch message appears only once something
has been typed into the confirm box, so an untouched form is never scolded. Submit is blocked on
mismatch through the drawer's existing `validate()` — which surfaces errors inline rather than
disabling the button, a property of this drawer worth preserving rather than working around.

Switching mode away from `invite` and back must not strand a typed value: the submit path already
drops the password in `invite` mode, and confirm follows the same rule.

### D7 — The API merges before the web

[`main.ts:71`](../../sudu-dealer-api/src/main.ts:71) sets `forbidNonWhitelisted: true`, so a body
carrying `passwordSetup` or `name` against today's API is a **400, not an ignored field**. The web
half is unshippable until the API half is merged. Same constraint as 17a, and for the same reason.

## The FE↔BE contract

`POST /organizations`, `admin` object only. Everything else on the route is unchanged.

| Field | Before | After |
|---|---|---|
| `username` | required | unchanged |
| `password` | **required**, 8–128 | **conditional** — required for `set`/`temporary`, must be absent for `invite` |
| `email` | required | unchanged |
| `phoneNumber` | optional | unchanged |
| `passwordSetup` | — | optional, `'set' \| 'invite' \| 'temporary'`; omitted ⇒ `set` |
| `name` | — | optional, ≤100 chars, free text (spaces allowed); omitted ⇒ the username |

**`name` is unchanged as a contract, but the web's use of it changed** — see D5's amendment: the
drawer mirrors the username into the field, so `name` is now present on nearly every create instead
of only when someone typed one. `omitted ⇒ the username` still holds and is still the server's rule;
it is simply reached less often.

`password` uses `@ValidateIf((o) => o.passwordSetup !== 'invite')`, copied from
[`create-user.dto.ts:44`](../../sudu-dealer-api/src/user/dto/create-user.dto.ts:44). **Omitting
`passwordSetup` keeps today's behaviour exactly**, so no existing caller changes.

Web mirror: `CreateOrgAdminInput` in
[`services/dealer-api.ts:904`](../../sudu-dealer-web/src/services/dealer-api.ts:904) — `password`
becomes `password?: string`, and `passwordSetup?` and `name?` are added, matching `CreateUserInput`.

## Testing

**API**

- New `create-organization.dto.spec.ts`, mirroring `create-user.dto.spec.ts`: no `passwordSetup`
  still requires a password; `invite` validates without one; `temporary` requires one; an unknown
  mode is rejected. The existing `update-organization.dto.spec.ts` is the pattern.
- `organization.service.spec.ts` has exactly one create test today
  ([`:207`](../../sudu-dealer-api/src/organization/organization.service.spec.ts:207)). Add one per
  mode: `set` unchanged; `temporary` leaves `mustResetPassword` true on the admin; `invite` creates
  an admin with no admin-chosen password and does not throw when the mailer fails.
- A `name` test: supplied, it lands on `user.name`; omitted, `user.name` is the username.
- **A regression test for D3**: when the transaction fails, no admin user survives. This is the one
  that would catch a later refactor moving the flag write back outside.

**Web**

- `CreateOrganizationDrawer` has **no spec file** — coverage lives in `OrganizationsView.spec.tsx`,
  where [`:229`](../../sudu-dealer-web/src/components/organizations/OrganizationsView.spec.tsx:229)
  ("creates an org with the org fields AND the nested admin") is the anchor. New cases go beside it
  rather than in a new file, so the existing render helper and mocks are reused.
- Per mode: `set` sends `passwordSetup: 'set'` with the password and is the only mode with a confirm
  field; `invite` renders no password or confirm field and sends neither; `temporary` renders the
  password field relabelled, no confirm field, and sends the password (D6 as amended).
- Confirm mismatch blocks submit and states why; an untouched confirm box shows no error.
- A typed password is dropped when the mode switches to `invite`.
- The display name mirrors the username while untouched and stops once edited, in both directions:
  a later username change must not overwrite an edited display name, and must still carry an
  untouched one (D5 as amended). Order matters in these tests — assert on document order, not just
  presence, since every other case finds fields by label and would not notice a reorder.
- Display name cleared sends no `name` (the server falls back); edited, it is trimmed and sent.

`npm run build` is the real typecheck in the web repo — `tsc --noEmit` passes without checking
anything.

## Non-goals

- **Item 15's regrouping of the user form.** Out of scope by decision. Nothing here changes
  `CreateUserDrawer`'s layout; the D2 refactor is server-side and invisible to it.
- **`notes` on the org admin.** `CreateUserDto` has it and `CreateOrgAdminDto` does not. Not asked
  for; adding it because it would be symmetrical is how scope grows.
- **Unifying the create drawer's org fields with `OrganizationFields`.** `CreateOrganizationDrawer`
  is the only one of the three org forms not using it, because create requires `name`/`contactEmail`
  while edit forbids sending them. A real divergence with a real reason — not this item's business.
- **Re-sending an invite.** There is no re-invite action anywhere today, for users or org admins.
  If `invite` becomes the common path, that gap is a new item.
- **Any change to who may create an organization.** `organization:create` still gates it.
