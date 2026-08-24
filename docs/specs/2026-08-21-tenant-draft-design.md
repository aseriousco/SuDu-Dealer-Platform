# Tenant drafts — cross-repo design

**Status:** approved, not yet implemented
**Repos:** `sudu-dealer-api` · `sudu-dealer-web`
**Branches:** `feat/tenant-draft` (both), off `main`
**Plans:** api → [`sudu-dealer-api/docs/superpowers/plans/2026-08-21-tenant-drafts-api.md`](../../sudu-dealer-api/docs/superpowers/plans/2026-08-21-tenant-drafts-api.md) · web → [`sudu-dealer-web/docs/superpowers/plans/2026-08-21-tenant-drafts-web.md`](../../sudu-dealer-web/docs/superpowers/plans/2026-08-21-tenant-drafts-web.md)
**Order:** API first — every web task calls endpoints that do not exist until it is merged.
**Builds on:** [`2026-08-20-tenant-wizard-contract-update-design.md`](./2026-08-20-tenant-wizard-contract-update-design.md) — the credential store (Q6) and the wizard shape this feature persists.

## Problem

A dealer registers a tenant on behalf of their client, and the wizard is all-or-nothing:
the form lives in component state, so closing the tab loses it. Real registrations do not
arrive complete. The client has not decided their subdomain, or has not said whether they
run SQL Accounting or AutoCount, or the person whose name goes on the initial user is on
leave. The dealer has some of the answers today and the rest next week.

Today that leaves two bad options. Invent placeholder values, provision a real tenant, and
then correct it in SuDuAI ERP — where the corrections we care about (subdomain, initial
user) are the ones that cannot be corrected. Or keep the half-gathered details in a
spreadsheet and retype them later.

A **draft** is the missing middle: a saved, incomplete registration that anyone at the
dealer can resume and submit once the information is in. It affects the **org plane**
only; nothing here is a platform surface.

## Decisions

All six were settled on 2026-08-21 and are recorded rather than deleted, so a later reader
sees what was weighed.

| | Question | Decision |
|---|---|---|
| **Q1** | Who can see and resume a draft? | **Anyone in the dealer org** — scoped by `organizationId`, author recorded and shown |
| **Q2** | What does a draft do with the tenant admin password? | **Store it encrypted**, and never return it to any client |
| **Q3** | Does drafting hold the subdomain? | **No hold** — re-checked live on resume and at submit |
| **Q4** | Does a draft consume a demo slot? | **No** — the cap is checked at submit, as it is today |
| **Q5** | Where does a draft live? | **A new `tenant_draft` table**, not a status on `tenant_provisioning_request` |
| **Q6** | Where does a dealer see drafts? | **Inline in the tenants list**, under a new `Draft` filter bucket |

### On Q2 — the password never comes back

Storing the password is what makes a draft resumable without retyping. Returning it is
not: a draft may sit for weeks and be opened by several people, and every read that hands
a secret to a browser is a copy we stop controlling.

So the draft stores ciphertext (`credential-cipher`, AES-256-GCM, `DEALER_CREDENTIAL_KEY`)
and **no draft view carries the password, not even through an audited reveal route.** The
consequence is structural rather than cosmetic, and it is the reason `POST
/tenant-drafts/:id/submit` exists at all: the plaintext is needed only at submit, and
submit happens on the server, so the password is decrypted there and never travels.

This differs deliberately from `tenant_provisioning_request.tenantAdminPassword`, which
*does* have a reveal route — that column is the only readable copy of a live tenant's root
credentials and the detail page's whole job is handing them to a client. A draft has no
tenant yet, so it has no such job.

### On Q1 — the scoping divergence it creates

Every tenant read goes through `ScopingService.resolveVisibleScope()`, which narrows a
non-ADMIN role to its member-node subtree by returning an `ownerMemberNodeId` filter.
Drafts cannot use it: `tenant_draft` has no such column, because a draft has no owner node
until submit resolves one.

So drafts are scoped by plain `organizationId`, and the consequence is worth stating rather
than discovering: **a custom-role user sees every draft in their organization, while they
see only their subtree's tenants.** That follows directly from the Q1 answer — the feature
is a colleague finishing a registration someone else started — but it is a genuine
difference in visibility rules between two things shown in the same list. If it ever has to
change, the fix is an `ownerMemberNodeId` column on the draft plus `resolveVisibleScope`,
not a filter in a controller.

### On Q5 — why not a status on the provisioning request

`tenant_provisioning_request` was the obvious home and is the wrong one. `requestRef` and
`idempotencyKey` are `NOT NULL UNIQUE` there; `status` drives the poller and
`reconcilePending`; `DemoCountService` counts `PENDING` rows; `list()` advances stale rows
as a side effect; `toView()` computes credentials from columns a draft would not have. A
`DRAFT` member would need an "unless DRAFT" branch in every one of those, and a draft is
*defined* by incomplete data, so nearly every column would have to go nullable — weakening
the guarantees of rows that are not drafts.

A separate table costs one migration and changes nothing that already works.

### On Q3 — what "no hold" means in practice

The subdomain lives in SuDuAI ERP, which this platform does not own. Any reservation we
record is a promise we cannot keep: someone creating the tenant directly in the ERP still
wins. So the draft stores the typed slug as typed, and resuming re-runs the existing live
availability check — a slug taken since is simply shown as taken and Continue stays shut,
which is the behaviour the wizard already has.

---

## Contract

Base path `/api/tenant-drafts`. `SessionGuard` only, matching the provisioning routes,
which deliberately do not gate on `client:create`. Every route is scoped to the actor's
`organizationId`.

### `TenantDraftView`

```ts
interface TenantDraftView {
  id: string;
  clientName: string;              // the only required field
  slug: string | null;             // the label only, e.g. "acme" — never the full domain
  account: string | null;
  name: string | null;
  realName: string | null;
  email: string | null;
  expireTime: string | null;       // YYYY-MM-DD
  planId: string | null;           // a su-code snowflake. ALWAYS a string
  accountingType: 'SQL' | 'ATC' | null;
  tenantAdmin: { username: string | null; hasStoredPassword: boolean };
  createdBy: { userId: string; label: string | null };
  updatedBy: { userId: string; label: string | null } | null;
  createdAt: string;
  updatedAt: string;
}
```

**No password field, on any draft response, ever.** `hasStoredPassword` is the boolean
that lets the UI say "saved" and offer a Change action without asking for the secret —
the same shape `ProvisioningCredentialsView.tenantAdmin` already uses.

`label` is resolved through `formatActorLabel` (`displayUsername → username → name →
email`), the same function the audit trail uses, so a person is called the same thing on
both screens. It is `null` for a user whose account carries none of those — display only,
never something to authorize against.

`slug` holds the **label**, not `<slug>.mes.sudu.ai`. The suffix is composed at submit,
exactly where `CreateTenantForm` composes it today, so a future move of the suffix
server-side does not have to rewrite stored rows.

### Routes

| Method | Path | Returns |
|---|---|---|
| `POST` | `/api/tenant-drafts` | `201` · `TenantDraftView` |
| `GET` | `/api/tenant-drafts` | `200` · `TenantDraftView[]`, newest `updatedAt` first |
| `GET` | `/api/tenant-drafts/:id` | `200` · `TenantDraftView` |
| `PATCH` | `/api/tenant-drafts/:id` | `200` · `TenantDraftView` |
| `DELETE` | `/api/tenant-drafts/:id` | `204` |
| `POST` | `/api/tenant-drafts/:id/submit` | `201`, or `202` · `ProvisioningRequestView` |

`POST` and `PATCH` take the same body. `clientName` is required and non-empty — it is the
row's label in the tenants list, and it is the wizard's first field anyway. Every other
field is optional and may be `null`; a draft with nothing but a client name is legal and
expected.

```ts
interface TenantDraftBody {
  clientName: string;
  slug?: string | null;
  account?: string | null;
  name?: string | null;
  realName?: string | null;
  email?: string | null;
  expireTime?: string | null;
  planId?: string | null;
  accountingType?: 'SQL' | 'ATC' | null;
  tenantAdmin?: { username?: string | null; password?: string | null };
}
```

`PATCH` replaces the fields present in the body and leaves absent fields untouched. For
the password specifically, the three cases are distinct and must stay distinct:

- **absent** — keep whatever is stored
- **`null`** — clear it
- **a string** — re-encrypt and replace

An empty string is normalized to `null` on write, for every field including the password.
The wizard sends its whole form on save, so in practice every field is present on a
`PATCH` and a field the dealer cleared arrives as `""`; without that rule the password's
three cases collapse back into two and "cleared" becomes unreachable.

A draft is not validated as a provisioning request. `expireTime` may be a past date, the
email may not parse, the slug may be taken — all of that is caught at submit, by the
validation that already exists. Refusing a draft for being incomplete would defeat the
feature.

### Submit

```ts
type SubmitDraftBody = CreateProvisioningRequestDto & {
  keepStoredTenantAdminPassword?: boolean;
};
```

The body is the ordinary create DTO, so the dealer submits what is **on screen**, not what
was last saved — resuming a draft and editing a field before submitting must send the
edit. The flag resolves the one value the browser cannot send because it never received it:

| `tenantAdmin.password` | `keepStoredTenantAdminPassword` | Password used |
|---|---|---|
| a string | *(ignored)* | the string — the dealer changed it |
| absent | `true` | the draft's stored password, decrypted server-side |
| absent | absent / `false` | none — the tenant keeps its built-in admin |

Once resolved, the handler calls the **same** `TenantProvisioningService.submit()` as
`POST /api/tenant-provisioning-requests`. One submit path, one set of guards in one order,
one submit-handoff guarantee. There is no second implementation to drift.

**The status code splits exactly as the create route's does**, because the same reasoning
applies: `201` normally, and `202` when the row was written but `jobId` is still null —
the handoff is unconfirmed and the job's fate genuinely unknown. Returning a `5xx` there
would tell the caller nothing was created, and their retry would mint a fresh idempotency
key: a second real tenant. Draft submit gets its own audit action,
`tenant_draft.submit`, with the same metadata shape and the same absence of the password.

**The `admin`/`admin` refusal must be re-checked after resolution.** `@IsNotBuiltInTenantAdmin()`
is a DTO decorator and only ever sees the request body, so a draft holding the password
`admin` submitted with username `admin` and `keepStoredTenantAdminPassword: true` would
walk straight past it — and land the failed credential-update step that guard exists to
prevent. The check on the resolved pair belongs in the service, before the row write.

### Errors

| Status | When |
|---|---|
| `400` | Body validation, including the resolved `admin`/`admin` pair on submit |
| `404` | No draft with that id **in the actor's organization** — a draft belonging to another org is reported as absent, never as forbidden, so existence is not leaked |
| `503` | `DEALER_CREDENTIAL_KEY` unconfigured while a password is being stored or resolved |

Submit additionally inherits every existing failure of the create path unchanged: the demo
cap, plan resolution, and orchestrator availability.

### Amendment to the submit-handoff guarantee

The existing guarantee stands: *if the provisioning row was written, the caller gets a 2xx
carrying its id; any error status means nothing was written.* Draft submit extends it by
one clause.

**The draft is deleted after the provisioning row is written, best-effort.** A failed
delete is logged and does not change the response. Deleting first would risk destroying
the dealer's only copy of the data on a submit that then fails; letting a failed delete
turn a successful provision into an error would break the guarantee the web client's
error handling is built on. The cost of the choice is a stale draft the dealer discards by
hand, which is the mildest of the three outcomes.

---

## API side

**Migration.** One new table, `tenant_draft`:

- `id`, `organization_id`, `created_by_user_id`, `updated_by_user_id` (nullable)
- `client_name` (required); `slug`, `account`, `name`, `real_name`, `email`,
  `expire_time`, `plan_id`, `accounting_type`, `tenant_admin_username` — all nullable
- `tenant_admin_password` — **ciphertext only**, `v1:<iv>:<tag>:<data>`, never plaintext at
  any point in any row
- `created_at`, `updated_at`
- index on `(organization_id, updated_at)`

Explicit columns rather than one JSON blob, specifically so the secret occupies its own
column. A blob is a thing that gets logged, serialized into a view, or spread into an audit
payload by someone who did not know what was inside it.

`created_by_user_id` and `updated_by_user_id` are plain `String`s, not relations — the same
treatment `TenantProvisioningRequest.actorUserId` and `CreditReload.actorUserId` already
get, because `User` is a better-auth model and `auth:generate` strips back-relations from it.

**Module.** `TenantDraftService` + `TenantDraftController`, following the shape of
`tenant-provisioning`. The service owns org scoping and encryption; the controller owns
nothing but request/response mapping.

**Audit.** Create, update, delete and submit are mutating requests, so the global
`AuditInterceptor` records them with no extra work. The audit metadata must carry the
draft id and the client name and **never the password, in plaintext or as ciphertext** —
the same rule the provisioning row's column already lives under.

**Deliberately unchanged, so nobody "fixes" it later:**

- `DemoCountService` does not count drafts (Q4). It counts live demo tenants and `PENDING`
  provisioning rows, and a draft is neither — it may never become a tenant, and charging a
  slot for a maybe would refuse real provisioning on speculation.
- The dealer-tenants endpoint returns no drafts. A draft has no `dealer_client` row, and
  synthesizing one would corrupt every consumer of that shape. The merge is the web's job.

## Web side

**Service + hook.** `createTenantDraft`, `listTenantDrafts`, `getTenantDraft`,
`updateTenantDraft`, `deleteTenantDraft`, `submitTenantDraft` in `services/dealer-api.ts`;
a `useTenantDrafts()` hook alongside `useDealerTenants()`.

**Wizard.** `CreateTenantForm` gains an optional `draftId` and a seeded initial form, plus
a **Save draft** button in the footer on all three steps, enabled once `clientName` is
non-empty. Saving is explicit, not autosave: autosave would write an audit row per
debounce and race with itself for no benefit a button does not already give.

On a resumed draft with `hasStoredPassword`, the password field renders as **saved** with a
Change action rather than as a value, and submit sends `keepStoredTenantAdminPassword: true`
until the dealer changes it. Seeding the slug makes `useSubdomainLookup` re-run on its own,
so the Q3 recheck needs no new code.

**Route.** `/tenants/drafts/:id` re-enters the wizard seeded from the draft. On successful
submit it navigates to the provisioning status page, exactly as the create path does now.

**Tenants list.** `DealerTenantsView` merges `useDealerTenants()` and `useTenantDrafts()`
into one row list with a `kind` discriminator, and gains a `Draft` filter bucket. This is
not a new kind of mixing: the list already carries `Awaiting approval` for `PENDING`
claims, which are not tenants either. `Draft` joins the `FILTERS` tuple, which is also
`FILTER_DEFS.status.allowed` — so the URL param name and its allow-list stay as they are,
and the dashboard KPI tiles that deep-link into this list keep working untouched.

| Column | A draft row shows |
|---|---|
| Tenant | Client name as plain text — no domain link, because there is no tenant to link to. Sub-line: *Draft · saved <when> by <who>* |
| Owner | Who saved it |
| Status | A `Draft` pill, visually distinct from the SaaS statuses |
| AI Credits | — |
| Claimed | — |

Clicking the row opens the wizard, not a tenant detail page.

Two rules that follow, and are easy to get wrong:

- **Counts exclude drafts.** Anything reporting "N tenants" — including the dashboard KPI
  tiles that deep-link into this list — keeps counting real tenants only. A draft may never
  become one.
- **Filters that assume a tenant do not apply.** Text search on client name works. The plan
  filter and the claim-date range do not: a draft's plan is not committed and its dates are
  not claim dates. Drafts appear under `All` and `Draft` and drop out of a plan filter, the
  way `SUSPENDED`/`CHURNED` claims already do.

## Out of scope

- **Autosave.** Explicit Save draft only — see above.
- **Draft expiry or cleanup.** Drafts persist until deleted. Revisit if they accumulate.
- **Any subdomain hold** (Q3).
- **In-flight provisioning rows in the tenants table.** They remain in `ProvisioningTray`
  only. Noted because it leaves a real gap: after this change a dealer sees `Draft` and
  `Live` in one list but a currently-provisioning tenant in neither. Folding those in is a
  coherent follow-up with its own edge cases (a job that fails mid-render, a job that
  lands) and is not part of this feature.
- **A "waiting on" note field** on the draft. Offered during design and not taken up; it
  would fit the scenario, and it is one nullable column if it is ever wanted.
- **Platform-plane visibility.** SuDu AI admins do not see dealer drafts. Nothing in the
  admin console changes.

## Open questions

None.
