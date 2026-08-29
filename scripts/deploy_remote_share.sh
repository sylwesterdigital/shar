#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/release_profile.sh"
shar_load_release_profile
API_URL="${SHAR_REMOTE_API_URL:-https://mojoworks.xyz/api/shar/remote/v1}"
RECEIVE_BASE="${SHAR_RECEIVE_BASE:-https://mojoworks.xyz/labs/shar/receive.html}"
TURN_HOST="${SHAR_TURN_HOST:-$SHAR_REMOTE_HOST}"
TARGET="$SHAR_REMOTE_USER@$SHAR_REMOTE_HOST"
EXPECTED_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -p "$SHAR_REMOTE_PORT")
SCP=(scp -q -o BatchMode=yes -o ConnectTimeout=15 -P "$SHAR_REMOTE_PORT")
log(){ printf '\n==> %s\n' "$*"; }
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f "$ROOT/remote/server.js" ]] || fail "remote/server.js missing"
[[ -f "$ROOT/scripts/remote_bootstrap.sh" ]] || fail "scripts/remote_bootstrap.sh missing"
for t in ssh scp curl; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done
"${SSH[@]}" "$TARGET" true || fail "SSH connection failed."

# Fast path is valid only when BOTH the local service and public nginx route are
# healthy. A healthy localhost service can coexist with a broken/404 public route.
NEED_BOOTSTRAP=1
if "${SSH[@]}" "$TARGET" "test -w /opt/shar-remote && systemctl --quiet is-active shar-remote.service 2>/dev/null"; then
  log "Updating existing Shar remote signaling source"
  "${SCP[@]}" "$ROOT/remote/server.js" "$TARGET:/opt/shar-remote/server.js.new"
  "${SSH[@]}" "$TARGET" "chmod 0644 /opt/shar-remote/server.js.new && mv /opt/shar-remote/server.js.new /opt/shar-remote/server.js"
  log "Waiting for updated Shar signaling service"
  local_ready=0
  for n in {1..20}; do
    if remote_body="$("${SSH[@]}" "$TARGET" "curl --fail --silent --show-error --connect-timeout 1 --max-time 2 http://127.0.0.1:8787/health" 2>/dev/null)"; then
      if printf '%s' "$remote_body" | grep -Fq '"service":"shar-remote"' && printf '%s' "$remote_body" | grep -Fq "\"version\":\"$EXPECTED_VERSION\""; then
        local_ready=1
        break
      fi
    fi
    sleep 1
  done
  if [[ "$local_ready" != 1 ]]; then
    log "Updated local service did not become ready; entering bootstrap/repair path for systemd diagnostics and recovery"
  else
    body="$(curl --fail --silent --show-error "$API_URL/health" 2>/dev/null || true)"
    if [[ -n "$body" ]] && printf '%s' "$body" | grep -Fq '"service":"shar-remote"' && printf '%s' "$body" | grep -Fq "\"version\":\"$EXPECTED_VERSION\""; then
      NEED_BOOTSTRAP=0
    else
      log "Local Shar service exists, but the public API is missing/stale; repairing nginx/bootstrap configuration"
    fi
  fi
fi

if [[ "$NEED_BOOTSTRAP" == 1 ]]; then
  log "Bootstrapping/repairing Shar signaling + TURN infrastructure"
  "${SCP[@]}" "$ROOT/remote/server.js" "$TARGET:/tmp/shar-remote-server.js"
  "${SCP[@]}" "$ROOT/scripts/remote_bootstrap.sh" "$TARGET:/tmp/shar-remote-bootstrap.sh"
  if ! "${SSH[@]}" "$TARGET" "chmod 700 /tmp/shar-remote-bootstrap.sh && /tmp/shar-remote-bootstrap.sh '$TURN_HOST' '$API_URL' '$RECEIVE_BASE' '$SHAR_REMOTE_USER' /tmp/shar-remote-server.js"; then
    printf '\nShar remote bootstrap/repair failed before publication.\n' >&2
    printf 'One-time manual fallback:\n  ssh -p %s %s\n  sudo /tmp/shar-remote-bootstrap.sh %q %q %q %q /tmp/shar-remote-server.js\n' "$SHAR_REMOTE_PORT" "$TARGET" "$TURN_HOST" "$API_URL" "$RECEIVE_BASE" "$SHAR_REMOTE_USER" >&2
    exit 1
  fi
fi

log "Verifying remote-share API"
for n in 1 2 3 4 5; do
  if body="$(curl --fail --silent --show-error "$API_URL/health" 2>/dev/null)"; then
    printf '%s\n' "$body"
    printf '%s' "$body" | grep -Fq "\"version\":\"$EXPECTED_VERSION\"" || fail "Public signaling is online but is not Shar v$EXPECTED_VERSION."
    printf '%s' "$body" | grep -q '"turn":true' || fail "Signaling is online but TURN is not configured."
    printf 'Remote sharing infrastructure verified: %s\n' "$API_URL"
    exit 0
  fi
  sleep 2
done
fail "Remote-share public health check failed: $API_URL/health"
