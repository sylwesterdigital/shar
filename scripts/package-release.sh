#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SHELL_BIN="${SHELL_BIN:-/bin/zsh}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$ROOT/archive}"
OUT="$ARCHIVE_DIR/LocalWebSharePrototype-v${VERSION}.zip"
TMP="$(mktemp -d /tmp/localwebshare-package.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $VERSION" >&2; exit 1; }
"$SHELL_BIN" "$ROOT/scripts/verify_repo.sh"
[[ -f "$ROOT/README.md" ]] || { echo "README.md missing" >&2; exit 1; }
[[ -f "$ROOT/CHANGELOG.md" ]] || { echo "CHANGELOG.md missing" >&2; exit 1; }
grep -Fq "$VERSION" "$ROOT/README.md" || { echo "README.md is not updated for $VERSION" >&2; exit 1; }
grep -Fq "## [$VERSION]" "$ROOT/CHANGELOG.md" || { echo "CHANGELOG.md is not updated for $VERSION" >&2; exit 1; }
grep -Eq '^/archive/$|^archive/$' "$ROOT/.gitignore" || { echo "archive/ must be Git ignored" >&2; exit 1; }

mkdir -p "$ARCHIVE_DIR" "$TMP/repo"
rsync \
  --archive \
  --checksum \
  --exclude='archive/' \
  --exclude='.watch-state/' \
  --exclude='build/' \
  --exclude='release/' \
  --exclude='android/.gradle/' \
  --exclude='android/**/build/' \
  --exclude='.git/' \
  --exclude='*.xcuserstate' \
  --exclude='xcuserdata/' \
  --exclude='.DS_Store' \
  "$ROOT/" "$TMP/repo/"

rm -f "$OUT"
( cd "$TMP/repo" && /usr/bin/zip -qry "$OUT" . )
echo "$OUT"
