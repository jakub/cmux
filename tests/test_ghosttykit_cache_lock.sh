#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_HELPER="$ROOT_DIR/scripts/ghosttykit-cache-lock.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghosttykit-lock-test.XXXXXX")"
LOCK_DIR="$TMP_DIR/cache.lock"
READY_FILE="$TMP_DIR/holder.ready"

cleanup() {
  if [[ -n "${HOLDER_PID:-}" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

wait_for_file() {
  local path="$1"
  local attempts=0
  while [[ ! -e "$path" ]]; do
    attempts=$((attempts + 1))
    if (( attempts > 100 )); then
      echo "timed out waiting for $path" >&2
      exit 1
    fi
    sleep 0.05
  done
}

(
  # shellcheck source=/dev/null
  source "$LOCK_HELPER"
  ghosttykit_cache_lock_acquire "$LOCK_DIR" 10 1 0.05
  touch "$READY_FILE"
  sleep 5
  ghosttykit_cache_lock_release
) &
HOLDER_PID=$!
wait_for_file "$READY_FILE"

if (
  # shellcheck source=/dev/null
  source "$LOCK_HELPER"
  ghosttykit_cache_lock_acquire "$LOCK_DIR" 1 0 0.05
); then
  echo "waiter unexpectedly acquired a live owner's lock" >&2
  exit 1
fi

if [[ ! -d "$LOCK_DIR" ]] || ! kill -0 "$HOLDER_PID" 2>/dev/null; then
  echo "waiter disturbed the live lock owner" >&2
  exit 1
fi

kill "$HOLDER_PID"
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""

mkdir -p "$LOCK_DIR"
printf '999999999\n' > "$LOCK_DIR/owner_pid"
printf 'dead-owner-token\n' > "$LOCK_DIR/token"
printf '0\n' > "$LOCK_DIR/created_at"

# shellcheck source=/dev/null
source "$LOCK_HELPER"
ghosttykit_cache_lock_acquire "$LOCK_DIR" 2 0 0.05
if [[ "$(cat "$LOCK_DIR/owner_pid")" != "${BASHPID:-$$}" ]]; then
  echo "dead owner was not replaced by the current process" >&2
  exit 1
fi

ghosttykit_cache_lock_release
if [[ -d "$LOCK_DIR" ]]; then
  echo "owned lock was not released" >&2
  exit 1
fi

ghosttykit_cache_lock_acquire "$LOCK_DIR" 2 0 0.05
printf 'different-owner-token\n' > "$LOCK_DIR/token"
ghosttykit_cache_lock_release
if [[ ! -d "$LOCK_DIR" ]]; then
  echo "token mismatch released another owner's lock" >&2
  exit 1
fi

echo "ghosttykit cache lock tests passed"
