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
| [`dealer-platform-production-profile-key-handoff-2026-08-24.md`](./dealer-platform-production-profile-key-handoff-2026-08-24.md) | 2026-08-24 | Top-level `profile_key` on tenant creation. Without it the orchestrator resolves `dev_default` |
| [`dealer-platform-handoff-2026-08-20.md`](./dealer-platform-handoff-2026-08-20.md) | 2026-08-20 | `customer_domain` and `plan.plan_id` required with no fallback; optional `tenant_admin` block |
| [`sudu-tenant-orchestrator-api-handoff-2026-08-19.md`](./sudu-tenant-orchestrator-api-handoff-2026-08-19.md) | 2026-08-19 | API changes |
| [`handoff-dealer-api-orchestrator-env-contract.md`](./handoff-dealer-api-orchestrator-env-contract.md) | ongoing | **Outbound** — our open questions to them, and the env values we owe each other. The one file here we DO write in |
| [`handoff-tenant-orchestrator-jwt-access.md`](./handoff-tenant-orchestrator-jwt-access.md) | — | ES256 service-identity registration and JWT minting |
| [`sudu-tenant-orchestrator-api-handoff-2026-08-06.md`](./sudu-tenant-orchestrator-api-handoff-2026-08-06.md) | 2026-08-06 | The original API map |

A later document supersedes an earlier one **only for the fields it names**. The 2026-08-24
handoff adds `profile_key` and says "keep all other existing request fields unchanged" — so
2026-08-20 is still the authority on everything else in that same request body. Read them as
a stack, not as replacements.
