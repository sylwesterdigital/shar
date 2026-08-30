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

read -r SALT VERIFIER GOOD_PROOF BAD_PROOF <<EOF
$(python3 - <<'PY'
import base64,hashlib,os
pin=b'483921'; salt=os.urandom(16); it=150000
enc=lambda b:base64.urlsafe_b64encode(b).decode().rstrip('=')
proof=hashlib.pbkdf2_hmac('sha256',pin,salt,it,32)
bad=hashlib.pbkdf2_hmac('sha256',b'000000',salt,it,32)
print(enc(salt),enc(proof),enc(proof),enc(bad))
PY
)
EOF
CREATE_BODY="$(python3 - "$SALT" "$VERIFIER" <<'PY'
import json,sys
print(json.dumps({
  'files':[{'path':'Encrypted item','size':5,'mime':'application/octet-stream'}],
  'ttlSeconds':600,'oneTime':True,'pinSalt':sys.argv[1],'pinVerifier':sys.argv[2],
  'pinIterations':150000,'approvalRequired':True,'e2ee':True,'privateMetadata':True
}))
PY
)"
CREATE="$(curl --fail --silent --show-error -X POST -H 'Content-Type: application/json' --data "$CREATE_BODY" "http://127.0.0.1:$PORT/session")"
read -r SID HOST <<EOF
$(python3 - "$CREATE" <<'PY'
import json,sys
j=json.loads(sys.argv[1])
assert j['ok'] and j['pinRequired'] and j['approvalRequired'] and j['e2eeRequired'] and j['privateMetadata']
assert j['files'][0]['path']=='Encrypted item 1'
assert 'receiverBase' in j and '#share=' not in j['receiverBase']
urls=[str(u) for x in j['iceServers'] for u in x.get('urls',[])]
assert 'stun:turn.example.invalid:3479' in urls
assert any(u.startswith('turn:turn.example.invalid:3479') for u in urls)
assert not any('google' in u.lower() for u in urls)
print(j['id'],j['hostSecret'])
PY
)
EOF

BAD_JOIN_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' --data "{\"pinProof\":\"$BAD_PROOF\"}" "http://127.0.0.1:$PORT/session/$SID/join")"
[[ "$BAD_JOIN_CODE" == 401 ]] || { echo "ERROR: incorrect PIN proof was not rejected (HTTP $BAD_JOIN_CODE)" >&2; exit 1; }

JOIN="$(curl --fail --silent --show-error -X POST -H 'Content-Type: application/json' --data "{\"pinProof\":\"$GOOD_PROOF\"}" "http://127.0.0.1:$PORT/session/$SID/join")"
read -r REQUEST APPROVAL_TOKEN <<EOF
$(python3 - "$JOIN" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert j['ok'] and j['pending'] and not j.get('guestToken'); print(j['requestId'],j['approvalToken'])
PY
)
EOF

HOST_POLL="$(curl --fail --silent --show-error -H "Authorization: Bearer $HOST" "http://127.0.0.1:$PORT/session/$SID/signal?since=0")"
python3 - "$HOST_POLL" "$REQUEST" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); req=sys.argv[2]
assert any(m['type']=='join-request' and m.get('payload',{}).get('requestId')==req for m in j['messages'])
PY

PENDING="$(curl --fail --silent --show-error -H "Authorization: Bearer $APPROVAL_TOKEN" "http://127.0.0.1:$PORT/session/$SID/approval?request=$REQUEST")"
python3 - "$PENDING" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert j['ok'] and j['approved'] is False and not j.get('guestToken')
PY

curl --fail --silent --show-error -X POST -H "Authorization: Bearer $HOST" -H 'Content-Type: application/json' \
  --data "{\"requestId\":\"$REQUEST\",\"approved\":true}" "http://127.0.0.1:$PORT/session/$SID/approve" >/dev/null
APPROVED="$(curl --fail --silent --show-error -H "Authorization: Bearer $APPROVAL_TOKEN" "http://127.0.0.1:$PORT/session/$SID/approval?request=$REQUEST")"
GUEST="$(python3 - "$APPROVED" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert j['ok'] and j['approved'] and j.get('guestToken'); print(j['guestToken'])
PY
)"

curl --fail --silent --show-error -X POST -H "Authorization: Bearer $HOST" -H 'Content-Type: application/json' \
  --data '{"type":"offer","payload":{"sdp":"secure-smoke-test"}}' "http://127.0.0.1:$PORT/session/$SID/signal" >/dev/null
POLL="$(curl --fail --silent --show-error -H "Authorization: Bearer $GUEST" "http://127.0.0.1:$PORT/session/$SID/signal?since=0")"
python3 - "$POLL" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert any(m['type']=='offer' and m['payload'].get('sdp')=='secure-smoke-test' for m in j['messages'])
PY

BAD_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{"files":[{"path":"../secret","size":1}]}' "http://127.0.0.1:$PORT/session")"
[[ "$BAD_CODE" == 400 ]] || { echo "ERROR: traversal manifest was not rejected (HTTP $BAD_CODE)" >&2; exit 1; }
BAD_COMPLETE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H "Authorization: Bearer $GUEST" -H 'Content-Type: application/json' --data '{"receivedBytes":4,"fileCount":1}' "http://127.0.0.1:$PORT/session/$SID/complete")"
[[ "$BAD_COMPLETE" == 409 ]] || { echo "ERROR: mismatched completion was not rejected (HTTP $BAD_COMPLETE)" >&2; exit 1; }
curl --fail --silent --show-error -X POST -H "Authorization: Bearer $GUEST" -H 'Content-Type: application/json' --data '{"receivedBytes":5,"fileCount":1}' "http://127.0.0.1:$PORT/session/$SID/complete" >/dev/null
DONE="$(curl --fail --silent --show-error "http://127.0.0.1:$PORT/session/$SID")"
python3 - "$DONE" <<'PY'
import json,sys
j=json.loads(sys.argv[1]); assert j['ok'] and j['completed'] is True and j.get('completedAt')
PY
REJOIN_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' --data "{\"pinProof\":\"$GOOD_PROOF\"}" "http://127.0.0.1:$PORT/session/$SID/join")"
[[ "$REJOIN_CODE" == 410 ]] || { echo "ERROR: completed one-time share allowed another receiver (HTTP $REJOIN_CODE)" >&2; exit 1; }
printf 'Shar secure remote signaling protocol smoke test passed.\n'
