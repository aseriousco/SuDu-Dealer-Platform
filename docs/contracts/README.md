# docs/contracts/

The FE↔BE surface, by area. One file per area (`auth.md`, `users.md`, `tenants.md`,
`roles.md`, …).

A spec in [`../specs/`](../specs/) describes one feature at one point in time. A contract
here describes an area's **current** surface, and is updated as it changes. Together:
specs are the changelog, contracts are the state.

## Why this is separate from the API's own docs

Changing anything in here is a two-repo change by definition. Keeping it outside both
repos means neither side can quietly redefine the surface in a commit the other side
never sees.

## What belongs in a contract file

- Endpoints, with method and path
- Request and response shapes — **camelCase in HTTP bodies**, never column names
- Error cases and status codes, especially the ones the web app branches on
- Which plane may call it (platform / org / client — see [`../glossary.md`](../glossary.md))

## What does not

- Implementation detail on either side
- Anything already stated as an invariant in a repo's `CLAUDE.md` — link to it instead

## Type rules that apply to every shape here

- **`tenantId` is a string.** Always, both sides. Parsing one to a number corrupts it silently.
- **Money is a string** carrying a `Decimal`. Never a JS `number`.
- **Authorization is the API's decision alone.** A contract may describe what the web app
  is *shown*; it never implies the web app *enforces* anything.

## Status

Empty. Populate an area's file the next time that area changes rather than trying to
document everything at once — a contract written from a diff you just made is accurate;
one reverse-engineered in bulk is guesswork.

Sensible first candidates, based on where the code is moving: `auth.md` (session, reset,
invite) and `users.md` (the onboarding-modes work in flight on both repos).
