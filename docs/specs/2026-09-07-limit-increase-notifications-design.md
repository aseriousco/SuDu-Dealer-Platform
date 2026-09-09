# Limit-increase requests get an in-app notification

**Item 2.** Cross-repo: `sudu-dealer-api` and `sudu-dealer-web`.

> **Rewritten 2026-09-08.** A first pass shipped to the branches
> (`feat/limit-increase-notifications` in both repos, unmerged) against the original D3–D5
> below. Five rounds of UI prototyping on `proto/notification-popover` then changed the
> shape of the thing, and three of the original decisions are now wrong rather than merely
> incomplete. They are kept, struck through, with what replaced them — **a plan that
> implements this spec has to DELETE working code, and it will not know that from a spec
> that quietly forgot its own history.** Nothing has merged, so the removals are amendments
> to unmerged branches, not migrations against production.

## The request

> "when the dealer click the request higher limit, it will send email to the email in partner
> interest, now i want to add for the notification, when the user that in the partner interest, it
> will have the notification on the top right, and when click it will redirect to increase higher
> limit page"

Then, after the first pass was demonstrated:

> "you should have a notification pop up instead of direct to the page, when user click on one of
> the raise limit, then only direct to the dealer plan & limit, in the notification pop up, you
> should have the read all, clear all"

and across the prototype rounds: group by dealer; a labelled top-right button in place of the
bell, then icon-only to match tenant provisioning; the latest sender and an exact-but-short
timestamp; drop "mark all read"; drop a dealer whose limit has already been raised; and rework
the all-requests page into a per-dealer roll-up with an Outstanding / Resolved filter.

An **additional channel for an event that already exists**. The email keeps working exactly as it
does.

## Item 2 was largely built before this spec

The backlog entry (raised 2026-08-27) records two unsettled readings — a dealer *requesting* a
higher limit, versus *notifying* someone about a limit. **The first shipped**, in
[api#25](https://github.com/aseriousco/sudu-dealer-api/pull/25), for the demo-tenant cap:

- [`DemoSlots.tsx`](../../sudu-dealer-web/src/components/tenants/DemoSlots.tsx) shows "N of M demo
  slots used" and a **"Request a higher limit"** button.
- [`limit-increase.service.ts`](../../sudu-dealer-api/src/dealer-client/limit-increase.service.ts)
  emails the partner-interest recipients behind a **24-hour cooldown**, and its docblock settles a
  design question this spec must not reopen:

  > "No table and no approval queue by decision: raising a limit is a conversation, and the tier and
  > override screens already exist for actually doing it."

The cooldown reads `audit_log` rather than inventing storage, and counts only `outcome: 'success'`
rows so a dealer retrying inside the window cannot push their own window out.

**This spec is the second reading, scoped to that one event.** It is not a general notification
system, and it does not add a limit-increase table.

## What exists today

Verified against the code on 2026-09-08. "branch" means present on
`feat/limit-increase-notifications`, unmerged.

| piece | state |
|---|---|
| the request itself | shipped to `main` — button, email, 24h cooldown |
| the record of a request | **one `audit_log` row**: `action = 'dealer_client.limit_increase_requested'`, carrying `organizationId`, `actorUserId`, `actorLabel`, `outcome`, `occurredAt`, and a `metadata Json?` column that this request does not yet use |
| the record of a limit being raised | **one `audit_log` row**: `action = 'organization.update_limits'`, written by `@Audit` on `organization.controller.ts:81` and enriched post-call by `AuditContext.set` with the DTO |
| notification recipients | `PartnerInterestSettings.notifyEmails` — **`string[]`, bare addresses, not user accounts** |
| eligibility + list endpoint | branch — `limit-increase-notifications.service.ts`, `GET /notifications/limit-increase` |
| `notificationsSeenAt` + `POST /notifications/seen` | branch — **to be removed, see D3** |
| the bell | branch — a real `Link` to `/admin/limit-increases` with an unread badge. **To be removed, see D4** |
| the all-requests page | branch — a flat table, one row per ask. **To be reworked, see D11** |
| where a limit is actually raised | `OrganizationLimitsDrawer`, opened from `/organizations` |
| who may raise one | `isPlatformAdmin(actor)` — a hard check in `organization.service.ts:696`, not a permission. "Dealer limits are set by SuDu AI only" |

## Principles

1. **Add a channel, do not rebuild the feature.** The email path, the cooldown and the audit row
   stay exactly as they are. Everything here reads what already happens.
2. **Never notify someone about something they cannot open.** A count computed from one rule and an
   authorization check applied from another produces a bell that leads to a `403`.
3. **A trade-off that was chosen must be visible, not silent.** See D2.
4. **The popup is the queue; the page is the record.** Anything the popup drops on purpose has to
   be findable somewhere, or the feature has quietly lost data the operator needed. This is what
   forces D11.

## Decisions

### D1 — The `audit_log` row is the source; no new request table

*(Unchanged.)*

A successful request already writes exactly the row a notification list needs. The list is
`audit_log` filtered to `action = LIMIT_INCREASE_ACTION` and `outcome = 'success'`, newest first,
joined to the organization for its name.

`LIMIT_INCREASE_ACTION` is already exported from `limit-increase.service.ts` for precisely this
reason — its own comment says the constant exists so the audited name and the cooldown's read
"never drift". This adds a third reader of the same constant; **do not restate the string.**

Adding a `LimitIncreaseRequest` table would contradict the shipped decision quoted above and would
duplicate a row the system already writes.

### D2 — Recipients are users whose email is in `notifyEmails`, **and** who may act

*(Unchanged, and already built on the branch.)*

`notifyEmails` is a list of addresses. An address is not a user: it can be `leads@sudu.ai`, an alias
with no account. So eligibility is the **intersection** of two things:

```
notified = users whose email ∈ notifyEmails  ∩  users for whom isPlatformAdmin(actor) is true
```

**Both halves are load-bearing.** The email match alone would give a bell to anyone whose address
happened to be in the list — including a dealer, or vendor **staff**, who is on the platform plane
but is not `ADMIN` — who would then click through to a `403`. Principle 2.

**The consequence must be visible.** An entry in `notifyEmails` that matches no user account, or
matches a non-platform-admin, gets **email but no in-app notification**, and nothing on screen
would say so. So `/settings/partner-interest` carries a per-entry indicator: this address reaches a
user who will also see it in-app, or it is email-only.

**This is a knowingly accepted trade-off, not an oversight.**
[`partner-interest-settings.service.ts:23`](../../sudu-dealer-api/src/partner-interest/partner-interest-settings.service.ts)
says:

> "Rename or split the setting before adding a third consumer."

This **is** the third consumer, and the list is deliberately still shared. The alternative — a
separate recipient setting that picks users rather than addresses — was considered and not taken.
It stays the right fix if the alias gap ever bites; the indicator above is what makes it visible
when it does.

### ~~D3 — Unread is one "seen up to" timestamp per user~~ — RETIRED

> ~~Add `notificationsSeenAt` to the user. Unread is the count of qualifying rows with
> `occurredAt > notificationsSeenAt`.~~

**"Mark all read" was cut from the popup, and read state went with it.** Once the only actions are
*act on it* or *clear it*, there is no third state for "seen but still here" to describe. A count
of things you have looked at and not dealt with is not a useful number, and maintaining it costs a
column, an endpoint, and a write on every page view.

**What replaces it:** the badge counts **outstanding asks** — every ask belonging to a dealer who
is neither resolved (D9) nor dismissed (D10). It is derived, not stored.

**What must be removed from the branch.** This is the part a plan cannot infer:

- `notificationsSeenAt` from `auth.ts`'s `user.additionalFields`
- the same field from `prisma/schema.prisma`
- the migration `20260907063241_user_notifications_seen_at/`
- `POST /notifications/seen`, its controller method, service method and tests
- `unreadCount` from the list response
- `markSeen` from `use-limit-increase-notifications.ts`, and the `markSeen()` effect in the
  all-requests view

Because the branch is **unmerged and this column exists in no deployed database**, remove it by
deleting the migration directory and re-running `prisma migrate dev`, not by layering an
add-then-drop pair. Shipping a column's birth and death in one merge is noise in the migration
history for no gain. Any developer who ran the branch resets their local database; nobody else is
affected.

### ~~D4 — The dot becomes real, or it is not drawn~~ — SUPERSEDED by the button

> ~~The bell renders an unread count when there is one and nothing when there is not.~~

The bell is **gone**, not fixed. It was replaced first by a labelled "Limit requests" pill and then,
on review, by an **icon-only button modelled on `ProvisioningMenu`** — same `p-2`, same
`rounded-xl`, same corner badge, same trick of moving the words into the accessible name.

The reason is that the two sit side by side in the top bar and are the same kind of thing: an
ambient status signal a vendor admin scans rather than navigates to. A labelled pill beside a bare
glyph read as two different *kinds* of control. Its accessible name follows
`ProvisioningMenu.EMPTY_LABEL`'s pattern — a real sentence, and a separate one for the empty case,
because "0 asks" is a claim about nothing rather than an empty state.

The original decision's substance survives: **a viewer who is not an eligible recipient gets no
button at all** — not a button that is always empty — and the badge is drawn only above zero.

### ~~D5 — The destination is a list that links into the drawer that already exists~~ — SUPERSEDED by the popup

> ~~Clicking the bell goes to a page listing limit-increase requests.~~

One click too many. The button opens a **popup**; a dealer's "Raise their limit" in that popup goes
straight to `/organizations?limits=<id>`, which opens the existing `OrganizationLimitsDrawer`.

**No second editing surface**, exactly as before — the popup's job is "who asked, and when"; the
drawer's job is the change itself, and it already validates tier, overrides, reason and expiry.

The popup carries a "View all requests" link to the page (D11), and **closes itself on arrival
there**: it is a shortcut *to* that page, and a panel hovering over the list you just asked for
hides the thing you came for.

### D6 — Nothing here changes what the dealer sees

*(Unchanged.)*

`DemoSlots`, the button, the cooldown copy and the email are untouched. A dealer cannot tell whether
this shipped. The one exception is the settings screen (D2), which only a platform admin opens.

### D7 — The dealer is the unit, not the ask

Five asks from one dealer are **one decision**, not five rows. Raising that dealer's limit answers
all five at once, so the popup groups by organization: one card per dealer, carrying the count, the
**latest** requester and the **latest** timestamp, with the individual asks behind a disclosure.

This was tested against the real data — one dealer, five asks over three weeks — and against three
listing shapes. Grouping won on the first round and was never seriously contested afterwards.

The disclosure shows **only the asks**: a bare timeline of timestamps, no repeated requester name.
In practice the same person asks every time, and repeating "jojo" five times down the expansion
said nothing five times.

### D8 — Timestamps name the day, then the time, and never the year

`today, 03:25 PM` · `yesterday, 04:06 PM` · `Sep 2, 05:57 PM`.

A named day is read faster than a date for the two days that matter most, and the oldest thing in
this queue is weeks old, so the year was spending a third of the string on characters nobody read.
This format is used in the popup, in the disclosure, and on the page — one function, one place.

### D9 — "Already raised" means the cap is higher than it was when they asked

**This is the one part of the design that today's API cannot answer, and it is the reason the API
work must land before the web work.**

The rule the operator asked for is *"if the dealer limit already increase, then auto remove"*.
Stating it precisely: a dealer's asks are resolved when their **effective `maxDemoTenants` is
strictly greater than it was at the moment of their most recent ask.**

Nothing currently records the second half of that comparison, and it cannot be reconstructed. A
dealer's effective cap can rise three different ways:

1. an **override** set on the organization (`limits.overrides.maxDemoTenants`),
2. the organization **moved to a different tier**,
3. the **tier's own** `maxDemoTenants` edited, which lifts every organization on that tier without
   touching any of them.

**So: record the cap at ask time.** `LimitIncreaseService.request` resolves the dealer's effective
limits already in order to send the email; it additionally writes that number onto the audit row it
is about to cause, via `AuditContext.set({ metadata: { maxDemoTenantsAtRequest } })`. `audit_log`
already has a `metadata Json?` column and `AuditContext` already merges metadata patches, so this
costs no schema change.

Resolution is then one comparison against the organization's live effective cap, and it is correct
for all three paths above.

**Rows written before this change have no `maxDemoTenantsAtRequest` and are treated as
outstanding.** History cannot be recovered, and this is the safe direction to fail: showing a dealer
you have already helped costs a glance, whereas hiding one you have not costs them the wait. On
this machine that means the five existing JOJO ORG 1 rows all stay outstanding until the dealer asks
again — which is correct, since their cap is 5 and they have asked five times.

**Alternative considered and rejected:** treat a later `organization.update_limits` audit row for
that organization as the resolution signal. It needs no new data at all, which is genuinely
attractive — but it counts a save that *lowered* the cap, or changed only the expiry note, as an
answer, and it misses paths 2 and 3 entirely. A queue that clears itself on the wrong signal is
worse than one that does not clear itself.

**The popup does not say a dealer was auto-removed.** An earlier round showed a footer line
accounting for them; it was cut. The cost is real and is accepted here: a dealer can vanish between
two glances with nothing on screen explaining why. **D11 is what pays that cost back** — the page's
`Resolved` filter is the only remaining record that anyone acted, which is why the page is part of
this increment and not a follow-up.

### D10 — Clearing is per user, per dealer, and a new ask brings the dealer back

"Clear all" was asked for; per-dealer "Clear" was added during prototyping and kept, because a queue
whose only clearing action is *all of it* is a worse queue — the case it exists for is a dealer you
have decided not to raise, and clearing the rest along with them is not a way to say that.

Both need storage, and it is genuinely new state rather than a duplicate of an event, so unlike D1
this does earn a table:

```prisma
model NotificationDismissal {
  id             String   @id @default(uuid())
  userId         String   @map("user_id")
  organizationId String   @map("organization_id")
  dismissedAt    DateTime @default(now()) @map("dismissed_at")

  @@unique([userId, organizationId])
  @@index([userId])
  @@map("notification_dismissal")
}
```

A dealer is hidden while `dismissedAt >= their latest ask`, so **a new ask after the dismissal
brings them back**. Clear-all is one upsert per currently-visible dealer, bounded by the number of
dealers with outstanding asks.

**Dismissal is per user, and the consequence is that this is not a shared worklist.** If one admin
clears a dealer, another still sees them. That is right for a notification — it is *your* view of
what needs your attention — and the risk it appears to create, two admins both raising the same
limit, is what D9 actually removes: the moment one of them raises it, it resolves for everyone.

This table is plain application state and is deliberately **not** in `audit_log`. Dismissing a
notification is not a domain event.

### D11 — The all-requests page is the record: a per-dealer roll-up with a status filter

The popup drops things on purpose — resolved dealers (D9), dismissed dealers (D10) — so Principle 4
requires somewhere they remain visible. That is this page, and it is why the page is in scope.

- **One row per dealer**, matching the popup's unit: name, latest requester beneath it, ask count,
  latest ask, **current cap and tier**, status, action.
- **The cap column is the point.** "Asked 5×, still on 5" is the whole judgement in one row, and it
  is the number neither the popup nor the old flat table could show.
- **Filter pills: Outstanding / Resolved / All**, counting **dealers**, because the rows are
  dealers. A pill counting asks above a list of dealers is a mismatch nobody notices and everybody
  misreads.
- Clicking a dealer expands the same ask timeline the popup uses.
- The row action is the same journey as the popup's: `/organizations?limits=<id>`.
- A resolved row's action cell is **empty**, not a dash. A dash claims a value is missing; there is
  no action because none is needed.

**It reports; it does not edit.** No approval queue — explicitly rejected by the shipped design.

### D12 — The page and the popup follow `OrganizationsTable`, not their own idiom

The page's one action navigates into `OrganizationsTable`'s "Dealer plan & limits" drawer, so the
two tables are read a click apart and any divergence is felt. The page therefore borrows that
table's chrome verbatim: an **11px uppercase `0.06em`-tracked header against 13px data**, a 12px
secondary line, 11px badges, `align-middle` cells, and row actions as `size="sm" variant="outline"`
buttons carrying the same `SlidersHorizontal` glyph.

Two details worth keeping when this is rewritten for production:

- The header/data gap must be **11 vs 13**, not 12 vs 13. At one pixel the eye cannot find the
  difference and the header reads as more data.
- The row action stays an **anchor** styled with `buttonVariants`, not a `Button`. It navigates, so
  middle-click and open-in-new-tab have to keep working.

## The FE↔BE contract

Recorded in [`docs/contracts/notifications.md`](../contracts/notifications.md), rewritten with this
spec.

| method + path | returns |
|---|---|
| `GET /notifications/limit-increase` | dealers with outstanding asks and dealers already resolved, each with their asks, ask count, latest requester, latest timestamp, current cap and tier |
| `POST /notifications/dismissals` | dismiss one organization for the calling user |
| `POST /notifications/dismissals/all` | dismiss every currently-outstanding organization for the calling user |
| ~~`POST /notifications/seen`~~ | **removed** — D3 |

`organizationId` is a **string** on both sides, as every contract in this repo requires. Timestamps
are ISO-8601 strings in HTTP bodies, never `Date`.

A caller who is not an eligible recipient gets `403` from all of them — **not** an empty list, which
would imply "nothing to see" rather than "not yours".

**Grouping happens server-side.** The client receives dealers, not a flat list it has to fold. The
resolution rule (D9) needs the cap at ask time and the live effective cap, and only the API holds
both; splitting the fold across the boundary would put half the rule in each repo.

## Testing

- **The intersection in D2 is still the test that matters most.** A user whose email is in the list
  but who is not a platform admin must get no button and a `403` — one case, both halves. This test
  exists on the branch and must survive the rewrite.
- **D9 needs a test per path**: an override raise, a tier move, and a tier-catalog edit must each
  resolve the dealer. A test that only covers the override would pass against the rejected
  alternative and prove nothing.
- **D9 needs its fail-open test**: an ask with no `maxDemoTenantsAtRequest` in metadata stays
  outstanding, and does not throw.
- **D10 needs the return path**: dismiss a dealer, record a newer ask, and the dealer reappears.
  Dismissal must also be per user — a second recipient still sees the dealer.
- The cooldown means at most one request per organization per 24h; a test should pin that the list
  does not de-duplicate beyond what the cooldown already guarantees, rather than inventing its own.
- **The web needs a test that the button is absent when the caller is not a recipient**, and that
  the badge is absent at zero. The original bug was a dot that was always drawn, and nothing failed.
- Both repos' suites are large; a plan quoting a baseline must measure it on the branch rather than
  carry a number from another document. `tsc --noEmit` is a false-green in the web repo — the gate
  is `npm run build`.

## Non-goals

- **A general notification system.** One event type. A second kind is a real design question — what
  the button does when kinds disagree about their destination — and it is not answered here.
- **An approval queue.** Explicitly rejected by the shipped design; the page reports, it does not
  decide.
- **A limit-increase table.** D1.
- **Splitting `notifyEmails`.** D2 records the warning and the accepted trade-off.
- **Per-ask dismissal.** D10 dismisses a dealer, not one of their asks. Grouping (D7) makes the ask
  the wrong unit for every other action too.
- **A shared worklist.** D10 is per user by decision.
- **Extending the request button to headroom.** The wallet's headroom limit has no request path at
  all, and it is the limit that actually blocks a purchase (`wallet.service.ts:178`,
  `balance + headroom >= subtotal`). That is a separate item, and a better-founded one than this
  spec's scope — it is noted here so it is not lost.
