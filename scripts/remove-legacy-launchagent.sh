#!/bin/zsh

# Idempotent cleanup of the obsolete LocalWebShare LaunchAgent used by <= 1.3.3.

LABEL="com.localwebshare.build-watch"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "Removing obsolete LaunchAgent: $LABEL"
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || \
        launchctl remove "$LABEL" >/dev/null 2>&1 || true
fi

if [[ -f "$PLIST" ]]; then
    echo "Deleting obsolete LaunchAgent plist: $PLIST"
    rm -f "$PLIST"
fi

rm -f "$REPO_DIR/bin/build-watch.sh" 2>/dev/null || true
rmdir "$REPO_DIR/bin" 2>/dev/null || true

exit 0
