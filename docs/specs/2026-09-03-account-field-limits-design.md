# Account field limits: making every layer agree

**Item 27.** Cross-repo: `sudu-dealer-api` and `sudu-dealer-web`.

## The request

> "check the max/min character for all account name, username, password, and email and phone
> format validation"

That was answered as an audit (item 27 in the task backlog). This spec is the change that
follows it, scoped by a later instruction: **fix the six disagreements, and require a minimum
of five characters for every username.** Phone *format* was explicitly deferred — see
[Non-goals](#non-goals).

## The correction this spec starts from

The audit's `username` row says the web form has "required; no length, no charset", and its
disagreements #3 and #4 are built on that. **It is wrong.**
`sudu-dealer-web/src/lib/username.ts` already exists and enforces better-auth's whole rule —
3–30 characters, `/^[a-zA-Z0-9_.]+$/` — exports a `USERNAME_HINT`, and has its own spec file.
Both create drawers call `usernameError()` and render the hint beneath the field, replacing it
with the error when invalid.

The audit was written by reading the drawers' JSX and missing the imported helper. The
direction of the username fix therefore inverts: **the client is the correct layer here; the
API DTOs are the wrong one.** Two of the six disagreements dissolve into "mirror the client's
existing rule into the DTO".

This also means the shape this spec adopts is already half-built: `src/lib/username.ts` *is*
the named rules module, on the web side. The API has no equivalent.

## What exists today

Verified against the code on 2026-09-03, not carried over from the audit.

Three facts frame everything below:

- **The database caps nothing.** Every field here is Prisma `String` → Postgres `text`. The
  only `@db.VarChar` in the schema is `currency(3)`. The DTO is the last gate for everything
  except username and password.
- **better-auth's defaults are the rule for those two.** `auth.ts:236` calls `username()` with
  no options, and nothing overrides `emailAndPassword` password lengths. So: username **3–30**,
  `/^[a-zA-Z0-9_.]+$/`, **lowercased on save** (`displayUsername` keeps what was typed);
  password **8–128**. (better-auth's own doc comment for the validator says "alphanumeric
  characters and underscores" and omits the dot. The source at
  `plugins/username/index.mjs:12` is authoritative; the dot is allowed.)
- **Self-service sign-up is closed.** `disableSignUp: true` (`auth.ts:203`). Users exist only
  because `UserService.create` or `OrganizationService.create` minted them, and both go through
  a DTO. **There is no other path that creates a user.** This is what makes a DTO-level rule a
  complete rule.

| field | DB | API DTO | better-auth | web form |
|---|---|---|---|---|
| org `name` | text | create `IsNotEmpty` + **200**; update `Matches(/\S/)` + **200** | — | required + trimmed; no `maxLength` |
| org `contactEmail` | text | create `IsEmail` **only**; update `IsEmail` + **320** | — | `EMAIL_RE`, `type=email`; no `maxLength` |
| `billingAddress` | text | **500** both | — | required; no `maxLength` |
| `invoiceNotes` | text | **2000** both | — | no `maxLength` |
| `username` | text | org admin **64**; user **none** (`IsNotEmpty` = ≥1) | **3–30**, `[a-zA-Z0-9_.]`, lowercased | **3–30 + charset + hint** (`lib/username.ts`) |
| display `name` | text | create **100** (both drawers); update **none** | — | no `maxLength` |
| `password` | n/a | **8–128** in all four DTOs | **8–128** | `length < 8` only — **no maximum** |
| `email` (user/admin) | text | `IsEmail`, no length | — | `EMAIL_RE`, `type=email` |
| `phoneNumber` | text | org admin **32**; user **none**; update **none** | — | bare `<Input>` — nothing |
| `notes` | text | **none** in create, update, or update-me | — | no `maxLength` |

## The disagreements, restated

| # | as audited | status after re-reading the code |
|---|---|---|
| 1 | DTOs say 64 / unlimited; the real cap is 30 | **stands** — the core fix |
| 2 | a validation failure arrives as a `409` | **shrinks** — see [D6](#d6--a-validation-failure-is-never-a-409) |
| 3 | the minimum is 3 and nothing says so | **wrong** — the client says so; becomes "raise to 5, mirror into the DTO" |
| 4 | no form documents the charset | **wrong** — both do; becomes "mirror the charset into the DTO" |
| 5 | create is weaker than update on org fields | **stands** |
| 6 | display name capped at create, uncapped at update | **stands** |

Two the audit missed, same class, folded in here: the **web password field has no maximum**
against the DTO's 128, and **`notes` is uncapped in all three DTOs** that carry it.

## Principles

1. **Our layer is never looser than the layer behind it.** Every cap we state must be one the
   next layer down will also accept. A DTO that accepts 64 characters in front of a store that
   accepts 30 is not a limit, it is a delayed failure.
2. **A create rule goes on the create path, never on a shared lookup.** Item 24 established
   this for subdomains. It matters more here — see [D1](#d1--the-username-minimum-goes-on-the-dtos-not-on-better-auth).
3. **Where two paths disagree, the stricter one wins and both then read the same constant.**
   Disagreements #5 and #6 exist because create and update carry separately-typed numbers for
   the same field. Copying the stricter number fixes the instance; sharing the constant fixes
   the class.

## Decisions

### D1 — The username minimum goes on the DTOs, not on better-auth

`username()` accepts `minUsernameLength`. **Do not use it.** The option feeds three call sites
in the plugin, and only one of them is creation:

| site | `index.mjs` | what a minimum of 5 would do |
|---|---|---|
| `user.create.before` DB hook | 38 | enforce it on create — the wanted effect |
| **`/sign-in/username`** | 160 | **`422 USERNAME_TOO_SHORT`, thrown *before* the user lookup** |
| `/is-username-available` | 239 | a short name answers "invalid", never "taken" |

The dev database holds 15 users, 8 of which carry a username — and **two of those are four
characters** (`dong`, `jojo`). Setting the option stops those accounts using
`/sign-in/username` at all. Our own login sends `signIn.email` (`login.tsx:26`), so nobody is
locked out of the dealer app — but it is a live behaviour change on a public endpoint, bought
for nothing.

**The rule instead lands as `@MinLength(5)` on the two create DTOs**, which is complete rather
than partial: `disableSignUp: true` means those DTOs are the only path that mints a user.

This is principle 2, in a place where it bites harder than it did for item 24. There, a
minimum on the shared subdomain regex would have stranded existing short tenants from being
*found*. Here, a minimum on the shared username option strands existing short accounts from
*signing in*.

### D2 — The numbers get one home per repo

**API — new `src/common/account-limits.ts`**, beside `reserved-subdomains.ts`, imported by all
four DTOs (`create-user`, `update-user`, `create-organization`, `update-organization`) so that
create and update cannot drift apart again:

```ts
/** Mirrors better-auth's username plugin, which we deliberately leave unconfigured — see the
 *  spec's D1. Ours is stricter at the minimum (5 vs 3) and must NEVER be looser at the
 *  maximum: 30 is what the plugin will accept, and anything we allow past it dies there. */
export const USERNAME_MIN = 5;
export const USERNAME_MAX = 30;
export const USERNAME_RE = /^[a-zA-Z0-9_.]+$/;

/** Mirrors better-auth's emailAndPassword defaults, also unconfigured. */
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 128;

export const ACCOUNT_FIELD_MAX = {
  displayName: 100,
  email: 320,
  orgName: 200,
  billingAddress: 500,
  invoiceNotes: 2000,
  notes: 2000,
  phoneNumber: 32,
} as const;
```

**Every number here except `USERNAME_MIN` already exists** on the stricter side of a
disagreement, or as the agreed value in both DTOs. Nothing is invented. `notes: 2000` is the
one gap-fill, and it takes `invoiceNotes`'s number because it is the same kind of field.

**Web — `src/lib/username.ts` gains the minimum**, and a sibling `src/lib/account-limits.ts`
carries the rest, mirrored by hand with a comment naming the API as the authority — the rule
`ORCHESTRATOR_FIELD_MAX` and `INITIAL_PASSWORD_RULE` already follow.

### D3 — Create adopts update's stricter rule, never the reverse

Two changes, no new numbers:

- **`CreateOrganizationDto.contactEmail`** gains `@MaxLength(320)`, matching update.
- **`CreateOrganizationDto.name`** gains `@Matches(/\S/)`, matching update. Update's own
  comment already spells out why: `IsNotEmpty` alone lets a whitespace-only value "silently
  blank out the org's display name". The client trims before sending, so the UI hides this
  today — which is exactly the arrangement the web repo's hard boundary 2 says not to rely on.

### D4 — Display name is capped on update at the same 100 as create

`UpdateUserDto.name` gains `@MaxLength(ACCOUNT_FIELD_MAX.displayName)`. A name created under
100 characters can currently be renamed to any length at all.

`UpdateMeDto` is deliberately untouched: it carries no `name` field, because self-service edits
only email, phone and notes.

### D5 — The two gaps the audit missed are closed with it

- **`notes`** gains `@MaxLength(ACCOUNT_FIELD_MAX.notes)` in `CreateUserDto`, `UpdateUserDto`
  and `UpdateMeDto`. Today an unbounded string reaches a `text` column on three paths.
- **The web password field gains a maximum.** `password.length < 8` is the whole client rule;
  a 200-character password is accepted, submitted, and 400s. Both create drawers gain the
  128 bound.

### D6 — A validation failure is never a `409`

Today both `createAuthUser` and `createAdminUser` catch *every* `auth.api.createUser` failure
and rethrow `ConflictException` — "Could not create the user (username or email may already be
in use)". The real code (`USERNAME_TOO_LONG`, `INVALID_USERNAME`) is appended, so it is not
hidden; it is led with the wrong sentence under the wrong status. The web drawers pass
`err.message` straight through (`errorMessage()` in `lib/api-error.ts`), so a user genuinely
reads that sentence.

**D1's DTO rules dissolve most of this.** Once the DTO enforces 5–30 *and* the charset, a
username that better-auth would reject can no longer reach it — `jo admin` is stopped at the
DTO with a message that names the actual problem.

What remains is the catch itself, which still reports an infrastructure failure as "username or
email may already be in use". **Narrow it**: rethrow `ConflictException` only for a genuine
duplicate, and let anything else surface as a `500` rather than a confident, wrong `409`.

### D7 — `maxLength` mirrors the DTO; a counter only where the cap is tight

The repo already has this policy, written and tested, on the one form that follows it:
`partner-interest.spec.tsx:167` — *"mirrors the API's DTO limits as HTML attributes so most
invalid inputs never reach the server"* — paired with a `400` handler that shows the server's
own sentence verbatim, precisely because a DTO limit may have no HTML mirror. The finding that
the public form is stricter than the staff forms is not a coincidence: it is the only form
following a policy nobody wrote down for the others.

**The account forms adopt the same two-part policy.** `maxLength` on every capped field, and
the server's message shown verbatim as the backstop — the second half already works, since
`errorMessage()` returns `err.message` and `extractError` joins class-validator's `string[]`
into one sentence.

**`FieldLimit` is not extended to these forms.** It exists because the orchestrator's caps are
*tight* — 10 characters for Real name — and `maxLength` swallows the refused keystroke in
silence. A live counter under a 200-character organization name is noise. It stays in
`create-tenant/`.

Two rules `maxLength` cannot express, which therefore stay as inline text:

- **The minimum.** `usernameError()` already returns a sentence for it; only the number and the
  hint change (3 → 5).
- **The lowercasing.** better-auth stores `username` lowercased and keeps the typed form in
  `displayUsername`. No form says so today, and `USERNAME_HINT` is where it belongs.

### D8 — Phone: the length is aligned, the format is untouched

`phoneNumber` is capped at 32 on `CreateOrgAdminDto` and uncapped on the other three paths.
That is the same create/update drift as D3 and D4, so it is fixed the same way — 32 everywhere,
from `ACCOUNT_FIELD_MAX`.

**No format rule, no `type="tel"`, no minimum.** See [Non-goals](#non-goals): the format
question is deferred and is larger than it looks. A 32-character cap remains correct whatever
that question decides — E.164 is at most 15 digits.

### D9 — The email regex gets one home, and keeps its strictness

`/^[^\s@]+@[^\s@]+\.[^\s@]+$/` is exported from `create-tenant/data.ts` and **re-declared
verbatim** in `CreateUserDrawer.tsx:43` and `CreateOrganizationDrawer.tsx:50`. It moves to
`src/lib/email.ts`, matching `lib/username.ts`'s shape; `create-tenant/data.ts` re-exports it
so item 24's imports keep working.

**Its strictness does not change.** It is looser than the server's `@IsEmail()`, so the failure
direction is the safe one: an odd address reaches the API and returns a `400` whose message the
drawers already display. Tightening it to match validator.js is a behaviour change nobody asked
for, and it belongs to whoever next has a reason.

### D10 — The API merges before the web

The API half has no conflict with anything in flight. The web half touches
`CreateOrganizationDrawer` (**item 22**, implemented, unmerged, still blocked on its visual
check) and `CreateUserDrawer` (**item 21**, not started, and its own spec already plans to move
this exact markup).

So: **the API plan lands first and independently.** The web plan rebases onto `main` after item
22 merges. Landing them in the other order guarantees a conflict in two files that two other
items are already rewriting.

## The FE↔BE contract

`docs/contracts/` is populated per area, and its README names `users.md` as a first candidate
for exactly this reason. This work seeds two files with the field constraints it settles —
**`docs/contracts/users.md`** and **`docs/contracts/organizations.md`** — rather than one
`accounts.md`, because "accounts" is not an area on either side.

Each records, for the endpoints this spec touches: the field, its constraint, which layer
enforces it, and the status code a violation returns. Neither file attempts to document its
whole area — the README is explicit that a contract written from a diff you just made is
accurate and one reverse-engineered in bulk is guesswork.

The single most important line in both: **username is 5–30 and `[a-zA-Z0-9_.]` at our DTO,
3–30 at better-auth, and the difference is deliberate** — so that nobody later "fixes" the
mismatch by configuring the plugin and locking out the short accounts.

## Testing

- **API** — DTO specs are the natural home and already exist for the tenant DTOs. Per field
  changed: the boundary accepted, the boundary + 1 refused, and the message naming the field.
  Username gets the four-character case explicitly, since 4 is valid to better-auth and invalid
  to us.
- **`account-limits.ts` needs no test of its own.** It is data. What needs a test is that a DTO
  reads it — a hard-coded `@MaxLength(100)` that happens to match is the drift this spec exists
  to prevent.
- **The narrowed catch (D6)** gets a test that a non-duplicate `createUser` failure is not
  reported as a `409`.
- **Web** — `username.spec.ts` gains the 4-character case. The attribute mirror is asserted the
  way `partner-interest.spec.tsx` already asserts it, so the two forms are checked identically.
- **The counting caveat.** Both repos' suites are large; a plan that quotes a baseline total
  must measure it on the branch rather than carry a number from another document.

## Non-goals

- **Phone format.** Deferred deliberately. `sudu-dealer-web/src/lib/phone.ts` already validates
  numbers properly with `libphonenumber-js/max` — but it validates *against a country*, and
  partner-interest pairs the field with a `COUNTRY_OPTIONS` picker. The internal account forms
  have **no country field at all**, so doing this properly means either adding a country column
  to `User` or requiring `+`-prefixed input. That is a schema-or-UX decision, and it gets its
  own item.
- **Configuring better-auth's `username()`.** D1 is the whole reason. Whether 30 and the silent
  lowercasing are the rules we *want* is a real question and is not this one.
- **Tightening the client email regex** to match `@IsEmail()`. D9.
- **The tenant wizard's four `initial_user` fields.** Item 24 owns them; they are the same class
  of bug on a different path and are already fixed.
- **Any change to `SUBDOMAIN_RE`, `SLUG`, or the claim flow.** Untouched here, as in item 24.
