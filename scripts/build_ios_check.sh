#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/sync_ui_icons.sh"
PROJECT="$ROOT/LocalWebShare.xcodeproj"
SCHEME="LocalWebShare"
DERIVED="$ROOT/build/ios-release-check"
LOG="$ROOT/build/logs/ios-release-check.log"
mkdir -p "$(dirname "$LOG")"
rm -rf "$DERIVED"
printf '\n==> Compiling iOS/iPadOS release for generic device (unsigned validation)\n'
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  clean build > >(tee "$LOG") 2>&1
printf '\n==> iOS/iPadOS release compilation passed\nLog: %s\n' "$LOG"
