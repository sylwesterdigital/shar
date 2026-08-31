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

# Keep the expensive downloads outside the repository as a second line of
# defence. build-watch.sh also preserves Dependencies/, so normal releases do
# not touch the network at all after the first successful preparation.
CACHE_ROOT="${SHAR_WHISPER_CACHE_DIR:-$HOME/Library/Caches/Shar/whisper}"
CACHE_MODEL="$CACHE_ROOT/models/ggml-base.bin"
CACHE_XC_ZIP="$CACHE_ROOT/$XC_NAME"
CACHE_XC="$CACHE_ROOT/whisper.xcframework"
DOWNLOAD_ATTEMPTS="${SHAR_DOWNLOAD_ATTEMPTS:-12}"
DOWNLOAD_RETRY_DELAY="${SHAR_DOWNLOAD_RETRY_DELAY:-10}"

say(){ shar_section "$*"; }
warn(){ shar_warn "$*"; }
fail(){ shar_error "$*"; exit 1; }
sha(){ shasum -a 256 "$1" | awk '{print $1}'; }
size(){ stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || wc -c < "$1"; }
valid_model(){ [[ -f "$1" ]] && [[ "$(sha "$1" 2>/dev/null || true)" == "$MODEL_SHA" ]]; }
valid_xc_dir(){
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -d "$dir/macos-arm64_x86_64/whisper.framework" ]] || return 1
  local count="$(find "$dir" -type d -name whisper.framework -print 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${count:-0}" -ge 2 ]] || return 1
  return 0
}

fetch_resumable(){
  local url="$1" out="$2" label="$3"
  command -v curl >/dev/null 2>&1 || fail "curl is required to prepare local Whisper dependencies."
  mkdir -p "$(dirname "$out")"
  local tmp="${out}.part"
  local attempt=1 rc=0

  while (( attempt <= DOWNLOAD_ATTEMPTS )); do
    local resume_args=()
    if [[ -s "$tmp" ]]; then
      resume_args=(--continue-at -)
      warn "Resuming partial $label download ($(size "$tmp" 2>/dev/null || echo '?') bytes already cached)."
    fi

    if curl -fL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
      -H 'Accept: application/octet-stream' \
      -H 'Cache-Control: no-cache' \
      --progress-bar "${resume_args[@]}" "$url" -o "$tmp"; then
      mv "$tmp" "$out"
      return 0
    else
      rc=$?
    fi

    # Some CDNs do not honour a Range request after a redirect. Preserve the
    # partial file for ordinary network failures, but restart once if curl says
    # the server cannot resume this object.
    if (( rc == 33 || rc == 36 )); then
      warn "$label server rejected resume; restarting this download from byte 0."
      rm -f "$tmp"
    fi

    if (( attempt >= DOWNLOAD_ATTEMPTS )); then
      break
    fi
    warn "$label download interrupted (attempt $attempt/$DOWNLOAD_ATTEMPTS). Keeping the partial file and retrying in ${DOWNLOAD_RETRY_DELAY}s."
    sleep "$DOWNLOAD_RETRY_DELAY"
    attempt=$((attempt+1))
  done

  fail "$label could not be downloaded after $DOWNLOAD_ATTEMPTS attempts. Any partial download remains at $tmp and will resume on the next run."
}

verify_xc_zip(){
  [[ -f "$1" ]] || return 1
  [[ "$(sha "$1" 2>/dev/null || true)" == "$XC_SHA" ]] || return 1
  [[ "$(size "$1" 2>/dev/null || true)" == "$XC_BYTES" ]] || return 1
  unzip -tq "$1" >/dev/null 2>&1 || return 1
  return 0
}

fetch_xc_direct(){
  fetch_resumable "$XC_URL" "$CACHE_XC_ZIP" "whisper.cpp Apple XCFramework"
}

fetch_xc_with_gh(){
  command -v gh >/dev/null 2>&1 || return 1
  local tmp="${CACHE_XC_ZIP}.gh.part"
  rm -f "$tmp"
  say "Retrying whisper.cpp XCFramework through GitHub CLI release API"
  if gh release download "v${XC_VERSION}" --repo ggml-org/whisper.cpp --pattern "$XC_NAME" --output "$tmp"; then
    mv "$tmp" "$CACHE_XC_ZIP"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

fetch_xc_with_api(){
  command -v python3 >/dev/null 2>&1 || return 1
  local meta="${CACHE_XC_ZIP}.release.json"
  local tmp="${CACHE_XC_ZIP}.api.part"
  local api="https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/v${XC_VERSION}"
  rm -f "$meta" "$tmp"
  say "Retrying whisper.cpp XCFramework through GitHub Releases API"
  if ! curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 \
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
  if curl -fL --retry 5 --retry-all-errors --connect-timeout 20 \
      -H 'Accept: application/octet-stream' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Cache-Control: no-cache' \
      "https://api.github.com/repos/ggml-org/whisper.cpp/releases/assets/${asset_id}" -o "$tmp"; then
    mv "$tmp" "$CACHE_XC_ZIP"
    rm -f "$meta"
    return 0
  fi
  rm -f "$meta" "$tmp"
  return 1
}

prepare_xc_cache_zip(){
  if verify_xc_zip "$CACHE_XC_ZIP"; then
    say "Using cached whisper.cpp Apple XCFramework archive"
    return 0
  fi
  if [[ -f "$CACHE_XC_ZIP" ]]; then
    warn "Discarding invalid cached $XC_NAME (sha256=$(sha "$CACHE_XC_ZIP" 2>/dev/null || echo unknown), bytes=$(size "$CACHE_XC_ZIP" 2>/dev/null || echo unknown))."
    rm -f "$CACHE_XC_ZIP"
  fi

  say "Downloading whisper.cpp Apple XCFramework v${XC_VERSION}"
  fetch_xc_direct
  if verify_xc_zip "$CACHE_XC_ZIP"; then
    return 0
  fi

  warn "Direct GitHub release download did not match the pinned GitHub Release asset SHA-256 (got $(sha "$CACHE_XC_ZIP" 2>/dev/null || echo unknown), bytes=$(size "$CACHE_XC_ZIP" 2>/dev/null || echo unknown)). Retrying through an independent GitHub release transport."
  rm -f "$CACHE_XC_ZIP"
  if fetch_xc_with_gh && verify_xc_zip "$CACHE_XC_ZIP"; then
    return 0
  fi

  [[ ! -f "$CACHE_XC_ZIP" ]] || warn "GitHub CLI retry returned sha256=$(sha "$CACHE_XC_ZIP" 2>/dev/null || echo unknown), bytes=$(size "$CACHE_XC_ZIP" 2>/dev/null || echo unknown)."
  rm -f "$CACHE_XC_ZIP"
  if fetch_xc_with_api && verify_xc_zip "$CACHE_XC_ZIP"; then
    return 0
  fi

  local got="missing" bytes="0"
  if [[ -f "$CACHE_XC_ZIP" ]]; then
    got="$(sha "$CACHE_XC_ZIP" 2>/dev/null || echo unreadable)"
    bytes="$(size "$CACHE_XC_ZIP" 2>/dev/null || echo unknown)"
  fi
  rm -f "$CACHE_XC_ZIP"
  fail "whisper.cpp XCFramework integrity verification failed. Expected SHA-256 $XC_SHA; last SHA-256 $got; bytes $bytes. No unverified framework will be used."
}

install_xc_from_zip(){
  local destination="$1"
  command -v unzip >/dev/null 2>&1 || fail "unzip is required to prepare local Whisper dependencies."
  local local_tmp="$(mktemp -d /tmp/shar-whisper-xc.XXXXXX)"
  trap 'rm -rf "$local_tmp"' EXIT
  unzip -q "$CACHE_XC_ZIP" -d "$local_tmp"
  local found="$(find "$local_tmp" -type d -name whisper.xcframework -print -quit)"
  [[ -n "$found" ]] || fail "Downloaded archive does not contain whisper.xcframework."
  rm -rf "$destination"
  ditto "$found" "$destination"
  rm -rf "$local_tmp"
  trap - EXIT
  valid_xc_dir "$destination" || fail "Extracted whisper.xcframework failed local structure validation."
}

mkdir -p "$MODEL_DIR" "$CACHE_ROOT/models"

recover_model_from_previous_build(){
  local candidate
  for candidate in \
    "$ROOT/build/macos-release/Shar.app/Contents/Resources/ggml-base.bin" \
    "$ROOT/build/macos/Shar.app/Contents/Resources/ggml-base.bin"; do
    if valid_model "$candidate"; then
      say "Recovering local Whisper model from previous build output"
      cp -p "$candidate" "$CACHE_MODEL"
      return 0
    fi
  done
  candidate="$(find "$ROOT/build" -type f -name ggml-base.bin -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && valid_model "$candidate"; then
    say "Recovering local Whisper model from previous build output"
    cp -p "$candidate" "$CACHE_MODEL"
    return 0
  fi
  return 1
}

recover_xc_from_previous_build(){
  local candidate="$(find "$ROOT/build" -type d -name whisper.xcframework -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && valid_xc_dir "$candidate"; then
    say "Recovering whisper.cpp Apple XCFramework from previous build output"
    rm -rf "$CACHE_XC"
    ditto "$candidate" "$CACHE_XC"
    return 0
  fi
  return 1
}

if valid_model "$MODEL"; then
  say "Local Whisper model already prepared"
  if ! valid_model "$CACHE_MODEL"; then
    cp -p "$MODEL" "$CACHE_MODEL"
  fi
elif valid_model "$CACHE_MODEL"; then
  say "Restoring local Whisper model from persistent cache"
  rm -f "$MODEL"
  cp -p "$CACHE_MODEL" "$MODEL"
elif recover_model_from_previous_build; then
  rm -f "$MODEL"
  cp -p "$CACHE_MODEL" "$MODEL"
else
  say "Downloading Shar's local multilingual Whisper model (about 148 MB)"
  rm -f "$CACHE_MODEL"
  fetch_resumable "$MODEL_URL" "$CACHE_MODEL" "Whisper base model"
  valid_model "$CACHE_MODEL" || { rm -f "$CACHE_MODEL"; fail "Whisper model checksum mismatch."; }
  rm -f "$MODEL"
  cp -p "$CACHE_MODEL" "$MODEL"
fi

if [[ "$MODE" != "android" ]]; then
  if valid_xc_dir "$XC"; then
    say "whisper.cpp Apple XCFramework already prepared"
    if ! valid_xc_dir "$CACHE_XC"; then
      rm -rf "$CACHE_XC"
      ditto "$XC" "$CACHE_XC"
    fi
  elif valid_xc_dir "$CACHE_XC"; then
    say "Restoring whisper.cpp Apple XCFramework from persistent cache"
    rm -rf "$XC"
    ditto "$CACHE_XC" "$XC"
  elif recover_xc_from_previous_build; then
    rm -rf "$XC"
    ditto "$CACHE_XC" "$XC"
  else
    # Seed the persistent archive from a valid repository copy when available.
    if verify_xc_zip "$XC_ZIP" && ! verify_xc_zip "$CACHE_XC_ZIP"; then
      cp -p "$XC_ZIP" "$CACHE_XC_ZIP"
    fi
    prepare_xc_cache_zip
    install_xc_from_zip "$CACHE_XC"
    rm -rf "$XC"
    ditto "$CACHE_XC" "$XC"
  fi

  # Keep a verified archive in Dependencies as a convenient local fallback.
  if verify_xc_zip "$CACHE_XC_ZIP" && ! verify_xc_zip "$XC_ZIP"; then
    cp -p "$CACHE_XC_ZIP" "$XC_ZIP"
  fi
fi

ANDROID_MODEL="$ROOT/android/app/src/main/assets/models/ggml-base.bin"
if [[ "$MODE" != "apple" ]]; then
  mkdir -p "$(dirname "$ANDROID_MODEL")"
  if [[ ! -f "$ANDROID_MODEL" || "$(sha "$ANDROID_MODEL" 2>/dev/null || true)" != "$MODEL_SHA" ]]; then
    cp -p "$MODEL" "$ANDROID_MODEL"
  fi
fi

cat > "$DEPS/NOTICE.txt" <<NOTICE
Shar local captions use whisper.cpp v${XC_VERSION} and the multilingual Whisper base model.
Audio is processed on the user's device. Shar does not upload media for transcription.
whisper.cpp and Whisper model licensing: MIT; upstream https://github.com/ggml-org/whisper.cpp
Pinned model SHA-256: $MODEL_SHA
Pinned Apple XCFramework SHA-256: $XC_SHA
Pinned Apple XCFramework bytes: $XC_BYTES
Persistent download cache: $CACHE_ROOT
NOTICE

shar_success "Local Whisper dependencies ready"
shar_field "Model:" "$MODEL"
[[ -d "$XC" ]] && shar_field "Apple:" "$XC"
[[ "$MODE" != "apple" ]] && shar_field "Android:" "$ANDROID_MODEL"
shar_field "Cache:" "$CACHE_ROOT"

# A false optional-print condition must not become this helper's process status.
# build_macos_release.sh runs with set -e, so MODE=apple must explicitly succeed.
exit 0
