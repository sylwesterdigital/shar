#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/terminal_style.sh"
cd "$ROOT"
"$ROOT/scripts/prepare_local_whisper.sh" all
VERSION="$(tr -d '[:space:]' < VERSION)"
shar_banner_info "Shar distribution build v$VERSION"
shar_section "Android signing setup/check"
./scripts/setup_android_release.sh
./scripts/check_android_release_credentials.sh
shar_section "macOS signed/notarized universal2"
./scripts/build_macos_release.sh
shar_section "Android signed APK + AAB"
./scripts/build_android_release.sh
shar_section "iOS/iPadOS generic release compile"
./scripts/build_ios_check.sh
shar_section "iOS/iPadOS connected-device install (when available)"
set +e
./scripts/app_build.sh
IOS_STATUS=$?
set -e
if (( IOS_STATUS == 20 )); then
  shar_info "No tethered iPhone/iPad detected; generic iOS compile already passed, continuing."
elif (( IOS_STATUS == 21 )); then
  shar_warn "Connected iPhone/iPad is out of storage; the signed device build passed but the optional install could not be staged. Continuing the distribution release. Free device storage before the next manual install."
elif (( IOS_STATUS != 0 )); then
  exit "$IOS_STATUS"
fi
shar_banner_success "All platform builds completed"
