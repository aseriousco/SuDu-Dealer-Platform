# Dealer platform handoff: tenant orchestration and recovery

### Recycle suspension flag — pending deployment (2026-09-09)

Branch `codex/fix-recycle-suspension` changes recycle to set only numeric
`sudu_customer.is_suspended = 1`. `customer_status` is left unchanged, including custom
statuses and historical values containing Suspended. No status mapping is used.

New `/recycle` submissions must omit `customer_status` and `is_suspended`; either field
returns 400. Keep `expected_tenant_name` as the optional safety guard. Historical
idempotency receipts still match their original requests; old queued status fields are
ignored when executed by the new worker. Resubmit the original body/key only to recover
its job ID, then retry the failed job through `POST /v1/jobs/{job_id}/retry`.

After a partial failure, retry skips an already-completed BladeX recycle call but still
sets/verifies the billing flag. Already-suspended rows need no update; missing billing
rows remain allowed. Dry runs remain write-free. This adds no restore/unsuspend API,
creation default, or historical data conversion.

Before rollout, ensure the target `sudu_billing.sudu_customer` table has `is_suspended`.
The shared lookup also serves customer registration and repair; an absent column would
break those reads. Deploy both API and worker. No Prisma migration or profile re-seed is
needed; old stored `recycled_status_map` values are ignored.

### Flexible customer status — pending deployment (2026-09-09)

Branch `codex/feat-flexible-customer-status` allows any trimmed, non-empty string for
`customer_status`, preserving case. The field remains optional; null, numbers and blank
strings are invalid. Full creation accepts `"customer": { "customer_status": "Trial" }`;
`step_overrides.register_sudu_customer.customer_status` retains precedence. When omitted,
the selected profile's creation default applies (seeded `Live`). Existing customer rows are
still skipped/rejected according to the registration policy, never updated by registration.

Standalone registration accepts the same flexible string. Recycle no longer accepts a
status override; see the suspension-flag contract above.

Deploy the new API/worker before sending custom values. There is no migration or profile
re-seed for this change. su-code may still enforce its own allowed values or field limits;
orchestrator acceptance does not prove downstream acceptance.

### Accounting addition — pending deployment

Feature branch `codex/feat-no-accounting-integration` adds the exact input `"-"` alongside
`SQL` and `ATC`. Do not send it until the receiving API and worker include this feature;
the earlier DEV deployment described below does not include it.
Use `accounting: { "type": "-" }` for the default organization or inside an additional
organization. Each organization chooses independently. Accounting remains required and every
organization still needs at least one department under the existing default-department rules.
`NONE`, null, and omission are not aliases.

`"-"` creates a `No Accounting Integration` configuration row for that organization with
empty agent/API credentials, no generated API key/fingerprint, and all six posting/account-number
flags set to zero. Tenant master seeding still runs once; organization seeding, warehouse setup,
user assignments and scheduler behavior are unchanged.
Standalone `/accounting-integration` accepts `{ "type": "-" }` under its existing
`tenant:accounting:setup` scope, with the same default-root targeting and optional
`seed_sql_defaults` switch. It is not an API for converting an existing integration.

No database migration or mandatory profile re-seed is required: the missing new mapping alone
falls back for older stored profiles/job snapshots; existing mappings and seed settings are
preserved. Live DEV execution of this addition remains to be verified after deployment.

## Local implementation status — 2026-09-08

All five approved fixes are implemented on local branch `codex/dealer-readiness-fixes`, based on dev `096cf510`: selected-profile routing, encrypted job secrets, resumable admin credential changes, effective overrides/validated organization targets, and atomic retry/recoverable dispatch. Task reviews and the final whole-branch review are closed with no open findings in that scope.

Final verification on 2026-09-08: 56 suites/833 unit tests and 7 suites/76 local PostgreSQL/Redis integration tests passed; `npm run build`, `npm run prisma:validate` and whitespace checks passed. Downstream effects were mocked. These changes are uncommitted and not deployed; reviewed local correctness is not production proof.

Stored-credential recovery accepts optional profile_key/profile_version and resolves reliable tenant provisioning history when omitted. Missing history returns 409 tenant_profile_required; conflicting routing returns 409 tenant_profile_ambiguous before login/storage. Identical historical receipt recovery remains compatible with original SHA and converted HMAC fingerprints; new jobs still reject effective admin/initial-user account collisions. Deployment needs the four migrations and coordinated cutover in section 10, not a profile re-seed.

## 1. Scope, source baseline, and how to use this document

Prepared 2026-09-07. Covers automatic tenant creation, all request overrides, account/password handling, job monitoring/retry, standalone setup, schedulers, repair, recycle, profiles, and dealer integration gaps.

Read the companion **`tenant-orchestrator-field-reference-2026-09-07.md`** for every recognized caller field, exact types, character limits, scope matrix, supported overrides and NEW-submission rejections. The [field-disposition matrix](superpowers/specs/2026-09-07-override-field-dispositions.md) maps every override/auth leaf to executable evidence. This runbook explains how to use those contracts safely. Together these documents supersede older handoffs where they disagree.

Evidence boundaries:

- Orchestrator: fetched remote `dev` at `096cf510b54d05fdc12f1009241e52489db0d746` (PR #44 merge). Its tree exactly matches the inspected clean hotfix worktree at `5cdc2a17a01474d651a6e0177b82658969a1229f`.
- The main local checkout remained on `dev` at `8d95e8c`; it was not switched, pulled, reset, or overwritten. Documentation was added there, but describes the newer verified remote tree.
- Dealer repository source snapshots and integration findings are recorded below. A local checkout is not proof of the version currently deployed.
- Production service permissions are the four scopes supplied by the operator, not a fresh production database read.
- The original audit was read-only. Subsequent approved fixes modify local application code; tests/migrations use only a dedicated local PostgreSQL database and isolated local Redis test keys. No production/DEV tenant mutations, permission changes, live provisioning requests or deployments were made.
- Previously accepted data caveats from tenant 739250 are not reopened here.

## 2. Who owns what

```text
Dealer web -> dealer API -> orchestrator API -> PostgreSQL job + BullMQ
                                                |
                                         orchestrator worker
                                                |
                                  BladeX / su-code / named MySQL operations
```

The browser authenticates to the dealer platform. The dealer API signs a separate internal service JWT for the orchestrator; the browser must never receive the signing private key or call these internal APIs using that key.

The orchestrator service JWT is not a BladeX admin token. Internally, master tenant `000000` credentials handle platform tenant administration and billing records. Tenant-scoped setup runs as the tenant's built-in admin, with stored credentials taking precedence after a successful rotation. The initial user is a separate customer-facing login, normally attached to the child Super Admin role.

Keep these identifiers distinct:

| Identifier | Meaning |
|---|---|
| Dealer client/company ID | Dealer's business record and authorization boundary |
| `request_ref` | Caller correlation label, useful for finding a job after a lost response |
| `Idempotency-Key` | Stable key for one logical submitted operation under one caller service |
| `job_id` | Local orchestrator job UUID; use it to poll/retry |
| Local `Tenant.id` | Orchestrator PostgreSQL tenant UUID, not the URL tenant ID |
| `bladex_tenant_id` | Downstream tenant identity; preserve leading zeroes and use as a string |
| Organization/department IDs | BladeX `blade_dept` IDs; organization is a root, department is a child |
| `scope_key` | Internal step grouping such as tenant/default/an-additional-org; not a public target override |
| `scheduler_id` | su-code quartz document ID, looked up through a tenant-scoped local mapping |

Do not use legacy `tenant_code` as the canonical new provisioning identity. Do not infer completion from a local tenant becoming ACTIVE: that happens when BladeX tenant creation resolves, before later setup steps finish.

## 3. Production dealer permissions

The supplied production identity is `serviceId=sudu-dealer-api`, `keyId=dealer-api-1`, enabled, with:

```json
["tenant:create", "job:read", "job:retry", "tenant:location:sync"]
```

| Capability | Authorized by this identity? |
|---|---|
| Full creation including optional schedulers and final admin changes | Yes, through `tenant:create` on the full endpoint |
| List/get job, including detailed diagnostics | Yes, `job:read` |
| Retry a failed job using its original snapshot | Yes, `job:retry` |
| Standalone accounting-location plant synchronization | Yes, `tenant:location:sync` |
| Add/edit scheduler later | No; requires `tenant:scheduler:create` / `tenant:scheduler:update` |
| Recover stored admin credentials or change admin later | No; requires `tenant:admin_credentials:update` |
| Standalone department/user/package/domain/customer/setup commands | No; each requires its specific scope |
| Repair | No; requires `tenant:repair` |
| Recycle tenant | No; requires `tenant:recycle` |
| Read/change/activate/test profiles | No; requires the corresponding provisioning_profile scope |

Authorization checks both JWT scopes and enabled ServiceIdentity scopes. Merely adding a scope to the token does not grant it. The dealer signer must request a subset of the registered scopes. Keep the established separate-scope pattern; `tenant:create` is not a wildcard for standalone routes.

Recommended operating split: ordinary dealers keep create/read/retry/location capabilities; a trusted backend support role or operator identity handles credential recovery and selected maintenance APIs after authorization/ownership checks. Broader scopes are a separate approval, not a prerequisite for nested full-flow schedulers. There is no public ServiceIdentity registration API.

Important security boundary: the orchestrator's job read/retry handlers are service-scope gated but do not enforce per-dealer customer ownership. The dealer API must enforce that boundary before forwarding a job or tenant identifier; possession of a job ID is not authorization.

### Manual JWT for Postman/support

Dealer runtime normally signs its own short-lived ES256 JWT per required scope. It uses TENANT_ORCHESTRATOR_JWT_PRIVATE_KEY (PEM), TENANT_ORCHESTRATOR_JWT_KID, TENANT_ORCHESTRATOR_SERVICE_ID, TENANT_ORCHESTRATOR_JWT_ISSUER, TENANT_ORCHESTRATOR_JWT_AUDIENCE, and optional TENANT_ORCHESTRATOR_TOKEN_TTL_SEC. The matching public key is registered only in the orchestrator ServiceIdentity.

The built orchestrator image also provides this operator CLI:

```sh
npm run --silent jwt:generate
```

It reads a **different variable convention**: INTERNAL_JWT_ISSUER, INTERNAL_JWT_AUDIENCE, JWT_SERVICE_ID, JWT_KEY_ID, JWT_PRIVATE_KEY_BASE64 (base64 of matching PEM), JWT_SCOPES (space/comma-separated), optional JWT_TTL_SECONDS (default 900). These must already be securely configured in the terminal environment; it cannot mint from the public key in ServiceIdentity. Do not paste a private key into chat, a committed file, or a shell command/history. Output is a live bearer credential: use only in a private Postman variable and do not export it. Generating a token with extra scopes cannot grant permissions absent from the registered identity.

## 4. Full creation: submission and exact execution order

### 4.1 Request example

Substitute verified environment-specific IDs and profile. This example omits direct admin passwords; section 6 explains optional credential changes and section 10 explains the required compatible-reader/encrypted-secret rollout.

```http
POST {{orchestrator_base_url}}/v1/provisioning/tenant-jobs
Authorization: Bearer {{orchestrator_jwt}}
Content-Type: application/json
Idempotency-Key: dealer-demo-acme-create-001
```

```json
{
  "request_ref": "dealer-demo-acme-001",
  "profile_key": "REPLACE_WITH_VERIFIED_PROFILE_KEY",
  "tenant": { "client_name": "Acme Demo" },
  "customer_domain": "https://acme-demo.mes.sudu.ai/login",
  "plan": { "plan_id": "REPLACE_WITH_PLAN_ID" },
  "accounting": { "type": "SQL" },
  "initial_user": {
    "account": "acme.owner",
    "name": "Acme Owner",
    "real_name": "Acme Owner",
    "email": ""
  },
  "customer": {
    "customer_status": "Testing",
    "organization_limit": 2,
    "user_limit": 10,
    "wa_number_limit": 3,
    "wa_able_read": 1,
    "total_price_per_month": 199.9
  },
  "organization_setup": {
    "default": {
      "departments": [{ "dept_name": "HQ" }, { "dept_name": "Finance" }]
    },
    "additional": [
      {
        "organization_name": "Acme Trading",
        "accounting": { "type": "ATC" },
        "departments": [{ "dept_name": "Operations" }]
      }
    ]
  }
}
```

Expected acceptance body: `{ "job_id": "<uuid>", "status": "queued" }`. Nest's current POST default is HTTP 201; do not hard-code 202 as the only success status. Repeating the identical logical operation/key can return the existing job and its current status. The acceptance response does not mean downstream creation is finished.

### 4.2 Execution order

For N organizations (including the default) and S requested schedulers, the planner creates **14 + 7N + S** step records. Thus one organization/no scheduler has 21 steps; two organizations/no scheduler has 28. A skipped final admin step still has a record. Department count changes work inside steps, not the number of step records.

| Order | Step | Scope / result |
|---|---|---|
| 1 | `create_tenant` | Master-authenticated BladeX creation or existing-name lookup; resolve downstream tenant ID |
| 2 | `setup_resource_package` | Plan's tenant_package_id applied to tenant |
| 3 | `update_tenant_details` | Optional expiry and plan tenant_user_limit; skip if neither available |
| 4 | `set_tenant_domain_url` | Tenant domain persisted and read back |
| 5 | `register_sudu_customer` | Billing customer in master tenant, related by tenant_id2; skip existing |
| 6 | `login_new_tenant` | Bootstrap tenant admin login |
| 7 | `setup_object_storage` | Submit OSS configuration, find row, enable it |
| 8 | `setup_organization_structure` | Resolve default root named client_name, create additional roots, create/reuse each organization's requested children |
| 9 | `create_hq_role` | Tenant-level child Super Admin role |
| 10 | `create_initial_user` | Separate login, not built-in admin |
| 11 | `update_user_assignments` | Built-in admin + initial account receive all root/department IDs; existing roles preserved |
| 12 | `update_role_permissions` | Grant plan default_permission_id to target role, or explicit menu_ids override |
| Next N | `setup_accounting_integration` | One per organization, each using its own SQL/ATC/- type; see pending-deployment note |
| Next 1 | `seed_tenant_master_data` | Once per tenant for SQL, ATC and - |
| Next 6 per org | `seed_org_master_data`, `setup_storage_location`, `setup_bin_location`, `setup_batch_configuration`, `setup_transfer_order_configuration`, `setup_prefixes` | Finish these six for default, then each additional organization in request order |
| Next S | `create_scheduler` | One per request entry, after base setup |
| Final | `update_tenant_admin_credentials` | Rename/password change if supplied; otherwise skipped |

Not automatically run: legacy `create_hq_department`, `setup_document_number_rules`, `ensure_orchestrator_service_account`, standalone `create_location_plant`, scheduler update, tenant recycle. In particular, there is no third sudu_orchestrator login created by normal full provisioning and no subsequent switch to it.

### 4.3 What is seeded and where

| Resource | Scope / default |
|---|---|
| Tenant master data | Tenant-level workflow; eight supported tables: irbm, address_purpose, costing_method, country, state, courier_company, business_type, business_activity |
| Serial-number rules + stock strategy | Each organization via ORG_CREATE_SEEDING_MASTER; not the separate legacy document-number step |
| Storage | Each department gets profile defaults HQ and HQL (HQ Load) |
| Bins | Each department gets HQ and HQ Load tied to its corresponding storage |
| Batch level configuration | Each organization; defaults BATCH, running 1, padding 10, preview BATCH-0000000001 |
| Batch-number workflow configuration | Each organization; `%4d`, preview 0001, initial 0, running 1, Never Reset |
| Picking | Organization root plus each direct department |
| Putaway/packing/plant transfer/sales return | Each requested department |
| Prefixes | Each organization: Items/ITM, Suppliers/SUP, Customers/CUST |

The same default codes across organizations/departments are intentional. Warehouse existence checks include tenant + organization + department (and storage parent for bins). Prefix existence checks include tenant + organization + document type. `%4d` is a profile default, not derived from another organization's record; it is not currently an exposed batch-number-format request field.

The published organization-seeding workflow must resolve explicit organization input with legacy first-level-department fallback. The batch workflow's duplicate/default lookups must use the passed organization. Earlier DEV publishing/tenant verification in this task established these changes there; this handoff does not prove equivalent production workflow publication.

## 5. Validation and business restrictions to show in the dealer UI

The field reference is exhaustive. The practical pre-submit checks are:

1. Require name, domain, selected plan, default accounting type, and all four initial-user fields (email may be empty).
2. Limit initial account/name/real_name/email to 45/20/10/45; do not use one shared name limit. Reject initial account admin ignoring case/spaces.
3. Use a trimmed client_name of at most 20 characters until tenant truncation and root-name lookup are aligned. Otherwise the tenant can be created under a shortened name and the later default-root lookup can fail.
4. Require at least one department in each explicit organization; explicit default departments replace HQ. Reject duplicate organization names and duplicate department names within one organization.
5. Additionally guard slug collisions and the reserved default scope; current server validation misses them.
6. Preserve numeric zero for customer limits, wa_able_read, and monthly price. Negative limits/price and fractional limits are invalid; wa_able_read must be numeric 0/1.
7. Keep all IDs as strings. Verify plan/organization/department/user IDs against the selected environment and tenant.
8. If final admin rename is enabled, compare the effective username and effective initial account after all overrides. The server rejects matching names case-insensitively after trimming, before accepting the job.
9. Expose only supported override controls. NEW requests receive field-specific 400 for no-effect options; recognized historical schema fields are not proof of current support.

What is **not** currently enforced by the orchestrator:

- Organization/user/WA count caps from customer limits; commercial entitlement checks must be handled elsewhere if desired.
- Active-plan selection: lookup excludes is_deleted=1 but does not filter is_active. A plan may exist and still fail because tenant_package_id or default_permission_id is missing.
- Domain uniqueness, DNS/subdomain grammar, certificate setup, or tenant-domain reachability.
- Email syntax; broad length/format constraints on organization/dept/role/customer finance fields.
- A strong password policy, random initial-user password generation, cron grammar, workflow/task-type compatibility, or meaningful priority/full_sync bounds.
- A successful creation job does not prove an accounting agent is online, sync has completed, scheduler jobs have fired, or object upload/download works.

Plan effects are separate: package assignment, BladeX account-number limit, billing sibling plan links, and role permissions are separate steps. A standalone package change does not update all of them. Customer user_limit does not overwrite blade_tenant.account_number; that comes from plan tenant_user_limit or explicit details override. Customer registration remains create-only by the agreed contract.

## 6. Admin password and username lifecycle

These tenant credential APIs are for customer tenants, **not platform master tenant `000000`**. Master login deliberately uses configured platform secrets and ignores TenantAdminCredential. Do not use `/admin-credentials` or `/stored-credentials` to rotate/recover that master account. The existing routes do not enforce this exclusion; adding an explicit API guard is a separate follow-up. Master-secret maintenance needs its own authorized operator procedure.

### 6.1 Two different accounts and two different password inputs

- **Built-in admin:** created by BladeX during tenant creation. Its baseline username is admin; its baseline password comes from the deployed new-tenant admin secret. All tenant orchestration runs using this identity (or its stored renamed credentials).
- **Initial user:** caller supplies account/name/real_name/email. If password_secret_ref is absent, password is predictably `${account}@123!`. A secret reference points to a worker environment variable, not a plaintext value. There is no general existing-initial-user password-reset endpoint here.
- **Final admin change:** tenant_admin.password/current_password are plaintext inputs over HTTPS; the worker computes the MD5 parameters BladeX requires. Do not send an MD5 digest as the caller password.

### 6.2 Full-flow admin change

Accepted fragment (placeholders only):

```json
{
  "tenant_admin": {
    "username": "acme.platform",
    "password": "REPLACE_SECURELY_WITH_NEW_PASSWORD",
    "current_password": "REPLACE_SECURELY_WITH_CURRENT_PASSWORD"
  }
}
```

Either username or password may be omitted; absent/empty object skips the step. It remains last in full provisioning. Current password precedence is explicit `current_password`, then the verified stored password, then the configured bootstrap password when no stored credential exists. The chosen pair must actually authenticate; database/key/transport failures do not silently fall back. Username-only changes preserve the current password, password-only changes use the mapped admin's live account, and verified equal-value changes cause no downstream mutation.

Actual sequence:

1. Offline dry-run reports intent; connected dry-run validates without creating mappings/intents or resuming mutations.
2. Validate key usability and internal tenant/job/step association. An existing immutable completion receipt returns the recorded completion without reapplying old credentials.
3. Resolve the same admin by stable downstream user ID. For a missing legacy mapping, establish successful-login identity, tenant membership and active root-admin role evidence before storing the mapping. A matching username alone is insufficient.
4. Verify current credentials and atomically acquire a per-tenant operation with encrypted immutable current/desired pairs. Another unresolved operation returns a conflict; no timeout-based takeover is allowed.
5. Before a required rename, persist `RENAME_SUBMITTED`, send the existing full-record BladeX update and read back the stable user ID. Unknown in-flight completion requires reconciliation rather than another rename.
6. Before a required password change, persist `PASSWORD_SUBMITTED`, send the confirmed MD5 old/new/confirmation fields, and verify the desired pair through login. On restart, successful desired-pair verification recognizes an already-applied change without resubmitting it.
7. In one local transaction, promote verified encrypted credentials, increment their revision, complete the operation and persist its immutable step completion receipt. A storage failure rolls back all four local changes while keeping recoverable encrypted intent.
8. Token services check stored revision on each lookup, so separate API/worker processes stop reusing stale cached credentials after promotion. Wrong/missing key cannot return a cached stored token.

`TENANT_CREDENTIAL_KEY` must be the same valid 32-byte key on API and worker, represented as 64 hex characters or base64. Preserve it across deployments. Replacing it without migrating existing ciphertext breaks stored credential decryption.

**Encrypted job requests (local fix, deployment required):** new full/standalone admin jobs persist internal references in request/step JSON and an AES-256-GCM encrypted secret bag in the same database transaction. The worker hydrates only the effective admin request in memory. Pending desired credentials are separate from verified current credentials. Missing/unusable TENANT_CREDENTIAL_KEY fails secret-bearing submission before tenant/job writes; secretless requests do not gain this requirement. API/worker diagnostics and password-query tracing are redacted. This fixes new writes, not historical exposure: old snapshots need the controlled converter in section 10; backups and previously emitted logs are unaffected.

### 6.3 Change an existing tenant's admin

Requires a privileged identity with tenant:admin_credentials:update:

```http
POST {{orchestrator_base_url}}/v1/tenants/{{tenant_id}}/admin-credentials
Authorization: Bearer {{support_jwt}}
Content-Type: application/json
Idempotency-Key: admin-change-unique-operation-001
```

```json
{
  "profile_key": "REPLACE_WITH_VERIFIED_PROFILE_KEY",
  "password": "REPLACE_SECURELY_WITH_NEW_PASSWORD",
  "current_password": "REPLACE_SECURELY_WITH_CURRENT_PASSWORD"
}
```

This is a job: poll it to completion. Repeated customer-tenant rotations use the stable admin ID, including after renaming. Use a new Idempotency-Key for a genuinely new change; retry an existing failed job only with its original saved request. A concurrent or unresolved credential operation must finish or be reconciled first. This API does not change an arbitrary tenant user's password.

### 6.4 External tenant onboarding or externally changed credentials

Do not reset the customer password just to repair access. Tell the orchestrator the verified current credentials:

```http
POST {{orchestrator_base_url}}/v1/tenants/{{tenant_id}}/stored-credentials
Authorization: Bearer {{support_jwt}}
Content-Type: application/json
```

```json
{
  "username": "CURRENT_ACTUAL_ADMIN_USERNAME",
  "password": "CURRENT_ACTUAL_ADMIN_PASSWORD"
}
```

This call is synchronous, requires no Idempotency-Key, and accepts optional profile_key and positive profile_version (version requires key). It verifies login against the selected environment before encrypting/storing the pair and returns stored:true/verified:true. It changes no BladeX password.

**Environment selection:** without selectors, the route requires reliable non-dry-run provisioning history for this tenant. It uses the latest eligible immutable snapshot only when all eligible history identifies one environment. No reliable history produces 409 tenant_profile_required; conflicting environment evidence produces 409 tenant_profile_ambiguous. An external tenant with no history needs explicit profile_key (and optionally profile_version). A supplied selector that contradicts known tenant environment evidence is rejected before login/storage. There is no silent dev_default fallback on this recovery route.

The route participates in the same per-tenant guard and verified promotion protocol. An unresolved job-owned credential change blocks this route with 409 `tenant_credential_change_in_progress`; it cannot overwrite that job's intent. If synchronous promotion fails after verification, retrying the identical pair can resume its own jobless intent, while a different pair cannot replace it. Named reconciliation failures return 409 `tenant_credential_needs_reconciliation` with safe operation metadata.

**First-time onboarding:** for a tenant created outside this orchestrator, send `profile_key` alongside the current root-admin `username` and plaintext `password` over HTTPS (`profile_version` is optional). A renamed root-admin account is supported. No old password, new password, user ID, database password or BladeX client secret is required in this body; shared credentials remain server-side. The caller needs `tenant:admin_credentials:update` in both its JWT and registered identity.

Login must prove the requested tenant and user; active tenant/root-admin membership is then checked through the selected profile's MySQL read connection before any new registration. A missing local tenant becomes `EXTERNAL_REGISTERED`, with its tenant/admin mappings recorded transactionally. Existing status is preserved, conflicting admin mappings are rejected, and concurrent requests cannot create duplicate registrations. Invalid credentials/identity create no registration. Encrypted credential promotion retains the existing recovery protocol; a later storage failure may leave a verified local registration, so retry the same pair. Success creates no provisioning job and changes no BladeX password or business data. A concurrent credential-operation conflict remains a 409; retry the same pair after the other request finishes.

Onboarding does not create full-provisioning history: keep supplying the explicit profile on subsequent recovery calls, and select the intended profile on standalone setup requests. Use the standalone API for the actual setup you need only after access is verified; do not run full tenant creation to onboard an existing tenant.

After successful recovery, retry the failed setup job if its original request is still valid. Unknown current credentials require an authorized BladeX account-recovery process first; this API cannot discover them. Do not use stored-credentials to bypass an unresolved job-owned change.

### 6.5 Partial admin-change failure

Downstream rename/password calls and local storage cannot be one atomic transaction. Durable checkpoints and verification make known completed changes resumable; they do not prove an outstanding HTTP request has stopped. The generic retry endpoint cannot inject a new current_password or change the original request.

| Job error / evidence | Required action |
|---|---|
| `tenant_credential_change_in_progress` | Inspect the owning operation/job. Do not submit another change or overwrite its intent. |
| `tenant_credential_needs_reconciliation` | Stop competing work, prove prior requests finished, establish the stable admin's actual account and verify known desired/current credentials in the correct environment. Use the controlled operator process below. |
| `tenant_credential_completion_unverified` | Completion evidence or its job/tenant association is missing/corrupt. Stop for operator investigation; do not clear the receipt or create a replacement job to bypass it. |
| Desired credentials already work, but storage previously failed | Retry the original owning job after fixing storage/configuration. The service verifies desired credentials and repeats promotion only. |
| Older A completed, newer B completed, then A retries | A's immutable receipt prevents reapplying its old credentials; B remains unchanged. |
| Neither known pair works, or identity is unverified | Use authorized downstream account recovery/reconciliation. The orchestrator will not guess passwords or admin identity. |

Metadata-only operator report, from a compatible built runtime:

```sh
npm run --silent credentials:operations -- --tenant-id <bladex_tenant_id>
```

Only after proving quiescence and reconciling downstream state, reopen the exact existing `NEEDS_RECONCILIATION` intent:

```sh
npm run --silent credentials:operations -- --apply --tenant-id <bladex_tenant_id> --operation-id <operation_id> --expected-version <version> --confirm-quiescence
```

The flag asserts operator evidence; it does not stop workers or remote requests. Stale versions and other phases fail. Apply preserves the original owner and encrypted pairs, changes only the phase to PREPARED, and does not change the BladeX password or promote credentials. Retry the original job afterward; desired credentials are checked before any further mutation. Do not invent completion receipts for pre-protocol jobs: uncertain historical admin-step partial successes require reconciliation before automatic retry at cutover. See [admin-credential-recovery-rollout.md](admin-credential-recovery-rollout.md) for the complete operator procedure.

## 7. Job monitoring, idempotency, and failure recovery

### 7.1 Keep and poll the job ID

```http
GET {{orchestrator_base_url}}/v1/jobs/{{job_id}}?detail=true
Authorization: Bearer {{orchestrator_jwt}}
```

Poll with a modest interval/backoff (for example, 2–5 seconds while the UI is open). Stop on succeeded or failed; show pending/queued/running without claiming readiness. Persist the relationship between dealer customer, request_ref, submitted payload version, and job_id in the dealer API.

Response includes job_id, type, bladex_tenant_id/name, request_ref, status, retry_count, error and steps. Each step has its own id, step_id, scope_key, phase, order, status, outcome, reason, retry_count and error. Detail adds redacted request/result/substeps plus runtime_context, including organization/resource/scheduler IDs where published. Multiple steps have the same step_id in multi-org runs: key UI rows by step UUID or step_id + scope_key, not step_id alone.

Find a lost job response:

```http
GET {{orchestrator_base_url}}/v1/jobs?request_ref=dealer-demo-acme-001
Authorization: Bearer {{orchestrator_jwt}}
```

Other filters are bladex_tenant_id and status. The list returns newest rows first with no implemented row cap/pagination; request_ref is a filter, not a uniqueness guarantee. Use narrow filters to avoid large responses.

### 7.2 Idempotency rules

- Generate one Idempotency-Key per intended operation; persist it before submitting.
- If the HTTP response is lost or times out, resubmit the same key and same body. Do not mint a new key merely because the network failed.
- Same caller service + key + same parsed request returns the existing job, including a failed job; it does not rerun it.
- Same key with a changed body returns 409. request_ref is not a replacement for Idempotency-Key.
- Use a new key for a genuinely new standalone change or a separately authorized corrected creation. Never use a new create request to repair an already-created tenant.
- Job creation and a durable dispatch intent now commit together. A Redis failure leaves the accepted job QUEUED; the dispatcher retries that same attempt at startup and every five seconds. Repeating the original key returns its job, not another tenant. A queued job that does not progress still needs worker/Redis/dispatch diagnosis.

### 7.3 Retry a failed job

```http
POST {{orchestrator_base_url}}/v1/jobs/{{job_id}}/retry
Authorization: Bearer {{orchestrator_jwt}}
```

No body is needed. No replacement plan, password, dry_run value, profile version, overrides, or target list is accepted. The handler atomically claims only the observed FAILED attempt, increments retry_count once, resets eligible failed/queued steps, and records a dispatch intent in the same transaction. Succeeded/skipped steps and internal credential completion receipts remain untouched. Remaining queued steps run after the failed step succeeds. A FAILED job with an orphan RUNNING step requires operator reconciliation first.

Retry uses the original request and stored profile snapshot but the deployed worker code and current external workflow implementations. Publishing a corrected downstream workflow or deploying a code hotfix can therefore unblock the existing job; changing the active profile alone does not rewrite its snapshot.

Disable duplicate UI submissions and poll after acceptance. Concurrent retry requests are protected in PostgreSQL: only one wins the observed failed attempt; losing requests receive a conflict. Dispatch uses a deterministic queue ID per job/attempt, and workers claim that attempt with a database execution token. Stale deliveries and stale local state writes cannot advance another attempt. These protections do not cancel a downstream HTTP request already sent or guarantee exactly-once external effects.

RUNNING jobs are never automatically taken over after a timeout. Operators must stop the old execution and reconcile downstream state, then use the exact-attempt/token recovery command before the ordinary retry API. Existing legacy queued messages require a coordinated cutover; see [retry dispatch rollout](retry-dispatch-rollout.md). These are operator procedures, not additional dealer permissions or public force-retry APIs.

### 7.4 Failure decision table

| Situation | Correct action |
|---|---|
| HTTP 400 validation error, no accepted job | Correct the request; fix UI/DTO validation. Do not poll/retry a nonexistent job |
| HTTP 401/403 | Check signature/KID/sub/issuer/audience/expiry/enabled identity/scopes; no tenant retry fixes auth |
| 409 idempotency mismatch | Recover original operation/key/body; use a new key only for a genuinely separate operation |
| 409 tenant_name_taken | Follow existing job/tenant; do not create a second tenant with a similar name to bypass recovery |
| Transient downstream/network error | Inspect failed step and downstream state; when original input remains correct, retry same job |
| Plan not found/deleted/missing package/permissions | Correct source plan data if that is truly the same intended plan, then retry. Another plan cannot be passed to retry |
| Tenant exists and original plan/input is wrong | Operator-led reconciliation using standalone APIs as appropriate; no public full-job payload patch/resume-with-new-plan API |
| Failure before any tenant ID resolved | Name reservation may be released as PROVISIONING_FAILED. Verify no ambiguous downstream creation; timeout may hide a real write. Choose either retrying the original job or submitting a corrected replacement. Once a replacement is accepted, never retry the old job: the backend does not enforce supersession |
| tenant_admin_login_failed / repair credential 409 | Restore actual stored credentials using privileged recovery route, then retry if the original step remains valid |
| master_admin_login_failed | Fix platform credential/routing configuration; do not alter customer credentials |
| credential_storage_unavailable | Configure/check the same TENANT_CREDENTIAL_KEY on API + worker; worker executes rotation |
| organization_tenant_not_persisted / ambiguous_downstream_target | Stop; inspect tenant/root ownership and duplicates. Do not auto-create another organization |
| org_seed_not_persisted | Verify workflow publication/organization input and actual organization-scoped rows before retry |
| Scheduler pending/mapping ambiguity | Reconcile quartz row and local mapping manually before any resubmission; see scheduler section |
| Queued indefinitely | Check pending ProvisioningDispatch rows, worker/Redis health, deployment and logs. Dispatcher retries recoverable enqueue failures; ordinary retry is only for FAILED jobs |
| RUNNING after worker loss, or FAILED with a RUNNING step | Stop the old execution, reconcile its downstream effects, then follow the exact-attempt/token operator procedure in retry-dispatch-rollout.md. Never force a second worker or edit retry_count |
| Failed recycle after downstream recycle | With the suspension-flag worker deployed, retry the same failed job; billing is reconciled without repeating BladeX recycle |

There is no global rollback. Successfully created organizations, users, storage, or billing rows remain after a later failure. Individual handlers vary in idempotence; “retry skips succeeded steps” does not prove every partially executed failed step is duplicate-safe.

### 7.5 Dry-run is not a promotion workflow

For full creation, use dry_run.mode=offline to validate/plan without downstream reads/writes, or connected for read-only downstream validation. Connected full provisioning cannot create its missing tenant/organizations and then validate their dependent resources; new organizations explicitly require offline planning first. Exception: the repair route still performs registration/login/state reads during planning even if its resulting job is requested offline. Profile tests called offline also check configured secret references and database URL syntax.

Dry-run still creates local jobs, idempotency records and, for full creation, tenant reservations. A successful dry-run can keep the name reserved even though no real tenant exists. Use a separate dry-run tenant name/key/request_ref; do not treat removing dry_run and resending the same request as supported promotion. Same-key body change conflicts; a new key with the same reserved name may also conflict. There is no public dry-run promotion/cancel/name-release API.

Offline success does not validate a live plan, password, database schema, or workflow publication. A synthetic dry-run tenant ID is not a real downstream ID.

## 8. Useful standalone operations

Each example below is an HTTP request-body fragment for the named route. Add common fields, bearer scope from the field reference, and a new operation-specific Idempotency-Key for job-creating routes. Poll the returned job. These are direct orchestrator APIs, not a claim that dealer API exposes matching proxy endpoints.

### Add a department or accounting location later

`POST /v1/tenants/{id}/departments`:

```json
{ "dept_name": "Finance", "full_name": "Finance", "parent_id": "EXISTING_ORGANIZATION_ID", "dept_category": 2, "sort": 2 }
```

`parent_id: 0` is supported for root organization creation, but this standalone route does not enforce “root must have a department” and does not orchestrate all organization resources. There is no one-shot add-fully-configured-organization endpoint. Do not expose it as equivalent to full organization_setup.

`POST /v1/tenants/{id}/location-plants`:

```json
{ "request_ref": "source-location-task-001", "organization_id": "EXISTING_ORGANIZATION_ID", "dept_name": "WH-A", "full_name": "Warehouse A" }
```

Location sync validates the active root belongs to the tenant, normalizes name uppercase, reconciles an exact direct child, and uses a Redis lock. It does not also create warehouse storage/bins, assign users, or run all tenant provisioning. More than one matching child stops with location_plant_duplicate_children. Lock unavailability/timeouts/ownership loss need operational diagnosis; don't bypass the lock with repeated new requests.

### Assign a user to new organization/departments

`POST /v1/tenants/{id}/users/update-assignments`:

```json
{ "account": "acme.owner", "dept_ids": ["ORG_ID", "HQ_DEPT_ID", "FINANCE_DEPT_ID"] }
```

Send the complete desired nonempty assignment list, not only the new ID: this replaces the supplied assignment field. Omitted role_ids preserves roles; omitted dept_ids preserves departments for a targeted user. Empty arrays are not a supported clear-all mechanism. user_id takes precedence over account if both are sent. New departments added after provisioning do not automatically propagate to every user's assignments.

### Create another user / role / explicit role grant

`POST /users` body:

```json
{ "account": "acme.finance", "name": "Finance", "real_name": "Finance", "email": "", "password_secret_ref": "WORKER_FINANCE_INITIAL_PASSWORD", "dept_ids": ["ORG_ID", "FINANCE_DEPT_ID"], "role_ids": ["ROLE_ID"] }
```

`POST /roles` accepts role_alias, role_name, parent_role_id, sort, but currently checks for an existing HQ/Super Admin role rather than the requested custom alias. A different requested role can be reported skipped_existing. Treat generic custom-role creation as a gap, not a reliable convenience API.

`POST /role-permissions` body:

```json
{ "role_id": "ROLE_ID", "plan_id": "VERIFIED_PLAN_ID" }
```

Alternatively provide menu_ids instead of plan_id. Explicit empty menu_ids is accepted and bypasses plan permission resolution; treat this as a potentially destructive permissions change, not a missing-value fallback.

### Subscription/package/domain changes

`POST /details`:

```json
{ "expire_time": "2027-09-30 23:59:59", "account_number": 30 }
```

This updates BladeX subscription details only. account_number must be a positive integer; 0 is rejected here even though customer.user_limit accepts 0.

`POST /package` with `{ "plan_id": "VERIFIED_PLAN_ID" }` updates package only. Separately decide details and role permissions. `/sudu-customer` does not update the existing customer's plan/price/limits; there is no generic subscription-upgrade transaction.

`POST /domain` with `{ "customer_domain": "https://new-domain.mes.sudu.ai/login" }` updates blade_tenant.domain_url only. Use the platform's full login-URL convention even in direct orchestrator calls when the dealer lookup must find it. The endpoint does not synchronize existing sudu_customer.customer_domain or dealer DNS. Re-registering the customer will skip an existing row.

### Repair missing warehouse setup

`POST /storage-locations` single row:

```json
{ "organization_id": "ORG_ID", "plant_id": "DEPT_ID", "storage_location_name": "HQ", "storage_location_code": "HQ", "location_type": "Common", "storage_status": 1, "is_default": 0 }
```

`POST /bin-locations` explicitly scoped rows:

```json
{ "rows": [{ "organization_id": "ORG_ID", "plant_id": "DEPT_ID", "storage_location_id": "STORAGE_ID", "bin_name": "HQ", "bin_code_tier_1": "HQ", "bin_location_combine": "HQ" }] }
```

Existing matching rows are reused/skipped, not necessarily updated. Confirm the organization/department relationship yourself; several generic target lookups are less strict than location-plants. Prefer explicit IDs over tenant-wide HQ/root fallbacks in multi-org cases.

Standalone `/accounting-integration`, `/org-seeding`, `/document-numbers`, `/prefixes` still lack an explicit public organization selector; do not advertise these as arbitrary additional-organization repair tools. `/batch-configuration` now validates and uses its explicit organization for both lookup/write substeps. `/transfer-order-configuration` uses a single validated organization/plant across selected areas. Storage/bin rows likewise use same-target references. An explicit plant can be the validated root itself or an active direct department; absent/ambiguous default root/HQ fails closed. Offline previews preserve supplied IDs but do not prove live ownership; connected previews perform read-only validation.

Full-flow supported generic overrides now apply in every planned organization; nested picking/prefix values merge, custom arrays replace defaults, and planned identities remain protected. Custom storage/bin rows must satisfy required fields and downstream references, including configured loading storage when putaway is selected. The same default code can still exist in different organizations/departments. Full transfer cannot be disabled or given an empty areas list; standalone explicit disabled setup retains its skip behavior. Package/menu-filter no-ops, excluded full-step overrides and ineffective document switches are rejected on NEW submissions. See the companion field reference before copying old examples.

An explicit full domain override becomes the domain used by both tenant setup and customer creation. Conflicting explicit aliases or domain overrides return 400. Supported authentication secret references and all eight object-storage fields now take effect over the corresponding saved-profile defaults; verified stored admin credentials still win. This does not change existing-customer registration into an update API.

### Repair endpoint

`POST /repair` example:

```json
{ "profile_key": "REPLACE_WITH_VERIFIED_PROFILE_KEY", "targets": ["setup_storage_location", "setup_bin_location"] }
```

Requires tenant:repair. This discovers eligible missing state and builds a new repair job; it does not rerun the original full provisioning body. It checks tenant access first using the same resolved profile snapshot selected for the repair job. targets is a filter, not force-run; absent or empty targets considers all repairable steps. Repair has no step_overrides/organization_setup body. It uses legacy root/HQ state rather than fully reconstructing every organization's desired setup. Many targets have no scanner and are queued as scan_unverified; others only test row presence. The planner report is persisted in requestSnapshot but is not exposed by job GET. Have support inspect the stored plan/step list and confirm its target scope; an already-present outcome does not prove fields are correct.

### Recycle endpoint

`POST /recycle` body:

```json
{ "expected_tenant_name": "Acme Demo" }
```

Requires tenant:recycle. This is an intentional lifecycle action, not normal failed-provisioning cleanup. It soft-recycles the BladeX tenant and sets only the billing row's is_suspended to numeric 1; customer_status stays unchanged. It does not transactionally undo provisioning, delete every associated row, release all local state, or offer a restore/unsuspend operation. Supply expected_tenant_name as a safety guard. New requests containing customer_status or is_suspended return 400. If the billing update fails, retry the same failed job after resolving the error; the new worker still reconciles billing when BladeX is already recycled. The result's customer block reports is_suspended, with outcome retired, already_retired, or no_billing_customer.

## 9. Schedulers: create now, create later, update, and recover

Full creation can include schedulers under tenant:create. Omit them if not needed. Later creation and update use separate scoped APIs; agent_id + task_type is deliberately not unique.

`POST /v1/tenants/{id}/schedulers` example (operator must verify referenced workflow and its task contract):

```json
{
  "agent_id": "VERIFIED_AGENT_ID",
  "task_type": "VERIFIED_TASK_TYPE",
  "workflow_id": "VERIFIED_WORKFLOW_ID",
  "cron_expression": "0 */1 * * * ?",
  "priority": 1,
  "full_sync": false,
  "status": "Paused",
  "description": "Provisioned schedule; enable after verification"
}
```

Paused is a sensible explicit integration-test choice. If omitted, status defaults Running. This example's priority/full_sync demonstrate accepted JSON types, not a guarantee of the target workflow's interpretation. The orchestrator does not validate cron grammar or agent/workflow compatibility.

Inspect the detailed job to obtain the returned scheduler_id. Store it with the dealer tenant and purpose. Update via:

```http
POST {{orchestrator_base_url}}/v1/tenants/{{tenant_id}}/schedulers/{{scheduler_id}}
Authorization: Bearer {{support_jwt}}
Content-Type: application/json
Idempotency-Key: scheduler-change-unique-operation-001
```

```json
{ "status": "Running", "cron_expression": "0 10 0 * * ?" }
```

The update API merges supplied fields with the mapped scheduler record. At least one field is required. A scheduler created outside this orchestrator does not automatically have the local mapping required for update; there is no public import/link endpoint.

Creation writes a deterministic pending local mapping **before** submitting downstream. If submission times out, there may already be a quartz row. Retry detects pending state and stops for reconciliation instead of risking a duplicate. An operator must inspect the tenant's downstream quartz jobs and local TenantExternalMapping, establish whether creation happened, and repair the mapping/pending state under an approved procedure. Do not invent a second scheduler by resending under a new key while that outcome is unknown.

Parameter updates merge against local mapping metadata, not a fresh downstream read. If changing any of agent_id/task_type/workflow_id/priority/full_sync in an offline scheduler-update dry run, all five must be supplied; otherwise it fails scheduler_offline_update_requires_full_payload. Status/cron/description-only offline updates do not need that full set. Priority and full_sync are converted to strings inside the downstream workflow parameters (false becomes "false", numeric 0 becomes "0").

Creation/registration success is not execution success. Separately inspect quartz status, next/last execution, workflow instances, integration task status, and the target accounting agent. Do not infer timezone or second-level cron support solely from a syntactically valid expression; verify the deployed scheduler.

## 10. Deployment, profiles, and operational diagnostics

This branch changes the internal queue protocol and adds encrypted job secrets and credential-operation state. Follow [retry dispatch cutover](retry-dispatch-rollout.md) and [admin recovery rollout](admin-credential-recovery-rollout.md), together with legacy conversion below. A rolling deployment mixing old and new consumers is not supported. These procedures have only been exercised locally; no production migration or conversion has been performed.

Four additive migrations implement the local changes: `20260907000100_add_provisioning_job_secret`, `20260907000200_add_tenant_credential_operation`, `20260907000210_harden_credential_resume`, and `20260907000300_add_job_dispatch`. They do not convert historical plaintext, reconcile interrupted jobs, or remove legacy queue entries automatically. No new dependency, external service, public scope or encryption key is required. Preserve the existing `TENANT_CREDENTIAL_KEY`; API, worker and operator tools must use the same durable value.

API and worker are separate processes. API validates/authenticates/enqueues and serves status; worker performs setup. They must use the intended common PostgreSQL/Redis and compatible configuration. Internal JWT signing is dealer-side; BladeX credentials and initial-user secret references resolve worker-side.

For an approved deployment requiring migrations/profile changes, in the built API container terminal (typically /app), an operator runs:

```sh
npx prisma migrate deploy
npm run prisma:seed
```

Run only what the change requires. Profile seed writes stored configuration; inspect deployment-specific profiles before reseeding. Source default edits alone do not update stored profile values, and seeding does not update snapshots in already-created jobs. Local source workflows require a seed compile first (`npx tsc -p tsconfig.seed.json`); runtime images already contain the compiled seed.

These five fixes do not change profile defaults/schema and therefore do **not** require a profile re-seed. They do require the four migrations and coordinated API/worker/queue cutover above. Do not run prisma:seed merely because it appears in the general recipe.

Explicitly select the intended production profile on job requests. The default key remains dev_default, regardless of NODE_ENV. Profile endpoint reads can inspect active config with a privileged identity; version creation takes the entire config directly, activation takes version, and offline/connected tests return checks without downstream writes. Do not treat a profile connectivity check as an end-to-end tenant test or proof all handlers honor profile routing.

Current profile resolution recursively merges stored objects over code defaults and replaces arrays, contrary to older top-level-only notes. Stored existing values still win. The seed upserts version 1 of dev_default as ACTIVE and main_default as INACTIVE; it does not update a custom production key or deactivate higher active versions. Activation does not require a passing profile test. Treat seeding/activation as deliberate configuration changes, not a blanket recovery command.

For incidents, collect only redacted evidence:

- Environment, deployed revision, job_id, request_ref, tenant ID and failing step_id + scope_key.
- HTTP status plus structured error_code/message; downstream HTTP 200 can still contain a failed body.
- Detailed job response, retries already attempted, actual side effects observed.
- Separate API and worker logs; correlate sudu.provisioning.job_id / trace_id where available.
- Selected profile/version, workflow IDs/published versions, DB/Redis reachability; no passwords, JWTs, private keys, API keys, or credential-bearing connection URLs.

### Encrypted job-secret rollout and legacy conversion

Before deploying override corrections, inventory unfinished jobs as well. The query below returns identifiers and field names only, never password/request values. Full-flow jobs with overrides/auth customization and unfinished standalone jobs are review candidates; being listed is not evidence of an error. Confirm the intended environment and use read-only database access.

```sql
SELECT j.id, j.type, j.status, j."retryCount", j."bladexTenantId",
       j."profileKey", j."profileVersion",
       ARRAY(SELECT jsonb_object_keys(
         CASE WHEN jsonb_typeof(j."requestSnapshot"->'step_overrides') = 'object'
              THEN j."requestSnapshot"->'step_overrides' ELSE '{}'::jsonb END
       )) AS override_steps,
       ARRAY(SELECT jsonb_object_keys(
         CASE WHEN jsonb_typeof(j."requestSnapshot"->'auth_overrides') = 'object'
              THEN j."requestSnapshot"->'auth_overrides' ELSE '{}'::jsonb END
       )) AS auth_fields,
       ARRAY(SELECT jsonb_object_keys(
         CASE WHEN jsonb_typeof(j."requestSnapshot"->'body') = 'object'
              THEN j."requestSnapshot"->'body' ELSE '{}'::jsonb END
       )) AS standalone_body_fields
FROM "ProvisioningJob" j
WHERE j.status IN ('QUEUED', 'RUNNING', 'FAILED')
  AND (j.type <> 'TENANT_PROVISIONING'
       OR j."requestSnapshot" ? 'step_overrides'
       OR j."requestSnapshot" ? 'auth_overrides')
ORDER BY j."queuedAt", j.id;
```

Review the selected profile and intended operation privately before resuming each affected job. Preserving its snapshot does not freeze worker behavior: supported fields that older code ignored may become effective. Do not patch a saved request, change its idempotency fingerprint, or assume new-submission validation has retroactively validated it. Runtime tenant/org/dept ownership checks still apply.

Warehouse row-level transport controls (for example url, headers or access_token) are forbidden, including in historical execution: such rows stop before authenticated submission. They must not redirect a tenant-authenticated call. Reconcile any affected historical custom request under operator control instead of bypassing the check. Ordinary nested business URLs are not request-routing instructions.

This is operator work, not a dealer API call. Obtain authorization for the target environment and conversion scope. Pause mutation intake and stop/drain old workers before applying migrations and deploying compatible API/worker readers and writers. Keep the existing durable TENANT_CREDENTIAL_KEY consistent on API, worker and converter; do not generate a replacement key during deployment.

```sh
# Report only; outputs IDs, codes and counts, never passwords
npm run --silent jobs:protect-secrets
npm run --silent jobs:protect-secrets -- --job-id <job_uuid>

# Only after reviewing the report and pausing intake/workers
npm run --silent jobs:protect-secrets -- --apply --job-id <job_uuid>
npm run --silent jobs:protect-secrets -- --apply --all --confirm-paused
```

The batch flag asserts that the operator paused processes; it does not stop them. Each conversion locks one job and atomically verifies/replaces its known secret copies, encrypted bag and both idempotency fingerprints. RUNNING jobs/steps, inconsistent copies and unverifiable legacy hash wrappers stop conversion for that job. Batch processing continues across per-job errors: inspect codes/counts, not just process exit. Repeated conversion is a no-op for an already protected valid job. New secret-bearing requests use a keyed, versioned fingerprint of the original request; same body/key still reuses its job, and changing a password with that key still conflicts.

Run the report again and resolve all remaining legacy candidates/manual-review failures before resuming. Never roll back to an artifact that cannot read protected jobs, and never restore plaintext snapshots to accommodate an old worker. Encrypted bags live with their jobs and cascade on deletion; no automatic purge or credential rotation was added. Failed/unreconciled jobs must retain their secrets. Old backups, emitted telemetry and completed-job retention require separate authorization; this converter cannot erase historical copies outside the database.

No public API currently provides job cancellation, forced queued-job requeue, arbitrary payload patch, full multi-org desired-state reconciliation, tenant restore, generic existing-customer update, generic initial-user password reset, or scheduler import/delete. Escalate these cases rather than improvising direct database edits from dealer UI.

## 11. Dealer API/web integration: current state and handoff work

### 11.1 Audited revisions

- Dealer API: clean main checkout `88d1569397693bd8df51f937b56746593af10874`; read-only remote check confirmed the same main revision.
- Dealer web: clean main checkout `32ec6bbf893f72ebb19dd235deca7bdfe8dad869`. Remote main was fetched to `0f964c6d4204c2f93f2bec514d2f05bad4c1156d` without changing the checkout. Its changes are confined to role-tree responsive presentation/tests and a related plan; the tenant integration files inspected are unchanged.
- No production deployment revision/configuration was read. References below use repository-relative paths with these revision boundaries.

### 11.2 Current dealer request contract and mapping

Browser uses session cookies against `/api`; dealer API generates orchestrator JWTs and stores submission state before calling upstream. The dealer body is **camelCase** and is not the raw orchestrator body:

```json
{
  "clientName": "Acme Demo",
  "planId": "REPLACE_WITH_PLAN_ID",
  "customerDomain": "acme-demo.mes.sudu.ai",
  "accountingType": "SQL",
  "initialUser": {
    "account": "acme.owner",
    "name": "Acme Owner",
    "realName": "Acme Owner",
    "email": ""
  }
}
```

| Dealer field/config | Orchestrator output |
|---|---|
| Generated requestRef | request_ref |
| Generated idempotencyKey | Idempotency-Key header |
| ORCHESTRATOR_PROFILE_KEY | profile_key, omitted when unset; profile_version not sent |
| clientName | tenant.client_name |
| planId | plan.plan_id |
| accountingType | accounting.type |
| customerDomain (hostname) | customer_domain as `https://{host}/login`, **not just the hostname** |
| Fixed Testing status | customer.customer_status=Testing |
| expireTime | expire_time |
| tenantAdmin.username/password | tenant_admin.username/password, only if supplied |
| initialUser.account/name/realName/email | initial_user.account/name/real_name/email |
| ownerMemberNodeId | Dealer ownership only, not tenant-internal organization selection |
| Legacy packageType | Accepted dealer-side but not forwarded; plan supplies package |

Dealer submit creates an encrypted local copy of a supplied admin password under DEALER_CREDENTIAL_KEY, then forwards plaintext over HTTPS. It trims admin username but deliberately preserves password spaces. Dealer-side encryption and orchestrator job-secret encryption protect different persistence boundaries. The dealer's credential key and orchestrator's TENANT_CREDENTIAL_KEY are different responsibilities; do not interchange them. Older orchestrator snapshots remain a separate conversion/retention concern.

Source: dealer API `src/tenant-orchestrator/orchestrator.client.ts:210`, `src/tenant-provisioning/tenant-provisioning.service.ts:53`, `:116`, `:175`; web `src/components/tenants/create-tenant/CreateTenantForm.tsx:233`.

### 11.3 Dealer-specific restrictions beyond orchestrator validation

| Rule | Dealer behavior |
|---|---|
| Authorization | Session + dealer tenant:create permission. Platform-plane actors cannot provision through the normal submit path |
| Plan | Required, maximum 32 characters; live catalog must be readable and contain the selected usable plan |
| Plan catalog completeness | Requires plan_code, tenant_package_id, nonempty permission array, resolvable ERP plan and positive user limit; stronger than orchestrator lookup alone |
| clientName | Maximum 200 characters in dealer API, only a truncation warning in UI; incompatible with current default-root lookup above 20 |
| Initial user | 45/20/10/45 lengths aligned across UI/API/orchestrator. Dealer validates nonempty email syntax, whereas orchestrator permits any string <=45 |
| customerDomain | Lowercase hostname, maximum 253; DNS labels bounded to 63, no leading/trailing hyphen. At least two labels; no scheme or path in dealer input |
| Subdomain | First label at least 3 characters; rejects code-defined reserved names, infrastructure/platform words, all-digit labels, tenant-prefixed labels, selected junk+numeric/hyphen suffixes, and reserved brand/profanity substrings |
| Expiry | YYYY-MM-DD, not before today in Asia/Kuala_Lumpur. UI uses browser-local today, which can differ near midnight |
| Tenant admin username/password | API caps 64/200. Username cap exceeds the initial account/storage boundary of 45; UI lacks equivalent maxLength checks |
| Default admin pair | Explicit admin/admin pair rejected; omit fields to keep existing defaults. This is not a general strong-password policy |
| Account collision | Initial login must differ from requested admin username, trim/case-insensitive |
| Demo entitlement | Every newly provisioned customer is Testing; dealer demo-cap check runs before submit. Remote-count uncertainty fails open, so this is not a strict transactionally enforced cap |
| Ownership attribution | ownerMemberNodeId optional, maximum 36, resolved/scoped dealer-side; current wizard does not expose it |
| Admin credential storage | Password input refused if dealer encryption key unavailable |
| Retry policy | Dealer gets at most 3 retries per request, 60-second cooldown; platform-admin retry has no cap/cooldown but still requires failed state + known upstream job |

The reserved-subdomain list is server-owned policy in `src/common/reserved-subdomains.ts`; the web should use server verdicts rather than copy a second blacklist. These are **dealer restrictions**, not promises made by the direct orchestrator API. Demo capacity, dealer wallet charging, and tenant customer.organization_limit are different concepts. Provisioning does not currently perform a wallet allocation/refund transaction.

### 11.4 Dealer APIs useful for operations

All following paths are dealer API `/api` paths, authenticated with the dealer session, not an orchestrator JWT. Use the local provisioning request ID in `{request_id}`, not the upstream job UUID.

| Method / route | Use |
|---|---|
| POST `/api/tenant-provisioning-requests` | Submit the camelCase dealer body; local durable request created before upstream call |
| GET `/api/tenant-provisioning-requests` | Authorized request list; reads also advance pending states |
| GET `/api/tenant-provisioning-requests/{request_id}` | Poll this request; local permissions/ownership apply |
| GET `/api/tenant-provisioning-requests/by-tenant/{tenant_id}` | Find local provisioning record after downstream tenant ID is known |
| POST `/api/tenant-provisioning-requests/{request_id}/retry` | Dealer-authorized retry subject to cap/cooldown and upstream failed status |
| POST `/api/tenant-provisioning-requests/{request_id}/tenant-admin-password` | Explicit audited reveal of dealer-stored admin password; this is a secret-returning operation, not an orchestrator recovery endpoint |
| GET `/api/admin/tenant-provisioning-requests` | Platform support list with organizationId, jobId, requestRef |
| POST `/api/admin/tenant-provisioning-requests/{request_id}/retry` | Platform-admin retry without dealer cap/cooldown |
| POST `/api/admin/tenant-provisioning-requests/reconcile?olderThanMinutes=15` | Explicit support reconciliation; nonnegative number, default 15 |
| GET `/api/tenant-plans` | Available plan catalog for create wizard |

The agent location gateway forwards the location body and Idempotency-Key unchanged using tenant:location:sync. It has its own machine-authentication boundary and is not the normal dealer-session create wizard.

The dealer has a saved-draft creation flow too. When adding fields, update draft persistence/validation/edit/reveal/submit as well as direct submit; otherwise one entry path loses fields. Existing admin-password reveal is a disclosure of what the dealer stored when submitting, not verification that this is still the tenant's current password after an external change or a partial failure.

### 11.5 Status and recovery behavior

Dealer local statuses are PENDING/SUCCEEDED/FAILED; orchestrator statuses are queued/running/succeeded/failed (plus step skipped). The status view includes handoff ACCEPTED/UNCONFIRMED from whether jobId is known. Once local terminal status is set, that status takes precedence over handoff.

The web polls every five seconds while pending, backs off transient failures up to 60 seconds, and stops on 4xx. The dealer API recovers a missing jobId by request_ref, polls the detailed upstream job, captures tenant ID early, and creates the dealerClient ownership row together with local completion in a transaction. If local completion fails after upstream success, that local record needs reconciliation, not another upstream create.

There is no autonomous reconciliation scheduler in the inspected source: list/detail reads and the explicit admin reconcile endpoint drive completion. An externally installed operational schedule was not checked. Closing the browser can delay local finalization until a later read/reconcile.

Current upstream job mapping preserves only stepId/status/outcome/errorMessage. It drops scope_key, step UUID, detailed result/substeps/runtime_context. In a future multi-org or scheduler integration, preserve those identifiers and result data server-side, with secret redaction. Otherwise support cannot distinguish which organization failed or obtain each scheduler_id. The full job may contain several create_scheduler steps; a single runtime scheduler_id only represents the last one.

### 11.6 Feature readiness

| Feature | Orchestrator source | Dealer API/web |
|---|---|---|
| Baseline create/expiry/domain/initial user | Implemented | Implemented |
| Final admin rename/password on create | Local encrypted/resumable fix; coordinated rollout required | Collected, stored encrypted dealer-side, forwarded |
| Multi-org / custom default departments | Implemented with restrictions described above | Not collected, persisted, or forwarded |
| Limits + wa_able_read + monthly price | Accepted and passed on customer creation | Not forwarded; sends only Testing status |
| Other optional customer finance fields | Accepted | Not exposed |
| Full schedulers | Accepted under tenant:create | Not exposed/forwarded |
| Later scheduler create/update | Separate APIs/scopes | No wrappers/UI; current identity not authorized |
| External admin credential recovery | Separate synchronous API; reliable profile history or explicit selector required | No wrapper/UI; current identity not authorized |
| Standalone setup/repair/recycle/profile admin | Separate APIs, several limitations | No general wrappers/UI; current identity not authorized |
| Location sync | Dedicated command | Machine gateway implemented |

Recommended dealer implementation order after orchestrator blockers are resolved:

1. Extend DTOs, local durable request/draft storage, mapping, validation, and review UI for organization_setup and the five new customer limit/read/price fields. Preserve omitted vs zero.
2. Add full schedulers if required, retaining each downstream scheduler ID and multi-org scope in status/support data. No new service scope needed for this nested full-create capability.
3. Add a scoped support recovery surface only after approving permissions and deploying/validating the environment/credential fixes. Do not expose all standalone routes as a generic unrestricted proxy.
4. Add a non-secret browser submission correlation handle and bounded upstream timeout; reconcile pending requests independently of the browser if required.
5. Test all direct and draft submit paths, completion/ownership linking, retry limits, no-job states, and redaction. Coordinate deployment order so the dealer never submits fields an older orchestrator rejects.

## 12. Improvement findings and recommended priorities

These findings were confirmed against the audited baseline. Rows marked resolved locally refer to reviewed local source, not deployed production fixes; other rows remain findings unless explicitly updated. P1 means address before expanding production use of the affected capability; P2 means a contained correctness/recovery improvement.

| Priority | Finding / impact | Recommended contained change | Source anchor |
|---|---|---|---|
| P1, resolved locally | Organization handler bypassed selected profile with DEV URLs/auth | Both root/child creation now use resolved profile routing/auth/defaults; custom-profile and ownership regressions passed | `src/provisioning/steps/organization/organization-structure.steps.ts` |
| P1, resolved locally for new writes | Admin passwords/current_password persisted in raw job/step snapshots | Encrypted job bags, private hydration and output protection implemented/reviewed; historical conversion still requires authorized rollout | `src/provisioning/secrets/job-secret.store.ts`, `src/cli/protect-job-secrets.ts` |
| P1, resolved locally | Repeated admin changes and interrupted rename/password/store sequence were not retry-safe | Stable identity, encrypted serialized intent, submitted checkpoints, verified atomic promotion and immutable step receipts implemented/reviewed; combined worker ownership/crash tests passed | `src/provisioning/auth/tenant-admin-change.service.ts`, `src/provisioning/auth/tenant-credential-operation.store.ts` |
| P1, resolved locally | Recovery/preflight could select default dev_default instead of tenant/job environment | Stored recovery now resolves reliable history or explicit selectors and fails closed; repair preflight shares its job profile | `src/provisioning/profiles/tenant-profile-resolver.ts`, `src/jobs/jobs.service.ts` |
| P1 | Job read/retry are global by scope, no caller ownership/type reauthorization; dealer job:retry can restart another identity's failed privileged job | Define trusted operator bypass and enforce caller/tenant/job-type authorization plus retry audit | Orchestrator `src/jobs/jobs.controller.ts:22`, `src/jobs/jobs.service.ts:439` |
| P1, resolved locally | Scoped step overrides were bypassed, plus several no-op fields | Supported scoped merge, shared domain, NEW field-specific400, legacy recovery compatibility and148-leaf/3-auth contract coverage | `src/provisioning/steps/effective-step-request.ts`, `src/provisioning/validation/override-dispositions.ts` |
| P1 | client_name >20 diverges from the created default-root name | Canonicalize tenant/default-root naming together; validate before mutation | Orchestrator tenant-core `:22`, jobs service `:532`, organization-structure `:101` |
| P1 | Additional names can collide after scope normalization or throw for non-ASCII-only names | Validate nonempty/unique scope IDs and reserved default, or use stable non-lossy internal IDs | Orchestrator organization-context `:13`, request schemas `:591`, Prisma scope uniqueness |
| P1, resolved locally | Standalone batch and transfer had inconsistent lookup/write targets | One validated organization/department target through lookup/write/verification; same-target storage references, trusted request routing and ambiguity checks | `src/provisioning/organizations/organization-target-resolver.ts`, `src/provisioning/steps/warehouse/warehouse.steps.ts` |
| P1, resolved locally | Job commit/enqueue gap could leave QUEUED work undispatched | Transactional dispatch intents, startup/periodic drain and deterministic attempt IDs; coordinated legacy cutover required | `src/jobs/provisioning-dispatch.service.ts`, `docs/retry-dispatch-rollout.md` |
| P1, resolved locally | Concurrent retry calls could accept the same FAILED job twice | Atomic observed-attempt claim, worker execution fencing, atomic step/context completion, and exact interrupted recovery; no remote exactly-once claim | `src/jobs/jobs.service.ts`, `src/provisioning/provisioning-step-runner.ts`, `src/cli/reconcile-interrupted-job.ts` |
| P1 | Dealer config permits DEV fallback in production and readiness tests only private-key presence | Validate complete ES256 configuration and explicit production URL/profile before any local submission write | Dealer API orchestrator.config `:121`, token.provider `:38`, client `:433` |
| P2, resolved locally | Full admin override could bypass initial-account collision validation | Validate effective merged initial/admin accounts before submission | `src/provisioning/validation/provisioning-request.schemas.ts` |
| P2 | Generic /roles can reuse unrelated HQ role | Correct the standalone role lookup identity in separate work; O changes do not redesign role lookup | Orchestrator access-control baseline `:206` |
| P2, resolved locally | Object-storage overrides and document toggles were ignored | All eight object-storage values now effective; unused document switches explicitly rejected on NEW submissions | `src/provisioning/steps/tenant-baseline/object-storage.step.ts`, `src/provisioning/validation/override-dispositions.ts` |
| P2 | Scheduler pending marker is inserted even before authentication succeeds; no public reconciliation route | Distinguish proven pre-submit failure from ambiguous submit, and provide controlled mapping reconciliation | Orchestrator scheduler `:43`–`:65` |
| P2, resolved locally; deployment pending | Recycle early return prevented finishing billing after partial failure | Always reconcile is_suspended after the name/dry-run guards, without repeating BladeX recycle | `src/provisioning/steps/tenant-lifecycle/tenant-recycle.step.ts` |
| P2, core classification resolved locally | Login transport/decryption failures could be treated as bad credentials or fall back | Structured rejection is distinct from operational failure; unusable store does not fall back; synchronous conflict/reconciliation errors map to409. Other operational HTTP errors still require diagnosis | `src/provisioning/auth/tenant-token.service.ts`, `src/jobs/jobs.service.ts` |
| P2 | Repair is presence-based, missing request context, not fully multi-org-aware; plan not returned | Define explicit supported repair scope/inputs and expose reviewable redacted plan | Orchestrator repair-planner `:32`, jobs service `:387` |
| P2 | Name precheck has no unique reservation constraint; old failed job can retry after a new creation reserves the same name | Add race-safe reservation and explicit supersession/retry ownership rules | Orchestrator jobs service `:235`; Prisma Tenant indexes |
| P2 | Dealer drops step scope/results and has no new feature fields | Extend persistence/mapping/status alongside UI, not just form inputs | Dealer API orchestrator.client `:210`, `:263` |
| P2 | Dealer has no bounded upstream timeout and browser lost-response recovery matches name | Add server deadline and exact non-secret submission correlation | Dealer API orchestrator.client `:422`; web CreateTenantForm `:279` |
| P2 | Dealer completion is read-driven; pending state can outlive upstream completion | Schedule authorized reconciliation if needed and fix misleading background-completion wording | Dealer API tenant-provisioning.service `:362`, admin controller `:59` |
| P2 | Dealer admin username/clientName limits diverge from usable downstream behavior; expiry timezones differ | Align effective length and date rules across layers; no silent truncation | Dealer DTO `:288`, `:311`; web create-tenant/data `:72` |

Other bounded gaps: job listing has no pagination or caller filter; invalid status/profile version/config inputs can fall through as generic 500; predictable initial-user passwords and broad tenant-view access to dealer password reveal deserve an explicit security policy. Master tenant000000 must not use the customer-tenant credential routes (see section6); an explicit endpoint guard remains follow-up work. Findings outside the approved five fixes remain separate work.

## 13. Acceptance checklist for the next integration release

- Confirm deployed API/worker revision and production profile/URLs; organization and recovery handlers must honor them.
- Confirm the requested production scopes and dealer local permissions/ownership checks separately.
- Test initial-user max lengths, reserved admin, effective admin collision, 20-character tenant naming, duplicate/slug-colliding org names, and required departments.
- Test absent vs zero vs nonzero customer values and existing-customer skip behavior.
- Test default-only, replaced-HQ, two organizations with different accounting types, repeated department names in different organizations, and explicit target ownership.
- Test no scheduler, multiple schedulers, late create, partial update, paused/running, and simulated ambiguous submission/pending mapping.
- Test first password change, password-only later rotation, rename then later maintenance, externally changed credentials, missing/wrong encryption key, and partial downstream success.
- Verify new secret values never appear in job/step JSON, logs/API diagnostics/audit; complete controlled historical conversion and assess old logs/backups separately.
- Test lost submit response, queued/enqueue failure, failed step retry, no-job local failure, wrong plan, snapshot profile changes, and dealer cooldown/cap.
- Test successful upstream job followed by failed dealerClient linking and subsequent reconciliation.
- Validate both saved-draft and direct-submit flows. Use a disposable test tenant in DEV with approved live mutations; a dry-run alone is insufficient.

## 14. Verification performed for this handoff

### Original read-only audit (before the approved fixes)

- Read-only remote checks and source-tree comparison established the revisions above.
- A local synthetic contract verifier parsed 18 JSON examples and ran 133 checks: field limits, zero values, invalid bodies, full-step count, override precedence, scope collisions, raw password snapshot persistence, and mocked profile-routing behavior. All passed; it made no network/database calls. Passing negative/reproduction assertions confirms the documented limitations exist, not that they are fixed.
- Focused existing Jest coverage: 8 suites / 131 tests passed against the current dev-equivalent worktree (`provisioning-validation`, `jobs.service`, `provisioning-worker`, `organization-structure.steps`, `accounting-steps`, `org-seeding-steps`, `warehouse-steps`, `prefix-steps`). The full npm test wrapper could not regenerate Prisma because its engine download was network-blocked; direct Jest used the existing generated client. No build or deployment verification is claimed.
- That original audit changed documentation only. Its reproduction checks are historical evidence, not verification of the subsequent fixes.

### Approved fix implementation

- All five task groups passed independent spec/quality review. Review findings were reproduced before fixes: short-password status redaction, interrupted admin rename and receipt replay, atomic step/context completion, admin mapping ownership, warehouse request routing, and missing standalone row validation. Their scoped re-reviews passed without parked findings.
- The whole-branch review found one additional compatibility edge: new collision validation blocked retrieval of some historical receipts. The single fix wave passed scoped re-review, including actual legacy-to-HMAC conversion followed by receipt recovery. No open or parked review findings remain in the approved five-fix scope.
- On the final frozen implementation, root ran `npm run test`: 56 suites/833 tests passed (45.454s). `npm run prisma:validate`, `npm run build` and `git diff --check` passed.
- Root ran `node node_modules/jest/bin/jest.js --config test/jest.integration.config.cjs --runInBand`: seven suites/76 tests passed (48.071s) against the dedicated localhost PostgreSQL database and isolated Redis DB15 prefixes. Downstream effects were mocked; deliberately duplicated/stale/outage scenarios emitted sanitized diagnostics. No shared Redis flush was used.
- Both handoffs'18 JSON blocks parsed, and16 orchestrator request examples passed actual built validators; the other two blocks are a scope list and a dealer DTO, not orchestrator request bodies. Seven local documentation links resolve. The unfinished-job metadata query passed against the local schema and six read-only fixture assertions; no sensitive values were selected.
- No production/DEV tenant writes, production permission changes, commits, pushes or deployment occurred.

The five contained orchestrator fixes are implemented, independently reviewed and locally verified. A coordinated DEV rollout and disposable-tenant end-to-end validation still require authorization before expanding the dealer UI. The current four dealer service scopes cover the currently implemented dealer integration; adding fields inside full creation does not itself require expanding those scopes.
