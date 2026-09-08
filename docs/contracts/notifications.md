# Contract — notifications

The in-app notification surface: the vendor's view of dealer limit-increase requests, and the
per-user record of which of them have been cleared.

Written from the limit-increase notifications change
([spec](../specs/2026-09-07-limit-increase-notifications-design.md)), so it covers **those
endpoints only**. There is no general notification feed — this area is named `notifications`
because it is where one will grow, not because one exists. Extend it the next time the area
changes rather than reverse-engineering the rest in bulk (see [`README.md`](./README.md)).

Authorization is the API's decision alone; nothing here implies the web app enforces anything.

> **Rewritten 2026-09-08** alongside the spec. `POST /notifications/seen` and the `unreadCount`
> field are **gone**, not deprecated: read state was removed from the design when "mark all read"
> was cut from the popup (spec D3). The list also now returns **dealers**, not a flat list of asks.
> Neither shape reached `main`, so there is no compatibility window to honour.

## Who may call these

**Platform plane, and only an eligible recipient within it.** Eligibility is two conditions at
once:

> The caller's email is in the partner-interest `notifyEmails` list **and** the caller is a
> platform **admin**.

The list holds bare addresses and is a delivery setting, not a grant of authority. The match alone
would notify someone who cannot act: raising a limit is platform-admin only, so a dealer — or
vendor **staff**, whose role is on the platform plane but is not `ADMIN` — would be shown a count
leading straight to a `403`.

**A caller who is not an eligible recipient gets `403`, not an empty list.** Empty would read as
"nothing has been requested"; the web uses this endpoint to decide whether to draw the top-bar
button at all.

Which addresses satisfy both halves is visible on the settings screen: see `notifyRecipients` in
[Related](#related) below.

## `GET /api/notifications/limit-increase`

Every dealer with at least one successful limit-increase request, newest ask first.

```json
{
  "dealers": [
    {
      "organizationId": "88574f89-0c88-4b32-87d8-a2214561e10c",
      "organizationName": "JOJO ORG 1",
      "status": "outstanding",
      "dismissedAt": null,
      "askCount": 5,
      "latestRequestedByLabel": "jojo",
      "latestOccurredAt": "2026-09-07T07:25:26.650Z",
      "maxDemoTenants": 5,
      "tierName": "Testing 1 acc",
      "asks": [
        {
          "id": "7db1a84c-ba2b-4dee-a86b-5a6f0e093d60",
          "requestedByLabel": "jojo",
          "occurredAt": "2026-09-07T07:25:26.650Z"
        }
      ]
    }
  ],
  "outstandingAskCount": 5
}
```

### The grouping is the API's job, not the client's

The client receives dealers, never a flat list it has to fold. `status` depends on the dealer's cap
**at ask time** and their **live effective cap**, and only the API holds both; folding in the client
would put half of one rule in each repo.

### Field by field

- `dealers` is ordered by `latestOccurredAt`, newest first. Capped at the 50 most recent **asks**
  before grouping — a recent-activity view, not a paginated archive. No cursor, no total.
- `asks` is that dealer's asks, newest first. `asks[0]` is always the ask that
  `latestRequestedByLabel` and `latestOccurredAt` describe.
- `askCount` equals `asks.length`. It is sent explicitly so a client rendering only the summary
  never has to reach into the array.
- `occurredAt` / `latestOccurredAt` / `dismissedAt` are **ISO-8601 strings**, never `Date`.
- `requestedByLabel` / `latestRequestedByLabel` are display-only and **nullable** — the audit row's
  actor label, absent on older rows. Never authorize off them.
- `organizationName` is `"Unknown organization"` when the organization has since been deleted. The
  row is still returned: dropping it would make the list and the count disagree.
- `maxDemoTenants` is the organization's **live effective** demo-tenant cap, tier and override
  resolved. `tierName` is its effective tier name, **nullable**.
- When the organization has been **deleted**, `maxDemoTenants` is `0` and `tierName` is `null` —
  deliberately paired, so a default tier name never sits beside a zero cap and reads like a real
  dealer on a real plan. A client should render that pairing (`tierName: null` alongside
  `maxDemoTenants: 0`) as "unknown", not as a real cap of zero.

### `status` — the resolution rule

`"resolved"` when the dealer's live effective `maxDemoTenants` is **strictly greater** than the cap
recorded on their most recent ask. `"outstanding"` otherwise.

The cap at ask time lives in that `audit_log` row's `metadata.maxDemoTenantsAtRequest`, written when
the request is made. **An ask with no such value is `"outstanding"`** — history from before this
change cannot be reconstructed, and showing a dealer who was already helped costs a glance, whereas
hiding one who was not costs them the wait.

This is a comparison of caps, not a search for a "someone edited the limits" event, so it is correct
whether the cap rose through an override, a tier move, or an edit to the tier itself.

### `dismissedAt` — a fact about the caller, not about the world

Non-null when **this caller** has cleared this dealer. It is deliberately separate from `status`:

| surface | filter |
|---|---|
| the popup | `status === 'outstanding'` **and** (`dismissedAt` is null **or** `dismissedAt < latestOccurredAt`) |
| the all-requests page | `status` only — a dealer you cleared is still a dealer who is waiting |

A new ask arriving after a dismissal therefore brings the dealer back into the popup on its own,
with no write.

### `outstandingAskCount`

The number of asks across dealers the **popup** would show — outstanding, and not dismissed by this
caller. It is the number the top-bar badge renders, computed once here so the badge and the popup
can never disagree. Zero means no badge.

## `POST /api/notifications/dismissals`

Clears one dealer for the calling user.

```json
{ "organizationId": "88574f89-0c88-4b32-87d8-a2214561e10c" }
```

```json
{ "organizationId": "88574f89-0c88-4b32-87d8-a2214561e10c", "dismissedAt": "2026-09-08T02:14:00.000Z" }
```

Returns `200`. Idempotent: dismissing an already-dismissed dealer moves the timestamp forward.
`400` when `organizationId` is missing or not a string. An organization id that matches no request
is accepted and stored — the dealer may ask later, and rejecting it would make the client responsible
for a race it cannot see.

## `POST /api/notifications/dismissals/all`

Clears every dealer the popup is currently showing this caller — outstanding and not already
dismissed. No request body.

```json
{ "dismissedAt": "2026-09-08T02:14:00.000Z", "count": 3 }
```

Returns `200`. `count` is how many dealers were newly dismissed or had their timestamp moved
forward; it is `0` on an empty popup, which is not an error.

The server chooses the set, not the client. A client sending its own list would clear whatever it
last rendered, including a dealer whose new ask arrived in between — and that dealer would be
silently cleared without ever having been seen.

## Errors the web app branches on

**`403`** — on **every** endpoint here, and it is the status that means "do not draw the button".
Deliberately not an empty `200`.

Note that `403` is not proof of ineligibility on its own: the session guard raises the same status
before these handlers run, for a suspended user, a suspended organization, no active organization,
or a member with no role. The web app should treat `403` on these endpoints as "no button"
regardless — every one of those cases is also a caller who must not be shown a count — but should
not report it to the user as "you are not a recipient".

**`401`** — no session (`Unauthenticated`). All of these sit behind the session guard.

## Related

- The **request** these notify about is `POST /api/dealer-clients/demo-slots/request-increase` —
  dealer plane, rate-limited to one per 24 hours per organization. It remains the only writer;
  nothing here creates a request. This change adds one thing to it: the dealer's effective
  `maxDemoTenants` is recorded on its audit row's `metadata`, which is what makes `status`
  computable.
- The **action** a notification leads to is `PATCH /api/organizations/:id/limits`, unchanged.
- The recipient list is the partner-interest settings' `notifyEmails`, shared with partner lead mail
  by decision. Its read view carries `notifyRecipients` — `{ email, inApp }` per entry — so the
  screen can show which addresses get email only and which also get an in-app notification.
- **Auditing:** `GET` is a read. The two dismissal endpoints record that a user tidied their own
  view, which is UI state rather than a domain event, so they are **not** audited — but they are
  `POST`s, so the global interceptor will record them under a derived action unless they carry
  `@Audit`. Suppress rather than name them; see the API plan.
