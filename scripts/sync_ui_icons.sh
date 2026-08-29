#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ICON_DIR="${UI_ICON_DIR:-$ROOT/archive/icons}"
SWIFT_OUT="$ROOT/LocalWebShare/GeneratedUIIcons.swift"
JAVA_OUT="$ROOT/android/app/src/main/java/com/localwebshare/app/GeneratedUIIcons.java"

python3 - "$ICON_DIR" "$SWIFT_OUT" "$JAVA_OUT" <<'PY'
from pathlib import Path
import base64, json, sys
src=Path(sys.argv[1]); swift=Path(sys.argv[2]); java=Path(sys.argv[3])
wanted=['add','cancel','close','config','delete','download','file','more','pause','photo','play','preview','remove','share','sound-on','stop','video']
icons={}
if src.is_dir():
    for name in wanted:
        p=src/f'{name}.svg'
        if p.is_file():
            icons[name]=base64.b64encode(p.read_bytes()).decode('ascii')

swift_lines=['import Foundation','','enum GeneratedUIIcons {','    static let base64: [String: String] = [']
for k,v in sorted(icons.items()):
    swift_lines.append(f'        {json.dumps(k)}: {json.dumps(v)},')
swift_lines += ['    ]','}','']
swift.write_text('\n'.join(swift_lines))

java_lines=['package com.localwebshare.app;','','import java.util.Collections;','import java.util.HashMap;','import java.util.Map;','','final class GeneratedUIIcons {','    static final Map<String,String> BASE64;','    static {','        Map<String,String> m = new HashMap<>();']
for k,v in sorted(icons.items()):
    java_lines.append(f'        m.put({json.dumps(k)}, {json.dumps(v)});')
java_lines += ['        BASE64 = Collections.unmodifiableMap(m);','    }','}','']
java.write_text('\n'.join(java_lines))
print(f'UI icons: embedded {len(icons)} SVG(s) from {src}' if icons else f'UI icons: {src} not available; native/fallback icons will be used')
PY
