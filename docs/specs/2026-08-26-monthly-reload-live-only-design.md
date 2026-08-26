# A monthly reload requires a Live tenant — cross-repo design

**Status:** draft
**Repos:** `sudu-dealer-api` · `sudu-dealer-web`
**Branches:** `feat/monthly-reload-live-only` — cut on this root repo, off `main`; the same name goes on `sudu-dealer-api` and `sudu-dealer-web` when implementation starts
**Plans:** api → `sudu-dealer-api/docs/superpowers/plans/…` · web → `sudu-dealer-web/docs/superpowers/plans/…` (neither written yet)

## Problem

A tenant provisioned for testing is handed a monthly AI-credit package at registration,
and that package is deliberately small. It is not a commercial choice — it is the cost
guard. A testing tenant exists so someone can walk the flow on our system; the package
is sized to let them do that and no more, because every credit they burn is our cost,
not a customer's.

Nothing enforces that today. `POST /api/tenants/:tenantId/reloads` accepts
`reloadType: 'MONTHLY_SUBSCRIPTION'` for any tenant whose claim is `ACTIVE`, and the
admin route accepts it for any tenant at all. Both resolve a plan from the live SaaS
catalog and send `ai_credit_plan` to the workflow, which grants that plan's whole
monthly allotment. A dealer wanting more headroom on a demo can simply buy a larger
package, and the guard evaporates.

The SaaS does not stop it either. Neither orchestrator handoff
([2026-08-19](../orchestrator/sudu-tenant-orchestrator-api-handoff-2026-08-19.md),
[2026-08-20](../orchestrator/dealer-platform-handoff-2026-08-20.md)) describes any
status precondition on a reload — they document `customer_status` as a value the
orchestrator *writes* and derives, never one it gates on. **This rule is ours.** If it
should also hold at the SaaS, that is a separate handoff (see Open questions).

Flex is the intended escape valve and must keep working untouched. A testing tenant
that genuinely needs more usage buys flex credit, which is priced per ringgit at the
published rate and is therefore self-limiting in a way a package swap is not.

This reads client-plane data (the SaaS registry row) to gate an org-plane and
platform-plane action. It writes nothing new and changes no schema.

## Decisions

| | Question | Decision |
|---|---|---|
| **Q1** | Which SaaS statuses may take a monthly reload? | **`Live` only** — `Testing`, `Testing Suspended` and `Live Suspended` are all refused |
| **Q2** | What happens when the status cannot be read? | **Refuse**, under a discriminant distinct from a policy refusal |
| **Q3** | Does the platform admin console get an override? | **No.** Nobody can change a non-Live tenant's package |
| **Q4** | Does anything about flex (`ADD_ON`) change? | **No** — no rule, no code path, no new dependency |
| **Q5** | Who decides eligibility? | **The API.** The web is *told* the verdict and never derives it |

### On Q1 — an allowlist of one, not a blocklist of three

The rule was stated as "block Testing", and it grew to "block everything that is not
`Live`" once the suspended statuses were considered. Writing it as an allowlist rather
than a blocklist is not cosmetic — it decides how the system behaves on a value nobody
anticipated.

`demo-tenant.ts` already documents the fragility this turns on: su-code returns the
dictionary *key*, and for `customer_status` the key is the human label itself
(`"Testing"`, not a code). Renaming a label in the SaaS dictionary changes the key, and
any comparison against it stops matching. Under a blocklist, a renamed `Testing` would
stop being recognised as blocked and monthly reloads would silently open up on exactly
the tenants this exists to protect. Under an allowlist, a renamed value simply is not
`Live`, and it is refused.

The cost, stated plainly: **if SaaS ever renames `Live`, every monthly reload on the
platform stops.** That is a loud, immediate, total failure rather than a quiet and
expensive one, and it is the direction we want to fail in on a cost guard. The raw
status value is logged on every refusal so the drift is visible the first time it
happens rather than after the invoices arrive.

Comparison is trimmed and case-insensitive, matching `readDemo`.

### On Q2 — two refusals that must not sound alike

A live registry read can fail: the SaaS call can be rejected, the row can be missing,
the field can be absent. Under Q1 all of those come out as "not `Live`", and the guard
refuses. But the *operator* is owed the difference between two very different
sentences:

- **"This tenant is Testing, so its package is frozen."** A policy refusal. It is
  correct, it is permanent until the tenant is converted, and retrying is pointless.
- **"We couldn't check this tenant's status."** An outage. The tenant may well be
  `Live`; retrying in a minute is exactly the right move.

Collapsing these would make a SaaS outage read as a business rule and teach dealers
that a real refusal is something you retry until it works. So the verdict carries a
discriminant — `TENANT_NOT_LIVE` or `TENANT_STATUS_UNVERIFIED` — the same shape the
retry gate uses on `feat/dealer-retry-provisioning`
(`docs/specs/2026-08-25-dealer-retry-provisioning-design.md`, on that branch).

They also differ in HTTP status, because they differ in what a client should do: `409`
for the policy refusal (well-formed request, conflicts with current state, succeeds
once the tenant converts) and `503` for the unverified one (transient, retry).

### On Q3 — no override, and what that costs

The package is the cost guard, so an override is a hole in it by definition. There is
no actor who should be able to enlarge a demo's package: not the dealer whose cost it
is not, and not the vendor, whose remedy is to convert the tenant to `Live` and then
sell it a package like any customer.

The cost lands on sequencing. `customer_status` is SaaS's field, so a tenant that was
converted commercially but not yet updated in SaaS will be refused here, and the fix is
in the SaaS, not in this platform. That is the correct place for it — SaaS is the record
of what a tenant is — but it does mean a sale can be blocked by a data-entry lag, with no
in-app way to force it through. Accepted.

### On Q5 — where the read happens, and where it must not

The gate is a **live registry read on the reload request**, not the status carried on a
tenant list row. A list can be minutes old, and this is a money decision.

Within `createDealerReload` / `createAdminReload`, the guard sits:

- **after** the idempotency check — a replay of an intent that already succeeded must
  keep returning its existing row. A tenant suspended *after* a legitimate monthly
  reload must not turn that reload's replay into a refusal.
- **before** `priceReload`, the wallet debit, and any database write. A refusal must
  leave nothing behind: no `credit_reload` row, no wallet movement, no invoice at the
  SaaS. The retry-provisioning work already recorded what a post-write failure
  costs when a failed job burns the tenant name; a pre-write guard has no such tail.
- **only** on the `MONTHLY_SUBSCRIPTION` path. A flex reload must not acquire a new
  dependency on a SaaS call, a new latency cost, or a new way to fail. Q4 means what it
  says: the flex path itself gains nothing, though refusal copy on the monthly path does
  point at flex as the remaining option.

`reconcilePending` is **not** gated. It settles rows the workflow already ran, without
re-running it; gating it would strand exactly the rows that most need settling.

## Contract

### Refusals on the two reload routes

Applies to `POST /api/tenants/:tenantId/reloads` (dealer) and
`POST /api/admin/tenants/:tenantId/reloads` (platform), identically. Only for
`reloadType: 'MONTHLY_SUBSCRIPTION'`.

```jsonc
// 409 — policy refusal. Definite, no side effects, retrying changes nothing.
{
  "code": "TENANT_NOT_LIVE",
  "message": "This tenant's SuDuAI ERP status is Testing. A monthly package can only be changed once the tenant is Live — you can still top up flex credit.",
  "saasStatus": "Testing"      // raw value as SaaS returned it; "" when absent
}

// 503 — could not verify. Definite, no side effects, retrying is the right move.
{
  "code": "TENANT_STATUS_UNVERIFIED",
  "message": "We couldn't check this tenant's status with SuDuAI ERP, so this monthly reload was not submitted. Nothing was charged. Please try again shortly — flex top-ups are unaffected."
}
```

Both are raised **before any write**, so both are unambiguously side-effect-free. The
web must treat the `503` as a definite refusal and **not** route it through the
indeterminate "credits may already be granted" band — the same exception
`reload-error.ts` already makes for the pricing guard's `503`, but keyed on `code`
rather than on status-plus-message.

### Eligibility published on tenant rows

`DealerTenant` (`GET /api/tenants`) and `AdminTenant` (`GET /api/admin/tenants`) each
gain one field. Both responses already read the registry row, so this costs no extra
SaaS call.

```ts
interface MonthlyReloadEligibility {
  allowed: boolean
  /** null when allowed. Same discriminants as the refusal above. */
  blockedBy: 'TENANT_NOT_LIVE' | 'TENANT_STATUS_UNVERIFIED' | null
  /** Raw SaaS status, for display. '' when unknown or withheld. */
  saasStatus: string
}

interface DealerTenant { /* …existing… */ monthlyReload: MonthlyReloadEligibility }
interface AdminTenant  { /* …existing… */ monthlyReload: MonthlyReloadEligibility }
```

**Security:** the dealer plane reveals SaaS data only for `ACTIVE` claims — an existing
invariant in `tenants.service.ts`, not something this feature may relax. A `PENDING`
claim therefore reports `{ allowed: false, blockedBy: 'TENANT_STATUS_UNVERIFIED',
saasStatus: '' }`, which is honest (we are withholding, so from the client's side it
is genuinely unverified) and leaks nothing. Such a claim is already `reloadable: false`
for every reload type, so nothing new is gated by it.

This field is **advisory** — it exists so the wizard can stop offering an action that
will be refused. The gate is the live read at reload time. The two can legitimately
disagree when a status changes between the list load and the submit, and when they do,
the API wins.

## API side

- **`src/credit-reload/monthly-eligibility.ts`** — a pure function over a
  `SaasTenantRow | null`, returning the verdict above. No I/O, no throwing, modelled
  directly on `demo-tenant.ts`, which is the existing precedent for "one module owns
  one question about `customer_status`". It is deliberately *not* folded into
  `readDemo`: that function answers "does this consume a demo slot" and fails **open**
  by design, and merging two opposite failure policies into one function is how one of
  them quietly becomes wrong.
- **A registry reader keyed by `tenantId`.** `tenants.service.ts` already has a private
  `readRegistry`; the reload path needs the same query. Extract it (or add a small
  `TenantStatusReader` alongside the existing `SaasFlexRateReader` / `ReloadHistoryReader`
  readers) rather than writing the su-code query a third time. Unlike the list's version,
  this one must **not** fail soft to `null`-means-carry-on — for the guard, unreadable is
  a refusal.
- **`MonthlyReloadBlockedException`**, following `demo-cap.exception.ts`: a
  `ConflictException` / `ServiceUnavailableException` pair carrying `code` and, for the
  policy case, `saasStatus`.
- **Enforcement** in `CreditReloadService.createDealerReload` and `createAdminReload`,
  positioned per Q5.
- **No migration, no schema change, no new table.** `credit_reload` is untouched.

## Web side

- `CreditTenant` gains `monthlyReload`, threaded through both `fromDealerTenant` and
  `fromAdminTenant` in `use-credit-tenants.ts`.
- `PickedTenant` gains it too — both wizard entry points need it, since the tenant-detail
  entry skips the picker step entirely and passes the tenant as a prop.
- `TopUpDrawer`'s `DetailsStep` **disables** the Monthly card and shows the reason.
  Disabled, not hidden: a hidden option makes an operator wonder whether the feature
  broke; a disabled one with a sentence attached teaches the rule. Flex stays exactly as
  it is, and stays selectable — the whole point is that this tenant still has a way to
  buy credit.
- `reload-error.ts` maps the two new codes, keyed on `code`, with the `503` handled as a
  definite refusal per the Contract section.
- The web derives nothing. No `saasStatus === 'Live'` comparison exists anywhere in the
  web repo when this is done.

## Out of scope

- **Flex is untouched** for every status, including suspended ones. Whether a suspended
  tenant should be able to buy anything at all is a real question and a separate one.
- **The testing package itself** — what provisioning assigns, and how big it is — is not
  changed here.
- **Any other plan-change surface.** The reload wizard is the only one that exists today.
- **Orchestrator-side enforcement.** If SaaS should refuse this too, that is a handoff to
  that team, not a change we can make.
- **Backfilling or reversing** any monthly reload already taken by a non-Live tenant.

## Open questions

1. **Does this refuse anything that is happening today?** Before shipping, query
   `credit_reload` for `MONTHLY_SUBSCRIPTION` rows against tenants currently not `Live`.
   A non-empty result is not a blocker, but it changes this from a theoretical guard to a
   live behaviour change with dealers to notify.
2. **Should the SaaS enforce it as well?** Our guard covers our two routes; anyone
   reaching the workflow another way bypasses it. Worth a handoff if such a path exists.
3. **Confirm the exact `Live` dict key on prod**, not just dev — Q1 makes an exact match
   the single point of failure for every monthly reload, so it should be verified against
   prod data the way the `customer_status` values were on 2026-08-19.
