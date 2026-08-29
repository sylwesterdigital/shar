#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
printf '\n=== Shar distribution build v%s ===\n' "$VERSION"
printf '\n--- Android signing setup/check ---\n'
./scripts/setup_android_release.sh
./scripts/check_android_release_credentials.sh
printf '\n--- macOS signed/notarized universal2 ---\n'
./scripts/build_macos_release.sh
printf '\n--- Android signed APK + AAB ---\n'
./scripts/build_android_release.sh
printf '\n--- iOS/iPadOS generic release compile ---\n'
./scripts/build_ios_check.sh
printf '\n--- iOS/iPadOS connected-device install (when available) ---\n'
set +e
./scripts/app_build.sh
IOS_STATUS=$?
set -e
if (( IOS_STATUS == 20 )); then
  printf 'No tethered iPhone/iPad detected; generic iOS compile already passed, continuing.\n'
elif (( IOS_STATUS != 0 )); then
  exit "$IOS_STATUS"
fi
printf '\n=== All platform builds completed ===\n'
