# Limit-increase requests get an in-app notification

**Item 2.** Cross-repo: `sudu-dealer-api` and `sudu-dealer-web`.

## The request

> "when the dealer click the request higher limit, it will send email to the email in partner
> interest, now i want to add for the notification, when the user that in the partner interest, it
> will have the notification on the top right, and when click it will redirect to increase higher
> limit page"

An **additional channel for an event that already exists**. The email keeps working exactly as it
does; this adds a bell.

## Item 2 was largely built before this spec

The backlog entry (raised 2026-08-27) records two unsettled readings — a dealer *requesting* a
higher limit, versus *notifying* someone about a limit. **The first shipped**, in
[api#25](https://github.com/aseriousco/sudu-dealer-api/pull/25), for the demo-tenant cap:

- [`DemoSlots.tsx`](../sudu-dealer-web/src/components/tenants/DemoSlots.tsx) shows "N of M demo
  slots used" and a **"Request a higher limit"** button.
- [`limit-increase.service.ts`](../sudu-dealer-api/src/dealer-client/limit-increase.service.ts)
  emails the partner-interest recipients behind a **24-hour cooldown**, and its docblock settles a
  design question this spec must not reopen:

  > "No table and no approval queue by decision: raising a limit is a conversation, and the tier and
  > override screens already exist for actually doing it."

The cooldown reads `audit_log` rather than inventing storage, and counts only `outcome: 'success'`
rows so a dealer retrying inside the window cannot push their own window out.

**This spec is the second reading, scoped to that one event.** It is not a general notification
system, and it does not add a limit-increase table.

## What exists today

Verified against the code on 2026-09-04.

| piece | state |
|---|---|
| the request itself | shipped — button, email, 24h cooldown |
| the record of a request | **one `audit_log` row**: `action = 'dealer_client.limit_increase_requested'`, carrying `organizationId`, `actorUserId`, `actorLabel`, `outcome`, `occurredAt` |
| notification recipients | `PartnerInterestSettings.notifyEmails` — **`string[]`, bare addresses, not user accounts** |
| a bell in the UI | **present and inert** — see below |
| a notification model | **none**. No table, no `readAt`, nothing in `schema.prisma` |
| a page to land on | **none** |
| where a limit is actually raised | `OrganizationLimitsDrawer`, opened from `/organizations` |
| who may raise one | `isPlatformAdmin(actor)` — a hard check in `organization.service.ts:696`, not a permission. "Dealer limits are set by SuDu AI only" |

### The bell already exists, and it is lying

[`TopBar.tsx:67`](../sudu-dealer-web/src/components/layout/TopBar.tsx) renders a
`<button aria-label="Notifications">` with **no `onClick`**, and an unconditional dot:

```tsx
<span className="absolute top-1.5 right-1.5 size-1.5 rounded-full bg-primary" />
```

Every user has been shown a permanent "you have something waiting" indicator for notifications that
do not exist. **Fixing that is part of this work, not a side effect** — after this, the dot means
something or it is not drawn.

## Principles

1. **Add a channel, do not rebuild the feature.** The email path, the cooldown and the audit row
   stay exactly as they are. Everything here reads what already happens.
2. **Never notify someone about something they cannot open.** A count computed from one rule and an
   authorization check applied from another produces a bell that leads to a `403`.
3. **A trade-off that was chosen must be visible, not silent.** See D2.

## Decisions

### D1 — The `audit_log` row is the source; no new request table

A successful request already writes exactly the row a notification list needs. The list is
`audit_log` filtered to `action = LIMIT_INCREASE_ACTION` and `outcome = 'success'`, newest first,
joined to the organization for its name.

`LIMIT_INCREASE_ACTION` is already exported from `limit-increase.service.ts` for precisely this
reason — its own comment says the constant exists so the audited name and the cooldown's read
"never drift". This adds a third reader of the same constant; **do not restate the string.**

Adding a `LimitIncreaseRequest` table would contradict the shipped decision quoted above and would
duplicate a row the system already writes.

### D2 — Recipients are users whose email is in `notifyEmails`, **and** who may act

`notifyEmails` is a list of addresses. An address is not a user: it can be `leads@sudu.ai`, an alias
with no account. So eligibility is the **intersection** of two things:

```
notified = users whose email ∈ notifyEmails  ∩  users for whom isPlatformAdmin(actor) is true
```

**Both halves are load-bearing.** The email match alone would give a bell to anyone whose address
happened to be in the list — including a dealer — who would then click through to a `403`, because
raising a limit is platform-admin-only. Principle 2.

**The consequence must be visible.** An entry in `notifyEmails` that matches no user account, or
matches a non-platform-admin, gets **email but no bell**, and nothing on screen would say so today.
So `/settings/partner-interest` gains a per-entry indicator: this address reaches a user who will
also see it in-app, or it is email-only. Without that, the setting quietly means two different
things depending on each entry.

**This is a knowingly accepted trade-off, not an oversight.**
[`partner-interest-settings.service.ts:23`](../sudu-dealer-api/src/partner-interest/partner-interest-settings.service.ts)
says:

> "Rename or split the setting before adding a third consumer."

This **is** the third consumer, and the list is deliberately still shared. The alternative — a
separate recipient setting that picks users rather than addresses — was considered and not taken.
It stays the right fix if the alias gap ever bites; the indicator above is what makes it visible
when it does.

### D3 — Unread is one "seen up to" timestamp per user

`audit_log` has no read state and must not grow one — it is an audit trail, not application state.

Add **`notificationsSeenAt`** to the user. Unread is the count of qualifying rows with
`occurredAt > notificationsSeenAt`; a null means everything is unread. Opening the page sets it to
now.

**It cannot mark one item read and leave another unread.** That is the whole cost, and it buys: no
migration for a fan-out table, no row per recipient per event, no retention policy, and nothing to
backfill. A bell whose only action is "open the page" does not need per-item state.

**Implementation constraint that will bite otherwise:** custom columns on `user` are declared in
`auth.ts`'s `user.additionalFields` (`phoneNumber`, `notes`, `mustResetPassword` are all there), and
`npm run auth:generate` regenerates `prisma/schema.prisma` from that file. **A column added only to
`schema.prisma` is wiped by the next `auth:generate`.** It must also carry `input: false`, as
`mustResetPassword` does — it is server-controlled and no client may set it.

**Unverified, and the plan must check it first:** whether `additionalFields` accepts a date type in
better-auth 1.6.23. `'string'` and `'boolean'` are proven in this codebase; a date type is not.
**Fallback if it does not:** store an ISO-8601 string. The comparison stays correct because ISO-8601
sorts lexicographically, and the API is the only reader.

### D4 — The dot becomes real, or it is not drawn

The bell renders an unread count when there is one and nothing when there is not. The current
unconditional dot is removed either way. A viewer who is not an eligible recipient (D2) gets **no
bell at all** — not a bell that is always empty.

### D5 — The destination is a list that links into the drawer that already exists

Clicking the bell goes to a page listing limit-increase requests: which dealer, who asked, when.
Each row links to that organization's **existing** `OrganizationLimitsDrawer` on `/organizations` —
the place a limit is actually raised.

**No second editing surface.** The page's job is "who asked, and when"; the drawer's job is the
change itself, and it already validates tier, overrides, reason and expiry.

The page is gated by the same `isPlatformAdmin` check as `updateLimits`, so its authorization and
the action it leads to cannot disagree.

### D6 — Nothing here changes what the dealer sees

`DemoSlots`, the button, the cooldown copy and the email are untouched. A dealer cannot tell whether
this shipped. The one exception is the settings screen (D2), which only a platform admin opens.

## The FE↔BE contract

Two endpoints, both platform-admin only, recorded in
[`docs/contracts/`](./contracts/) as part of the implementation:

| method + path | returns |
|---|---|
| `GET /notifications/limit-increase` | the requests, newest first, plus `unreadCount`, derived per D1/D2/D3 |
| `POST /notifications/seen` | sets the caller's `notificationsSeenAt`; returns the new value |

`organizationId` is a **string** on both sides, as every contract in this repo requires. Timestamps
are ISO-8601 strings in HTTP bodies, never `Date`.

A caller who is not an eligible recipient gets `403` from both — **not** an empty list, which would
imply "nothing to see" rather than "not yours".

## Testing

- **The intersection in D2 is the test that matters most.** A user whose email is in the list but
  who is not a platform admin must get no bell and a `403` — one case, both halves.
- An address in `notifyEmails` matching no user must still receive **email**, and must be reported
  as email-only on the settings screen.
- The cooldown means at most one request per organization per 24h; a test should pin that the list
  does not de-duplicate beyond what the cooldown already guarantees, rather than inventing its own.
- **`TopBar` needs a test that the dot is absent when the count is zero.** The bug being fixed is
  precisely a dot that was always drawn, and nothing failed.
- Both repos' suites are large; a plan quoting a baseline must measure it on the branch rather than
  carry a number from another document.

## Non-goals

- **A general notification system.** One event type. A second kind is a real design question — what
  the bell does when kinds disagree about their destination — and it is not answered here.
- **An approval queue.** Explicitly rejected by the shipped design; the page reports, it does not
  decide.
- **A limit-increase table.** D1.
- **Splitting `notifyEmails`.** D2 records the warning and the accepted trade-off.
- **Extending the request button to headroom.** The wallet's headroom limit has no request path at
  all, and it is the limit that actually blocks a purchase (`wallet.service.ts:178`,
  `balance + headroom >= subtotal`). That is a separate item, and a better-founded one than this
  spec's scope — it is noted here so it is not lost.
- **Per-item read state**, marking one notification read while leaving another unread. D3.
