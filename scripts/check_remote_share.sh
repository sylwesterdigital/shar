#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/release_profile.sh"
shar_load_release_profile
API_URL="${SHAR_REMOTE_API_URL:-https://mojoworks.xyz/api/shar/remote/v1}"
TARGET="$SHAR_REMOTE_USER@$SHAR_REMOTE_HOST"
STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1
printf 'Shar remote host: %s\nShar remote API:  %s\n' "$TARGET" "$API_URL"
ssh -o BatchMode=yes -o ConnectTimeout=12 -p "$SHAR_REMOTE_PORT" "$TARGET" true >/dev/null || { echo 'ERROR: SSH access failed.' >&2; exit 1; }
if body="$(curl --fail --silent --show-error "$API_URL/health" 2>/dev/null)"; then
  printf 'Remote API health: %s\n' "$body"
  printf '%s' "$body" | grep -q '"turn":true' || { echo 'ERROR: Remote API is missing TURN configuration.' >&2; exit 1; }
  exit 0
fi
printf 'Remote API is not installed/online yet. deploy_remote_share.sh will attempt a safe bootstrap.\n'
if ssh -o BatchMode=yes -o ConnectTimeout=12 -p "$SHAR_REMOTE_PORT" "$TARGET" 'sudo -n true' >/dev/null 2>&1; then
  printf 'Passwordless sudo is available for automatic first-time bootstrap.\n'
  exit 0
fi
printf 'Passwordless sudo is not available. The first remote-share release will stop with a one-time sudo command to run over SSH.\n'
(( STRICT )) && exit 2
exit 0
