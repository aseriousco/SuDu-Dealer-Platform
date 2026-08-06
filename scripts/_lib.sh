#!/usr/bin/env bash
# Shared helpers for the dev scripts. Sourced, never executed directly.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# Switch this shell to Node 22 via nvm and assert a minimum version.
#
# Why this exists: the machine default is Node 20, and neither repo picks up a
# version on its own. On Node 20 the API dies with ERR_REQUIRE_ESM (better-auth
# is ESM-only, reached through require(esm), unflagged only since 22.12) and the
# web build fails in ways that look like code problems. Failing loudly here is
# much cheaper than debugging the symptom.
use_node() {
  local min="${1:-22.12.0}"

  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "error: nvm not found at $NVM_DIR" >&2
    echo "       Install nvm, or run the app yourself on Node >= $min." >&2
    return 1
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"

  if ! nvm use 22 >/dev/null 2>&1; then
    echo "error: Node 22 is not installed under nvm." >&2
    echo "       Fix: nvm install 22" >&2
    return 1
  fi

  local have
  have="$(node -v | sed 's/^v//')"
  if [ "$(printf '%s\n%s\n' "$min" "$have" | sort -V | head -1)" != "$min" ]; then
    echo "error: Node >= $min required, but nvm resolved to $have." >&2
    echo "       Fix: nvm install 22 && nvm alias default 22" >&2
    return 1
  fi

  echo "node $(node -v)"
}

# Block until Postgres accepts connections, or give up with a useful message.
wait_for_postgres() {
  local tries="${1:-30}"
  local i=1
  while [ "$i" -le "$tries" ]; do
    if docker compose exec -T postgres pg_isready -U dealer -d sudu_dealer >/dev/null 2>&1; then
      echo "postgres ready on :5433"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "error: postgres did not become ready within ${tries}s." >&2
  echo "       Check: docker compose -f sudu-dealer-api/docker-compose.yml logs postgres" >&2
  return 1
}
