#!/bin/zsh

echo "apply-release.sh is deprecated; using scripts/deploy.sh."
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/deploy.sh" "$@"
