#!/bin/zsh
# Foreground release entry point used by build-watch.sh.
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec "$ROOT/scripts/release_and_deploy.sh" "$@"
