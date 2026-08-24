Integration contract · Sudu Tenant Orchestrator

Tenant Lifecycle API
Everything the dealer platform needs to create, amend and retire a Sudu tenant — including the four routes added this week and the one breaking change to the create body.

Base /v1
Auth Internal service JWT (ES256)
Model Async · job per request
Revised 19 Aug 2026
What changed
Auth & headers
The async model
Create a tenant
The customer block
Individual routes
Recycling a tenant
Step reference
Error codes
Sharp edges
What changed
Four new routes and one breaking change. If you wire nothing else, wire the breaking change.

Breaking
customer_domain is now required on the create-tenant body. A request without it is rejected with 400 before anything is created.

It is required rather than optional on purpose. The domain feeds two steps that run at positions 4 and 5 of the sequence — so an absent value would pass validation, create the tenant, assign its package, and only then fail, leaving a half-provisioned tenant to clean up by hand. Rejecting it up front leaves nothing behind.

New surface
Route Purpose Added
POST /v1/tenants/{id}/details Sets subscription expiry and the tenant user limit Today
POST /v1/tenants/{id}/domain Sets the tenant's domain on blade_tenant.domain_url Yesterday
POST /v1/tenants/{id}/sudu-customer Creates the Sudu billing customer record Yesterday
POST /v1/tenants/{id}/recycle Moves the tenant to the recycle bin and suspends its billing record Today
All four also run automatically as part of creating a tenant, apart from recycle, which never does. The standalone routes exist for repair and for lifecycle actions taken long after provisioning.

Auth & headers
Every route is guarded twice: the scope must be present in the JWT and on the registered service identity.

Authorization: Bearer <internal service JWT>
Content-Type: application/json
Idempotency-Key: <unique per logical request>
Scopes by route
Scope Grants
tenant:create Full tenant provisioning
tenant:details:update Expiry and user limit
tenant:domain:set Domain
tenant:sudu_customer:register Billing customer record
tenant:recycle Recycle — destructive
job:read Poll job status
job:retry Retry a failed job
tenant:recycle is deliberately separate from every provisioning scope. A credential that can create tenants cannot delete them unless it is granted this as well — grant it narrowly.

Idempotency-Key
Required on every mutating route. Replaying a key with an identical body returns the original job rather than starting a second one. Replaying it with a different body is rejected as a hash mismatch — so generate a fresh key whenever the payload changes, and reuse the key when retrying the same logical operation after a network failure.

The async model
Nothing is done by the time the POST returns. Every mutating route enqueues a job and answers immediately with its id.

// POST returns straight away
{ "job_id": "4fb7c587-a5a1-4db7-a601-0a3752597478", "status": "queued" }
GET
/v1/jobs/{job_id}?detail=full
job:read
Poll this until status leaves queued / running. Add detail=full to get each step's request, result and runtime context — without it you get status only.

POST
/v1/jobs/{job_id}/retry
job:retry
Re-runs a failed job. Steps that already succeeded are skipped, so it resumes at the first failure rather than starting over. Safe to call repeatedly.

Job and step status is one of queued, running, succeeded, failed, skipped. A skipped step is not a failure — it means the work was already done, which is how most steps behave on a second run.

Dry runs
Add "dry_run": { "mode": "connected" } to any body to validate against live data without writing anything. "offline" skips even the reads and just echoes what would be sent. Use connected when you want to see derived values — the plan fan-out, the resolved user limit — before committing.

Create a tenant
POST
/v1/provisioning/tenant-jobs
tenant:create
Runs the full 21-step sequence. One call provisions the tenant, its package, domain, billing record, users, org data and warehouse configuration.

{
"request_ref": "dealer-order-88213",
"tenant": { "client_name": "Plan Live 002" },
"plan": { "plan_id": "2089572840018726914" },
"accounting": { "type": "SQL" },
"customer_domain": "planlive002.sudu.ai",
"expire_time": "2027-01-31",
"customer": {
"customer_status": "Live",
"customer_currency_id": "2071864755349745669",
"customer_tax_rate_id": "2047207963138121732",
"customer_tax_percent": 8,
"customer_credit_limit": 10000,
"customer_tin_no": "tin123"
},
"initial_user": {
"account": "pl02",
"name": "Plan Live",
"real_name": "PL",
"email": "pl02@example.com"
}
}
Top-level fields
Field Type Notes
tenant.client_name string req Truncated to 20 chars for BladeX
plan.plan_id string req Drives package, credits and user limit
accounting.type SQL | ATC req —
customer_domain string req New. Written to both the tenant and the billing record
initial_user object req account must be unique across BladeX
expire_time string opt New. ISO or YYYY-MM-DD; absent means no expiry
customer object opt New. Finance details — see below
package.type WMS | AI | MES opt Only when the plan's package is unmapped
request_ref string opt Your reference; searchable via GET /v1/jobs
What the plan supplies for you
Send the plan_id and the orchestrator derives the rest by reading sudu_plan — you do not send any of these:

The BladeX product package, from tenant_package_id, and the WMS/AI/MES shape that follows from it
The ERP, AI service and AI credit plan links on the billing record
Monthly credits, from the AI credit plan's monthly_credit_amount
The tenant user limit, from tenant_user_limit
The customer block
Optional finance and registration details for the billing record. Send only what the dealer actually collected — a field you omit is left off the record entirely, never written as a blank.

Accepted fields · all optional
Field Type
customer_status Live | Testing | Live Suspended | Testing Suspended
customer_currency_id string
customer_tax_rate_id string
customer_tax_percent number
customer_payment_term_id string
customer_credit_limit number
overdue_limit number
price_tag_id string
customer_area_id string
customer_agent_id string
organization_id string
customer_com_reg_no string
customer_com_old_reg_no string
customer_tin_no string
customer_sst_sales_no string
customer_sst_service_no string
customer_irbm_id string
business_type_id string
business_activity_id string
is_accurate integer
is_exceed_limit integer
Strict
The block is strictly validated. A misspelled field name is a 400, not a silent drop — without that, the record would be created successfully with your value quietly missing.

customer_status defaults to Live when omitted. Note that suspension is a modifier on the tier rather than a status of its own, which is why there is no bare Suspended.

Individual routes
Each targets one tenant by its six-digit tenant code. Each returns a job, exactly like the create route.

Identifier
The {id} in these paths is the six-digit tenant code — 966073 — not blade_tenant.id. Where BladeX itself needs the surrogate row id, the orchestrator resolves it for you.

POST
/v1/tenants/{id}/details
tenant:details:update
{ "expire_time": "2027-01-31", "plan_id": "2089572840018726914" }
Sets subscription expiry and the tenant user limit. The limit comes from the plan; pass account_number to override it. At least one of expire_time or account_number is required. Dates may be ISO-8601 or YYYY-MM-DD.

POST
/v1/tenants/{id}/domain
tenant:domain:set
{ "customer_domain": "planlive002.sudu.ai" }
Sets the tenant's domain. Re-sending the value it already has returns already_set rather than writing again. domain_url is accepted as an alias.

POST
/v1/tenants/{id}/sudu-customer
tenant:sudu_customer:register
{
"customer_domain": "planlive002.sudu.ai",
"plan_id": "2089572840018726914",
"customer_currency_id": "2071864755349745669"
}
Creates the billing record for an existing tenant. Takes the same finance fields as the customer block, flat rather than nested. A tenant that already has a record returns skipped — it will not create a second one.

Recycling a tenant
The only destructive operation in this API. It is a soft delete — the tenant moves to BladeX's recycle bin and can be restored.

POST
/v1/tenants/{id}/recycle
tenant:recycle
{
"customer_status": "Live Suspended",
"expected_tenant_name": "KL Test 3"
}
Both fields optional. Does two things in one job: moves the tenant to the recycle bin, then suspends its billing record.

What it actually changes
The tenant's status becomes -1. Its is_deleted stays 0 — that flag means permanently deleted and is a different state.
Users, departments, org data and object storage all survive untouched. Nothing is dropped.
The billing record moves to the customer_status you passed. Omit it and the orchestrator derives it: Live → Live Suspended, Testing → Testing Suspended.
Recommended
Always send expected_tenant_name. The tenant code sits in the URL, so a mistyped digit addresses a real but different tenant — and nothing else would catch it. When the name doesn't match the tenant found, the job refuses with tenant_name_mismatch before anything is touched.

Recycling a tenant that is already in the bin returns skipped, not an error. A tenant with no billing record still succeeds, reporting no_billing_customer.

Step reference
The order a create-tenant job executes in. Steps highlighted in teal are the ones added this week. Each appears in the job's steps array with its own status, outcome and error.

create_tenant
setup_resource_package
update_tenant_details
set_tenant_domain_url
register_sudu_customer
login_new_tenant
setup_object_storage
create_hq_department
create_hq_role
create_initial_user
update_user_assignments
ensure_orchestrator_service_account
update_role_permissions
setup_accounting_integration
seed_tenant_master_data
seed_org_master_data
setup_storage_location
setup_bin_location
setup_batch_configuration
setup_transfer_order_configuration
setup_prefixes
recycle_tenant is a step too, but it is excluded from this sequence by design and can only be reached through its own route. create_location_plant and setup_document_number_rules are likewise excluded and have their own routes.

Error codes
Failures surface as error.error_code on the job and on the failing step. These are the ones the new routes can produce.

Rejected before anything is written
Code Meaning & fix
domain_url_required No customer_domain. Send one.
plan_id_required No plan supplied and none on the job context.
plan_not_found The plan_id is not in sudu_plan. Check it is active.
expire_time_invalid Not a date. Use ISO-8601 or YYYY-MM-DD.
tenant_name_mismatch Your expected_tenant_name is not this tenant. Check the id.
bladex_tenant_not_found No such tenant code.
sudu_customer_exists Billing record already present.
Written but not confirmed — retry after investigating
Code Meaning & fix
tenant_domain_url_not_persisted The domain did not land. Upstream accepted and dropped it.
tenant_expire_time_not_persisted Same, for expiry — usually a date format upstream rejected.
tenant_account_number_not_persisted Same, for the user limit.
tenant_not_recycled The tenant is still active after a reported success.
sudu_customer_status_not_updated The billing status did not change. Tenant is recycled; retry.
sudu_customer_status_unmappable Billing status has no suspended equivalent. Pass customer_status explicitly.
tenant_submit_clobbered_row An update overwrote a field it should not have. Stop and report this one.
The second group all come from the same design choice: upstream returns HTTP 200 even when it silently drops a value, so every write is read back and confirmed. A job that reports success has been verified, not merely accepted.

Sharp edges
The things most likely to cost an afternoon.

Success is not the HTTP status
Both upstream systems answer 200 with failure in the body. Never treat a 2xx from a job-creating POST as "the work is done" — it only means the job was queued. Poll the job.

The tenant code is not the row id
Six-digit codes like 966073 identify tenants in this API. The 19-digit blade_tenant.id never appears in a request you write.

A skipped step is a success
Re-running any route is safe, and most steps report skipped the second time. Treat skipped as done, not as a problem to escalate.

Retry the job, don't repost the request
After a failure, call the retry route with the job id rather than POSTing the original request again. Retry resumes from the failed step; a fresh POST with a new idempotency key starts a second job that may duplicate work.

Billing status vocabulary is live
The customer_status values changed once already this month. If a status is rejected as invalid, confirm the current vocabulary before assuming the record is wrong.

Sudu Tenant Orchestrator · contract as of 19 August 2026. Behaviour described here is covered by the service's test suite; the recycle route's billing update has been exercised against dev but its upstream update format is still being confirmed — report anything that behaves differently.
