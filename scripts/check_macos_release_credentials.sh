#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/terminal_style.sh"
SIGNING_FINGERPRINT="${SHAR_SIGNING_FINGERPRINT:-B97863CA4E17170FCD5FBFA4C76A8DF3D91D5F6B}"
NOTARY_PROFILE="${SHAR_NOTARY_PROFILE:-workwork-caption-notary}"
NETWORK_ATTEMPTS="${SHAR_APPLE_NETWORK_ATTEMPTS:-20}"
NETWORK_DELAY="${SHAR_APPLE_NETWORK_RETRY_DELAY:-15}"
fail(){ shar_error "$*"; exit 1; }
retry(){ local n=1 max="$1" delay="$2"; shift 2; until "$@"; do local rc=$?; (( n >= max )) && return "$rc"; shar_warn "Apple service check failed; retry $n/$max in ${delay}s."; sleep "$delay"; n=$((n+1)); done; }
[[ "$(uname -s)" == Darwin ]] || fail "macOS release must run on macOS."
for t in security xcrun codesign; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGNING_FINGERPRINT" | head -n 1 || true)"
[[ -n "$IDENTITY_LINE" ]] || fail "Developer ID signing fingerprint not found: $SIGNING_FINGERPRINT"
if retry "$NETWORK_ATTEMPTS" "$NETWORK_DELAY" xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
  printf 'macOS Developer ID and notarization credentials are usable.\n%s\n' "$IDENTITY_LINE"
else
  shar_warn "Apple notary service is unreachable during credential preflight. Developer ID is present; continuing to the build. The notarization stage will retry the saved profile instead of failing the release here."
  printf '%s\n' "$IDENTITY_LINE"
fi
