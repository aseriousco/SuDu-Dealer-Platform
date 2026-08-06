# Glossary — SuDu Dealer Platform

Shared vocabulary for both repos. Terms here mean the same thing on the frontend and the
backend; where they don't, that's a bug worth reporting.

**This file defines terms. It does not own rules.** Each invariant below is stated once,
in the repo that enforces it, and linked from here. If this file and a repo's `CLAUDE.md`
ever disagree, **the repo wins** — and the drift should be fixed here.

Canonical sources: [`sudu-dealer-api/CLAUDE.md`](../sudu-dealer-api/CLAUDE.md) ·
[`sudu-dealer-web/CLAUDE.md`](../sudu-dealer-web/CLAUDE.md)

---

## The three planes

The platform's central structure. Almost every authorization question resolves to
"which plane is the actor on?"

**platform** — the vendor (SuDu AI). A cross-org view of everything.
As of the role-model change on 2026-07-24 this is **membership of the default (SuDu AI)
organization holding its ADMIN role** — *not* the absence of membership. Surfaces in the
web app under `/admin/*`.

**org** — a dealer company. An external reseller. Owns its own members and its own role
tree. Surfaces in the web app at `/`.

**client** — a BladeX tenant. **Referenced, never owned.** The tenant record lives in
BladeX; this platform stores only the mapping (`dealer_client`).

## Identity and authorization

**`organization_role`** — a role, as a **database row**, not a compile-time constant.
Arranged in a per-org tree via `parentRoleId`. Roles are created and renamed at runtime,
which is why no authorization decision may key off a role's *name*.

**`roleKind`** — `'ADMIN'` or `'CUSTOM'`. The thing authorization branches on.
`roleKind === 'ADMIN'` is what grants org-wide visibility.

**permission vs. position** — a role's `permission` JSON is *what you may do*; the role's
position in the tree is *whose data you see*. Two different questions, two different
mechanisms. A child role's permissions must be a subset of its parent's.

**`resolveVisibleScope()`** — the single authorization rule. Every query touching
`dealer_client` or `sale_event` goes through it; it walks the role subtree → members →
their `member_node`s. Ad-hoc `where` clauses are how one dealer reads another's data.

**`member_node`** — an **attribution anchor only**: who owns or sold a client. Since
2026-07-24 it is *not* the visibility hierarchy. Easy to misread as the old meaning.

**`getOwnedOrThrow()`** — an ownership check treated as a security control, not a
convenience. The gateway trusts this service's assertion because the mapping exists only
here.

**`mustResetPassword`** — a server-controlled hygiene nudge, **not an auth boundary**.
The API authenticates a flagged user normally; enforcement of the forced reset is
**frontend-only**.

## External systems

**BladeX** (`su-code-ai-boot`) — the upstream product, owned by the China Team. A
**Strict Black Box**: not modified, and dealers are not modelled inside it. Owns tenants.

**`sudu-chat-gateway`** — the sole writer of `billing.*`. The dealer API never writes
AI-token or billing data directly; it calls the gateway with a service credential.

**The three secrets** — dealer session secret, gateway service credential, and BladeX's
key are **three separate things** that never mix. Dealer sessions are an independent
issuer.

## Data types that bite

**`tenantId` is always a string.** Both sides, always. BladeX tenant ids exceed
`Number.MAX_SAFE_INTEGER` (~9×10¹⁵), so parsing one to a number corrupts it **silently
and irreversibly**. Never `parseInt`, never a `number` field, never arithmetic.

**Money is a `Decimal`, carried as a string.** `sale_event.amount` is `Decimal(18,4)`.
Never a JS `number`. Format for display; never render a `parseFloat` result as
authoritative.

**`sale_event` is append-only.** Never updated, never deleted. Attribution cannot be
reconstructed after the fact — which is why the ledger exists before the commission
engine does.

## Frontend terms

**dealer surface vs. vendor surface** — `/` and `/admin/*` are **one app** sharing
components, serving two audiences. Neither fork a component "for admin" when a prop will
do, nor leak vendor-only affordances into the dealer surface.

**`VITE_*`** — build-time values **compiled into the public bundle**. Not secret,
whatever they're named. Also invisible at runtime when wrong: a build once shipped
pointing at a dev gateway.

---

## Known gap

Both repos cite a foundation spec at
`sudu-docs/docs/superpowers/specs/2026-07-16-dealer-platform-foundation-design.md`.
**That path does not exist on this machine**, and there is no `sudu-docs` checkout under
`~/SUMES`. Definitions above are drawn from the two repos' `CLAUDE.md` files instead.

If the foundation spec surfaces, put it in [`specs/`](./specs/) and repoint both repos'
references at it.
