#!/bin/zsh
set -e
set -o pipefail
TEAM_ID="${TEAM_ID:-${SHAR_APPLE_TEAM_ID:-5P9V78UZAC}}"
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "iOS release requires macOS."
for t in xcodebuild xcrun security; do command -v "$t" >/dev/null 2>&1 || fail "Required iOS tool missing: $t"; done
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Invalid Apple team ID: $TEAM_ID"
xcodebuild -version >/dev/null
printf 'iOS/Xcode prerequisites found. Team: %s\n' "$TEAM_ID"
