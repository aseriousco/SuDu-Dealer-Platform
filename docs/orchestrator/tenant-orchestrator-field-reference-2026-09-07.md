# Tenant orchestrator: complete caller field reference

Recycle addition (2026-09-09, pending deployment): `codex/fix-recycle-suspension` makes
`POST /recycle` set only numeric `sudu_customer.is_suspended = 1`, preserving
`customer_status`. Neither field is accepted on new recycle request bodies. Existing
queued status fields are ignored and historical idempotency receipts remain recoverable.
Retrying a failed recycle finishes billing even if BladeX was already recycled.
No unsuspend endpoint, new creation default, or historical conversion is included.
Ensure the downstream billing table has `is_suspended` before deploying API and worker;
the shared lookup also serves registration/repair. No migration or profile re-seed is needed.

Customer-status addition (2026-09-09, pending deployment):
`codex/feat-flexible-customer-status` replaces the fixed customer-status enum with an
optional, trimmed, non-empty string. Custom values such as `Trial` are accepted without
changing case. Empty/whitespace-only strings, null and non-string values return 400.
This applies to full `customer.customer_status`, the registration step override, standalone
registration. Omission retains the existing creation profile default (seeded `Live`).
Registration remains create-only, not a customer update API.
The downstream su-code schema must also accept the supplied value; no downstream enum or
workflow is changed here. No migration or profile re-seed is needed.

Accounting addition (pending deployment): `codex/feat-no-accounting-integration` adds
the exact value `"-"` for No Accounting Integration. The `-` entries below require that
feature on both API and worker; earlier DEV deployment evidence does not cover this addition.
It creates an accounting row with empty agent/API credentials and six posting/account-number
flags set to zero, without skipping normal full-flow seeding/setup. It does not convert existing
integrations. Older stored profiles may omit the new mapping; only that mapping gets a fallback,
so no migration or mandatory profile re-seed is required.

Local update (2026-09-08): branch `codex/dealer-readiness-fixes` implements routing, encrypted job secrets, resumable admin recovery, atomic retry/dispatch, and override/target corrections. All task and whole-branch reviews passed; 833 unit/76 integration tests, Prisma validation, build and whitespace checks passed. Permissions are unchanged. Local changes are uncommitted and not deployed.

Source baseline: remote `dev` commit `096cf510b54d05fdc12f1009241e52489db0d746`, checked 2026-09-07. This is a source contract, not proof of the deployed production version. Read together with `tenant-orchestrator-dealer-handoff-2026-09-07.md` in this directory, especially its limitations and recovery guidance.

Primary authority: `src/provisioning/validation/provisioning-request.schemas.ts`; actual behavior also depends on the job planner, worker request precedence, and step handlers. Comments and older handoffs sometimes describe superseded behavior.

## 1. Type notation and general rules

| Notation | Meaning |
|---|---|
| `S` | Nonempty JSON string, length at least 1; no API maximum unless stated |
| `T` | String trimmed by validation, then required to be nonempty |
| `s` | Any string, including empty string |
| `I` | Integer JSON number; negative values accepted unless bounded below |
| `N` | Finite JSON number, decimals accepted |
| `B` | JSON boolean `true`/`false`, not strings or numeric flags |
| `F` | Numeric flag, exactly `0` or `1` |
| `S[]` | Array of nonempty strings; empty array accepted unless stated |
| `object` | JSON object, not an array |

Fields are optional unless explicitly marked required. Optional does not mean nullable: omit an unused field rather than sending `null`. Do not send numbers as quoted strings unless a union explicitly allows strings. Keep downstream IDs as strings: 19-digit IDs exceed JavaScript's exact integer range. Objects are strict (unknown keys produce HTTP 400), except the explicitly open warehouse row objects and organization workflow-data object.

String validation generally measures JavaScript string length, not user-perceived Unicode graphemes. Most `S` fields are not trimmed at validation. Trim sensible human inputs in the dealer UI, but do not assume every downstream field is normalized identically.

### Common job fields

Available on full creation, individual command routes, and repair:

| Field | Type | Behavior |
|---|---|---|
| `request_ref` | `T` | Correlation label, not an idempotency key; required specifically for `/location-plants` |
| `profile_key` | `S` | Defaults to `dev_default`; production callers must explicitly select their verified production profile |
| `profile_version` | Integer > 0 | Pins a stored profile version; omitted selects the active version |
| `dry_run` | `{ "mode": "offline" }` or `{ "mode": "connected" }` | Omit entirely for a real run; booleans are invalid |

These fields do **not** apply to synchronous `/stored-credentials`, `/jobs/:id/retry`, or the profile administration bodies. Ordinary job-creating POSTs also require `Idempotency-Key` and a valid scoped bearer JWT.

## 2. Full tenant creation body

`POST /v1/provisioning/tenant-jobs` — scope `tenant:create`.

| Field | Type / required | Behavior and restriction |
|---|---|---|
| `tenant` | Required object | Only `client_name` accepted |
| `tenant.client_name` | Required `S` | Tenant name and first organization name. Tenant creation truncates to 20 characters, while organization planning retains the original string. Until aligned, send a trimmed name of at most 20 characters |
| `customer_domain` | Required `S` | Default shared tenant/billing domain; explicit domain step overrides may replace it, but must agree with one another. No DNS syntax, uniqueness, or length rule in this validator |
| `plan` | Required object | Only `plan_id` accepted |
| `plan.plan_id` | Required `S` | Must resolve to a non-deleted billing plan with a package and usable permissions at execution |
| `accounting` | Required object | Only `type` accepted |
| `accounting.type` | Required `SQL`, `ATC`, or `-` | Type for the default organization; `-` means No Accounting Integration, not null/omission |
| `initial_user` | Required object | See below; distinct from BladeX's built-in admin |
| `package` | Optional object | If present, requires `type` of `WMS`, `AI`, or `MES`; hint only, not a substitute for a plan |
| `expire_time` | `S` | Optional expiry; worker accepts `YYYY-MM-DD`, `YYYY-MM-DD HH:mm:ss`, or parseable date-time. Bare date means midnight; ISO offsets normalize through UTC. No enforced future-date rule |
| `tenant_admin` | Admin credential object | Optional final-step rename/password change; see section 4 |
| `customer` | Customer field object | All fields in section 3; create-only, not an existing-row update |
| `organization_setup` | Organization setup object | See organization rules below |
| `schedulers` | Array of scheduler-create objects | Empty or absent means no scheduler steps. See section 7 |
| `auth_overrides` | Auth secret-reference object | See section 5; secret references are not a password-recovery API |
| `step_overrides` | Strict object of the 21 recognized keys in section 6 | Supported values take effect; NEW submissions reject unsupported/no-effect options with field-specific 400 |

### Initial user

| Field | Type / required | Restriction |
|---|---|---|
| `account` | Required string, 1–45 | Must not equal `admin` after trim + case folding. May contain spaces under current API validation |
| `name` | Required string, 1–20 | Display name; may equal account |
| `real_name` | Required string, 1–10 | Not 20 or 100; validate separately in the dealer UI |
| `email` | Required string, 0–45 | `""` allowed; no email-format validator |
| `password_secret_ref` | `S` | Worker environment variable name, **not a password** and not the dealer server's environment variable. If omitted, generated password is `${account}@123!` |

The effective final admin username (including `step_overrides.update_tenant_admin_credentials.username`) must differ from the effective initial-user account (including `step_overrides.create_initial_user.account`), ignoring case and surrounding spaces. The server checks both merged values before accepting the job.

### Organization setup

| Path | Accepted fields |
|---|---|
| `organization_setup` | `default`, `additional` only |
| `organization_setup.default` | `departments` only; no name/accounting override here |
| `organization_setup.default.departments` | Optional department array, minimum 1 if supplied; **replaces** automatic HQ |
| `organization_setup.additional` | Optional array; empty accepted |
| Each additional organization | Required `organization_name: T`, required `accounting` object with `type` of `SQL`, `ATC`, or `-`, required `departments` array with minimum 1 |
| Each department | Required `dept_name: T`; optional `full_name: T`, `dept_category: string or integer`, `sort: I` |

Business rules:

- Without `default.departments`, the default organization gets HQ. With an explicit array, only those requested departments are planned; include HQ yourself if you want it.
- Every additional organization must supply its own accounting type and at least one department. No default department is invented for it.
- No `parent_id` or free-standing/unattached department in this nested body: the enclosing organization determines ownership.
- Organization names must be unique within the request and not equal `tenant.client_name`, trimmed and case-insensitive. Department names must be unique within their organization; the same department name may occur in different organizations.
- There is no API-enforced upper bound on organizations or department counts and no comparison against `customer.organization_limit`.
- Additional names become internal lowercase ASCII slugs. Avoid a slug of `default`, duplicate slugs such as `A B`/`A-B`, or names with no ASCII letter/digit. These are current planner limitations, not fully implemented API validation rules.
- The model is roots + direct departments, not arbitrary nested department trees.

## 3. Customer fields: complete allowlist

All optional in `customer`; for `/sudu-customer` or `step_overrides.register_sudu_customer`, place them **flat**, not inside another `customer` object.

| Field | Type / bounds |
|---|---|
| `customer_status` | Optional `T`: any trimmed, non-empty string; case preserved; downstream acceptance still required |
| `organization_limit` | Integer >= 0 |
| `user_limit` | Integer >= 0 |
| `wa_number_limit` | Integer >= 0 |
| `wa_able_read` | Numeric `0` or `1` |
| `total_price_per_month` | Number >= 0, including `0` and decimals |
| `organization_id` | `S` |
| `price_tag_id` | `S` |
| `customer_area_id` | `S` |
| `customer_agent_id` | `S` |
| `customer_currency_id` | `S` |
| `customer_tax_rate_id` | `S` |
| `customer_tax_percent` | `N`, no minimum/maximum enforced |
| `customer_payment_term_id` | `S` |
| `customer_credit_limit` | `N`, no nonnegative restriction enforced |
| `overdue_limit` | `N`, no nonnegative restriction enforced |
| `customer_com_reg_no` | `S` |
| `customer_com_old_reg_no` | `S` |
| `customer_tin_no` | `S` |
| `customer_sst_sales_no` | `S` |
| `customer_sst_service_no` | `S` |
| `customer_irbm_id` | `S` |
| `business_type_id` | `S` |
| `business_activity_id` | `S` |
| `is_accurate` | `I`, not restricted to 0/1 |
| `is_exceed_limit` | `I`, not restricted to 0/1 |

Zero is preserved. Omission leaves a caller field out of the payload rather than writing a blank/zero. Limits are stored metadata here: the orchestrator does not enforce organization/user/WhatsApp counts against them. Price has no currency inference, tax calculation, or two-decimal precision restriction.

`customer.organization_id` describes the billing customer row; it is not the target selector for the full-flow organizations.

Caller cannot set protected identity/derived columns through this object, including `tenant_id2`, `sudu_plan`, `erp_plan`, `ai_service_plan`, `ai_credit_plan`, `monthly_max_credit`, or `monthly_remain_credit`. Plan fanout resolves the sibling plan IDs. Credit balances are currently deliberately **not written**, despite older comments suggesting otherwise.

`/sudu-customer` additionally accepts `plan_id: S` (required), `customer_domain: S` or `domain_url: S` (at least one), `customer_com_name: S`, `plan_start_date: S`, `created_date: S`. Name otherwise resolves from registered tenant context. Dates have no format validation here. Existing customer rows skip by default; even a profile `update` value does not make this a customer-update API.

## 4. Admin credential fields

Customer tenants only: do not target platform master `000000`, whose authentication intentionally ignores the tenant credential store. This is an operational restriction; the existing endpoints do not yet enforce a master-tenant guard.

| Context | Body |
|---|---|
| Full request `tenant_admin` | Optional `username: S`, `password: S`, `current_password: S` |
| `step_overrides.update_tenant_admin_credentials` | Same three optional fields; overlays `tenant_admin` |
| Standalone `/admin-credentials` | Same fields; at least `username` or `password` must be supplied |
| Synchronous `/stored-credentials` | Required `username: S` and `password: S`; optional `profile_key: T`, `profile_version: positive integer` (requires key). No other common job fields |

Without selectors, recovery requires reliable non-dry-run provisioning history with one environment. Missing history returns 409 `tenant_profile_required`; conflicting history/explicit environment returns 409 `tenant_profile_ambiguous`. Explicit selection is required for an external tenant with no recorded history. Passwords are verified against the resolved profile before storage; the route never silently selects dev_default.

This route also onboards an externally created tenant: after login and active root-admin verification using the selected profile's MySQL read connection, it creates a missing local `Tenant` as `EXTERNAL_REGISTERED` and records tenant/admin mappings. Existing tenant status is preserved. Invalid credentials or identity do not register a tenant. Supply the current username/password (including a renamed admin), not old/new password fields or shared infrastructure secrets. It creates no job and makes no downstream changes. Registration and credential promotion are separate recoverable stages; retry the same pair after an interrupted storage operation. No full-provisioning history is synthesized, so external tenants still need explicit profile selection on later recovery calls.

These passwords are caller plaintext sent over HTTPS; do not pre-hash them. The worker converts the password-change API parameters to MD5 as required by BladeX. This is different from an initial-user `password_secret_ref`.

For admin changes, `current_password` wins when explicitly supplied; otherwise the verified stored password wins, then the profile bootstrap password only when storage has no row. The selected pair must authenticate. Renames and later rotations target the same stable admin user ID. Equal-value verified requests perform no downstream mutation; username-only preserves the password. Full-flow collision validation compares the effective initial-user account and effective admin username after both step overrides, trimmed and case-insensitive.

Credential operations serialize per tenant. An unresolved operation cannot be replaced by a new body or a synchronous stored-credentials call. The original job retains its encrypted intent across retries, and completed job operations have immutable internal receipts so an old retry cannot undo a newer change. Operator reconciliation is required for uncertain in-flight mutations; no public force-reset/receipt-edit field exists. See companion handoff section 6 for phase/error/CLI details.

The local encrypted-job fix keeps internal references in ordinary request/step JSON and stores secrets in a separate encrypted job bag, using the existing TENANT_CREDENTIAL_KEY. Callers continue sending the same fields, never internal references. Secret-bearing submissions fail before writes if the key is unusable. Same body/key remains idempotent; changed password/current_password with the same key conflicts. Existing plaintext jobs require the controlled operator conversion described in the companion handoff; this is not a claim that production or historical backups have been cleaned.

No API maximum length, password complexity, or whitespace-only rejection is implemented for these fields. That is a validation gap, not a promise that arbitrary strings work in BladeX. For usernames, align dealer validation with the login account's 45-character storage boundary. Never include actual passwords in tickets, examples, URLs, logs, or exported Postman environments.

## 5. Auth override fields

Recognized auth fields and NEW submission support:

- `bootstrap_admin_password_secret_ref: S`: effective master/bootstrap secret reference.
- `tenant_admin_password_secret_ref: S`: effective tenant bootstrap secret reference when no verified stored credentials exist.
- `tenant_service_password_secret_ref: S`: legacy shape only; NEW full/repair submissions reject it because workers authenticate as tenant admin.

Supported references are applied through an in-memory view of the saved profile, including repair access checks; the persisted profile is not rewritten. They name existing process-side environment secrets, not uploaded passwords. Verified stored per-tenant credentials retain priority. Use `/stored-credentials` for external admin password changes. There is no full-run switch to the legacy orchestrator service account.

## 6. Every recognized `step_overrides` key and its support

An override is a request customization, **not** permission to overwrite an existing database row. Existing-row behavior is handler/profile-specific.

For full provisioning, supported generic values merge into each applicable planned organization request. Nested picking/prefix values merge field-by-field; custom arrays replace defaults; permitted zero/false/empty values survive. Planned tenant/org/dept identity and final user assignments remain protected. Standalone bodies and scheduler requests are not replaced by generic full-flow overrides. Unscoped full steps retain their effective top-level-plus-step overlay.

NEW business restrictions are separate from the recognized historical JSON shape. Identical caller/key/body replay can recover an already accepted job before NEW restrictions are applied, with original fingerprint equality required. `/retry` and controlled secret conversion do not revalidate saved jobs as new submissions. Their snapshots stay unchanged, but unfinished supported overrides can now become effective with the new worker; ownership checks can stop unsafe historical targets. See the handoff's pending-job preflight before rollout. The executable [148-leaf disposition matrix](superpowers/specs/2026-09-07-override-field-dispositions.md) supplies per-field evidence.

Recovering a historical receipt does not create a replacement job or certify that the old input can finish successfully. In particular, an old effective admin/initial-user account collision still needs operator diagnosis; NEW submissions reject it. Changing that body's fields under the same key remains a conflict.

| Key | Complete recognized fields | NEW full-run support / effect |
|---|---|---|
| `setup_resource_package` | `type` of `WMS`, `AI`, or `MES`; `plan_id: S`, `menu_parent_ids: S[]`, `menu_excluded_ids: S[]`, `enable_transfer_order_setup: B` | Plan effective; type metadata only. Menu filters and transfer flag return 400, including standalone |
| `update_tenant_details` | `expire_time: S`, `account_number: integer > 0`, `plan_id: S` | Effective; explicit account number wins over plan limit |
| `update_tenant_admin_credentials` | `username: S`, `password: S`, `current_password: S` | Effective overlay; secret persistence and validation caveats apply |
| `set_tenant_domain_url` | `customer_domain: S`, `domain_url: S` | Explicit override replaces default for both tenant and billing; conflicting explicit aliases/step domains return 400 |
| `register_sudu_customer` | All 26 customer fields above, plus `customer_domain: S`, `domain_url: S`, `plan_id: S`, `customer_com_name: S`, `plan_start_date: S`, `created_date: S` | Effective for creation; protected fields still resolved by handler; existing customer is not updated |
| `setup_object_storage` | `bucket_name: S`, `endpoint: S`, `oss_code: S`, `category: I`, `transform_endpoint: valid URL string`, `access_key_secret_ref: S`, `secret_key_secret_ref: S`, `oss_submit_auth_token_secret_ref: S` | All eight request values override corresponding profile defaults, including standalone; secrets resolve privately |
| `create_hq_department` | `dept_category: string or I`, `dept_name: S`, `full_name: S`, `parent_id: numeric 0 or S`, `sort: I` | Nonempty full override returns 400: use organization_setup. Standalone remains supported |
| `create_hq_role` | `role_alias: S`, `role_name: S`, `parent_role_id: numeric 0 or S`, `sort: I` | Reaches handler; tenant-level shared role |
| `create_initial_user` | All user override fields below | Effective for creation; later full assignment step assigns all organizations/departments regardless of initial dept selection |
| `update_user_assignments` | `user_id: S`, `account: S`, `dept_ids: S[]`, `role_ids: S[]` | Nonempty full override returns 400; built-in admin + initial account still receive all planned departments. Standalone explicit assignments remain supported |
| `ensure_orchestrator_service_account` | All user override fields below | Nonempty full override returns 400; step stays excluded. Standalone does not switch worker identity |
| `update_role_permissions` | `role_id: S`, `plan_id: S`, `package_type` of `WMS`, `AI`, or `MES`; `menu_ids: S[]`, `menu_parent_ids: S[]`, `menu_excluded_ids: S[]` | menu_ids wins, otherwise plan permissions. package_type and parent/exclusion filters return 400, including standalone |
| `setup_accounting_integration` | `type` of `SQL`, `ATC`, or `-`; `seed_sql_defaults: B` | Generic type must agree with every organization's type. Full seed_sql_defaults returns 400; standalone retains its real seed-step consumer |
| `seed_tenant_master_data` | `enabled: B` | Tenant-level required seed: true supported; false returns 400 in full provisioning |
| `seed_org_master_data` | `seed_org_master_data: B`, `org_seeding_workflow_data: open object` | Data transported per organization with protected organization_id; full false returns 400. Standalone false skips and cannot accompany nonempty workflow data |
| `setup_document_number_rules` | `copy_missing_rules: B`, `disable_draft_defaults: B`, `copy_stock_strategy: B` | Nonempty full override returns 400; all three unused switches also return 400 standalone |
| `setup_storage_location` | `rows: array of open objects` | Replaces per-department defaults in every org, subject to required fields, ownership and dependent bin/loading references; full empty rows rejected |
| `setup_bin_location` | `rows: array of open objects` | Replaces per-department defaults in every org, with same-target storage references and required fields; full empty rows rejected |
| `setup_batch_configuration` | Batch fields below | Supported values applied per org; protected full target. Standalone uses one validated target for reads/writes |
| `setup_transfer_order_configuration` | Transfer fields below | Supported selection/picking values applied per org; full disabling/empty areas rejected; protected target and dependency checks |
| `setup_prefixes` | `item`, `supplier`, `customer`, each a prefix object below | All nested values applied per planned org; repeated defaults remain valid |

No other override keys are accepted. In particular, no `create_tenant`, `login_new_tenant`, `setup_organization_structure`, `create_scheduler`, `update_scheduler`, `create_location_plant`, `recycle_tenant`, or per-organization scope-key map is accepted in `step_overrides`.

### User override object (complete)

`account: string 1–45`, `name: string 1–20`, `real_name: string 1–10`, `email: string 0–45`, `password_secret_ref: S`, `dept_id: S`, `dept_ids: S[]`, `role_id: S`, `role_ids: S[]`, `post_id: S`, `user_type: I`, `update_password_on_existing: B`.

All optional in overrides. `account` cannot normalize to admin. Standalone `/users` additionally requires account, name, real_name, password_secret_ref; email remains optional there. NEW user-creation submissions reject empty dept_ids/role_ids and simultaneous singular/plural forms of the same selector; omit unused forms. These are not clear-all controls. Verify access-control targets belong to the intended tenant rather than assuming the warehouse ownership fix covers every user/role API.

`update_password_on_existing: true` returns field-specific 400 for NEW submissions. Historical execution can still stop with `downstream_contract_unverified`, including dry runs. This is not an implemented initial-user password reset API.

### Batch override object (complete)

`organization_id: S`, `batch_level_selection: S`, `batch_prefix: s`, `batch_running_number: string or I`, `batch_padding_zeroes: string or I`, `batch_format: s`, `workflow_id: S`.

Important distinction: public `batch_format` is for **batch_level_config** (default `Default`). The workflow's `%4d` is sourced from profile `batch_configuration.batch_number_format`, then code fallback. `batch_number_format` and other `batch_number_*` keys are not accepted in this public object. `workflow_id` is supported only with the stored generic `/api/su-code-service/workflow/execute` endpoint; NEW requests specifying it against a concrete workflow URL return 400. Standalone organization_id is validated and used consistently for both batch substeps' lookups and writes.

### Transfer override object (complete)

`enabled: B`, `package_type: WMS|AI|MES`, `organization_id: S`, `plant_id: S`, `loading_bay_storage_location_code: S`, `loading_bay_bin_location_code: S`, `areas: array of picking|putaway|packing|plant_transfer|sales_return`, `picking: object`.

Every accepted field in `picking`:

- Strings `S`: `movement_type`, `picking_after`, `picking_mode`, `default_strategy_id`, `fallback_strategy_id`, `bin_validation_scope`, `split_policy`.
- Numeric flags `F`: `picking_required`, `auto_trigger_to`, `is_loading_bay`, `allow_full_picking`, `auto_completed_gd`, `auto_completed_si`, `require_bin_scan`, `require_batch_scan`, `require_item_scan`, `require_hu_scan`, `full_cl_check`, `convert_gd_created`.

The strategy fields hold strategy codes such as `RANDOM`/`FIXED BIN`, despite the `_id` suffix. No putaway/packing/plant_transfer/sales_return nested object exists. NEW package_type and loading_bay_bin_location_code are rejected as unused; picking no longer requires a package hint. Nonempty picking data requires the effective picking area; loading_bay_storage_location_code requires putaway. NEW full requests cannot set enabled:false or areas:[]; standalone enabled:false is a supported skip only without other ineffective options. Explicit standalone organization/plant selectors control all selected areas after ownership validation.

### Prefix object (complete)

For each of `item`, `supplier`, `customer`: `prefix_value: s`, `padding_zeroes: I`, `running_number: I`. No public organization selector. Negative integers are not rejected by this validator; downstream acceptance is not guaranteed.

### Warehouse row objects

`rows` is intentionally an open array of JSON objects, not a finite inner-key allowlist. Unknown non-target fields retain transport behavior; that does not prove an external workflow consumes them. Custom arrays replace profile rows. Storage rows require nonempty storage_location_name and storage_location_code; bin rows require bin_name and a storage_location_id/code/key reference. Required default bin/loading dependencies must remain satisfiable for full creation. Recognized tenant/org/plant selectors must agree with the resolved target; reserved internal execution/scope replacement is rejected.

Row-level transport controls are not business fields: url, access_token, tenant_id_header, headers, authorization, Authorization and request_data are rejected. They cannot select an authenticated request's destination or credentials. Historical saved rows containing these controls fail before authentication/write as well; they are not silently reused. Nested ordinary business data (including business URLs) remains opaque transport, subject to the recognized ownership/internal-control checks.

The captured default storage row uses `key`, `storage_status`, `is_default`, `storage_location_name`, `storage_location_code`, `location_type`, `storage_description`, `storage_qr_color`, `storage_qr_position`, `storage_tier_highlight`, `table_bin_location`, `language`; targeting can include `organization_id`, `plant_id`.

The captured default bin row uses `key`, `storage_location_key`, `bin_status`, `storage_location_name`, `bin_name`, `bin_label_tier_1`, `bin_code_tier_1`, `tier_1_active`, `bin_location_combine`, `language`; row resolution can use `storage_location_id`, `storage_location_code`, `organization_id`, `plant_id`. Supply an explicit organization/department and correct storage reference for multi-org standalone work. Never invent additional low-code column contracts from the open shape.

Standalone warehouse defaults must resolve uniquely; ambiguous/missing root/HQ fails closed instead of selecting an arbitrary tenant row. An explicit plant may be the validated organization root itself (root-level resources are supported) or an active direct department under it. Storage ID, code and key, when supplied together, must identify the same row within that target. Connected dry runs validate read-only; offline runs retain explicit selectors without proving live ownership.

## 7. Scheduler fields

Full `schedulers[]` and standalone `/schedulers` share the same schema:

| Field | Create | Type / behavior |
|---|---|---|
| `agent_id` | Required | `T`; multiple schedulers per agent permitted |
| `task_type` | Required | `T`; not an enum and not a unique key with agent_id |
| `workflow_id` | Required | `T`; caller supplies an existing appropriate workflow ID |
| `cron_expression` | Required | `T`; no cron grammar validation in orchestrator |
| `priority` | Required | Any string or integer number |
| `full_sync` | Required | Any string, boolean, or integer number |
| `status` | Optional | `Running` or `Paused`; handler default is Running |
| `description` | Optional | Any string |

`POST /schedulers/{scheduler_id}` accepts a partial object of those eight fields, but at least one must be supplied. Put the ID in the URL; it is the su-code quartz document ID, not agent ID, workflow ID, local job UUID, or a fabricated composite key. It must already have a tenant-scoped local mapping. There is no public scheduler listing/import/delete endpoint.

The validators' broad priority/full_sync unions are not a downstream business contract. Prefer values already confirmed for the caller workflow. Scheduler creation does not make an accounting agent online or prove task execution.

Offline scheduler updates that change any of agent_id/task_type/workflow_id/priority/full_sync require all five fields together, because no stored mapping is read. Status/cron/description-only offline updates can remain partial. Downstream parameter construction stringifies priority and full_sync.

## 8. Complete standalone command and scope matrix

All suffixes below are under `/v1/tenants/{bladex_tenant_id}` and use POST. Unless noted, they create jobs, accept common fields from section 1, and require `Idempotency-Key`. These scopes are **not** implicitly granted by `tenant:create`.

| Suffix | Required scope | Body / use |
|---|---|---|
| `/package` | `tenant:package:setup` | Package override object, plan_id required; package assignment only |
| `/details` | `tenant:details:update` | Tenant-details object; require expire_time or account_number (plan_id alone insufficient) |
| `/domain` | `tenant:domain:set` | customer_domain or domain_url required; tenant-domain change only |
| `/sudu-customer` | `tenant:sudu_customer:register` | Section 3 flat body, plan + domain required; missing customer creation only |
| `/object-storage` | `tenant:object_storage:setup` | Object-storage override object |
| `/departments` | `tenant:department:create` | Department override object, dept_name required; parent_id string selects parent, numeric 0/string "0" requests root |
| `/location-plants` | `tenant:location:sync` | Required request_ref, organization_id:T, dept_name:T; optional full_name:T. dept_name uppercased by validator |
| `/roles` | `tenant:role:create` | Role override object; role_alias and role_name required |
| `/users` | `tenant:user:create` | User object; account, name, real_name, password_secret_ref required |
| `/users/update-assignments` | `tenant:user:update` | user_id or account required; dept_ids or role_ids required |
| `/orchestrator-service-account` | `tenant:orchestrator_service_account:setup` | User override object; creates/ensures legacy account, does not switch worker auth |
| `/role-permissions` | `tenant:role_permission:setup` | Role-permissions object; provide role_id plus plan_id or menu_ids for usable standalone execution |
| `/accounting-integration` | `tenant:accounting:setup` | type required: SQL, ATC, or -; seed_sql_defaults optional. Runs accounting setup and tenant master seed; no organization_id accepted; does not convert an existing integration |
| `/org-seeding` | `tenant:org_seeding:setup` | Org-seeding object; no top-level organization_id accepted; nested workflow-data organization cannot override resolved root |
| `/document-numbers` | `tenant:document_number:setup` | Legacy root-based path; omit unused document-number toggles, which NEW submissions reject |
| `/storage-locations` | `tenant:storage_location:create` | Single-storage body below or rows array (minimum 1) |
| `/bin-locations` | `tenant:bin_location:create` | Single-bin body below or rows array (minimum 1) |
| `/batch-configuration` | `tenant:batch:setup` | Batch object; explicit organization_id validated and used for lookups/writes |
| `/transfer-order-configuration` | `tenant:transfer_order:setup` | Transfer object; explicit organization/plant validated and used across selected areas |
| `/prefixes` | `tenant:prefix:setup` | Prefix groups; no organization_id accepted, root fallback |
| `/schedulers` | `tenant:scheduler:create` | Full scheduler-create object |
| `/schedulers/{scheduler_id}` | `tenant:scheduler:update` | Partial scheduler fields, at least one |
| `/admin-credentials` | `tenant:admin_credentials:update` | username and/or password, optional current_password |
| `/stored-credentials` | `tenant:admin_credentials:update` | username + password required; optional profile_key/profile_version (section 4); synchronous, no idempotency/other common fields |
| `/repair` | `tenant:repair` | Common fields plus optional auth_overrides and targets:S[]; see repair restrictions |
| `/recycle` | `tenant:recycle` | Common job fields plus optional expected_tenant_name:S; omit customer_status and is_suspended (400 for new submissions). Sets is_suspended=1 without changing status; retry finishes billing. Destructive soft-recycle, not a status-only update |

Single-storage body: required `storage_location_name:S`, `storage_location_code:S`; optional `organization_id:S`, `plant_id:S`, `location_type:S`, `storage_status:string or I`, `is_default:string or I`.

Single-bin body: required `bin_name:S` and at least one of `storage_location_code:S`/`storage_location_id:S`; optional `bin_code_tier_1:S`, `bin_location_combine:S`. It does not accept top-level organization_id/plant_id; use an explicitly scoped rows body and verify behavior for multi-org work.

The `/location-plants` endpoint also supports its separately configured `X-Location-Plant-Key` authentication. That key does not authorize the rest of the API, including GET jobs. Do not confuse it with the dealer agent gateway's inbound shared key.

### Job APIs

| Method / path | Scope | Contract |
|---|---|---|
| GET `/v1/jobs` | `job:read` | Optional query bladex_tenant_id, request_ref, status; newest first, currently no row cap or pagination |
| GET `/v1/jobs/{job_id}` | `job:read` | `?detail=true` or `?detail=full` includes redacted step requests/results/substeps and runtime_context |
| POST `/v1/jobs/{job_id}/retry` | `job:retry` | No request-body patch and no required Idempotency-Key. Atomic claim of the observed FAILED attempt; one concurrent caller wins. Preserves completed/skipped steps and snapshots; durable dispatch retries queue outages. RUNNING or FAILED-with-RUNNING-step jobs require operator reconciliation, not this API |

### Repair targets

Accepted `targets` values are exactly:

`setup_resource_package`, `update_tenant_details`, `set_tenant_domain_url`, `register_sudu_customer`, `setup_object_storage`, `create_hq_department`, `create_hq_role`, `create_initial_user`, `update_user_assignments`, `ensure_orchestrator_service_account`, `update_role_permissions`, `setup_accounting_integration`, `seed_tenant_master_data`, `seed_org_master_data`, `setup_document_number_rules`, `setup_storage_location`, `setup_bin_location`, `setup_batch_configuration`, `setup_transfer_order_configuration`, `setup_prefixes`.

An accepted target is only considered by the repair planner's eligibility rules; it does not force execution or accept that step's body overrides. No setup_organization_structure, scheduler, admin change, recycle, or location-plant target. Repair is not a complete multi-org reconcile API.

### Profile administration APIs

| Method / path | Scope | Body / query |
|---|---|---|
| GET `/v1/provisioning-profiles` | `provisioning_profile:read` | None |
| GET `/v1/provisioning-profiles/{key}` | `provisioning_profile:read` | Optional `?version=N`; otherwise active |
| POST `/v1/provisioning-profiles/{key}/versions` | `provisioning_profile:write` | Entire config object, not `{config: ...}` and not a partial request override |
| POST `/v1/provisioning-profiles/{key}/activate` | `provisioning_profile:activate` | `{ "version": 2 }` |
| POST `/v1/provisioning-profiles/{key}/versions/{version}/test` | `provisioning_profile:test` | `{ "mode": "offline" }` or connected; defaults offline |

Profile operations are synchronous and do not use the provisioning-job Idempotency-Key workflow. These are platform-operator controls, not ordinary dealer customer inputs. For the complete operator configuration schema, use `src/provisioning/profiles/provisioning-profile.schema.ts` and a verified stored profile export; do not build a new production profile by pasting DEV defaults.
