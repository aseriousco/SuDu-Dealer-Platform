# Contract — notifications

The in-app notification surface: the vendor's view of dealer limit-increase requests, and
the marker that records having looked at them.

Written from the limit-increase notifications change
([spec](../specs/2026-09-07-limit-increase-notifications-design.md)), so it covers **those
two endpoints only**. There is no general notification feed — this area is named
`notifications` because it is where one will grow, not because one exists. Extend it the
next time the area changes rather than reverse-engineering the rest in bulk (see
[`README.md`](./README.md)).

Authorization is the API's decision alone; nothing here implies the web app enforces
anything.

## Who may call these

**Platform plane, and only an eligible recipient within it.** Eligibility is two conditions
at once:

> The caller's email is in the partner-interest `notifyEmails` list **and** the caller is a
> platform **admin**.

The list holds bare addresses and is a delivery setting, not a grant of authority. The
match alone would notify someone who cannot act: raising a limit is platform-admin only, so
a dealer — or vendor **staff**, whose role is on the platform plane but is not `ADMIN` —
would be shown a count leading straight to a `403`.

**A caller who is not an eligible recipient gets `403`, not an empty list.** Empty would
read as "nothing has been requested"; the web uses this endpoint to decide whether to draw
the bell at all. Eligibility is the `notifyEmails` match **and** platform admin — the match
alone would notify someone who cannot act.

Which addresses satisfy both halves is visible on the settings screen: see
`notifyRecipients` in [`partner-interest`](#related) below.

## `GET /api/notifications/limit-increase`

The newest requests, plus how many of them the caller has not yet seen.

```json
{
  "items": [
    {
      "id": "a3f1…",
      "organizationId": "0f2c…",
      "organizationName": "Acme Motors",
      "requestedByLabel": "Dana Lim",
      "occurredAt": "2026-09-01T10:00:00.000Z"
    }
  ],
  "unreadCount": 1
}
```

- `items` is newest-first, capped at the 50 most recent. It is a recent-activity view, not
  a paginated archive — there is no cursor and no total.
- `occurredAt` is an **ISO-8601 string**, never a `Date`.
- `requestedByLabel` is display-only and **nullable**; it is the audit row's actor label, so
  it may be absent on older rows. Never authorize off it.
- `organizationName` is `"Unknown organization"` when the organization has since been
  deleted. The row is still returned: dropping it would make the list and `unreadCount`
  disagree.
- `unreadCount` counts the items newer than the caller's last `POST /seen`. Before the first
  one it is every item returned, so it never exceeds `items.length`.

## `POST /api/notifications/seen`

Marks everything currently visible as seen, for the calling user only. No request body.

```json
{ "seenAt": "2026-09-04T12:00:00.000Z" }
```

Returns `200`. The marker is per user and server-set — a client cannot choose the
timestamp, so it cannot silently clear its own unread count. A subsequent `GET` returns
`unreadCount: 0` until something newer arrives.

## Errors the web app branches on

**`403`** — on **both** endpoints, and it is the status that means "do not draw the bell".
Deliberately not an empty `200`.

Note that `403` here is not proof of ineligibility on its own: the session guard raises the
same status before these handlers run, for a suspended user, a suspended organization, no
active organization, or a member with no role. The web app should treat `403` on these two
endpoints as "no bell" regardless — every one of those cases is also a caller who must not
be shown a count — but should not report it to the user as "you are not a recipient".

**`401`** — no session (`Unauthenticated`). Both endpoints sit behind the session guard.

## Related

- The **request** these notify about is `POST /api/dealer-clients/demo-slots/request-increase`
  — dealer plane, rate-limited to one per 24 hours per organization. It is unchanged by this
  contract, and it remains the only writer; nothing here creates a request.
- The recipient list is the partner-interest settings' `notifyEmails`, shared with partner
  lead mail by decision. Its read view carries `notifyRecipients` — `{ email, inApp }` per
  entry — so the screen can show which addresses get email only and which also get a bell.
- Neither endpoint here is audited. `GET` is a read; `POST /seen` records that a user looked
  at a page, which is UI state rather than a domain event.
