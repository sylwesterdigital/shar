#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/terminal_style.sh"
MODE="${1:-all}"
DEPS="$ROOT/Dependencies/whisper"
MODEL_DIR="$DEPS/models"
MODEL="$MODEL_DIR/ggml-base.bin"
XC="$DEPS/whisper.xcframework"
XC_VERSION="1.9.0"
XC_NAME="whisper-v${XC_VERSION}-xcframework.zip"
XC_ZIP="$DEPS/$XC_NAME"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin?download=true"
MODEL_SHA="60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
XC_URL="https://github.com/ggml-org/whisper.cpp/releases/download/v${XC_VERSION}/${XC_NAME}"
XC_SHA="fd6af2471980094eadf8a19d4241ab89cd64c6110bfb75793cdcc68cb2ccf467"
XC_BYTES="50438559"

say(){ shar_section "$*"; }
warn(){ shar_warn "$*"; }
fail(){ shar_error "$*"; exit 1; }
sha(){ shasum -a 256 "$1" | awk '{print $1}'; }
size(){ stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || wc -c < "$1"; }
fetch(){
  local url="$1" out="$2"
  command -v curl >/dev/null 2>&1 || fail "curl is required to prepare local Whisper dependencies."
  mkdir -p "$(dirname "$out")"
  local tmp="${out}.part"
  rm -f "$tmp"
  curl -fL --retry 3 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
    -H 'Accept: application/octet-stream' \
    -H 'Cache-Control: no-cache' \
    --progress-bar "$url" -o "$tmp"
  mv "$tmp" "$out"
}
verify_xc_zip(){
  [[ -f "$1" ]] || return 1
  [[ "$(sha "$1" 2>/dev/null || true)" == "$XC_SHA" ]] || return 1
  [[ "$(size "$1" 2>/dev/null || true)" == "$XC_BYTES" ]] || return 1
  unzip -tq "$1" >/dev/null 2>&1 || return 1
  return 0
}
fetch_xc_direct(){
  rm -f "$XC_ZIP"
  fetch "${XC_URL}?shar_cache_bust=$(date +%s)" "$XC_ZIP"
}
fetch_xc_with_gh(){
  command -v gh >/dev/null 2>&1 || return 1
  local tmp="${XC_ZIP}.gh.part"
  rm -f "$tmp"
  say "Retrying whisper.cpp XCFramework through GitHub CLI release API"
  if gh release download "v${XC_VERSION}" --repo ggml-org/whisper.cpp --pattern "$XC_NAME" --output "$tmp"; then
    mv "$tmp" "$XC_ZIP"
    return 0
  fi
  rm -f "$tmp"
  return 1
}
fetch_xc_with_api(){
  command -v python3 >/dev/null 2>&1 || return 1
  local meta="${XC_ZIP}.release.json"
  local tmp="${XC_ZIP}.api.part"
  local api="https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/v${XC_VERSION}"
  rm -f "$meta" "$tmp"
  say "Retrying whisper.cpp XCFramework through GitHub Releases API"
  if ! curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Cache-Control: no-cache' \
      "$api" -o "$meta"; then
    rm -f "$meta"
    return 1
  fi
  local fields
  fields="$(python3 - "$meta" "$XC_NAME" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data=json.load(f)
name=sys.argv[2]
asset=next((a for a in data.get('assets',[]) if a.get('name')==name), None)
if not asset:
    raise SystemExit(1)
print(asset.get('id',''))
print(asset.get('digest',''))
PY
)" || { rm -f "$meta"; return 1; }
  local asset_id="${fields%%$'\n'*}"
  local digest="${fields#*$'\n'}"
  [[ -n "$asset_id" ]] || { rm -f "$meta"; return 1; }
  if [[ -n "$digest" && "$digest" != "sha256:$XC_SHA" ]]; then
    rm -f "$meta"
    fail "GitHub reports an unexpected digest for $XC_NAME ($digest). Refusing to use changed binary content."
  fi
  if curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
      -H 'Accept: application/octet-stream' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Cache-Control: no-cache' \
      "https://api.github.com/repos/ggml-org/whisper.cpp/releases/assets/${asset_id}" -o "$tmp"; then
    mv "$tmp" "$XC_ZIP"
    rm -f "$meta"
    return 0
  fi
  rm -f "$meta" "$tmp"
  return 1
}
prepare_xc_zip(){
  if verify_xc_zip "$XC_ZIP"; then
    return 0
  fi
  if [[ -f "$XC_ZIP" ]]; then
    warn "Discarding invalid cached $XC_NAME (sha256=$(sha "$XC_ZIP" 2>/dev/null || echo unknown), bytes=$(size "$XC_ZIP" 2>/dev/null || echo unknown))."
    rm -f "$XC_ZIP"
  fi

  say "Downloading whisper.cpp Apple XCFramework v${XC_VERSION}"
  fetch_xc_direct
  if verify_xc_zip "$XC_ZIP"; then
    return 0
  fi

  warn "Direct GitHub release download did not match the pinned GitHub Release asset SHA-256 (got $(sha "$XC_ZIP" 2>/dev/null || echo unknown), bytes=$(size "$XC_ZIP" 2>/dev/null || echo unknown)). Retrying through an independent GitHub release transport."
  rm -f "$XC_ZIP"
  if fetch_xc_with_gh && verify_xc_zip "$XC_ZIP"; then
    return 0
  fi

  [[ ! -f "$XC_ZIP" ]] || warn "GitHub CLI retry returned sha256=$(sha "$XC_ZIP" 2>/dev/null || echo unknown), bytes=$(size "$XC_ZIP" 2>/dev/null || echo unknown)."
  rm -f "$XC_ZIP"
  if fetch_xc_with_api && verify_xc_zip "$XC_ZIP"; then
    return 0
  fi

  local got="missing"
  local bytes="0"
  if [[ -f "$XC_ZIP" ]]; then
    got="$(sha "$XC_ZIP" 2>/dev/null || echo unreadable)"
    bytes="$(size "$XC_ZIP" 2>/dev/null || echo unknown)"
  fi
  rm -f "$XC_ZIP"
  fail "whisper.cpp XCFramework integrity verification failed after direct, GitHub CLI, and Releases API downloads. Expected SHA-256 $XC_SHA; last SHA-256 $got; bytes $bytes. No unverified framework will be used."
}

mkdir -p "$MODEL_DIR"
if [[ ! -f "$MODEL" || "$(sha "$MODEL" 2>/dev/null || true)" != "$MODEL_SHA" ]]; then
  say "Downloading Shar's local multilingual Whisper model (about 148 MB)"
  rm -f "$MODEL"
  fetch "$MODEL_URL" "$MODEL"
  [[ "$(sha "$MODEL")" == "$MODEL_SHA" ]] || { rm -f "$MODEL"; fail "Whisper model checksum mismatch."; }
else
  say "Local Whisper model already prepared"
fi

if [[ "$MODE" != "android" ]]; then
  if [[ ! -d "$XC" ]]; then
    prepare_xc_zip
    command -v unzip >/dev/null 2>&1 || fail "unzip is required to prepare local Whisper dependencies."
    local_tmp="$(mktemp -d /tmp/shar-whisper-xc.XXXXXX)"
    trap 'rm -rf "$local_tmp"' EXIT
    unzip -q "$XC_ZIP" -d "$local_tmp"
    found="$(find "$local_tmp" -type d -name whisper.xcframework -print -quit)"
    [[ -n "$found" ]] || fail "Downloaded archive does not contain whisper.xcframework."
    rm -rf "$XC"
    ditto "$found" "$XC"
    rm -rf "$local_tmp"
    trap - EXIT
  else
    say "whisper.cpp Apple XCFramework already prepared"
  fi
fi

ANDROID_MODEL="$ROOT/android/app/src/main/assets/models/ggml-base.bin"
if [[ "$MODE" != "apple" ]]; then
  mkdir -p "$(dirname "$ANDROID_MODEL")"
  if [[ ! -f "$ANDROID_MODEL" || "$(sha "$ANDROID_MODEL" 2>/dev/null || true)" != "$MODEL_SHA" ]]; then
    cp "$MODEL" "$ANDROID_MODEL"
  fi
fi

cat > "$DEPS/NOTICE.txt" <<NOTICE
Shar local captions use whisper.cpp v${XC_VERSION} and the multilingual Whisper base model.
Audio is processed on the user's device. Shar does not upload media for transcription.
whisper.cpp and Whisper model licensing: MIT; upstream https://github.com/ggml-org/whisper.cpp
Pinned model SHA-256: $MODEL_SHA
Pinned Apple XCFramework SHA-256: $XC_SHA
Pinned Apple XCFramework bytes: $XC_BYTES
NOTICE

shar_success "Local Whisper dependencies ready"
shar_field "Model:" "$MODEL"
[[ -d "$XC" ]] && shar_field "Apple:" "$XC"
[[ "$MODE" != "apple" ]] && shar_field "Android:" "$ANDROID_MODEL"

# A false optional-print condition must not become this helper's process status.
# build_macos_release.sh runs with set -e, so MODE=apple must explicitly succeed.
exit 0
