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

## Decisions

All four open questions were answered on 2026-08-20 and are settled. They are recorded here
rather than deleted, so a later reader sees what was weighed.

| | Question | Decision |
|---|---|---|
| **Q1** | `admin`/`admin`, or a derived password? | **`admin`/`admin`**, always, as the default |
| **Q2** | Should an empty email become invalid? | **No** — the contract accepts `""` |
| **Q3** | Ship against one usable plan, or wait for the catalogue? | **Ship** |
| **Q4** | Where does the domain suffix come from? | **Keep the hardcoded `.mes.sudu.ai`**; revisit at production |

### On Q1

The alternative offered was the derived `{account}@123!` rule the initial user already uses —
same display benefit, no guessable root credential. `admin`/`admin` was chosen and is what §4
specifies.

What that means, stated once so it is not rediscovered later: **every tenant this wizard
provisions ships with root credentials of `admin`/`admin`**, on the account the orchestrator
itself authenticates as, reachable from a shared public login host. Nothing downstream
mitigates it — there is no forced rotation on first login, and §5 displays the pair to the
dealer by design. If that becomes unacceptable, the change is one constant and one boolean;
§5 keeps working unchanged because a derived password is just as computable as a constant.

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

**Suffix — decided (Q4): keep the hardcoded `.mes.sudu.ai` already in the code**, and revisit
at production. It is not new work: `TenantInfoStep.tsx:58` already renders it as the input
adornment, and the availability messages, `ReviewStep` and `ClaimTenantForm` all compose the
same string.

The accepted risk, recorded because the codebase already argues against it in two places
(`DomainLink.tsx` — "Never rebuild it from a `.mes.sudu.ai` template here: that was wrong on
dev" — and `dealer-api.ts:109`): dev tenants live at `dev.mes.sudu.ai`, so against the dev
orchestrator we now *submit* a production-shaped domain, where previously the mismatch only
affected a display hint. It is written to `blade_tenant.domain_url` and to the billing record.
Harmless on dev, wrong-looking, and the reason the suffix should become server-supplied when
production lands.

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

Q2 confirmed this: empty stays acceptable.

## 4 · Tenant admin credentials

**Web + API.** New optional `tenant_admin: { username, password }` on the create body,
applied by the orchestrator as **step 21**, after everything else.

- Both inputs optional and blank by default.
- **When both are blank, send `{ username: "admin", password: "admin" }`** (Q1, decided).
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
With Q1 decided, the defaulted case is the common one and resolves to `admin` / `admin`.
Storing the password itself instead would turn our database into a store of customers' root
credentials for a display convenience; it is not worth it, and the orchestrator takes the same
position — its own stored credentials "are never returned by any API".

Rules for the surface:
- Reachable only through the existing dealer scope. Every read goes through
  `resolveVisibleScope()`; a platform admin sees it via the admin route. No new access path.
- Masked by default with an explicit reveal control. No auto-copy, no URL parameters.
- The provisioning request is found from `dealerClientId`, which the completion path already
  writes.

## 6 · Dismissing tray tasks

**Web only.** The tray keeps finished rows for `KEEP_FINISHED_MS` (24 h) and offers no way to
clear one. The dealer gets an explicit control instead.

- **No timers.** Nothing disappears on its own. A row leaves the tray because the dealer
  dismissed it, or because the 24 h prune caught it.
- A **finished** row — `SUCCEEDED` or `FAILED` — gets a dismiss control.
- A **running** row does not. The tray exists to give the dealer a way back to work in flight;
  a control that throws that away is a trap, not a convenience. It becomes dismissible the
  moment it finishes.
- Dismissed ids persist in `localStorage` so a dismissed task does not return on the next page
  load. Request ids are not secrets; no session material goes near storage.
- The 24 h prune stays as the backstop for rows the dealer never dismisses.

Dismissing is a **view** action, not a state change: it hides the row locally and writes
nothing to the server. The job, its status page and the tenant remain exactly as they were, and
a dismissed job is still reachable from the tenants list.

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

None. All four are resolved in [Decisions](#decisions) above.

## Per-repo plans

- [`sudu-dealer-api/docs/superpowers/plans/2026-08-20-tenant-wizard-contract-update-api.md`](../../sudu-dealer-api/docs/superpowers/plans/2026-08-20-tenant-wizard-contract-update-api.md)
- [`sudu-dealer-web/docs/superpowers/plans/2026-08-20-tenant-wizard-contract-update-web.md`](../../sudu-dealer-web/docs/superpowers/plans/2026-08-20-tenant-wizard-contract-update-web.md)

Each links back to this spec.
