#!/usr/bin/env bash
# Start Postgres 16 for the dealer API (docker, :5433) and wait until it answers.
# Safe to re-run: docker compose up -d is idempotent.
set -euo pipefail

# shellcheck source=./_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

cd "$ROOT/sudu-dealer-api"

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not running. Start Docker Desktop and retry." >&2
  exit 1
fi

docker compose up -d
wait_for_postgres
