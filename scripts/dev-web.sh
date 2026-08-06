#!/usr/bin/env bash
# Start sudu-dealer-web (Vite) on :5173 with Node 22.
#
# Reach the app at http://localhost:5173 — never http://localhost:3001. Vite
# proxies /api to the API so the browser stays same-origin, which is what makes
# better-auth's httpOnly session cookies work without CORS. Going straight to
# :3001 gets you 403 MISSING_OR_NULL_ORIGIN from the CSRF guard.
set -euo pipefail

# shellcheck source=./_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

use_node 22.0.0

cd "$ROOT/sudu-dealer-web"

if ! curl -sf -o /dev/null --max-time 2 http://localhost:3001/health; then
  echo "warning: the API is not answering on :3001 — /api requests will fail." >&2
  echo "         Start it with ./scripts/dev-api.sh (and ./scripts/dev-db.sh first)." >&2
fi

exec npm run dev
