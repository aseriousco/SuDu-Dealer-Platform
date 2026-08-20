# Tenant wizard — 2026-08-20 contract update

**Status:** design, not yet implemented
**Branch (all three repos):** `feat/tenant-wizard-contract-update`, off `main`
**Parent contract:** [`../dealer-platform-handoff-2026-08-20.md`](../dealer-platform-handoff-2026-08-20.md)
**Supersedes for the create path:** [`2026-08-11-tenant-provisioning-design.md`](./2026-08-11-tenant-provisioning-design.md) and its 2026-08-18 amendment, which remain accurate for the submit-handoff guarantee.

## Why

The orchestrator's create body changed twice in two days. `customer_domain` and
`plan.plan_id` are now **required with no fallback**, so the payload we send today is
rejected before anything is created. Alongside that, a new optional `tenant_admin` block
lets the caller set the tenant's root credentials.

This spec covers six changes: the four that follow from the contract, and two the dealer
experience needs regardless.

Prototype of the resulting intake: <https://claude.ai/code/artifact/c3138fe7-a62a-4f5d-937b-528ee4fa9fa3>

## The one decision that needs sign-off before implementation

**Defaulting every tenant's root admin to `admin` / `admin` gives every provisioned tenant
a trivially guessable root credential on a shared public login host.** These are not our
tenants — they are the dealers' customers — and the account is the one the orchestrator
itself authenticates as.

The requirement as given is implemented below (§4). The alternative costs nothing and
removes the risk: default the password to the **same derived rule the initial user already
uses**, `{account}@123!`. It stays computable from data we already hold, so §5 can still
display it without storing a secret, and it is not a value an attacker guesses first.

Recorded as **Q1**. Everything else in this spec is unaffected by the answer.

---

## 1 · Customer domain

**Web + API.** The slug input already exists, validated and availability-checked, and has
been deliberately unsent since `49ed85b`. It now becomes a required submitted field.

- Render as a single control with a fixed, non-editable suffix adornment: `[ acme ] .mes.sudu.ai`.
  The dealer types the label only.
- Validation is unchanged and already built: `SUBDOMAIN_RE` (a DNS label) plus the debounced
  `GET /api/tenant-lookup`. **Continue stays gated on `status === 'not_found'`** — an
  available name. `reserved`, `found`, and `error` all block, including `error`: advancing on a
  failed check would let a dealer configure a whole tenant around a name that turns out to be
  someone else's.
- Submitted as `customer_domain = "<slug>" + <suffix>`.

**The suffix must come from the API, not a web constant.** It is environment-paired —
`main.mes.sudu.ai` in production, `dev.mes.sudu.ai` against the dev orchestrator — and the
API already resolves that pairing in `SAAS_TENANT_LOGIN_HOST` / `TENANT_DOMAIN_TEMPLATE`. A
hardcoded web constant would send production domains from a dev build. Expose it on the
existing bootstrap/config response the wizard already loads.

> **Invariant check.** `sudu-dealer-api/CLAUDE.md` states provisioned tenants have no
> subdomain and forbids reintroducing a local subdomain column. That rule is about
> `dealer_client.slug` — the dealer-typed, non-authoritative value dropped in #15 — and it
> still holds. What we add is `customerDomain` on `TenantProvisioningRequest`: a record of
> what we *sent*, needed for idempotent resend and for §5. **Do not write it to
> `dealer_client`.** The invariant text should be amended to say so explicitly, or the next
> reader will treat this as a violation.

## 2 · Expiry not before today

**Web + API.** `expire_time` is optional; absent means no expiry.

- Web: date input with `min` set to today, plus an inline message. Empty stays valid.
- API: reject a past date in the DTO rather than letting the orchestrator answer
  `expire_time_invalid`.

**Compare calendar dates in `Asia/Kuala_Lumpur`, not UTC.** For eight hours each day, "today"
in Malaysia is "yesterday" in UTC, and a naive `new Date(value) < new Date()` would reject a
same-day expiry that is perfectly valid to the dealer typing it. Compare `YYYY-MM-DD` strings
resolved in that zone; never compare instants.

Send as `YYYY-MM-DD`, which the contract accepts alongside ISO-8601.

## 3 · Email must be valid

**Web + API.** Today `initialUserEmail` accepts anything, documented as "legal empty: the
orchestrator documents `""` as an accepted value".

- Empty **stays** legal — that is the contract's own position, and tightening it would reject
  submissions that work today.
- A non-empty value must be a valid address: `@ValidateIf(v => v !== '') @IsEmail()` on the
  DTO, `type="email"` plus explicit validation on the form.

Recorded as **Q2**: if empty should also become invalid, it is a one-line change — but it is a
product decision, not a validation bug.

## 4 · Tenant admin credentials

**Web + API.** New optional `tenant_admin: { username, password }` on the create body,
applied by the orchestrator as **step 21**, after everything else.

- Both inputs optional and blank by default.
- **When both are blank, send `{ username: "admin", password: "admin" }`** (subject to Q1).
- When either is filled, send what the dealer typed.

The form must state what this account is, because it is easy to confuse with the initial user:
this is the tenant's **built-in root admin**, and it is the identity the orchestrator logs in
as to service the tenant. If the customer later changes this password in the Sudu UI, every
subsequent operation on that tenant fails with `tenant_admin_login_failed` until the current
credentials are re-supplied through `POST /v1/tenants/{id}/stored-credentials` — a route this
spec does not build.

### Handling of the password

**The password is forwarded and forgotten.** It is not a field on
`TenantProvisioningRequest`, not in the audit metadata, not in any log line, and not in any
error message. `tenantAdminUsername` **is** stored — it is not a secret and §5 needs it.

This makes it the fifth credential class in the estate and the first one belonging to a
customer rather than to us; it must not be mixed with the four in
`sudu-dealer-api/CLAUDE.md`'s boundary 2.

## 5 · Credentials on the tenant detail page

**Web + API.** After provisioning succeeds, the dealer opens the tenant and sees both
accounts, so they can hand them to their customer.

| Account | Username | Password | Source |
|---|---|---|---|
| Initial user | `initialUserAccount` | `{account}@123!` | Derived — already how `ProvisioningStatus` displays it |
| Tenant admin | `tenantAdminUsername` | `admin` **only when defaulted** | Constant, or unavailable |

**Nothing is stored to make this work, and nothing should be.** Both passwords are either
derived from a value we already hold or a known constant. When the dealer set a custom
password, we show the username and say plainly that the password was set by them at creation
and is not stored — which is true, and better than a reassuring blank.

That requires one boolean on the row (`tenantAdminDefaulted`) to distinguish the two cases.
Storing the password itself instead would turn our database into a store of customers' root
credentials for a display convenience; it is not worth it, and the orchestrator takes the same
position — its own stored credentials "are never returned by any API".

Rules for the surface:
- Reachable only through the existing dealer scope. Every read goes through
  `resolveVisibleScope()`; a platform admin sees it via the admin route. No new access path.
- Masked by default with an explicit reveal control. No auto-copy, no URL parameters.
- The provisioning request is found from `dealerClientId`, which the completion path already
  writes.

## 6 · Auto-dismissing tray tasks

**Web only.** The tray currently keeps finished rows for `KEEP_FINISHED_MS` (24 h), which is
right for recovery and wrong for a bar that sits over every page.

- A row that reaches **`SUCCEEDED`** starts a dismiss timer and disappears on its own.
  Proposed: **30 s** after first being observed finished.
- A row that reaches **`FAILED` does not auto-dismiss.** It is the one the dealer must act on;
  hiding it after a timer is how a failed tenant goes unnoticed. It gets a manual dismiss
  control instead.
- Every row gets manual dismiss regardless of state.
- Dismissed ids persist in `localStorage` so a dismissed task does not return on the next
  page load. Request ids are not secrets; no session material goes near storage.
- The 24 h prune stays as a backstop for rows never observed finishing.

Timer starts when the client **first sees** the terminal state, not from `completedAt` — a
job that finished while the tab was closed should still be visible when the dealer returns.

Polling is unaffected: the tray already stops polling when nothing is `PENDING`, and that must
stay, because every list GET makes the API sweep the org against the orchestrator.

---

## Data model

`TenantProvisioningRequest` gains:

| Column | Type | Notes |
|---|---|---|
| `planId` | `String` | **Never a number.** A 19-digit su-code snowflake, same class as `tenantId` |
| `customerDomain` | `String?` | Nullable for rows written before this change |
| `expireTime` | `DateTime?` | |
| `tenantAdminUsername` | `String?` | Not a secret |
| `tenantAdminDefaulted` | `Boolean` | Drives §5's display |

`packageType` stays for historical rows but is **no longer sent** — the plan supplies the
package via `tenant_package_id`. Keep the column, stop populating the payload field.

No password column. Ever.

## API surface

- **`GET /api/tenant-plans`** — active `sudu_plan` rows joined to their ERP, AI-credit and
  AI-service rows, for the selector. Needs three new collection ids as environment
  configuration, alongside the AI-credit id already present:

  | Table | Collection id |
  |---|---|
  | `sudu_plan` | `1984112444644995073` |
  | `sudu_erp_plan` | `2086068952784371713` |
  | `sudu_ai_service_plan` | `2086422976536707073` |
  | `sudu_ai_credit_plan` | `2086424808302510082` *(already configured)* |

  Inactive plans are excluded — the orchestrator rejects them with `plan_not_found`.
  A plan missing `tenant_package_id` or `default_permission_id` is also unusable
  (`plan_package_missing`, `plan_permissions_missing`); filter or flag rather than offering it.

- **`POST /api/tenant-provisioning-requests`** — DTO gains `planId` (required),
  `customerDomain` (required), `expireTime?`, `tenantAdmin?`.

- **`GET /api/tenant-provisioning-requests/:id`** and the tenant detail view gain the domain,
  the selected plan, and the §5 credentials block.

New orchestrator error codes to map: `plan_id_required`, `plan_not_found`,
`plan_package_missing`, `plan_permissions_missing`, `domain_url_required`,
`expire_time_invalid`.

## What does not change

The submit-handoff guarantee stands exactly as amended: **if the row was written the caller
gets a 2xx carrying its id, and any error status means nothing was written.** All new
validation happens *before* the write, so it produces 4xx with nothing created — the same
class as the existing `503` for an unconfigured orchestrator.

## Deploy order

**API first, deployed — not merely merged — then web.** Unchanged from the previous spec and
for the same reason: against an older API a 5xx re-enables the submit button, and the dealer's
retry mints a fresh idempotency key server-side, creating a second real tenant.

## Out of scope

- The `customer` finance block. Ten of its eighteen fields are id-typed
  (`customer_currency_id`, `customer_tax_rate_id`, `customer_payment_term_id`, `price_tag_id`,
  `customer_area_id`, `customer_agent_id`, `organization_id`, `business_type_id`,
  `business_activity_id`, `customer_irbm_id`) and each needs its own ERP lookup list before it
  can appear in a form.
- `stored-credentials`, `repair`, `recycle`, `role-permissions`, `admin-credentials`. Lifecycle
  routes, not creation.
- Populating `sudu_plan`.

## Open questions

| | Question | Recommendation |
|---|---|---|
| **Q1** | `admin`/`admin`, or the derived `{account}@123!` rule? | Derived — same display benefit, no guessable root credential |
| **Q2** | Should an empty email become invalid too? | No; the contract accepts `""` |
| **Q3** | `sudu_plan` holds two test rows, one inactive. Ship against one usable plan, or wait for the catalogue? | Ship — the selector is correct either way and the catalogue is data, not code |
| **Q4** | Is the domain suffix `.mes.sudu.ai` in every environment, or `.dev.mes.sudu.ai` against dev? | Confirm before wiring; it decides whether the API returns a suffix or a template |

## Per-repo plans

To be written once Q1 and Q4 are answered:

- `sudu-dealer-api/docs/superpowers/plans/2026-08-20-tenant-wizard-contract-update-api.md`
- `sudu-dealer-web/docs/superpowers/plans/2026-08-20-tenant-wizard-contract-update-web.md`

Each links back to this spec.
