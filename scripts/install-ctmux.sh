#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="ctmux"
APP_NAME="ctmux"
BUNDLE_ID="com.cmuxterm.app.debug.ctmux"
DERIVED_DATA="${CMUX_CTMUX_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-ctmux}"
DESTINATION="${CMUX_CTMUX_INSTALL_PATH:-/Applications/ctmux.app}"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
LAUNCH=0

usage() {
  cat <<'EOF'
usage: ./scripts/install-ctmux.sh [--launch]

build the current checkout as an isolated tagged debug app, then install it as:

  /Applications/ctmux.app

options:
  --launch  launch the installed app after replacement
  -h, --help

environment:
  CMUX_SKIP_ZIG_BUILD       defaults to 1; set to 0 for the full ghostty cli build
  CMUX_CTMUX_DERIVED_DATA  override the tagged deriveddata directory
  CMUX_CTMUX_INSTALL_PATH  override the install path (useful for script testing)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch)
      LAUNCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$DESTINATION" != /* ]]; then
  echo "error: install path must be absolute: $DESTINATION" >&2
  exit 2
fi

if [[ -z "${CMUX_SKIP_ZIG_BUILD+x}" ]]; then
  export CMUX_SKIP_ZIG_BUILD=1
fi

echo "==> building $APP_NAME.app from $REPO_ROOT"
(
  cd "$REPO_ROOT"
  "$SCRIPT_DIR/reload.sh" \
    --tag "$TAG" \
    --name "$APP_NAME" \
    --bundle-id "$BUNDLE_ID" \
    --derived-data "$DERIVED_DATA" \
    --no-global-cli-links
)

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: built app not found: $SOURCE_APP" >&2
  exit 1
fi
if [[ ! -x "$SOURCE_APP/Contents/MacOS/cmux DEV" ]]; then
  echo "error: built app has no executable: $SOURCE_APP/Contents/MacOS/cmux DEV" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"

DESTINATION_PARENT="$(dirname "$DESTINATION")"
STAGING_ROOT="$(mktemp -d "$DESTINATION_PARENT/.ctmux-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
BACKUP_APP="$STAGING_ROOT/previous.app"
REPLACEMENT_STARTED=0
INSTALL_COMPLETE=0

cleanup() {
  local status=$?
  trap - EXIT

  if [[ "$REPLACEMENT_STARTED" -eq 1 && "$INSTALL_COMPLETE" -eq 0 ]]; then
    rm -rf "$DESTINATION"
    if [[ -d "$BACKUP_APP" ]]; then
      mv "$BACKUP_APP" "$DESTINATION"
    fi
  fi
  rm -rf "$STAGING_ROOT"
  exit "$status"
}
trap cleanup EXIT

echo "==> staging $DESTINATION"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"

INFO_PLIST="$STAGED_APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: staged app has no Info.plist" >&2
  exit 1
fi

set_plist_env() {
  local key="$1"
  local value="$2"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:${key} \"${value}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${key} string \"${value}\"" "$INFO_PLIST"
}

set_plist_env CMUX_BUNDLED_CLI_PATH "$DESTINATION/Contents/Resources/bin/cmux"
set_plist_env CMUX_SHELL_INTEGRATION_DIR "$DESTINATION/Contents/Resources/shell-integration"

/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  --generate-entitlement-der \
  "$STAGED_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# reload.sh has already asked any app with this bundle id to quit. The exact-path
# fallback covers an instance whose LaunchServices registration has gone stale.
pkill -f "$DESTINATION/Contents/MacOS/cmux DEV" 2>/dev/null || true

REPLACEMENT_STARTED=1
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$DESTINATION"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"
INSTALL_COMPLETE=1

rm -rf "$BACKUP_APP"
rm -rf "$STAGING_ROOT"
trap - EXIT

echo
echo "installed: $DESTINATION"
echo "bundle id: $BUNDLE_ID"
echo "source commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"

if [[ "$LAUNCH" -eq 1 ]]; then
  /usr/bin/open -n "$DESTINATION"
fi
