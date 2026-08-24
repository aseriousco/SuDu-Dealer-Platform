# SuDu Tenant Orchestrator API Handoff

## Purpose

This is the operator handoff for calling the full tenant provisioning flow and every currently exposed public API in `D:\SuDuAi\repos\sudu-tenant-orchestrator`.

The service is asynchronous. A successful `POST` normally returns a queued job; the separate worker executes the BladeX, su-code, and named MySQL work. Always poll the job before treating a provisioning action as complete.

Detailed project reference: `D:\SuDuAi\repos\sudu-tenant-orchestrator\docs\tenant-provisioning-project-documentation.md`.

## Current Deployment State

- Public API base URL: `https://tenant-orchestrator.dev.sudu.ai`.
- The API was deployed to Coolify from the `dev` branch.
- The operator reports that the API, worker, PostgreSQL migrations/profile seed, and Redis are ready.
- The API and worker remain separate Coolify applications. They use the same runtime environment; the worker starts `node dist/worker/main.js` and has no public domain.
- `DATABASE_URL` must remain the complete Coolify PostgreSQL **Internal Database URL**, not a local Compose hostname such as `postgres`.

## Required Running Components

1. API process: `node dist/main.js`, exposed behind the API base URL.
2. Worker process: `node dist/worker/main.js`, connected to the same Redis and PostgreSQL database.
3. PostgreSQL: orchestration metadata, profiles, jobs, idempotency records, and registered JWT public keys.
4. Redis: BullMQ queue transport.
5. BladeX, SM2 service, su-code, and BladeX MySQL: only required for connected tests and live execution.

## Base Request Convention

Set these variables in Postman or your integration:

```text
base_url=https://tenant-orchestrator.dev.sudu.ai
jwt=<short-lived-service-jwt>
bladex_tenant_id=<BladeX tenant ID, for example 668171>
```

Every route requires this header:

```http
Authorization: Bearer {{jwt}}
```

Every `POST` that creates a job also requires a fresh idempotency key:

```http
Content-Type: application/json
Idempotency-Key: <unique-key-for-this-exact-request>
```

Use a distinct key for a different request body. Reusing the same key from the same calling service with the same body returns the original job; reusing it with a changed body returns `409 Conflict`.

## Authentication Requirements

The API does not accept a BladeX login token as its public API credential. It accepts a signed internal ES256 JWT.

The JWT must contain:

- `alg: ES256` and a `kid` that identifies a registered `ServiceIdentity` key in PostgreSQL.
- `iss` equal to `INTERNAL_JWT_ISSUER`.
- `aud` equal to `INTERNAL_JWT_AUDIENCE`.
- `sub` equal to the registered service ID.
- Valid `iat`, `exp`, and `jti` claims.
- A space-delimited `scope` claim containing the required scope for the API being called.

There is no public API for registering a `ServiceIdentity`. Register its public key through the controlled database/bootstrap process, then keep the matching private key in the calling service or secure operator tooling. Never put that private key in a request body, source repository, or this document.

Recommended non-secret development claim values, if they match the deployed environment variables:

```text
iss=internal-identity
aud=tenant-provisioning-service
```

These are the confirmed deployed values for `INTERNAL_JWT_ISSUER` and `INTERNAL_JWT_AUDIENCE`. An environment name is not required in public requests; choose a provisioning profile with `profile_key` and, when needed, `profile_version`.

## Service Operating Model

This service has two API families:

1. **Provisioning APIs** create asynchronous jobs. The API validates the request, persists an immutable request/profile snapshot, places a message on Redis, and returns quickly with a `job_id`.
2. **Read and control APIs** inspect those jobs, retry a failed job in place, inspect profiles, or test a profile without downstream writes.

The worker performs the actual BladeX, su-code, SM2, and named MySQL work. A `POST` receipt is not evidence that a tenant or downstream resource was created. Treat only a terminal job status as the outcome.

### Public API Map

All URLs are relative to `{{base_url}}`. Every endpoint requires `Authorization: Bearer {{jwt}}`. Every `POST` that creates a job also requires `Idempotency-Key`.

| API | Purpose | Required scope | Response form |
| --- | --- | --- | --- |
| `POST /v1/provisioning/tenant-jobs` | Start the 17-step full tenant flow. | `tenant:create` | Job receipt |
| `GET /v1/jobs` | List prior jobs; filter by tenant, request reference, or status. | `job:read` | Job-summary array |
| `GET /v1/jobs/:job_id` | Inspect a job and its step status. | `job:read` | Job detail |
| `POST /v1/jobs/:job_id/retry` | Requeue a failed job using its original snapshots. | `job:retry` | Job receipt |
| `POST /v1/tenants/:bladex_tenant_id/repair` | Run selected repairable steps for an existing tenant. | `tenant:repair` | Job receipt |
| `POST /v1/tenants/:bladex_tenant_id/*` | Run one tenant setup command for an existing BladeX tenant. | Command-specific | Job receipt |
| `GET /v1/provisioning-profiles` | List profile records and their versions. | `provisioning_profile:read` | Profile array |
| `GET /v1/provisioning-profiles/:key` | Read the active or requested profile snapshot. | `provisioning_profile:read` | Profile snapshot |
| `POST /v1/provisioning-profiles/:key/versions` | Create a draft profile version. | `provisioning_profile:write` | Version receipt |
| `POST /v1/provisioning-profiles/:key/activate` | Activate a tested profile version. | `provisioning_profile:activate` | Empty success response |
| `POST /v1/provisioning-profiles/:key/versions/:version/test` | Validate a profile offline or against connected dependencies. | `provisioning_profile:test` | Test report |

### Common Job Receipt

The full-flow, repair, and every individual tenant command return the same compact receipt. A repeated request with the same calling service, identical body, and identical `Idempotency-Key` returns the original receipt instead of creating another job.

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "queued"
}
```

- `job_id` is the immutable orchestration job identifier. Persist it in the caller before polling.
- `status: "queued"` means the request passed validation and was queued; it does not mean any downstream work has completed.
- The same receipt is returned by `POST /v1/jobs/:job_id/retry`, except that it refers to the existing job ID.

## First Safe Check: Profile Test

Run this before live tenant creation. It verifies the selected profile and configured secret references without creating a tenant.

```http
POST {{base_url}}/v1/provisioning-profiles/dev_default/versions/1/test
Authorization: Bearer {{jwt}}
Content-Type: application/json

{
  "mode": "connected"
}
```

Required scope: `provisioning_profile:test`.

`offline` is the default and validates configuration only. `connected` also checks endpoint reachability, both named MySQL connections, and master-login prerequisites. It remains non-mutating.

Do not run a live tenant provisioning job until relevant connected checks pass. A failed SM2 check is blocking because BladeX passwords must be SM2 encrypted.

Successful response example:

```json
{
  "profile_key": "dev_default",
  "profile_version": 1,
  "mode": "connected",
  "mutates_downstream": false,
  "mysql_writes": false,
  "checks": [
    { "name": "schema", "status": "passed" },
    { "name": "bladex_reachability", "status": "passed" },
    { "name": "mysql_write_connection", "status": "passed" }
  ]
}
```

Each `checks` item has `name`, `status` (`passed` or `failed`), and an optional `message` when failed. A HTTP `200` test response can still contain failed checks; inspect every check before live execution.

## Full Tenant Creation

### Endpoint

```http
POST {{base_url}}/v1/provisioning/tenant-jobs
```

Required scope: `tenant:create`.

### Minimal live payload

```json
{
  "request_ref": "tenant-20260806-001",
  "tenant": {
    "client_name": "Example Manufacturing Sdn Bhd"
  },
  "package": {
    "type": "WMS"
  },
  "accounting": {
    "type": "SQL"
  },
  "initial_user": {
    "account": "exampleteam",
    "name": "Example HQ",
    "real_name": "Example HQ",
    "email": ""
  }
}
```

Required fields:

- `tenant.client_name`: full client name. BladeX `tenantName`/`linkman` is always truncated to the first 20 characters.
- `package.type`: exactly `WMS`, `AI`, or `MES`.
- `accounting.type`: exactly `SQL` or `ATC`.
- `initial_user.account`, `name`, `real_name`, and `email`.

Initial-user password behavior:

- When `initial_user.password_secret_ref` is sent, its environment variable value is used.
- When omitted, the generated password is `${initial_user.account}@123!`.
- The generated/resolved password is never returned or persisted in API-visible job output.

Example with a supplied secret reference:

```json
{
  "request_ref": "tenant-20260806-002",
  "tenant": { "client_name": "Example Manufacturing Sdn Bhd" },
  "package": { "type": "WMS" },
  "accounting": { "type": "SQL" },
  "initial_user": {
    "account": "exampleteam",
    "name": "Example HQ",
    "real_name": "Example HQ",
    "email": "",
    "password_secret_ref": "EXAMPLE_TENANT_INITIAL_PASSWORD"
  }
}
```

The `EXAMPLE_TENANT_INITIAL_PASSWORD` environment variable must exist in both the API and worker runtime environments. The public request contains only the reference name, never plaintext.

### Full-flow options

These optional common fields are available on full and individual job requests:

```json
{
  "request_ref": "external-ticket-or-correlation-id",
  "profile_key": "dev_default",
  "profile_version": 1,
  "dry_run": { "mode": "offline" }
}
```

- Omit profile values to use the active `dev_default` profile.
- `dry_run.mode = offline`: no downstream calls and no MySQL reads/writes.
- `dry_run.mode = connected`: read-only checks only; no mutations.
- `step_overrides`: full flow only. It lets the caller override allowed profile defaults for a named step. Caller values win over the profile values for allowlisted fields.
- `auth_overrides`: the validator accepts these three secret-reference override fields in full-flow and repair requests. Current runtime limitation: they are injected for a repair-only internal `login_new_tenant` prerequisite, but are not flattened into normal full-flow steps. Do not rely on them to change a normal full-flow login credential until that worker behavior is fixed; use the selected profile's secret refs instead.

### Complete full-flow override contract

The full-flow request is strict: every field not listed below is rejected. Every field inside `step_overrides` is optional. When an allowlisted override is present, it wins over the selected provisioning-profile default for that step.

This is the complete accepted shape, excluding only the required top-level values already shown in the minimal request:

```json
{
  "request_ref": "external-ticket-or-correlation-id",
  "profile_key": "dev_default",
  "profile_version": 1,
  "dry_run": {
    "mode": "offline"
  },
  "auth_overrides": {
    "bootstrap_admin_password_secret_ref": "OPTIONAL_BOOTSTRAP_ADMIN_PASSWORD",
    "tenant_admin_password_secret_ref": "OPTIONAL_TENANT_ADMIN_PASSWORD",
    "tenant_service_password_secret_ref": "OPTIONAL_TENANT_SERVICE_PASSWORD"
  },
  "step_overrides": {
    "setup_resource_package": {
      "type": "WMS",
      "package_id": "optional-package-id",
      "menu_parent_ids": ["optional-menu-parent-id"],
      "menu_excluded_ids": ["optional-menu-id"],
      "enable_transfer_order_setup": true
    },
    "setup_object_storage": {
      "bucket_name": "optional-bucket",
      "endpoint": "optional-endpoint",
      "oss_code": "optional-code",
      "category": 1,
      "transform_endpoint": "https://optional-transform-endpoint",
      "access_key_secret_ref": "OPTIONAL_OSS_ACCESS_KEY",
      "secret_key_secret_ref": "OPTIONAL_OSS_SECRET_KEY",
      "oss_submit_auth_token_secret_ref": "OPTIONAL_OSS_SUBMIT_AUTH_TOKEN"
    },
    "create_hq_department": {
      "dept_category": 1,
      "dept_name": "HQ",
      "full_name": "HQ",
      "parent_id": "optional-parent-department-id",
      "sort": 1
    },
    "create_hq_role": {
      "role_alias": "Admin",
      "role_name": "Admin",
      "parent_role_id": "optional-parent-role-id",
      "sort": 1
    },
    "create_initial_user": {
      "account": "optional-account-override",
      "name": "optional-name-override",
      "real_name": "optional-real-name-override",
      "email": "",
      "password_secret_ref": "OPTIONAL_INITIAL_USER_PASSWORD",
      "dept_id": "optional-single-department-id",
      "dept_ids": ["optional-department-id-1", "optional-department-id-2"],
      "role_id": "optional-single-role-id",
      "role_ids": ["optional-role-id-1", "optional-role-id-2"],
      "post_id": "optional-post-id",
      "user_type": 1,
      "update_password_on_existing": false
    },
    "update_user_assignments": {
      "user_id": "optional-bladex-user-id",
      "account": "optional-account-fallback",
      "dept_ids": ["optional-department-id-1", "optional-department-id-2"],
      "role_ids": ["optional-role-id-1", "optional-role-id-2"]
    },
    "ensure_orchestrator_service_account": {
      "account": "sudu_orchestrator",
      "name": "sudu_orchestrator",
      "real_name": "sudu_orchestrator",
      "email": "",
      "password_secret_ref": "OPTIONAL_TENANT_SERVICE_PASSWORD",
      "dept_id": "optional-single-department-id",
      "dept_ids": ["optional-department-id-1", "optional-department-id-2"],
      "role_id": "optional-single-role-id",
      "role_ids": ["optional-role-id-1", "optional-role-id-2"],
      "post_id": "optional-post-id",
      "user_type": 1,
      "update_password_on_existing": false
    },
    "update_role_permissions": {
      "role_id": "optional-role-id",
      "package_type": "WMS",
      "menu_ids": ["optional-menu-id"],
      "menu_parent_ids": ["optional-parent-menu-id"],
      "menu_excluded_ids": ["optional-menu-id"]
    },
    "setup_accounting_integration": {
      "type": "SQL",
      "seed_sql_defaults": true
    },
    "seed_sql_accounting_defaults": {
      "enabled": true
    },
    "setup_document_number_rules": {
      "copy_missing_rules": true,
      "disable_draft_defaults": true,
      "copy_stock_strategy": true
    },
    "setup_storage_location": {
      "rows": [
        {
          "storage_location_name": "HQ",
          "storage_location_code": "HQ"
        }
      ]
    },
    "setup_bin_location": {
      "rows": [
        {
          "storage_location_code": "HQ",
          "bin_name": "HQ",
          "bin_code_tier_1": "HQ",
          "bin_location_combine": "HQ"
        }
      ]
    },
    "setup_batch_configuration": {
      "organization_id": "optional-organization-id",
      "batch_level_selection": "optional-level",
      "batch_prefix": "BAT",
      "batch_running_number": 1,
      "batch_padding_zeroes": 5,
      "batch_format": "optional-format",
      "workflow_id": "optional-workflow-id"
    },
    "setup_transfer_order_configuration": {
      "enabled": true,
      "organization_id": "optional-organization-id",
      "plant_id": "optional-plant-id",
      "loading_bay_storage_location_code": "HQL",
      "loading_bay_bin_location_code": "HQL",
      "areas": ["picking", "putaway", "packing", "plant_transfer", "sales_return"]
    },
    "setup_prefixes": {
      "item": {
        "prefix_value": "SKU",
        "padding_zeroes": 5,
        "running_number": 1
      },
      "supplier": {
        "prefix_value": "SUP",
        "padding_zeroes": 5,
        "running_number": 1
      },
      "customer": {
        "prefix_value": "CUS",
        "padding_zeroes": 5,
        "running_number": 1
      }
    }
  }
}
```

Override rules and limits:

- `package.type` and `update_role_permissions.package_type` accept only `WMS`, `AI`, or `MES`.
- `setup_accounting_integration.type` accepts only `SQL` or `ATC`.
- `parent_id` and `parent_role_id` accept `0` or a non-empty ID string. Do not send role `parent_id`.
- In user overrides, `dept_id`/`role_id` are the single-ID forms and `dept_ids`/`role_ids` are the multi-ID forms. Do not send conflicting forms unless the intended downstream behavior has been tested.
- `update_user_assignments` in full flow is optional. When supplied, it can target a specific user by `user_id` or `account`; omitted assignment dimensions are preserved by that step.
- `update_role_permissions` is accepted in `step_overrides`, but the full-flow job intentionally does not contain that step. It only takes effect through the individual role-permissions API or a repair job that targets `update_role_permissions`.
- `seed_sql_accounting_defaults.enabled` is accepted by the request validator, but the current worker does not consume it. `setup_accounting_integration.seed_sql_defaults` is also not forwarded to the separate seed step in a full-flow job. Therefore, the full-flow API currently has no functional caller override to disable SQL seeding. For the individual accounting API, `seed_sql_defaults: false` at the request root works because the API stores that same field on both step records.
- Storage/bin `rows` are replacement arrays. The full-flow override schema intentionally accepts row objects without listing every column; use the profile's existing row shape as the template and only override values required for the target tenant.
- The public contract accepts secret reference names only. It never accepts the actual secret value.

### Field-by-field full-flow behavior

This section describes the **current runtime effect**, not merely what the JSON validator accepts. `Effective` means the value reaches the relevant handler. `Schema-only` means the request is accepted but the current full-flow handler ignores it. `Not scheduled` means the step is not part of a normal full tenant job.

#### `setup_resource_package`

- `type` - **Effective.** Selects the WMS, AI, or MES package profile entry. It overrides top-level `package.type` for this step only.
- `package_id` - **Effective.** Sends this exact package ID instead of the package ID stored for the selected type in the profile.
- `menu_parent_ids`, `menu_excluded_ids` - **Schema-only for this step.** Resource-package setup no longer grants roles or menus; these values do not affect its BladeX package-setting call.
- `enable_transfer_order_setup` - **Schema-only.** Transfer setup is controlled by its own step override, not this package field.

#### `setup_object_storage`

All listed fields (`bucket_name`, `endpoint`, `oss_code`, `category`, `transform_endpoint`, and the three secret references) are **schema-only in a full-flow request today**. The object-storage handler reads its configuration from the selected profile and does not merge the step request. Change the profile for a live object-storage default; do not depend on a full-flow step override for this step.

#### `create_hq_department`

- `dept_category` - **Effective.** Sent to BladeX as `deptCategory`.
- `dept_name` - **Effective.** Sent as the department name and is used by the HQ department creation step.
- `full_name` - **Effective.** Sent as `fullName`; use it when the formal name differs from `dept_name`.
- `parent_id` - **Effective.** `0` means a root department; a string means that exact parent department ID. A non-root ID is validated against the tenant.
- `sort` - **Effective.** Sent as BladeX department sort order.

#### `create_hq_role`

- `role_alias` - **Effective.** Sent as BladeX `roleAlias`.
- `role_name` - **Effective.** Sent as BladeX `roleName`.
- `parent_role_id` - **Effective.** `0` means root role; a string is validated as a tenant role before submission.
- `sort` - **Effective.** Sent as BladeX role sort order.

Do not send `parent_id` for a role; the API rejects it.

#### `create_initial_user`

- `account`, `name`, `real_name`, `email` - **Effective.** These override the required top-level `initial_user` values for the creation request.
- `password_secret_ref` - **Effective.** Resolves the named worker environment variable. When omitted, password generation remains `${account}@123!`.
- `dept_ids` - **Effective and preferred for multiple departments.** All IDs are comma-joined into BladeX `deptId`; it takes precedence over `dept_id`.
- `dept_id` - **Effective single-department fallback.** Used only when `dept_ids` is absent/empty.
- `role_ids` - **Effective and preferred for multiple roles.** All IDs are comma-joined into BladeX `roleId`; it takes precedence over `role_id`.
- `role_id` - **Effective single-role fallback.** Used only when `role_ids` is absent/empty.
- `post_id` - **Effective.** Overrides the profile user post ID.
- `user_type` - **Effective.** Overrides the profile user type.
- `update_password_on_existing` - **Intentionally fails closed when `true`.** The downstream password-update contract has not been verified; it does not update an existing user's password.

If no department or role field is supplied, the step reads all non-root tenant departments and the first non-root tenant role from the named MySQL gateway.

#### `update_user_assignments`

- `user_id` - **Effective target selector.** Updates that BladeX user.
- `account` - **Effective fallback target selector.** Used when `user_id` is not supplied.
- `dept_ids` - **Effective.** Replaces the target user's BladeX `deptId` with the comma-joined IDs.
- `role_ids` - **Effective.** Replaces the target user's BladeX `roleId` with the comma-joined IDs.

When this full-flow override is omitted, the step selects the first-created user in the tenant, normally the BladeX master admin, and assigns all non-root departments while preserving that user's role. When one assignment array is omitted for a targeted user, that existing assignment value is preserved.

#### `ensure_orchestrator_service_account`

This step merges the profile's `sudu_orchestrator` defaults with the supplied user fields, then uses the same behavior as `create_initial_user`.

- `account`, `name`, `real_name`, `email`, `password_secret_ref`, `dept_id`, `dept_ids`, `role_id`, `role_ids`, `post_id`, and `user_type` - **Effective**, with the same precedence and meaning as `create_initial_user`.
- `update_password_on_existing: true` - **Fails closed**, as with the initial-user step.

Use this only to change the tenant-local orchestrator service account. It does not change the top-level initial user.

#### `update_role_permissions`

All fields are **not scheduled in normal full tenant creation** because this step was intentionally removed from the full-flow step list.

- `role_id`, `package_type`, `menu_ids`, `menu_parent_ids`, and `menu_excluded_ids` are meaningful only when calling the individual role-permissions API or a repair job that explicitly targets `update_role_permissions`.
- For that individual/repair step, `role_id` selects the target role; `package_type` selects profile menu rules; `menu_ids` supplies an explicit final menu list. `menu_parent_ids` and `menu_excluded_ids` are currently profile-derived when `menu_ids` is omitted, not caller-derived.

#### `setup_accounting_integration` and `seed_sql_accounting_defaults`

- `setup_accounting_integration.type` - **Effective.** `SQL` maps to SQL Accounting V2; `ATC` maps to AutoCount Accounting V2.
- `setup_accounting_integration.seed_sql_defaults` - **Schema-only in full flow.** It reaches the integration step, which does not use it, and it is not forwarded to the separate seed step.
- `seed_sql_accounting_defaults.enabled` - **Schema-only.** The seed handler does not read this field.

Consequently, SQL seed defaults cannot currently be caller-disabled in a full tenant job. ATC still skips the seed as not applicable. The individual accounting endpoint has different behavior: its root `seed_sql_defaults: false` does disable its seed step.

#### `setup_document_number_rules`

`copy_missing_rules`, `disable_draft_defaults`, and `copy_stock_strategy` are **schema-only in full flow today**. The handler currently always performs its three configured substeps: copy missing rules, disable inserted draft defaults, and insert missing stock strategy. Change the implementation or profile/data state before assuming a per-job flag changes that behavior.

#### `setup_storage_location`

- `rows` - **Effective.** Replaces the profile's entire storage-location row list for this job; it does not merge rows by code.
- Each row is passed to the storage-location submit operation. The step requires `storage_location_name` and `storage_location_code`.
- Common supported row fields are `organization_id`, `plant_id`, `location_type`, `storage_status`, and `is_default`. If organization/plant are omitted, the step derives the root organization and HQ department.
- The override schema accepts arbitrary row keys, but only use fields the configured su-code storage-location collection supports.

#### `setup_bin_location`

- `rows` - **Effective.** Replaces the profile's entire bin-location row list for this job.
- Each row requires `bin_name` and either `storage_location_code` or `storage_location_id`.
- `bin_code_tier_1` defaults to `bin_name`; `bin_location_combine` defaults to `bin_code_tier_1` when omitted.
- The row may include organization/plant values. Missing values are derived from the root organization and HQ department.

#### `setup_batch_configuration`

- `organization_id` - **Effective.** Replaces the derived root organization for both batch substeps.
- `batch_level_selection`, `batch_prefix`, `batch_running_number`, `batch_padding_zeroes`, and `batch_format` - **Effective.** Configure the batch-level record.
- `workflow_id` - **Effective when the configured batch workflow endpoint uses a workflow ID.** It changes the workflow-run URL; the rest of the batch-number workflow values remain profile-controlled.

The step always manages two substeps: batch-level configuration and batch-number workflow configuration.

#### `setup_transfer_order_configuration`

- `enabled` - **Effective.** `false` returns `skipped_by_request` without creating transfer setup.
- `areas` - **Effective.** Limits setup to any of `picking`, `putaway`, `packing`, `plant_transfer`, and `sales_return`.
- `organization_id`, `plant_id`, `loading_bay_storage_location_code`, and `loading_bay_bin_location_code` - **Schema-only in the current full-flow handler.** The handler derives root organization/HQ department and reads loading-bay storage code from the profile. Change the profile or implementation before relying on these request fields.

The normal full flow also skips this step for package types other than the profile's configured full-flow package condition, normally WMS.

#### `setup_prefixes`

Each of `item`, `supplier`, and `customer` is **effective**. Within each group:

- `prefix_value` changes the literal prefix.
- `padding_zeroes` changes serial-number padding length.
- `running_number` changes the starting serial number.

Document types and collection ID remain profile-owned and cannot be overridden per full-flow request.

### Full-flow step records

The full job creates 17 step records, in this order:

```text
create_tenant
setup_resource_package
login_new_tenant
setup_object_storage
create_hq_department
create_hq_role
create_initial_user
update_user_assignments
ensure_orchestrator_service_account
setup_accounting_integration
seed_sql_accounting_defaults
setup_document_number_rules
setup_storage_location
setup_bin_location
setup_batch_configuration
setup_transfer_order_configuration
setup_prefixes
```

`update_role_permissions` is intentionally excluded from full tenant creation. Call the individual role-permissions API only when its permission grant behavior is explicitly intended.

For accounting:

- `SQL` configures SQL Accounting V2 and runs the SQL defaults seed. The full-flow `seed_sql_defaults` override is not currently forwarded to the seed handler, so it cannot disable the seed for a full tenant job.
- `ATC` configures AutoCount Accounting V2; the SQL seed step is `skipped_not_applicable`.

### Submit, Poll, And Decide

1. Submit `POST /v1/provisioning/tenant-jobs` with a fresh `Idempotency-Key`.
2. Persist `job_id` from the common job receipt.
3. Poll `GET /v1/jobs/{{job_id}}?detail=full` until the job status is `succeeded` or `failed`.
4. On `succeeded`, retain the resulting `bladex_tenant_id` and finish any business-side registration.
5. On `failed`, inspect the first step whose status is `failed`. Correct the root cause, then use retry or repair as described in [Failure And Recovery Decisions](#failure-and-recovery-decisions).

```http
GET {{base_url}}/v1/jobs/{{job_id}}?detail=full
Authorization: Bearer {{jwt}}
```

Required scope: `job:read`.

#### Job-detail response body

`GET /v1/jobs/:job_id` always returns the job summary plus ordered `steps`. Add `?detail=full` for the diagnostic fields shown below.

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "type": "TENANT_PROVISIONING",
  "bladex_tenant_id": "668171",
  "bladex_tenant_name": "Example Tenant",
  "request_ref": "tenant-20260806-001",
  "status": "running",
  "retry_count": 0,
  "error": null,
  "runtime_context": {
    "bladex_tenant_id": "668171"
  },
  "steps": [
    {
      "id": "provisioning-step-uuid",
      "step_id": "create_tenant",
      "phase": "tenant_core",
      "order": 1,
      "status": "succeeded",
      "outcome": "created",
      "reason": null,
      "retry_count": 0,
      "error": null,
      "request": { "client_name": "Example Tenant" },
      "result": { "tenant_id": "668171" },
      "substeps": []
    }
  ]
}
```

The exact `result`, `substeps`, `outcome`, and `reason` values are step-specific. Do not depend on an illustrative field such as `tenant_id` unless that step has returned it in your environment. The stable fields are the job and step envelope fields shown above.

Without `detail=full`, each step includes only `id`, `step_id`, `phase`, `order`, `status`, `outcome`, `reason`, `retry_count`, and `error`. Full detail additionally exposes redacted `request`, `result`, `substeps`, and redacted `runtime_context`. The service does not expose the job's internal `result` field separately; use the step results instead.

#### Full-flow terminal results

| Job status | Meaning | Required action |
| --- | --- | --- |
| `queued` | Accepted but not yet picked up by the worker. | Continue polling. If it persists unexpectedly, verify API and worker use the same Redis and PostgreSQL environment. |
| `running` | Worker is executing steps. | Continue polling; do not submit a duplicate request. |
| `succeeded` | Every executed step completed or had an allowed successful skip. | Record `bladex_tenant_id`; review any `skipped_*` outcome if business policy requires the step. |
| `failed` | The worker stopped at the first failed step. Later queued steps did not run. | Inspect failed-step `error`, correct the cause, then retry in place or create a narrow repair job. |

## Individual Tenant APIs

All individual APIs take `:bladex_tenant_id`. The orchestrator automatically registers a local tenant record if the tenant is not already known locally; it does not create the BladeX tenant.

Each body can additionally include `request_ref`, `profile_key`, `profile_version`, and `dry_run` as described above. Unknown fields are rejected.

Every individual tenant `POST`, including repair, returns the [Common Job Receipt](#common-job-receipt). Poll its `job_id` in exactly the same way as a full tenant job. `GET /v1/jobs/:job_id?detail=full` identifies the single command step, or the two accounting steps, and contains its result or failure details.

| API | Required scope | Required/minimal body |
| --- | --- | --- |
| `POST /v1/tenants/:bladex_tenant_id/package` | `tenant:package:setup` | `{ "type": "WMS" }` |
| `POST /v1/tenants/:bladex_tenant_id/object-storage` | `tenant:object_storage:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/departments` | `tenant:department:create` | `{ "dept_name": "HQ" }` |
| `POST /v1/tenants/:bladex_tenant_id/roles` | `tenant:role:create` | `{ "role_alias": "Admin", "role_name": "Admin" }` |
| `POST /v1/tenants/:bladex_tenant_id/users` | `tenant:user:create` | account/name/real_name/password_secret_ref |
| `POST /v1/tenants/:bladex_tenant_id/users/update-assignments` | `tenant:user:update` | target user plus `dept_ids` and/or `role_ids` |
| `POST /v1/tenants/:bladex_tenant_id/orchestrator-service-account` | `tenant:orchestrator_service_account:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/role-permissions` | `tenant:role_permission:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/accounting-integration` | `tenant:accounting:setup` | `{ "type": "SQL" }` |
| `POST /v1/tenants/:bladex_tenant_id/document-numbers` | `tenant:document_number:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/storage-locations` | `tenant:storage_location:create` | one storage location or `rows` |
| `POST /v1/tenants/:bladex_tenant_id/bin-locations` | `tenant:bin_location:create` | one bin location or `rows` |
| `POST /v1/tenants/:bladex_tenant_id/batch-configuration` | `tenant:batch:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/transfer-order-configuration` | `tenant:transfer_order:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/prefixes` | `tenant:prefix:setup` | `{}` uses profile defaults |
| `POST /v1/tenants/:bladex_tenant_id/repair` | `tenant:repair` | optional target list |

### Copyable individual payloads

#### Package

```json
{ "type": "MES" }
```

Optional package fields: `package_id`, `menu_parent_ids`, `menu_excluded_ids`, `enable_transfer_order_setup`.

#### Object storage

```json
{
  "bucket_name": "optional-bucket",
  "endpoint": "optional-endpoint",
  "oss_code": "optional-code",
  "category": 1,
  "transform_endpoint": "https://optional-transform-endpoint",
  "access_key_secret_ref": "OPTIONAL_OSS_ACCESS_KEY",
  "secret_key_secret_ref": "OPTIONAL_OSS_SECRET_KEY",
  "oss_submit_auth_token_secret_ref": "OPTIONAL_OSS_SUBMIT_AUTH_TOKEN"
}
```

Omitted fields use profile defaults. This step submits the object storage config, reads the new `blade_oss` ID through the named MySQL gateway, then enables it through BladeX.

#### Department

```json
{
  "dept_name": "Finance",
  "full_name": "Finance",
  "parent_id": "parent-department-id",
  "dept_category": 1,
  "sort": 1
}
```

`full_name` defaults to `dept_name`. Send `parent_id: 0` to create a root-level department when that is intentional.

#### Role

```json
{
  "role_alias": "Manager",
  "role_name": "Manager",
  "parent_role_id": "parent-role-id",
  "sort": 1
}
```

Use `parent_role_id`, not `parent_id`.

#### User

```json
{
  "account": "financeuser",
  "name": "Finance User",
  "real_name": "Finance",
  "email": "",
  "password_secret_ref": "FINANCE_USER_PASSWORD",
  "dept_ids": ["department-id-1", "department-id-2"],
  "role_ids": ["role-id-1"],
  "post_id": "optional-post-id",
  "user_type": 1,
  "update_password_on_existing": false
}
```

Individual user creation requires `password_secret_ref`. Do not send plaintext `password` or `password2`.

#### Update user assignments

```json
{
  "user_id": "bladex-user-id",
  "dept_ids": ["department-id-1", "department-id-2"],
  "role_ids": ["role-id-1"]
}
```

`account` can replace `user_id` as the target selector. At least one of `user_id` or `account`, and at least one of `dept_ids` or `role_ids`, is required. Omitted assignment field values are preserved.

#### Orchestrator service account

```json
{
  "account": "sudu_orchestrator",
  "name": "sudu_orchestrator",
  "real_name": "sudu_orchestrator",
  "email": "",
  "password_secret_ref": "BLADEX_TENANT_ORCHESTRATOR_PASSWORD"
}
```

Normally send `{}` and use the profile defaults. This account exists so later tenant-authenticated downstream calls do not depend on a human initial user.

#### Role permissions

```json
{
  "role_id": "optional-role-id",
  "package_type": "WMS",
  "menu_ids": ["menu-id-1"],
  "menu_parent_ids": ["parent-menu-id-1"],
  "menu_excluded_ids": ["excluded-menu-id-1"]
}
```

This is deliberately separate from package setup and full tenant creation because role grants can overwrite or alter effective permissions. Validate the exact target role and menus before calling it live.

#### Accounting integration

```json
{
  "type": "SQL",
  "seed_sql_defaults": true
}
```

For individual `SQL`, the job has both `setup_accounting_integration` and `seed_sql_accounting_defaults` records. With `seed_sql_defaults: false`, the seed record succeeds with `skipped_by_request`. With `ATC`, the seed record is skipped as not applicable.

#### Document numbers

```json
{
  "copy_missing_rules": true,
  "disable_draft_defaults": true,
  "copy_stock_strategy": true
}
```

Omit fields to use profile defaults.

#### Storage locations

Single row:

```json
{
  "storage_location_name": "HQ Load",
  "storage_location_code": "HQL",
  "organization_id": "optional-organization-id",
  "plant_id": "optional-plant-id",
  "location_type": "optional-type",
  "storage_status": 1,
  "is_default": 0
}
```

Multiple rows:

```json
{
  "rows": [
    { "storage_location_name": "HQ", "storage_location_code": "HQ" },
    { "storage_location_name": "HQ Load", "storage_location_code": "HQL" }
  ]
}
```

#### Bin locations

```json
{
  "storage_location_code": "HQL",
  "bin_name": "HQ Load",
  "bin_code_tier_1": "HQL",
  "bin_location_combine": "HQL"
}
```

Use `storage_location_id` instead of `storage_location_code` when known. One of them is required. Multi-row format is `{ "rows": [ ... ] }`.

#### Batch configuration

```json
{
  "organization_id": "optional-organization-id",
  "batch_level_selection": "optional-level",
  "batch_prefix": "BAT",
  "batch_running_number": 1,
  "batch_padding_zeroes": 5,
  "batch_format": "optional-format",
  "workflow_id": "optional-workflow-id"
}
```

#### Transfer order configuration

```json
{
  "enabled": true,
  "organization_id": "optional-organization-id",
  "plant_id": "optional-plant-id",
  "loading_bay_storage_location_code": "HQL",
  "loading_bay_bin_location_code": "HQL",
  "areas": ["picking", "putaway", "packing", "plant_transfer", "sales_return"]
}
```

#### Prefixes

```json
{
  "item": { "prefix_value": "SKU", "padding_zeroes": 5, "running_number": 1 },
  "supplier": { "prefix_value": "SUP", "padding_zeroes": 5, "running_number": 1 },
  "customer": { "prefix_value": "CUS", "padding_zeroes": 5, "running_number": 1 }
}
```

## Repair, Job, And Profile APIs

### Repair

```http
POST {{base_url}}/v1/tenants/{{bladex_tenant_id}}/repair
```

```json
{
  "request_ref": "repair-20260806-001",
  "targets": ["setup_object_storage", "setup_document_number_rules"],
  "dry_run": { "mode": "connected" }
}
```

Allowed targets:

```text
setup_resource_package
setup_object_storage
create_hq_department
create_hq_role
create_initial_user
update_user_assignments
ensure_orchestrator_service_account
update_role_permissions
setup_accounting_integration
seed_sql_accounting_defaults
setup_document_number_rules
setup_storage_location
setup_bin_location
setup_batch_configuration
setup_transfer_order_configuration
setup_prefixes
```

`create_tenant` and caller-targeted `login_new_tenant` are not repairable. Omitting `targets` plans all repairable steps.

Use repair only after the BladeX tenant already exists and you know which setup data needs reconciliation. It does not create a BladeX tenant. For targets that need a tenant-authenticated downstream call, the worker runs `login_new_tenant` as an internal prerequisite; it is not exposed as a repair step.

The repair endpoint returns the common job receipt. Its full job detail exposes the resulting repair step records, not the internal repair-plan snapshot. A target found to already exist is reported as `skipped_existing` and does not make the repair job fail.

### Job control

```http
GET  {{base_url}}/v1/jobs
GET  {{base_url}}/v1/jobs?bladex_tenant_id={{bladex_tenant_id}}
GET  {{base_url}}/v1/jobs?request_ref=tenant-20260806-001&status=failed
GET  {{base_url}}/v1/jobs/{{job_id}}?detail=full
POST {{base_url}}/v1/jobs/{{job_id}}/retry
```

Scopes: `job:read` for GET routes and `job:retry` for retry.

#### List jobs

`GET /v1/jobs` returns a JSON array ordered from newest to oldest. The optional filters are combined when more than one is supplied:

- `bladex_tenant_id`: return jobs for one BladeX tenant.
- `request_ref`: return jobs created with one caller reference.
- `status`: one of `queued`, `running`, `succeeded`, or `failed`.

Example response:

```json
[
  {
    "job_id": "550e8400-e29b-41d4-a716-446655440000",
    "type": "TENANT_PROVISIONING",
    "bladex_tenant_id": "668171",
    "bladex_tenant_name": "Example Tenant",
    "request_ref": "tenant-20260806-001",
    "status": "failed",
    "retry_count": 1,
    "error": {
      "message": "Downstream request failed"
    }
  }
]
```

List responses do not include `steps`. Request the exact job ID with `?detail=full` to diagnose a specific job.

#### Retry a failed job

```http
POST {{base_url}}/v1/jobs/{{job_id}}/retry
Authorization: Bearer {{jwt}}
Idempotency-Key: <not-used-by-this-route>
```

The retry route does **not** require or read `Idempotency-Key`; the header is harmless but unnecessary. It returns the common receipt:

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "queued"
}
```

Retry only accepts jobs whose current status is `failed`. It keeps the original immutable request and profile snapshots. Steps already `succeeded` or `skipped` are reused; failed and not-yet-run queued steps return to `queued` and execute again. It increments the job `retry_count`. Do not retry until the underlying credentials, configuration, downstream availability, or data issue is corrected.

### Failure And Recovery Decisions

Use the failed job's full detail before deciding. The correct follow-up is determined by whether the original job can safely continue and whether the missing work is isolated.

| Situation | API to use | Why |
| --- | --- | --- |
| A full job is `queued` or `running`. | `GET /v1/jobs/:job_id?detail=full` | It is not terminal; wait rather than submit again. |
| A job failed because a recoverable prerequisite was corrected, such as a secret reference, downstream availability, or transient database error. | `POST /v1/jobs/:job_id/retry` | Preserves the original request/profile snapshot and reuses completed steps. |
| A tenant was created, but one or more setup areas must be reconciled later. | `POST /v1/tenants/:bladex_tenant_id/repair` with narrow `targets`. | Runs only the requested repairable setup steps and never creates another tenant. |
| A later business event needs one additional department, role, user, storage location, or another supported resource. | The matching individual tenant API in [Individual Tenant APIs](#individual-tenant-apis). | Creates a separate auditable job for that one action. |
| You need a different default configuration for future jobs. | Profile version APIs, then profile test and activation. | Existing jobs retain their original profile snapshot; do not edit history to change them. |
| A request was sent twice but has the same body and idempotency key. | `GET /v1/jobs/:job_id?detail=full` using the returned/original receipt. | The service intentionally returns the original job instead of duplicating work. |
| A request reused an idempotency key with a different body. | Submit again with a new `Idempotency-Key`. | The API correctly returns `409 Conflict` to prevent an ambiguous duplicate. |

Known HTTP exceptions use NestJS's standard response form, for example:

```json
{
  "message": "Only failed jobs can be retried",
  "error": "Conflict",
  "statusCode": 409
}
```

The service returns `400` for a missing idempotency key or an invalid profile-test mode, `401` for an invalid or unknown JWT identity, `403` for a missing scope, `404` for an unknown job or profile, and `409` for an invalid retry state or conflicting idempotency use. For a schema-validation failure, consume the deployed API's returned error body rather than assuming the example envelope: request schemas are parsed in the service layer and are not yet normalized through one shared validation filter.

### Profiles

```http
GET  {{base_url}}/v1/provisioning-profiles
GET  {{base_url}}/v1/provisioning-profiles/dev_default
GET  {{base_url}}/v1/provisioning-profiles/dev_default?version=1
POST {{base_url}}/v1/provisioning-profiles/dev_default/versions
POST {{base_url}}/v1/provisioning-profiles/dev_default/activate
POST {{base_url}}/v1/provisioning-profiles/dev_default/versions/1/test
```

Scopes:

```text
GET profile/list: provisioning_profile:read
Create version:    provisioning_profile:write
Activate version:  provisioning_profile:activate
Test version:      provisioning_profile:test
```

Create-version body is a complete profile-config JSON. Safe workflow: GET the current version, make a targeted copy, POST it as the next version, run an offline test, run a connected test, then activate only when the checks and values are verified. Existing jobs keep their immutable profile snapshot.

Response forms:

```json
// GET /v1/provisioning-profiles/:key
{
  "profile_key": "dev_default",
  "profile_version": 1,
  "config": { "...": "validated profile configuration" }
}
```

```json
// POST /v1/provisioning-profiles/:key/versions
{
  "profile_key": "dev_default",
  "version": 2
}
```

`GET /v1/provisioning-profiles` returns the persisted profile records with their version rows, using the service's storage field names. Use `GET /v1/provisioning-profiles/:key` when a caller needs the resolved profile snapshot that will be selected for a job.

Activate body:

```json
{ "version": 2 }
```

`POST /v1/provisioning-profiles/:key/activate` returns an empty success response. It marks the selected version active and marks the previously active version inactive. Always run both test modes before activation; the API does not implicitly run a test or promote a draft after a failed connected check.

## Status And Outcome Rules

Job statuses are `queued`, `running`, `succeeded`, and `failed`. Step statuses add `skipped`. A succeeded job can contain a `skipped` step only where the configuration genuinely does not apply, for example SQL seed defaults for `ATC` accounting.

| Step status | Outcome | Meaning | Typical follow-up |
| --- | --- | --- | --- |
| `succeeded` | Normal step outcome such as `configured` or `created`. | The step performed its intended work. | No action. |
| `succeeded` | `skipped_existing` | The target already existed and was treated as an idempotent success. | Review drift report/result if exact existing data matters. |
| `succeeded` | `skipped_by_request` | The caller disabled an allowed action. | No action unless the setup was actually required; then run a repair or individual command. |
| `skipped` | `skipped_not_applicable` | The step did not apply to this request, such as SQL-only seed work for `ATC`. | No action unless the selected package/accounting type was wrong. |
| `succeeded` | `dry_run_planned` | Dry run planned the action without downstream mutation. | Submit a new live request with a new idempotency key after review. |
| `failed` | Step-specific error/result. | This step stopped the job; following steps remained queued. | Correct root cause, then retry or use a narrow repair job. |

## Live-Use Checklist

1. Confirm API deployment has the correct Coolify PostgreSQL internal URL and starts without Prisma `P1001`.
2. Run `npx prisma migrate deploy && npm run prisma:seed` once from the API deployment.
3. Start the worker application with the same runtime env and confirm it connects to Redis.
4. Register a service identity/public key and generate a JWT with the exact necessary scope(s).
5. Run profile test in `connected` mode and investigate any failed check.
6. Submit an `offline` dry-run full job and inspect its full job detail.
7. Submit the live full job using a new idempotency key.
8. Poll `GET /v1/jobs/:job_id?detail=full` until terminal status.
9. If it fails, read the failed step and retry in place only after correcting the root cause. Use a narrow repair job for already-created tenants where appropriate.

## Sensitive Data Rules

- Do not pass or save BladeX passwords, MySQL URLs, basic-auth values, JWTs, access keys, private keys, or API keys in documentation or request bodies.
- Public request bodies accept `*_secret_ref` names. The actual values must be environment variables available to the **worker**.
- Values returned by job details are redacted, but keep `detail=full` restricted because it includes operational context.
- Use separate development and production profiles/secrets; do not point dev deployments at production credentials.

## Suggested Skills For The Next Agent

- `superpowers:using-superpowers`: before any work in a new session.
- `superpowers:systematic-debugging`: before diagnosing failed Coolify, Redis, PostgreSQL, or downstream jobs.
- `superpowers:brainstorming` and `superpowers:writing-plans`: before changing provisioning behavior or public API contracts.
- `superpowers:test-driven-development`: before implementing a behavior change.
- `superpowers:verification-before-completion`: before claiming a deployment, migration, or job flow is successful.

## Relevant Source Files

- Public controllers: `src/jobs/jobs.controller.ts`, `src/jobs/tenants.controller.ts`, `src/provisioning/profiles/provisioning-profiles.controller.ts`.
- Request validation: `src/provisioning/validation/provisioning-request.schemas.ts`.
- Job/step ownership: `src/jobs/jobs.service.ts`, `src/provisioning/domain/provisioning.constants.ts`.
- Full worker flow: `src/worker/provisioning-worker.service.ts`.
- Profile lifecycle: `src/provisioning/profiles/provisioning-profiles.service.ts`.
- Detailed project guide: `docs/tenant-provisioning-project-documentation.md`.
