#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/terminal_style.sh"

APP="${1:-}"
[[ -n "$APP" ]] || { shar_error "Usage: verify_ios_whisper_linkage.sh /path/to/LocalWebShare.app"; exit 2; }
[[ -d "$APP" ]] || { shar_error "iOS app bundle not found: $APP"; exit 1; }

OTOOL_BIN="${OTOOL_BIN:-otool}"
command -v "$OTOOL_BIN" >/dev/null 2>&1 || { shar_error "otool was not found."; exit 1; }

EXECUTABLE_NAME="${SHAR_IOS_EXECUTABLE:-LocalWebShare}"
MAIN_BINARY="$APP/$EXECUTABLE_NAME"
DEBUG_DYLIB="$APP/${EXECUTABLE_NAME}.debug.dylib"

[[ -f "$MAIN_BINARY" ]] || { shar_error "Built iOS app is missing executable: $MAIN_BINARY"; exit 1; }
[[ -d "$APP/Frameworks/whisper.framework" ]] || { shar_error "Built iOS app is missing embedded whisper.framework."; exit 1; }

# @rpath/whisper.framework/whisper must be resolvable from the app bundle.
# In Xcode 16 Debug builds, the app executable is a small preview/debug stub and
# the real app code (including framework dependencies) lives in
# LocalWebShare.debug.dylib. Release builds normally carry the dependency on the
# main executable. Verify the runpath on the executable, then locate the actual
# image that weak-links Whisper instead of assuming it is always the executable.
if ! "$OTOOL_BIN" -l "$MAIN_BINARY" | awk '
  /cmd LC_RPATH/ { rpath=1; next }
  rpath && /path @executable_path\/Frameworks/ { found=1 }
  /Load command/ { rpath=0 }
  END { exit(found ? 0 : 1) }
'; then
  shar_error "Built iOS app is missing @executable_path/Frameworks LC_RPATH; embedded Whisper would fail to resolve at runtime."
  exit 1
fi

weak_links_whisper() {
  local binary="$1"
  "$OTOOL_BIN" -l "$binary" | awk '
    /cmd LC_LOAD_WEAK_DYLIB/ { weak=1; next }
    weak && /name @rpath\/whisper\.framework\/whisper/ { found=1 }
    /Load command/ { weak=0 }
    END { exit(found ? 0 : 1) }
  '
}

WHISPER_LOADER=""
if [[ -f "$DEBUG_DYLIB" ]] && weak_links_whisper "$DEBUG_DYLIB"; then
  WHISPER_LOADER="$DEBUG_DYLIB"
elif weak_links_whisper "$MAIN_BINARY"; then
  WHISPER_LOADER="$MAIN_BINARY"
fi

if [[ -z "$WHISPER_LOADER" ]]; then
  shar_error "Built iOS app does not weak-link whisper.framework in either the app executable or Xcode Debug dylib."
  printf '%s\n' "Dependency diagnostics:" >&2
  "$OTOOL_BIN" -L "$MAIN_BINARY" >&2 || true
  if [[ -f "$DEBUG_DYLIB" ]]; then
    "$OTOOL_BIN" -L "$DEBUG_DYLIB" >&2 || true
  fi
  exit 1
fi

if [[ "$WHISPER_LOADER" == "$DEBUG_DYLIB" ]]; then
  shar_info "Whisper weak link is carried by Xcode Debug dylib: ${DEBUG_DYLIB##*/}"
else
  shar_info "Whisper weak link is carried by app executable: ${MAIN_BINARY##*/}"
fi
shar_success "iOS embedded Whisper launch contract verified"
