# Dealer Platform Handoff — Tenant Lifecycle API

**Revised 20 August 2026.** Supersedes `sudu-tenant-orchestrator-api-handoff-2026-08-06.md` for
everything a dealer platform calls. That document remains accurate for the provisioning
internals a dealer platform does not touch.

---

## What changed since the last handoff

| Change | Impact on you |
|---|---|
| `customer_domain` is **required** on the create body | **Breaking.** A request without it is rejected before anything is created |
| `plan_id` is **required** for package setup — no fallback | **Breaking** on `POST /:id/package`; unchanged for the create route, which always required it |
| `package_id` removed from the package body | **Breaking** if you sent it; it is now rejected rather than ignored |
| Four new routes | `details`, `domain`, `sudu-customer`, `admin-credentials` |
| Two lifecycle routes | `recycle`, `stored-credentials` |
| `sudu_orchestrator` is no longer created | A new tenant has two users, not three |
| Everything authenticates as the tenant admin | Changing admin credentials has consequences — see [Credential lifecycle](#credential-lifecycle) |
| Repair verifies access before planning | Returns `409` with a remediation block instead of a job that fails later |

---

## Model

Every mutating route **enqueues a job and returns immediately**. A `2xx` means "accepted", never
"done". Poll the job.

```
POST  →  { "job_id": "...", "status": "queued" }
GET   /v1/jobs/{job_id}?detail=full   →  status, steps, results
POST  /v1/jobs/{job_id}/retry         →  resumes at the first failed step
```

Job and step `status` is `queued` | `running` | `succeeded` | `failed` | `skipped`.
**`skipped` is a success** — it means the work was already done. Most steps report it on a
second run.

Add `"dry_run": { "mode": "connected" }` to any body to validate against live data without
writing. Use it to see derived values — plan fan-out, resolved user limit — before committing.

### Headers

```
Authorization: Bearer <internal service JWT>
Content-Type: application/json
Idempotency-Key: <unique per logical request>
```

Replaying a key with an identical body returns the original job. Replaying it with a **changed**
body is rejected as a hash mismatch — generate a fresh key whenever the payload changes, and
reuse it when retrying the same operation after a network failure.

### Identifiers

The `{id}` in every tenant route is the **six-digit tenant code** (`966073`), never
`blade_tenant.id`. Where BladeX needs the 19-digit surrogate id, the orchestrator resolves it.

---

## Create a tenant

```
POST /v1/provisioning/tenant-jobs          scope: tenant:create
```

```json
{
  "request_ref": "dealer-order-88213",
  "tenant": { "client_name": "Acme Manufacturing" },
  "plan": { "plan_id": "2089572840018726914" },
  "accounting": { "type": "SQL" },
  "customer_domain": "acme.sudu.ai",
  "expire_time": "2027-01-31",
  "tenant_admin": { "username": "acmeadmin", "password": "<customer password>" },
  "customer": {
    "customer_status": "Live",
    "customer_currency_id": "2071864755349745669",
    "customer_tax_rate_id": "2047207963138121732",
    "customer_tax_percent": 8,
    "customer_credit_limit": 10000,
    "customer_tin_no": "TIN123456"
  },
  "initial_user": {
    "account": "acme01",
    "name": "Acme Ops",
    "real_name": "Acme",
    "email": "ops@acme.example"
  }
}
```

| Field | | Notes |
|---|---|---|
| `tenant.client_name` | **required** | Truncated to 20 chars for BladeX |
| `plan.plan_id` | **required** | Drives package, credits, user limit, billing links |
| `accounting.type` | **required** | `SQL` or `ATC` |
| `customer_domain` | **required** | Written to both the tenant and the billing record |
| `initial_user` | **required** | `account` must be unique across all BladeX tenants |
| `expire_time` | optional | ISO-8601 or `YYYY-MM-DD`. Absent means no expiry |
| `customer` | optional | Finance details — see below |
| `tenant_admin` | optional | Admin credentials — see [Credential lifecycle](#credential-lifecycle) |
| `package.type` | optional | Only when the plan's package is unmapped |
| `request_ref` | optional | Your reference; searchable via `GET /v1/jobs` |

### What the plan supplies

Send `plan_id` and the orchestrator derives the rest from `sudu_plan` — you send none of these:

- The BladeX product package, and the WMS/AI/MES shape derived from it
- The ERP, AI service and AI credit plan links on the billing record
- Monthly credits, from the AI credit plan's `monthly_credit_amount`
- The tenant user limit, from `tenant_user_limit`

**There is no fallback.** A request without `plan_id` is rejected rather than assigned a default
package — a tenant licensed with no plan behind it has no credits, no user limit and nothing for
billing to derive from, and used to be created silently.

### The `customer` block

All optional. A field you omit is **left off the record entirely**, never written as a blank, so
"not collected" stays distinguishable from "set to nothing". The block is strictly validated —
a misspelled field is a `400`, not a silent drop.

`customer_status` accepts `Live` | `Testing` | `Live Suspended` | `Testing Suspended`, and
defaults to `Live`. Suspension is a modifier on the tier, which is why there is no bare
`Suspended`.

Other accepted fields: `organization_id`, `price_tag_id`, `customer_area_id`,
`customer_agent_id`, `customer_currency_id`, `customer_tax_rate_id`, `customer_tax_percent`,
`customer_payment_term_id`, `customer_credit_limit`, `overdue_limit`, `customer_com_reg_no`,
`customer_com_old_reg_no`, `customer_tin_no`, `customer_sst_sales_no`, `customer_sst_service_no`,
`customer_irbm_id`, `business_type_id`, `business_activity_id`, `is_accurate`, `is_exceed_limit`.

---

## The 21 steps

| # | Step | Phase |
|---|---|---|
| 1 | `create_tenant` | tenant_core |
| 2 | `setup_resource_package` | tenant_core |
| 3 | `update_tenant_details` | tenant_core |
| 4 | `set_tenant_domain_url` | tenant_core |
| 5 | `register_sudu_customer` | billing |
| 6 | `login_new_tenant` | tenant_core |
| 7 | `setup_object_storage` | tenant_baseline |
| 8 | `create_hq_department` | access_control |
| 9 | `create_hq_role` | access_control |
| 10 | `create_initial_user` | access_control |
| 11 | `update_user_assignments` | access_control |
| 12 | `update_role_permissions` | access_control |
| 13 | `setup_accounting_integration` | accounting |
| 14 | `seed_tenant_master_data` | accounting |
| 15 | `seed_org_master_data` | org_seeding |
| 16 | `setup_storage_location` | warehouse |
| 17 | `setup_bin_location` | warehouse |
| 18 | `setup_batch_configuration` | warehouse |
| 19 | `setup_transfer_order_configuration` | warehouse |
| 20 | `setup_prefixes` | prefixes |
| 21 | `update_tenant_admin_credentials` | access_control |

Four steps exist but never run here: `create_location_plant` and `setup_document_number_rules`
(own routes), `ensure_orchestrator_service_account` (see below), and `recycle_tenant`
(destructive).

### The tenant you get

Two users, not three:

| Account | Role | Menus |
|---|---|---|
| the built-in admin | `管理员` (root) | the full package tree |
| your `initial_user.account` | `Super Admin` (HQ) | the plan's `default_permission_id` |

`sudu_orchestrator` is no longer created. If you ever need it — it is the identity some
operational tooling expects — create it explicitly via
`POST /v1/tenants/{id}/orchestrator-service-account`.

---

## Individual routes

Each targets one tenant and returns a job.

### Subscription details

```
POST /v1/tenants/{id}/details          scope: tenant:details:update
{ "expire_time": "2027-01-31", "plan_id": "2089572840018726914" }
```

At least one of `expire_time` or `account_number` required. The user limit comes from the plan;
`account_number` overrides it. **Without `plan_id` and without `account_number`, no limit is
applied.**

### Domain

```
POST /v1/tenants/{id}/domain           scope: tenant:domain:set
{ "customer_domain": "acme.sudu.ai" }
```

Required. Re-sending the current value returns `already_set` without writing.

### Billing customer record

```
POST /v1/tenants/{id}/sudu-customer    scope: tenant:sudu_customer:register
{ "customer_domain": "acme.sudu.ai", "plan_id": "2089572840018726914" }
```

`plan_id` and `customer_domain` both **required** — the record cannot be built without the plan.
Takes the same finance fields as the `customer` block, sent flat. A tenant that already has a
record returns `skipped`.

### Role permissions

```
POST /v1/tenants/{id}/role-permissions scope: tenant:role_permission:setup
{ "role_id": "...", "plan_id": "2089572840018726914" }
```

`role_id` is required on this route — there is no job context to infer the HQ role from.

> **Always send `plan_id`.** With neither `plan_id` nor `package_type`, this does not fail — it
> falls back to the profile's **WMS** menu tree, because that is the default. An AI or MES tenant
> would be granted the wrong menus and the job would report success. Resolution order is
> `menu_ids` → `plan_id` → `package_type` → WMS.

### Repair

```
POST /v1/tenants/{id}/repair           scope: tenant:repair
{ "request_ref": "ticket-4821", "targets": ["setup_prefixes"] }
```

Omit `targets` to check all 20 repairable steps. It inspects the tenant's real state first and
only schedules steps that are actually missing — the plan and its `drift_reports` come back on
the job. Naming a non-repairable step is rejected.

**It verifies access before planning.** If the orchestrator can no longer log into the tenant you
get an immediate `409` — see below.

---

## Credential lifecycle

This is the part most likely to cause confusion, so it is worth reading in full.

The orchestrator authenticates into every tenant as that tenant's built-in admin. It therefore
needs to know the current credentials at all times.

### Changing them

```
POST /v1/tenants/{id}/admin-credentials   scope: tenant:admin_credentials:update
{ "username": "acmeadmin", "password": "<new password>" }
```

Both optional — send one, the other, or both. Neither means the step is skipped. The same fields
can be supplied as `tenant_admin` on the create body, where they are applied as **step 21**,
after everything else, because every earlier step needs the default credentials.

When you change credentials this way, the orchestrator **records them automatically**. Nothing
further is needed and the tenant stays serviceable.

### When they change outside this API

If a customer changes their password in the Sudu UI, the orchestrator is locked out of that
tenant — every route against it will fail. Tell us the new credentials:

```
POST /v1/tenants/{id}/stored-credentials  scope: tenant:admin_credentials:update
{ "username": "acmeadmin", "password": "<current password>" }
```

This is **synchronous and creates no job** — a locked-out tenant cannot run one. It verifies by
logging in before storing, so a `200` means access is genuinely restored. Credentials are stored
encrypted and are never returned by any API.

### What a lockout looks like

Any job step:

```json
{ "error_code": "tenant_admin_login_failed",
  "details": { "remediation": "POST /v1/tenants/966073/repair" } }
```

Repair, up front, as `409`:

```json
{ "error_code": "tenant_admin_credentials_invalid",
  "remediation": {
    "action": "Send the tenant's current admin credentials, then retry this repair",
    "route": "POST /v1/tenants/966073/stored-credentials",
    "body": { "username": "<current admin username>", "password": "<current admin password>" }
  } }
```

Recovery is always: call `/stored-credentials`, then retry whatever failed.

---

## Deleting a tenant

```
POST /v1/tenants/{id}/recycle          scope: tenant:recycle
{ "customer_status": "Live Suspended", "expected_tenant_name": "Acme Manufacturing" }
```

A **soft delete** — the tenant moves to BladeX's recycle bin and can be restored. Users,
departments, org data and object storage all survive.

Both fields optional, but **send `expected_tenant_name`**. The tenant code is in the URL, so a
mistyped digit addresses a real but different tenant and nothing else would catch it. On
mismatch the job refuses with `tenant_name_mismatch` before touching anything.

It also suspends the billing record. Send `customer_status` to say where it should land; omitted,
it derives `Live → Live Suspended` and `Testing → Testing Suspended`.

Recycling an already-recycled tenant returns `skipped`, not an error.

> `tenant:recycle` is the only destructive scope. Grant it narrowly — ideally to a separate
> credential from the one that provisions.

---

## Error codes

### Rejected before anything is written

| Code | Fix |
|---|---|
| `plan_id_required` | Send `plan_id`. There is no package fallback |
| `plan_not_found` | The plan is not in `sudu_plan`, or is inactive |
| `plan_package_missing` | The plan has no `tenant_package_id` |
| `plan_permissions_missing` | The plan has no `default_permission_id` — no menus to grant |
| `domain_url_required` | Send `customer_domain` |
| `expire_time_invalid` | Use ISO-8601 or `YYYY-MM-DD` |
| `role_id_required` | Send `role_id` on `/role-permissions` |
| `tenant_name_mismatch` | `expected_tenant_name` is not this tenant — check the id |
| `bladex_tenant_not_found` | No such tenant code |
| `sudu_customer_exists` | Billing record already present |
| `tenant_admin_credentials_invalid` | `409` from repair — call `/stored-credentials` first |

### Written but not confirmed — investigate, then retry

| Code | Meaning |
|---|---|
| `tenant_domain_url_not_persisted` | The domain did not land |
| `tenant_expire_time_not_persisted` | The expiry did not land — usually a rejected date format |
| `tenant_account_number_not_persisted` | The user limit did not land |
| `tenant_admin_username_not_persisted` | The rename did not land |
| `tenant_not_recycled` | Tenant still active after recycle reported success |
| `sudu_customer_status_not_updated` | Billing status unchanged; tenant **is** recycled, retry |
| `sudu_customer_status_unmappable` | Pass `customer_status` explicitly |
| `tenant_admin_login_failed` | Locked out — call `/stored-credentials` |
| `tenant_submit_clobbered_row` | An update overwrote a field it should not have. **Report this** |

Every code in the second table exists because both BladeX and su-code return **HTTP 200 while
silently dropping values they cannot bind**. Each write is read back and confirmed, so a job that
reports success has been verified rather than merely accepted.

---

## Scopes

| Scope | Grants |
|---|---|
| `tenant:create` | Full provisioning |
| `tenant:details:update` | Expiry and user limit |
| `tenant:domain:set` | Domain |
| `tenant:sudu_customer:register` | Billing record |
| `tenant:admin_credentials:update` | Change **and** store admin credentials |
| `tenant:role_permission:setup` | Re-grant role permissions |
| `tenant:repair` | Repair |
| `tenant:recycle` | Delete — **destructive** |
| `job:read` | Poll job status |
| `job:retry` | Retry a failed job |

Scopes are checked twice: in your JWT **and** against your registered service identity. Adding a
scope to your token alone changes nothing — the identity must be widened too, which is an
operator action.

Environment and credential setup is in the separate onboarding document.

---

## Checklist for a first integration

1. Generate an ES256 keypair; have the public key registered with the scopes above.
2. Confirm `INTERNAL_JWT_ISSUER` and `INTERNAL_JWT_AUDIENCE` for the deployed environment.
3. Sign tokens with a JOSE library — the signature must be raw `r||s`, and `aud` must be a
   plain string, not an array.
4. `GET /v1/jobs` with `job:read` returns `200` when the wiring is right.
5. Create a tenant with `"dry_run": { "mode": "connected" }` first — it validates against live
   data and writes nothing.
6. Drop the `dry_run` and create for real. Poll to `succeeded`.
7. Confirm the tenant has two users and the HQ role reads `Super Admin`.
