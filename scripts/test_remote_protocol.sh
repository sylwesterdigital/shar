#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
for t in node curl python3; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: Remote protocol test requires $t" >&2; exit 1; }; done
PORT="$((18000 + ($$ % 10000)))"
LOG="${TMPDIR:-/tmp}/shar-remote-protocol-${$}.log"
SECRET="shar-test-secret-${$}-not-production"
SHAR_REMOTE_PORT="$PORT" \
SHAR_RECEIVE_BASE='https://example.invalid/labs/shar/receive.html' \
SHAR_PUBLIC_API_BASE='https://example.invalid/api/shar/remote/v1' \
SHAR_TURN_HOST='turn.example.invalid' \
SHAR_TURN_PORT=3479 \
SHAR_TURN_SECRET="$SECRET" \
SHAR_MAX_ACTIVE_SESSIONS=10 \
SHAR_MAX_CREATES_PER_HOUR=30 \
node "$ROOT/remote/server.js" >"$LOG" 2>&1 &
PID=$!
cleanup(){ kill "$PID" >/dev/null 2>&1 || true; wait "$PID" >/dev/null 2>&1 || true; rm -f "$LOG"; }
trap cleanup EXIT INT TERM
n=0
until curl --fail --silent "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
  n=$((n+1)); [[ $n -lt 50 ]] || { cat "$LOG" >&2; echo 'ERROR: signaling smoke-test service did not start' >&2; exit 1; }; sleep 0.1
done
CREATE="$(curl --fail --silent --show-error -X POST -H 'Content-Type: application/json' \
  --data '{"files":[{"path":"folder/a.txt","size":5,"mime":"text/plain"}],"ttlSeconds":600}' \
  "http://127.0.0.1:$PORT/session")"
read -r SID HOST <<EOF
$(python3 - "$CREATE" <<'PY'
import json,sys
j=json.loads(sys.argv[1])
assert j['ok'] and j['files'][0]['path']=='folder/a.txt'
assert any(str(u).startswith('turn:turn.example.invalid:3479') for x in j['iceServers'] for u in x.get('urls',[]))
print(j['id'],j['hostSecret'])
PY
)
EOF
JOIN="$(curl --fail --silent --show-error -X POST -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$PORT/session/$SID/join")"
GUEST="$(python3 - "$JOIN" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert j['ok']; print(j['guestToken'])
PY
)"
curl --fail --silent --show-error -X POST -H "Authorization: Bearer $HOST" -H 'Content-Type: application/json' \
  --data '{"type":"offer","payload":{"sdp":"smoke-test"}}' "http://127.0.0.1:$PORT/session/$SID/signal" >/dev/null
POLL="$(curl --fail --silent --show-error -H "Authorization: Bearer $GUEST" "http://127.0.0.1:$PORT/session/$SID/signal?since=0")"
python3 - "$POLL" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert any(m['type']=='offer' and m['payload'].get('sdp')=='smoke-test' for m in j['messages'])
PY
BAD_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' \
  --data '{"files":[{"path":"../secret","size":1}]}' "http://127.0.0.1:$PORT/session")"
[[ "$BAD_CODE" == 400 ]] || { echo "ERROR: traversal manifest was not rejected (HTTP $BAD_CODE)" >&2; exit 1; }
BAD_COMPLETE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H "Authorization: Bearer $GUEST" -H 'Content-Type: application/json' --data '{"receivedBytes":4,"fileCount":1}' "http://127.0.0.1:$PORT/session/$SID/complete")"
[[ "$BAD_COMPLETE" == 409 ]] || { echo "ERROR: mismatched completion was not rejected (HTTP $BAD_COMPLETE)" >&2; exit 1; }
curl --fail --silent --show-error -X POST -H "Authorization: Bearer $GUEST" -H 'Content-Type: application/json' --data '{"receivedBytes":5,"fileCount":1}' \
  "http://127.0.0.1:$PORT/session/$SID/complete" >/dev/null
DONE="$(curl --fail --silent --show-error "http://127.0.0.1:$PORT/session/$SID")"
python3 - "$DONE" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert j['ok'] and j['completed'] is True and j.get('completedAt')
PY
REJOIN_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$PORT/session/$SID/join")"
[[ "$REJOIN_CODE" == 410 ]] || { echo "ERROR: completed one-time share allowed another receiver (HTTP $REJOIN_CODE)" >&2; exit 1; }
printf 'Shar remote signaling protocol smoke test passed.\n'
