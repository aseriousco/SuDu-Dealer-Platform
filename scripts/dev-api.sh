#!/usr/bin/env bash
# Start sudu-dealer-api (NestJS, watch mode) on :3001 with Node 22.
# Requires Postgres: run ./scripts/dev-db.sh first.
set -euo pipefail

# shellcheck source=./_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

use_node 22.12.0

cd "$ROOT/sudu-dealer-api"

if [ ! -f .env ]; then
  echo "error: sudu-dealer-api/.env is missing. Copy .env.example and fill it in." >&2
  exit 1
fi

exec npm run start:dev
