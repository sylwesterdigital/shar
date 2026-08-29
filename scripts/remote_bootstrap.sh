#!/usr/bin/env bash
# Runs on the Ubuntu/Debian deployment host. Invoked by deploy_remote_share.sh.
set -Eeuo pipefail
TURN_HOST="${1:?TURN host required}"
PUBLIC_API_BASE="${2:-https://mojoworks.xyz/api/shar/remote/v1}"
RECEIVE_BASE="${3:-https://mojoworks.xyz/labs/shar/receive.html}"
DEPLOY_USER="${4:-$(id -un)}"
SOURCE="${5:-/tmp/shar-remote-server.js}"
PORT=8787
TURN_PORT=3479
RELAY_MIN=49210
RELAY_MAX=49250
log(){ printf '\n==> %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f "$SOURCE" ]] || die "Remote server source is missing: $SOURCE"
[[ -r /etc/os-release ]] || die "Cannot identify Linux distribution."
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "Automatic Shar remote bootstrap currently supports Ubuntu/Debian (found ${ID:-unknown}).";; esac
sudo -n true 2>/dev/null || die "Passwordless sudo is required for the one-time Shar remote bootstrap. Run this uploaded script once over SSH with sudo, then future code updates can be non-root."

need=()
command -v node >/dev/null 2>&1 || need+=(nodejs)
command -v qrencode >/dev/null 2>&1 || need+=(qrencode)
command -v turnserver >/dev/null 2>&1 || need+=(coturn)
command -v nginx >/dev/null 2>&1 || need+=(nginx)
command -v curl >/dev/null 2>&1 || need+=(curl)
command -v openssl >/dev/null 2>&1 || need+=(openssl)
command -v python3 >/dev/null 2>&1 || need+=(python3)
if ((${#need[@]})); then
  log "Installing missing packages: ${need[*]}"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
fi
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
(( NODE_MAJOR >= 16 )) || die "Node.js 16+ is required (found $(node --version))."

log "Installing Shar remote signaling service"
# An already-active path unit can observe server.js replacement and asynchronously
# restart the service while bootstrap is also restarting it. Stop the watcher first
# and re-enable it only after the new signaling process is confirmed healthy.
sudo systemctl stop shar-remote.path 2>/dev/null || true
sudo install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/shar-remote
sudo install -m 0644 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SOURCE" /opt/shar-remote/server.js
if ! id shar-remote >/dev/null 2>&1; then sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin shar-remote; fi

TURN_SECRET=""
if sudo test -f /etc/shar-remote.env; then
  TURN_SECRET="$(sudo sed -n 's/^SHAR_TURN_SECRET=//p' /etc/shar-remote.env | head -n1 || true)"
fi
[[ -n "$TURN_SECRET" ]] || TURN_SECRET="$(openssl rand -hex 32)"
TMP_ENV="$(mktemp)"; trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<ENV
SHAR_REMOTE_PORT=$PORT
SHAR_RECEIVE_BASE=$RECEIVE_BASE
SHAR_PUBLIC_API_BASE=$PUBLIC_API_BASE
SHAR_TURN_HOST=$TURN_HOST
SHAR_TURN_PORT=$TURN_PORT
SHAR_TURN_SECRET=$TURN_SECRET
SHAR_SESSION_TTL=1800
SHAR_SESSION_MAX_TTL=3600
SHAR_MAX_ACTIVE_SESSIONS=1000
SHAR_MAX_CREATES_PER_HOUR=30
ENV
sudo install -m 0600 -o root -g root "$TMP_ENV" /etc/shar-remote.env

log "Configuring dedicated Shar TURN relay on $TURN_HOST:$TURN_PORT"
TMP_TURN="$(mktemp)"
cat > "$TMP_TURN" <<TURN
listening-port=$TURN_PORT
min-port=$RELAY_MIN
max-port=$RELAY_MAX
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$TURN_HOST
stale-nonce
no-multicast-peers
no-cli
no-tls
no-dtls
TURN
sudo install -m 0600 -o root -g root "$TMP_TURN" /etc/shar-turnserver.conf
rm -f "$TMP_TURN"
cat > /tmp/shar-coturn.service <<UNIT
[Unit]
Description=Shar dedicated TURN relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v turnserver) -c /etc/shar-turnserver.conf
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
sudo install -m 0644 /tmp/shar-coturn.service /etc/systemd/system/shar-coturn.service
rm -f /tmp/shar-coturn.service

cat > /tmp/shar-remote.service <<UNIT
[Unit]
Description=Shar WebRTC signaling service
After=network-online.target shar-coturn.service
Wants=network-online.target

[Service]
Type=simple
User=shar-remote
Group=shar-remote
EnvironmentFile=/etc/shar-remote.env
ExecStart=$(command -v node) /opt/shar-remote/server.js
Restart=on-failure
RestartSec=2
ExecStartPre=$(command -v node) --check /opt/shar-remote/server.js
TimeoutStartSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
sudo install -m 0644 /tmp/shar-remote.service /etc/systemd/system/shar-remote.service
rm -f /tmp/shar-remote.service

# Let future ZIP deployments replace server.js without requiring sudo. A system path unit restarts it.
cat > /tmp/shar-remote-restart.service <<'UNIT'
[Unit]
Description=Restart Shar remote after source update

[Service]
Type=oneshot
ExecStart=/bin/systemctl try-restart shar-remote.service
UNIT
cat > /tmp/shar-remote.path <<'UNIT'
[Unit]
Description=Watch Shar remote source for updates

[Path]
PathChanged=/opt/shar-remote/server.js
Unit=shar-remote-restart.service

[Install]
WantedBy=multi-user.target
UNIT
sudo install -m 0644 /tmp/shar-remote-restart.service /etc/systemd/system/shar-remote-restart.service
sudo install -m 0644 /tmp/shar-remote.path /etc/systemd/system/shar-remote.path
rm -f /tmp/shar-remote-restart.service /tmp/shar-remote.path

log "Configuring nginx API proxy safely"
PUBLIC_HOST="$(python3 - "$PUBLIC_API_BASE" <<'PYHOST'
from urllib.parse import urlsplit
import sys
u=urlsplit(sys.argv[1])
if u.scheme != 'https' or not u.hostname:
    raise SystemExit('Shar public API must be an https URL with a hostname')
print(u.hostname)
PYHOST
)"
PUBLIC_PORT="$(python3 - "$PUBLIC_API_BASE" <<'PYPORT'
from urllib.parse import urlsplit
import sys
u=urlsplit(sys.argv[1])
print(u.port or 443)
PYPORT
)"
sudo install -d -m 0755 /etc/nginx/snippets
cat > /tmp/shar-remote-nginx.conf <<'NGINX'
location ^~ /api/shar/remote/v1/ {
    proxy_pass http://127.0.0.1:8787/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 512k;
    proxy_connect_timeout 5s;
    proxy_read_timeout 35s;
    add_header Cache-Control "no-store" always;
}
NGINX
sudo install -m 0644 /tmp/shar-remote-nginx.conf /etc/nginx/snippets/shar-remote.conf
rm -f /tmp/shar-remote-nginx.conf /tmp/shar-nginx-rollback /tmp/shar-nginx-effective.txt /tmp/shar-nginx-effective.err

# Use nginx's own expanded configuration as the source of truth. Complex hosts can
# contain duplicate server_name blocks, symlinks, or listeners bound to a specific
# public address. Directory iteration and a forced 127.0.0.1 SNI probe are not
# authoritative in those layouts.
if ! sudo nginx -T >/tmp/shar-nginx-effective.txt 2>/tmp/shar-nginx-effective.err; then
  cat /tmp/shar-nginx-effective.err >&2 || true
  die "Could not inspect the effective nginx configuration."
fi

sudo env SHAR_NGINX_HOST="$PUBLIC_HOST" SHAR_NGINX_DUMP=/tmp/shar-nginx-effective.txt python3 - <<'PYNGINX'
from pathlib import Path
import os, re, shutil, time
host=os.environ['SHAR_NGINX_HOST'].strip().lower().rstrip('.')
dump=Path(os.environ['SHAR_NGINX_DUMP']).read_text(errors='replace')
include_path='/etc/nginx/snippets/shar-remote.conf'
include_line='    include /etc/nginx/snippets/shar-remote.conf;\n'
manifest=Path('/tmp/shar-nginx-rollback')
stamp=int(time.time())

# nginx -T emits each loaded file prefixed with a source marker. Preserve that
# load-set instead of guessing which files under sites-enabled/conf.d matter.
source_paths=[]; seen=set()
for m in re.finditer(r'(?m)^# configuration file (/.+?):\s*$', dump):
    raw=Path(m.group(1))
    try: p=raw.resolve()
    except Exception: p=raw
    key=str(p)
    if key in seen or not p.exists() or not p.is_file():
        continue
    seen.add(key); source_paths.append(p)

def blocks(text):
    out=[]
    for m in re.finditer(r'(?m)^\s*server\s*\{', text):
        depth=0; quote=None; escaped=False; end=None
        for i in range(m.end()-1,len(text)):
            c=text[i]
            if quote:
                if escaped: escaped=False
                elif c=='\\': escaped=True
                elif c==quote: quote=None
                continue
            if c in ('\"', "'"): quote=c; continue
            if c=='#':
                # Skip comment content when counting braces.
                j=text.find('\n',i)
                if j<0: break
                continue
            if c=='{': depth+=1
            elif c=='}':
                depth-=1
                if depth==0: end=i+1; break
        if end: out.append((m.start(),end))
    return out

def names(block):
    values=[]
    for m in re.finditer(r'(?m)^\s*server_name\s+([^;]+);', block):
        values += [x.strip().lower().rstrip('.') for x in m.group(1).split()]
    return values

def is_tls(block):
    # Accept the ordinary 443 listeners as well as explicit "ssl" listeners.
    return bool(re.search(r'(?m)^\s*listen\s+[^;]*(?:\b443\b|\bssl\b)[^;]*;', block))

def backup(p):
    # One rollback copy per source file, even when multiple server blocks change.
    if manifest.exists():
        for line in manifest.read_text(errors='replace').splitlines():
            if '\t' in line and line.split('\t',1)[0] == str(p):
                return
    b=p.with_name(p.name+f'.shar-backup-{stamp}')
    n=1
    while b.exists():
        n+=1; b=p.with_name(p.name+f'.shar-backup-{stamp}-{n}')
    shutil.copy2(p,b)
    with manifest.open('a') as f: f.write(str(p)+'\t'+str(b)+'\n')

exact_blocks=0; exact_files=[]
for p in source_paths:
    try: original=p.read_text()
    except Exception: continue
    text=original
    edits=[]
    for start,end in blocks(text):
        block=text[start:end]
        exact=(host in names(block) and is_tls(block))
        has=(include_path in block)
        if exact:
            exact_blocks += 1
            if str(p) not in exact_files: exact_files.append(str(p))
            if not has:
                close=end-1
                replacement=block[:close-start]+include_line+block[close-start:]
                edits.append((start,end,replacement,'add'))
        elif has:
            cleaned=re.sub(r'(?m)^\s*include\s+/etc/nginx/snippets/shar-remote\.conf;\s*\n?', '', block)
            if cleaned != block: edits.append((start,end,cleaned,'remove'))
    if not edits: continue
    backup(p)
    for start,end,replacement,kind in reversed(edits):
        text=text[:start]+replacement+text[end:]
    p.write_text(text)
    adds=sum(1 for *_,k in edits if k=='add')
    removes=sum(1 for *_,k in edits if k=='remove')
    if adds: print(f'Added Shar API include to {adds} exact {host} TLS block(s) in {p}')
    if removes: print(f'Removed stale Shar include from {removes} non-{host} block(s) in {p}')

if exact_blocks < 1:
    raise SystemExit(f'Could not locate any loaded HTTPS nginx server block with server_name exactly {host}.')
print(f'Loaded nginx configuration contains {exact_blocks} exact {host} TLS block(s) across {len(exact_files)} file(s).')
PYNGINX

restore_nginx(){
  if [[ -f /tmp/shar-nginx-rollback ]]; then
    while IFS=$'\t' read -r target backup; do
      [[ -n "$target" && -n "$backup" && -f "$backup" ]] && sudo cp -p "$backup" "$target"
    done < /tmp/shar-nginx-rollback
  fi
}
if ! sudo nginx -t; then
  restore_nginx
  sudo nginx -t >/dev/null 2>&1 || true
  die "nginx validation failed; the previous nginx configuration was restored automatically."
fi

log "Starting services"
sudo systemctl daemon-reload
sudo systemctl enable shar-coturn.service shar-remote.service shar-remote.path >/dev/null
sudo systemctl restart shar-coturn.service

# Validate exactly what systemd is about to run before changing public routing.
sudo test -r /opt/shar-remote/server.js || die "Installed Shar signaling source is not readable."
sudo node --check /opt/shar-remote/server.js >/dev/null || die "Installed Shar signaling source failed node --check."
sudo test -s /etc/shar-remote.env || die "Shar signaling environment file is missing/empty."
sudo grep -q '^SHAR_REMOTE_PORT=' /etc/shar-remote.env || die "Shar signaling environment is missing SHAR_REMOTE_PORT."
sudo grep -q '^SHAR_TURN_SECRET=' /etc/shar-remote.env || die "Shar signaling environment is missing SHAR_TURN_SECRET."

sudo systemctl restart shar-remote.service

log "Waiting for direct Shar signaling upstream"
UPSTREAM_HEALTH=""
SERVICE_READY=0
for n in $(seq 1 30); do
  if sudo systemctl --quiet is-active shar-remote.service; then
    UPSTREAM_HEALTH="$(curl --fail --silent --show-error --connect-timeout 1 --max-time 2 http://127.0.0.1:$PORT/health 2>/dev/null || true)"
    if [[ -n "$UPSTREAM_HEALTH" ]] && printf '%s' "$UPSTREAM_HEALTH" | grep -Fq '"service":"shar-remote"'; then
      SERVICE_READY=1
      break
    fi
  fi
  sleep 1
done
if [[ "$SERVICE_READY" != 1 ]]; then
  printf '\nShar signaling startup diagnostics:\n' >&2
  printf '%s\n' '--- systemctl status ---' >&2
  sudo systemctl status shar-remote.service --no-pager -l >&2 2>/dev/null || true
  printf '%s\n' '--- journalctl (last 100) ---' >&2
  sudo journalctl -u shar-remote.service -n 100 --no-pager >&2 2>/dev/null || true
  printf '%s\n' '--- listeners on signaling port ---' >&2
  sudo ss -lntp 2>/dev/null | grep -E ":$PORT\\b" >&2 || true
  printf '%s\n' '--- installed source syntax ---' >&2
  sudo node --check /opt/shar-remote/server.js >&2 2>/dev/null || true
  restore_nginx
  sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx || true
  die "Shar signaling service did not become ready on 127.0.0.1:$PORT within 30 seconds; nginx changes were rolled back."
fi
printf '%s\n' "$UPSTREAM_HEALTH"
# Start the source watcher only after bootstrap-owned service restart is complete,
# preventing a second asynchronous restart from racing the health/public probes.
sudo systemctl enable --now shar-remote.path >/dev/null
sudo systemctl reload nginx
UPSTREAM_VERSION="$(printf '%s' "$UPSTREAM_HEALTH" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
[[ -n "$UPSTREAM_VERSION" ]] || die "Shar upstream health response did not contain a version."

log "Verifying public HTTPS routing (authoritative)"
PUBLIC_OK=0
PUBLIC_STATUS=""
for n in 1 2 3 4 5 6 7 8; do
  PROBE_URL="$PUBLIC_API_BASE/health?deploy=$(date +%s)-$n"
  PUBLIC_STATUS="$(curl --silent --show-error --connect-timeout 5 --max-time 12 \
    -H 'Cache-Control: no-cache' -D /tmp/shar-public-health.headers \
    -o /tmp/shar-public-health.body -w '%{http_code}' "$PROBE_URL" 2>/tmp/shar-public-health.error || true)"
  BODY="$(cat /tmp/shar-public-health.body 2>/dev/null || true)"
  if [[ "$PUBLIC_STATUS" == 200 ]] \
     && printf '%s' "$BODY" | grep -Fq '"service":"shar-remote"' \
     && printf '%s' "$BODY" | grep -Fq "\"version\":\"$UPSTREAM_VERSION\""; then
    PUBLIC_OK=1
    printf '%s\n' "$BODY"
    break
  fi
  printf 'Public API attempt %d/8 returned HTTP %s; retrying...\n' "$n" "${PUBLIC_STATUS:-000}" >&2
  sleep 3
done
if [[ "$PUBLIC_OK" != 1 ]]; then
  printf '\nShar public-route diagnostics before rollback:\n' >&2
  printf '  URL: %s/health\n  Last HTTP status: %s\n' "$PUBLIC_API_BASE" "${PUBLIC_STATUS:-000}" >&2
  [[ -s /tmp/shar-public-health.headers ]] && { printf '%s\n' '--- response headers ---' >&2; cat /tmp/shar-public-health.headers >&2; }
  [[ -s /tmp/shar-public-health.body ]] && { printf '%s\n' '--- response body ---' >&2; head -c 4096 /tmp/shar-public-health.body >&2; printf '\n' >&2; }
  [[ -s /tmp/shar-public-health.error ]] && { printf '%s\n' '--- curl error ---' >&2; cat /tmp/shar-public-health.error >&2; }
  printf '%s\n' '--- loaded Shar nginx includes ---' >&2
  sudo nginx -T 2>&1 | grep -n -B8 -A8 'shar-remote\.conf' >&2 || true
  printf '%s\n' '--- DNS addresses ---' >&2
  getent ahostsv4 "$PUBLIC_HOST" >&2 2>/dev/null || true
  restore_nginx
  sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx || true
  rm -f /tmp/shar-public-health.headers /tmp/shar-public-health.body /tmp/shar-public-health.error /tmp/shar-nginx-rollback
  die "Public Shar API did not route after nginx reload; the previous nginx configuration was restored automatically."
fi
rm -f /tmp/shar-public-health.headers /tmp/shar-public-health.body /tmp/shar-public-health.error

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "Opening dedicated TURN ports in UFW"
  sudo ufw allow "$TURN_PORT/tcp" comment 'Shar TURN TCP' >/dev/null
  sudo ufw allow "$TURN_PORT/udp" comment 'Shar TURN UDP' >/dev/null
  sudo ufw allow "$RELAY_MIN:$RELAY_MAX/tcp" comment 'Shar TURN relay TCP' >/dev/null
  sudo ufw allow "$RELAY_MIN:$RELAY_MAX/udp" comment 'Shar TURN relay UDP' >/dev/null
fi

log "Verifying local services"
curl --fail --silent --show-error http://127.0.0.1:$PORT/health
printf '\n'
sudo systemctl --quiet is-active shar-coturn.service || die "Shar TURN service is not active."
sudo systemctl --quiet is-active shar-remote.service || die "Shar signaling service is not active."
ss -lntup 2>/dev/null | grep -E ":$TURN_PORT\\b" >/dev/null || die "TURN port $TURN_PORT is not listening."

rm -f /tmp/shar-nginx-rollback
printf 'Shar remote infrastructure is ready. TURN: %s:%s; API: %s\n' "$TURN_HOST" "$TURN_PORT" "$PUBLIC_API_BASE"
