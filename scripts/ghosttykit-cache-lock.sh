#!/usr/bin/env bash

# Owned directory lock used by ensure-ghosttykit.sh. Callers source this file,
# acquire once, and register ghosttykit_cache_lock_release on EXIT.

ghosttykit_cache_lock_now() {
  date +%s
}

ghosttykit_cache_lock_mtime() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null
}

ghosttykit_cache_lock_owner_is_alive() {
  local lock_dir="$1"
  local owner_pid=""
  owner_pid="$(cat "$lock_dir/owner_pid" 2>/dev/null || true)"
  case "$owner_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$owner_pid" 2>/dev/null
}

ghosttykit_cache_lock_remove_stale() {
  local lock_dir="$1"
  local ownerless_stale_seconds="$2"
  local owner_pid="" created_at="" now age

  owner_pid="$(cat "$lock_dir/owner_pid" 2>/dev/null || true)"
  case "$owner_pid" in
    ''|*[!0-9]*)
      created_at="$(cat "$lock_dir/created_at" 2>/dev/null || true)"
      case "$created_at" in
        ''|*[!0-9]*) created_at="$(ghosttykit_cache_lock_mtime "$lock_dir" || true)" ;;
      esac
      case "$created_at" in
        ''|*[!0-9]*) return 1 ;;
      esac
      now="$(ghosttykit_cache_lock_now)"
      age=$((now - created_at))
      if (( age < ownerless_stale_seconds )); then
        return 1
      fi
      echo "==> Removing ownerless stale GhosttyKit cache lock (age ${age}s)" >&2
      ;;
    *)
      if ghosttykit_cache_lock_owner_is_alive "$lock_dir"; then
        return 1
      fi
      echo "==> Removing GhosttyKit cache lock with dead owner PID $owner_pid" >&2
      ;;
  esac

  # Remove only entries owned by this lock protocol. An unexpected file makes
  # rmdir fail closed instead of recursively deleting another process's data.
  rm -f -- "$lock_dir/owner_pid" "$lock_dir/token" "$lock_dir/created_at"
  if ! rmdir -- "$lock_dir" 2>/dev/null; then
    echo "error: stale GhosttyKit lock contains unexpected entries: $lock_dir" >&2
    return 1
  fi
}

ghosttykit_cache_lock_acquire() {
  local lock_dir="$1"
  local wait_timeout_seconds="${2:-1800}"
  local ownerless_stale_seconds="${3:-300}"
  local poll_seconds="${4:-1}"
  local owner_pid token start now elapsed

  mkdir -p "$(dirname "$lock_dir")"
  owner_pid="${BASHPID:-$$}"
  token="$owner_pid.$RANDOM.$(ghosttykit_cache_lock_now)"
  start="$(ghosttykit_cache_lock_now)"

  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      if ! printf '%s\n' "$owner_pid" > "$lock_dir/owner_pid" \
        || ! printf '%s\n' "$token" > "$lock_dir/token" \
        || ! printf '%s\n' "$start" > "$lock_dir/created_at"; then
        rm -f -- "$lock_dir/owner_pid" "$lock_dir/token" "$lock_dir/created_at"
        rmdir -- "$lock_dir" 2>/dev/null || true
        echo "error: could not initialize GhosttyKit cache lock: $lock_dir" >&2
        return 1
      fi
      GHOSTTYKIT_CACHE_LOCK_DIR="$lock_dir"
      GHOSTTYKIT_CACHE_LOCK_TOKEN="$token"
      GHOSTTYKIT_CACHE_LOCK_OWNER_PID="$owner_pid"
      GHOSTTYKIT_CACHE_LOCK_OWNED=1
      export GHOSTTYKIT_CACHE_LOCK_DIR GHOSTTYKIT_CACHE_LOCK_TOKEN
      export GHOSTTYKIT_CACHE_LOCK_OWNER_PID GHOSTTYKIT_CACHE_LOCK_OWNED
      return 0
    fi

    if [[ -L "$lock_dir" || ! -d "$lock_dir" || ! -O "$lock_dir" ]]; then
      echo "error: GhosttyKit cache lock is not an owned directory: $lock_dir" >&2
      return 96
    fi

    if ghosttykit_cache_lock_remove_stale "$lock_dir" "$ownerless_stale_seconds"; then
      continue
    fi

    now="$(ghosttykit_cache_lock_now)"
    elapsed=$((now - start))
    if (( elapsed >= wait_timeout_seconds )); then
      owner_pid="$(cat "$lock_dir/owner_pid" 2>/dev/null || echo unknown)"
      echo "error: timed out waiting for GhosttyKit cache lock after ${elapsed}s (owner PID $owner_pid)" >&2
      return 1
    fi

    echo "==> Waiting for GhosttyKit cache lock (${elapsed}s elapsed)..." >&2
    sleep "$poll_seconds"
  done
}

ghosttykit_cache_lock_release() {
  [[ "${GHOSTTYKIT_CACHE_LOCK_OWNED:-0}" == "1" ]] || return 0

  local lock_dir="$GHOSTTYKIT_CACHE_LOCK_DIR"
  local token="$GHOSTTYKIT_CACHE_LOCK_TOKEN"
  local owner_pid="$GHOSTTYKIT_CACHE_LOCK_OWNER_PID"
  if [[ ! -L "$lock_dir" && -d "$lock_dir" && -O "$lock_dir" \
    && "$(cat "$lock_dir/token" 2>/dev/null || true)" == "$token" \
    && "$(cat "$lock_dir/owner_pid" 2>/dev/null || true)" == "$owner_pid" ]]; then
    rm -f -- "$lock_dir/owner_pid" "$lock_dir/token" "$lock_dir/created_at"
    rmdir -- "$lock_dir" 2>/dev/null || true
  fi
  GHOSTTYKIT_CACHE_LOCK_OWNED=0
}
