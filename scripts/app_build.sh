#!/bin/zsh
set -e
set -o pipefail

# LocalWebShare one-command physical-device build/install/launch script.
#
# Defaults:
#   - finds full Xcode automatically
#   - finds the first connected physical iPhone/iPad
#   - uses the configured Apple Development Team ID (default: 5P9V78UZAC)
#   - uses Xcode automatic signing/provisioning
#   - builds into ./build/DerivedData
#   - installs over the current app (preserves Documents/uploads)
#   - launches with devicectl instead of attaching LLDB
#
# Optional overrides:
#   TEAM_ID=XXXXXXXXXX ./scripts/app_build.sh
#   DEVICE_ID=<udid> ./scripts/app_build.sh
#   BUNDLE_ID=com.example.app ./scripts/app_build.sh
#   ./scripts/app_build.sh --fresh       # uninstall first; DELETES app data
#   ./scripts/app_build.sh --console     # keep terminal attached to app stdout/stderr
#   ./scripts/app_build.sh --no-launch

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

"$SCRIPT_DIR/sync_ui_icons.sh"

PROJECT="$REPO_DIR/LocalWebShare.xcodeproj"
SCHEME="LocalWebShare"
CONFIGURATION="Debug"
DERIVED_DATA="$REPO_DIR/build/DerivedData"
LOG_DIR="$REPO_DIR/build/logs"
BUILD_LOG="$LOG_DIR/app_build.log"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/LocalWebShare.app"

FRESH=0
CONSOLE=0
LAUNCH=1
TEAM_ID="${TEAM_ID:-5P9V78UZAC}"
DEVICE_ID="${DEVICE_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/app_build.sh [options]

Options:
  --team TEAMID          Override Apple Development team (default: 5P9V78UZAC).
  --device UDID          Override auto-detected connected iPhone/iPad.
  --bundle-id ID         Override generated bundle identifier.
  --fresh                Uninstall the existing app before install (deletes app data).
  --console              Launch and stream app stdout/stderr until the app exits.
  --no-launch            Build and install, but do not launch.
  -h, --help             Show this help.

Environment equivalents: TEAM_ID, DEVICE_ID, BUNDLE_ID.
USAGE
}

while (($#)); do
  case "$1" in
    --team)
      TEAM_ID="${2:?--team requires a value}"; shift 2 ;;
    --device)
      DEVICE_ID="${2:?--device requires a value}"; shift 2 ;;
    --bundle-id)
      BUNDLE_ID="${2:?--bundle-id requires a value}"; shift 2 ;;
    --fresh)
      FRESH=1; shift ;;
    --console)
      CONSOLE=1; shift ;;
    --no-launch)
      LAUNCH=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Use full Xcode even if xcode-select currently points at CommandLineTools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    SELECTED="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$SELECTED" == *".app/Contents/Developer"* ]]; then
      export DEVELOPER_DIR="$SELECTED"
    fi
  fi
fi

command -v xcodebuild >/dev/null 2>&1 || fail "Full Xcode was not found. Install Xcode in /Applications/Xcode.app."
command -v xcrun >/dev/null 2>&1 || fail "xcrun was not found."
command -v python3 >/dev/null 2>&1 || fail "python3 was not found (normally supplied by Xcode/macOS)."
[[ -d "$PROJECT" ]] || fail "Project not found: $PROJECT"

mkdir -p "$LOG_DIR"
: > "$BUILD_LOG"

say "Xcode"
xcodebuild -version
printf 'Developer dir: %s\n' "${DEVELOPER_DIR:-$(xcode-select -p)}"

# Complete Xcode first-launch setup if this Xcode installation needs it.
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  say "Completing Xcode first-launch setup"
  xcodebuild -runFirstLaunch || fail "Xcode first-launch setup could not complete. Open Xcode once if macOS requires an administrator/license confirmation."
fi

# Avoid the IDE logging path that produced the IDEPreferLogStreaming timeout.
export IDEPreferLogStreaming=YES

# The previous auto-detection selected an unrelated Keychain certificate and
# produced "No Account for Team". Keep the known Xcode account/team explicit.
# TEAM_ID remains overrideable for another developer account.
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Invalid TEAM_ID: $TEAM_ID"

if [[ -z "$BUNDLE_ID" ]]; then
  TEAM_LOWER="$(printf '%s' "$TEAM_ID" | tr '[:upper:]' '[:lower:]')"
  BUNDLE_ID="com.localwebshare.${TEAM_LOWER}"
fi
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || fail "Invalid bundle identifier: $BUNDLE_ID"

say "Signing"
printf 'Team:      %s\n' "$TEAM_ID"
printf 'Bundle ID: %s\n' "$BUNDLE_ID"
printf 'Mode:      Automatic signing + provisioning updates\n'

# Get the first connected physical iPhone/iPad. The parser supports both the
# Xcode 15/16/26 JSON fields and newer properties.* CoreDevice JSON layouts.
DEVICE_JSON="$(mktemp -t localwebshare-devices)"
trap 'rm -f "$DEVICE_JSON"' EXIT

xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null \
  || fail "devicectl could not enumerate devices."

DEVICE_ROWS_FILE="$(mktemp -t localwebshare-device-rows)"
trap 'rm -f "$DEVICE_JSON" "$DEVICE_ROWS_FILE"' EXIT

python3 - "$DEVICE_JSON" > "$DEVICE_ROWS_FILE" <<'PYDEV'
import json, sys
p=sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    data=json.load(f)

rows=[]
for d in data.get('result', {}).get('devices', []):
    old_hw=d.get('hardwareProperties') or {}
    old_dev=d.get('deviceProperties') or {}
    old_conn=d.get('connectionProperties') or {}
    props=d.get('properties') or {}
    hw=props.get('hardware') or {}
    state=props.get('state') or {}
    conn=props.get('connection') or {}

    reality=(old_hw.get('reality') or hw.get('reality') or '').lower()
    platform=(old_hw.get('platform') or hw.get('platform') or '').lower()
    dtype=(old_hw.get('deviceType') or hw.get('deviceType') or '').lower()
    name=old_dev.get('name') or props.get('name') or state.get('name') or 'iOS device'
    udid=old_hw.get('udid') or hw.get('udid') or d.get('udid') or ''
    core_id=d.get('identifier') or ''
    tunnel=(old_conn.get('tunnelState') or conn.get('tunnelState') or conn.get('state') or '').lower()
    pairing=(old_conn.get('pairingState') or conn.get('pairingState') or '').lower()
    transport=(old_conn.get('transportType') or conn.get('transportType') or '').lower()
    devmode=(old_dev.get('developerModeStatus') or state.get('developerModeStatus') or props.get('developerModeStatus') or '').lower()
    boot=(old_dev.get('bootState') or state.get('bootState') or '').lower()

    is_ios = ('ios' in platform or 'iphone' in platform or dtype in ('iphone','ipad'))
    if not platform and not dtype:
        is_ios = bool(udid)
    physical = reality in ('', 'physical') and is_ios
    online = tunnel in ('connected','available') or (pairing == 'paired' and transport in ('wired','usb','localnetwork','network')) or boot == 'booted'
    ident=udid or core_id
    if physical and online and ident:
        rows.append((ident, str(name).replace('\t',' '), devmode))

for row in rows:
    print('\t'.join(row))
PYDEV

if [[ -z "$DEVICE_ID" ]]; then
  FIRST_DEVICE="$(head -n 1 "$DEVICE_ROWS_FILE")"
  [[ -n "$FIRST_DEVICE" ]] || fail "No connected physical iPhone/iPad is available to CoreDevice. Connect/unlock the device and approve any iOS trust prompt, then rerun this same script."
  IFS=$'\t' read -r DEVICE_ID DEVICE_NAME DEVICE_DEVMODE <<< "$FIRST_DEVICE"
else
  DEVICE_NAME="selected device"
  DEVICE_DEVMODE=""
  MATCHED_DEVICE="$(awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }' "$DEVICE_ROWS_FILE")"
  if [[ -n "$MATCHED_DEVICE" ]]; then
    IFS=$'\t' read -r _ DEVICE_NAME DEVICE_DEVMODE <<< "$MATCHED_DEVICE"
  fi
fi

if [[ "$DEVICE_DEVMODE" == "disabled" ]]; then
  fail "Developer Mode is disabled on $DEVICE_NAME. iOS itself requires this to be enabled before development apps can be launched; it cannot be switched on by a build script."
fi

say "Device"
printf 'Name: %s\nID:   %s\n' "$DEVICE_NAME" "$DEVICE_ID"

say "Cleaning previous build output"
rm -rf "$DERIVED_DATA"
mkdir -p "$DERIVED_DATA"

say "Building and signing"
set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  clean build > >(tee "$BUILD_LOG") 2>&1
BUILD_STATUS=$?
set -e

if ((BUILD_STATUS != 0)); then
  printf '\nBuild log: %s\n' "$BUILD_LOG" >&2
  fail "xcodebuild failed. The complete signing/build error is in the log above."
fi

[[ -d "$APP_PATH" ]] || fail "Build succeeded but app bundle was not found at $APP_PATH"

# Verify the product is signed before touching the device.
say "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
[[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] || fail "Built bundle identifier '$ACTUAL_BUNDLE_ID' does not match '$BUNDLE_ID'."

if ((FRESH)); then
  say "Removing previous install (--fresh)"
  xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

say "Installing on $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

if ((LAUNCH)); then
  say "Launching without LLDB attach"
  if ((CONSOLE)); then
    xcrun devicectl device process launch --device "$DEVICE_ID" --console "$BUNDLE_ID"
  else
    if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"; then
      printf '\nInstalled successfully, but iOS refused automatic launch (commonly because the device locked between install and launch).\n' >&2
      exit 3
    fi
  fi
fi

say "Done"
printf 'App:       %s\n' "$APP_PATH"
printf 'Bundle ID: %s\n' "$BUNDLE_ID"
printf 'Build log: %s\n' "$BUILD_LOG"
