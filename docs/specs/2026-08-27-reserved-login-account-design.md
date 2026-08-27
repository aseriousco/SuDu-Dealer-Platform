# Reserved login account — cross-repo design

**Status:** approved (2026-08-27)
**Repos:** sudu-dealer-api · sudu-dealer-web
**Branches:** `feat/reserved-login-account` (both)
**Plans:** api → [`2026-08-27-reserved-login-account-api.md`](../../sudu-dealer-api/docs/superpowers/plans/2026-08-27-reserved-login-account-api.md) · web → [`2026-08-27-reserved-login-account-web.md`](../../sudu-dealer-web/docs/superpowers/plans/2026-08-27-reserved-login-account-web.md)

## Problem

The tenant-creation wizard collects two credentials that are **two different identities**, and
lets them be the same one.

- **Login account** (`initialUser.account`) — the tenant's day-to-day administrator, the person
  the dealer's customer signs in as.
- **Username** (`tenantAdmin.username`) — the tenant's built-in **ROOT** account, the identity
  the *orchestrator* authenticates as to service the tenant.

Today a dealer may set Login account to `admin`, and may set it to whatever they typed as
Username. Both are accepted, stored, and forwarded upstream.

Two rules are wanted, on the **frontend and the backend**:

1. `admin` is not an allowed Login account.
2. Login account and Username must differ.

**The backend rule is the one that matters.** The frontend check is a courtesy; the API must
refuse, and must never forward `admin` as the login account to the tenant orchestrator. Hiding
a control is UX — the API is the authority. (`sudu-dealer-web/CLAUDE.md`, hard boundary 1.)

Affected plane: **org** (dealers creating tenants at `/tenants/new`). The platform plane has no
create route of its own, so it inherits whatever this route enforces.

### Why the collision matters

If Login account and Username name the same account, two different people — the dealer's
customer and the orchestrator — hold one credential. Either can change the password out from
under the other; a customer rotating their own password can lock the orchestrator out of the
tenant it is supposed to service.

### What is NOT already covered

`isBuiltInTenantAdmin` exists in both repos and looks adjacent, but is a different rule. It
returns true only when the username is `admin` **and** the password is `admin`, blocking the
default *pair* — because sending that pair asks for what the tenant already has while making
the orchestrator run a step that fails when `TENANT_CREDENTIAL_KEY` is unconfigured.

It says nothing about the Login account, and nothing about the two fields colliding. **Neither
rule below exists today.** Do not mistake one for the other.

## Decisions

| | Question | Decision |
|---|---|---|
| Q1 | Is `admin` the only reserved word, or the start of a list? | **`admin` only.** |
| Q2 | Which error copy? | **"'admin' is not allowed for account name"** |
| Q3 | Tenants already provisioned with `admin`? | **Left alone.** New provisioning only. |
| Q4 | How are the values compared? | **Trimmed, case-insensitive**, both rules. |
| Q5 | Is saving a *draft* with `admin` blocked? | **No.** Submit is the gate. |
| Q6 | Rule 2's error copy? | **"Login account and username must be different"** |
| Q7 | Where does rule 2's error appear? | **Both fields marked invalid; the message shown once, under Username.** |

### On Q1 — one word, not a list, and not the subdomain list

`src/common/reserved-subdomains.ts` already exists and is tempting: a reviewed, unit-tested
code constant that the web never duplicates, reading verdicts from the API instead. That
**pattern** is the right one and this follows it.

Its **contents** are not. `RESERVED_EXACT` blocks `mail`, `test`, `abc`, `foo`, `dev`, `api`
and ~200 more, because a DNS label is a public, phishing-shaped namespace. A login account
inside one tenant is not that namespace, and refusing a customer named `mail` would be
nonsense. The two lists must stay separate even though both contain `admin`.

So: one word. `administrator` and `root` are visible gaps and may well be reported later —
they are cheap to add to the same predicate when they are, and that is a better trade than
guessing at a policy nobody has asked for.

### On Q2 — "not allowed", not "not available"

*"Login Account not available"* describes a collision, and invites the dealer to try `admin2`
until something sticks. Nothing is taken; the name is refused as policy. **Ship one string,
not both.**

The chosen copy names the offending value and the field it was rejected from — *"'admin' is not
allowed for account name"* — rather than restating the label back at the dealer. It reads the
same whether it arrives from the API or is raised locally, which matters because both paths
render it.

Casing follows the field label: the input is **Login account**, so neither message capitalises
"Account", and rule 2 lowercases "username" for the same reason. The two errors can appear on
one screen, and a capital in one and not the other reads as two different systems talking.

### On Q3 — nothing migrates

Existing tenants keep working. Changing a live customer's login account is a support action
against a running tenant, not something a validation rule may do retroactively. The rule gates
new provisioning; it makes no claim about what already exists.

### On Q4 — normalized, because a login form does

`Admin`, `ADMIN`, and `admin ` are the same account to anything that authenticates. Comparing
raw strings would refuse `admin` and wave through `Admin`, which is worse than not having the
rule — it reads as enforced while being trivially bypassed.

The password is the exception, and is untouched here: case and spaces are meaningful in one,
which is why `isBuiltInTenantAdmin` already compares the username loosely and the password
exactly. Keep that asymmetry.

### On Q5 — a draft is not a provisioning act

`TenantDraftBodyDto.account` is optional and nullable; a draft is a half-finished form the
dealer saves and returns to. Refusing to *save* a value the dealer is still typing is hostile
and buys nothing, because the draft cannot provision anything by itself.

The authoritative gate is submit — and submit is covered for free, see below.

### On rule 2's narrow reach

`tenantAdmin` is **omitted entirely** when the dealer leaves both its fields blank, which is
the expected case. When it is omitted the tenant keeps its built-in root account, which *is*
named `admin` — so **rule 1 already prevents the default collision.**

Rule 2 therefore bites in exactly one situation: the dealer renamed root to something else and
then reused that same name as the Login account. Narrow, but real, and not reachable by rule 1.

### On Q7 — two fields marked, one message

A collision is a property of a *pair*, so marking one field misrepresents it: the dealer cannot
see which two values are in conflict, and may "fix" the wrong one. Both inputs therefore take
the invalid state.

The message appears **once, under Username**, for a reason that is not arbitrary: Login account
is already the anchor for rule 1's *"'admin' is not allowed for account name"*. Hanging rule 2's message
there too would let one field carry two different errors with two different causes, and in the
`admin`-plus-collision case display both at once. Username carries no message of its own, so it
is free to hold this one.

It is also where the collision is normally completed — Login account is filled first, Username
second — so the message lands next to the value the dealer just typed.

Note this diverges from the API, which attaches rule 2 to `initialUser`. That is deliberate and
harmless: the API's attachment point is chosen so the error payload never carries the tenant
admin password, not to tell the UI where to draw. **The web must not derive its placement from
the server's `property` field**, or a later change on either side silently moves the other.

## Contract

Two new refusals, on the two routes that provision.

### `POST /api/tenant-provisioning-requests`

| Condition | Status | Message |
|---|---|---|
| `initialUser.account` normalizes to `admin` | `400` | `'admin' is not allowed for account name` |
| `initialUser.account` equals `tenantAdmin.username` (normalized) | `400` | `Login account and username must be different` |

Normalization for both: `.trim().toLowerCase()`. Rule 2 applies only when `tenantAdmin.username`
is present — an omitted `tenantAdmin` is rule 1's business, not rule 2's.

#### What a caller actually receives — amended 2026-08-27 after implementation

The messages above are the **copy**, not the wire format. Verified against the built branch and
`@nestjs/common@11.1.28`:

| Body | HTTP `message` |
|---|---|
| `account: 'admin'` | `["initialUser.'admin' is not allowed for account name"]` |
| `account` duplicates `tenantAdmin.username` | `["Login account and username must be different"]` |
| **both rules violated at once** | `["initialUser.'admin' is not allowed for account name"]` — rule 2's message is dropped |

Two Nest behaviours produce this, and neither is ours to change cheaply:

1. **Nested constraints are prefixed with their parent property.** Rule 1 lives on
   `ProvisioningInitialUserDto.account`, so `prependConstraintsWithParentProp` prefixes it. The
   pre-existing `admin`/`admin` rule already behaves this way. The frontend renders its own bare
   copy, so a dealer normally never sees the prefix — only a direct API caller does.

2. **A parent's own constraints are discarded whenever that property has child errors.**
   `mapChildrenToValidationErrors` returns early into the children and never reads the node's own
   `constraints`. Rule 2 is declared on the parent `initialUser`, so its message is dropped
   whenever any field *inside* `initialUser` is also invalid — including rule 1 firing, and
   including an unrelated bad email.

**Why this was not "fixed":** moving rule 1 to the parent would clean up the prefix but put rule 1
under behaviour 2 as well, trading a cosmetic prefix for a message that sometimes vanishes. A
global `exceptionFactory` would change the error shape of every endpoint in the API, far outside
this feature. Both messages are pinned by tests so a change to either is loud.

**Enforcement is unaffected in every case** — a 400 is always returned, nothing is written, and
nothing is forwarded to the orchestrator. This is message fidelity only.

Both refusals happen in DTO validation, **before** `OrchestratorClient` is called. Nothing is
written and nothing is forwarded upstream.

### `POST /api/tenant-drafts/:id/submit`

**Identical, and inherited rather than restated.** `SubmitDraftDto extends
CreateProvisioningRequestDto`, so both validators apply to the draft submit path automatically.

This is load-bearing: the wizard has two submit routes (`createProvisioningRequest` and
`submitTenantDraft`), and a rule added only to the first would leave the draft path as a
bypass. **Any future rule added to the create DTO must be checked against this inheritance,
and a plan that adds validation to a hand-written copy of the create body reintroduces the
hole.**

### What does not change

No response shape changes. No new endpoint, no new field, no migration.

## API side

`sudu-dealer-api/src/tenant-provisioning/dto/create-provisioning-request.dto.ts`, following the
`IsNotBuiltInTenantAdmin` decorator already in that file.

**Rule 1 — `@IsNotReservedAccount()` on `ProvisioningInitialUserDto.account`.** Self-contained:
it needs only the value it is attached to.

**Rule 2 — a cross-field validator declared on `CreateProvisioningRequestDto.initialUser`, at
the parent level.** It cannot go on `ProvisioningInitialUserDto.account`: class-validator gives
a nested DTO no pointer to its parent, so `args.object` there is the initial-user object and
`tenantAdmin` is out of reach.

It must **not** be declared on `tenantAdmin`. That object carries the tenant admin password,
and the file's existing comment states the constraint plainly — a `ValidationError` carries the
value of whatever property it is attached to, and only one of those two fields may ever go near
an error path. `initialUser` holds no secret; `tenantAdmin` does.

Both refusals sit in validation, so `TenantProvisioningService.submit` and everything downstream
of it are unchanged.

## Web side

A courtesy check only — it exists so the dealer finds out while typing rather than on submit.

- Two predicates in `src/components/tenants/create-tenant/data.ts`, beside `isBuiltInTenantAdmin`
  and normalized the same way.
- Rule 1 surfaces on the **Login account** field in `TenantInfoStep.tsx` (~line 125).
- Rule 2 marks **both** Login account and **Username** (~line 195) invalid, and renders its
  message once, beneath Username. See Q7.
- Folded into `stepOneValid` in `CreateTenantForm.tsx`, exactly as `tenantAdminValid` already is,
  so Continue stays shut rather than the dealer configuring a whole tenant around a name the API
  will refuse.

Dealer surface (`/tenants/new`). No admin-surface change.

**The web check is never the enforcement.** If these two implementations disagree, the API wins
and the web is wrong.

## Out of scope

- Widening the reserved word to a list (`administrator`, `root`, `system`). See Q1.
- Anything about tenants already provisioned with `admin`. See Q3.
- Blocking `admin` at draft-save time. See Q5.
- The reserved-**subdomain** list. Different namespace, unchanged by this.
- `isBuiltInTenantAdmin` and the `admin`/`admin` pair rule, which stays exactly as it is.
- Item 1 of the backlog ("change the create tenant flow"). Same screen, still an open question.

## Open questions

None. Q6 and Q7 were the last two and were resolved on 2026-08-27; both are recorded in the
Decisions table above.
