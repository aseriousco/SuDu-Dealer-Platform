# Dealer Platform Handoff - Production Provisioning Profile

**Date:** 24 August 2026

## Required change

Dealer Platform must include this top-level field in every production tenant creation request:

```json
"profile_key": "main_default"
```

This applies to:

```http
POST /v1/provisioning/tenant-jobs
```

## Request example

Before:

```json
{
  "request_ref": "dealer-order-88213",
  "tenant": {
    "client_name": "Acme Manufacturing"
  }
}
```

Production request:

```json
{
  "request_ref": "dealer-order-88213",
  "profile_key": "main_default",
  "tenant": {
    "client_name": "Acme Manufacturing"
  }
}
```

Keep all other existing request fields unchanged.

## Why this is required

The orchestrator currently defaults requests without `profile_key` to `dev_default`. Activating
`main_default` does not change that global default.

Sending `main_default` makes the orchestrator resolve its currently active production profile
version and store that exact profile configuration on the provisioning job.

Do not send `profile_version` unless a specific version must be pinned. Omitting it selects the
currently active version of `main_default`.

## Acceptance checklist

- The field is at the request body's top level, not inside `tenant`, `plan`, or the JWT.
- Every production tenant creation request sends `"profile_key": "main_default"`.
- A new `Idempotency-Key` is used when retrying with a corrected request body.
- The returned job is monitored through completion before provisioning is considered successful.

