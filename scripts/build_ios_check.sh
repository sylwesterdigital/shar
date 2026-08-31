#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/terminal_style.sh"
cd "$ROOT"
"$ROOT/scripts/sync_ui_icons.sh"
"$ROOT/scripts/prepare_local_whisper.sh" apple
PROJECT="$ROOT/LocalWebShare.xcodeproj"
SCHEME="LocalWebShare"
DERIVED="$ROOT/build/ios-release-check"
LOG="$ROOT/build/logs/ios-release-check.log"
mkdir -p "$(dirname "$LOG")"
rm -rf "$DERIVED"
shar_section "Compiling iOS/iPadOS release for generic device (unsigned validation)"
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
APP="$DERIVED/Build/Products/Release-iphoneos/LocalWebShare.app"
"$ROOT/scripts/verify_ios_whisper_linkage.sh" "$APP"
shar_success "iOS/iPadOS release compilation passed"
shar_field "Log:" "$LOG"
