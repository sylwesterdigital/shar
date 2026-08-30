#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo 'ERROR: Remote crypto test requires node' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'ERROR: Remote crypto test requires python3' >&2; exit 1; }
TMP="${TMPDIR:-/tmp}/shar-remote-crypto-${$}.js"
trap 'rm -f "$TMP"' EXIT INT TERM
python3 - "$ROOT/homepage/receive.html" "$TMP" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
cls=re.search(r'class Sha256\{.*?\}\nSha256\.K=new Uint32Array\(\[.*?\]\);',s,re.S)
if not cls: raise SystemExit('receiver Sha256 implementation missing')
code=cls.group(0)+r'''
const te=new TextEncoder();
const vectors=[
 ['', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
 ['abc','ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'],
 ['hello world','b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9']
];
for(const [text,expected] of vectors){const h=new Sha256();const u=te.encode(text);h.update(u.subarray(0,Math.min(1,u.length)));h.update(u.subarray(Math.min(1,u.length)));if(h.hex()!==expected)throw Error('SHA-256 vector failed: '+text)}
(async()=>{const raw=crypto.getRandomValues(new Uint8Array(32)),key=await crypto.subtle.importKey('raw',raw,{name:'AES-GCM'},false,['encrypt','decrypt']),iv=crypto.getRandomValues(new Uint8Array(12)),plain=te.encode('Shar secure transfer');const c=await crypto.subtle.encrypt({name:'AES-GCM',iv},key,plain),p=await crypto.subtle.decrypt({name:'AES-GCM',iv},key,c);if(new TextDecoder().decode(p)!=='Shar secure transfer')throw Error('AES-GCM roundtrip failed');console.log('Shar remote crypto primitives test passed.')})().catch(e=>{console.error(e);process.exit(1)});
'''
Path(sys.argv[2]).write_text(code)
PY
node "$TMP"
grep -Fq "location.hash" "$ROOT/homepage/receive.html" || { echo 'ERROR: secure receiver does not read capability from URL fragment' >&2; exit 1; }
grep -Fq "name:'AES-GCM'" "$ROOT/homepage/receive.html" || { echo 'ERROR: AES-GCM receiver path missing' >&2; exit 1; }
grep -Fq "SHA-256 verification failed" "$ROOT/homepage/receive.html" || { echo 'ERROR: receiver SHA-256 verification missing' >&2; exit 1; }
! grep -RFiq 'stun.l.google.com' "$ROOT/LocalWebShare" "$ROOT/remote" "$ROOT/homepage" "$ROOT/android/app/src/main/java" || { echo 'ERROR: Google STUN runtime dependency reappeared' >&2; exit 1; }
