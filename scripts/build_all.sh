#!/bin/zsh
set -e
set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

printf '\n=== LocalWebShare multi-platform build ===\n'
printf 'Version: %s\n' "$(tr -d '[:space:]' < VERSION)"

printf '\n--- macOS ---\n'
./scripts/build_macos.sh

printf '\n--- Android ---\n'
./scripts/build_android.sh

printf '\n--- iOS / iPadOS ---\n'
./scripts/app_build.sh

printf '\n=== All requested platform builds completed ===\n'
