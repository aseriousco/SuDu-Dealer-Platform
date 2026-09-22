# docs/orchestrator/

Contracts and handoff notes the **`sudu-tenant-orchestrator`** team hands to us.

**These are inbound documents. We do not own them and must not edit them** — not to fix a
typo, not to add a note. When something here is wrong or unclear, ask that team and file
their reply as a new dated document. An edited contract is a contract nobody can trust,
because the copy we hold stops matching the copy they sent.

Keep their filenames exactly as delivered, even when the naming is inconsistent. The name is
how they refer to it in conversation.

## Not to be confused with

| Folder | Whose | What it is |
|---|---|---|
| `docs/orchestrator/` | **theirs** | What the orchestrator expects from us, and what it promises back |
| [`docs/contracts/`](../contracts/) | ours | The surface between `sudu-dealer-web` and `sudu-dealer-api` |
| [`docs/specs/`](../specs/) | ours | Cross-repo feature designs, which cite the documents here as parents |

## What we hold, newest first

| Document | Date | What changed |
|---|---|---|
| [`tenant-orchestrator-dealer-handoff-2026-09-07.md`](./tenant-orchestrator-dealer-handoff-2026-09-07.md) | 2026-09-07 | The current operating manual: job lifecycle, retry and repair, dry runs, failure-code table, standalone routes. Supersedes 2026-08-06 as the API map |
| [`tenant-orchestrator-field-reference-2026-09-07.md`](./tenant-orchestrator-field-reference-2026-09-07.md) | 2026-09-07 | Every accepted field, and §8's **command-and-scope matrix** — the authority on which scope each standalone route needs |
| [`dealer-platform-production-profile-key-handoff-2026-08-24.md`](./dealer-platform-production-profile-key-handoff-2026-08-24.md) | 2026-08-24 | Top-level `profile_key` on tenant creation. Without it the orchestrator resolves `dev_default` |
| [`dealer-platform-handoff-2026-08-20.md`](./dealer-platform-handoff-2026-08-20.md) | 2026-08-20 | `customer_domain` and `plan.plan_id` required with no fallback; optional `tenant_admin` block |
| [`sudu-tenant-orchestrator-api-handoff-2026-08-19.md`](./sudu-tenant-orchestrator-api-handoff-2026-08-19.md) | 2026-08-19 | API changes |
| [`handoff-dealer-api-orchestrator-env-contract.md`](./handoff-dealer-api-orchestrator-env-contract.md) | ongoing | **Outbound** — our open questions to them, and the env values we owe each other. The one file here we DO write in |
| [`handoff-tenant-orchestrator-jwt-access.md`](./handoff-tenant-orchestrator-jwt-access.md) | — | ES256 service-identity registration and JWT minting |
| [`sudu-tenant-orchestrator-api-handoff-2026-08-06.md`](./sudu-tenant-orchestrator-api-handoff-2026-08-06.md) | 2026-08-06 | The original API map |

## The restore API has no handoff document, and both 2026-09-07 documents deny it exists

`POST /v1/tenants/{bladex_tenant_id}/restore` — the reverse of a recycle — landed on their
`main` on **2026-09-17** in `150e101`, "feat(unsuspended): add api for reverse suspended
customers", merged as their PR #54. **No dated handoff was sent for it**, and the two documents
above predate it and say so in as many words: the field reference's opening note reads "No
unsuspend endpoint", and the dealer handoff's §8 says recycle "does not ... offer a
restore/unsuspend operation".

**Do not read that as the current contract.** It was true on 2026-09-07 and is not true now.
Until a dated document arrives, what describes the route is their `README.md`, their
`src/docs/openapi.ts` and the Postman collection, all on their `main` — read them from the
checkout, and treat anything sourced to them as provisional in the way
[the root `CLAUDE.md`](../../CLAUDE.md) means it: their contracts are the authority, their
source is a debugging aid.

**Asking for the document is the fix**, and the ask belongs in
[`handoff-dealer-api-orchestrator-env-contract.md`](./handoff-dealer-api-orchestrator-env-contract.md)
with the two operational questions it has to answer — whether `tenant:restore` is granted on our
registered `ServiceIdentity`, and whether the `20260917120000_add_restore_tenant_job_type`
migration is applied on the environment we call. A route we hold no contract for is not a route
we can ship against.

A later document supersedes an earlier one **only for the fields it names**. The 2026-08-24
handoff adds `profile_key` and says "keep all other existing request fields unchanged" — so
2026-08-20 is still the authority on everything else in that same request body. Read them as
a stack, not as replacements.
