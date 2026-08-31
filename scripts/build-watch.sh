#!/bin/zsh

# Foreground release watcher for LocalWebShare.
# Runs visibly in the current Terminal and stops with Ctrl+C.

set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/terminal_style.sh"
REPO_DIR="${REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
WATCH_DIR="${WATCH_DIR:-$REPO_DIR/archive}"
ZIP_PATTERN="LocalWebSharePrototype-v*.zip"
STATE_DIR="${STATE_DIR:-$REPO_DIR/.watch-state}"
STATE_FILE="$STATE_DIR/last-processed-release"
LOCK_DIR="/tmp/localwebshare-watch.lock"
POLL_SECONDS="${POLL_SECONDS:-5}"
STABLE_SECONDS="${STABLE_SECONDS:-3}"
ZSH_BIN="${ZSH_BIN:-/bin/zsh}"

mkdir -p "$WATCH_DIR" "$STATE_DIR"

cleanup() {
    rm -rf "$LOCK_DIR"
}

trap 'cleanup; echo; shar_warn "LocalWebShare watcher stopped."; exit 130' INT TERM
trap cleanup EXIT

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    shar_error "LocalWebShare watcher is already running."
    exit 1
fi

log() {
    printf '%b[%s]%b %s\n' "$SHAR_C_MUTED" "$(date '+%H:%M:%S')" "$SHAR_C_RESET" "$*"
}

valid_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_gt() {
    local left="$1" right="$2"
    python3 - "$left" "$right" <<'PYVER'
import sys
a=tuple(map(int, sys.argv[1].split('.')))
b=tuple(map(int, sys.argv[2].split('.')))
raise SystemExit(0 if a > b else 1)
PYVER
}

current_repo_version() {
    if [[ -f "$REPO_DIR/VERSION" ]]; then
        local v
        v="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
        if valid_version "$v"; then
            printf '%s\n' "$v"
            return 0
        fi
    fi
    printf '0.0.0\n'
}

get_signature() {
    local file="$1"
    if stat -f '%N|%m|%z' "$file" >/dev/null 2>&1; then
        stat -f '%N|%m|%z' "$file"
    else
        printf '%s|' "$file"
        stat -c '%Y|%s' "$file"
    fi
}

get_latest_zip() {
    local file name version best_file="" best_version=""
    for file in "$WATCH_DIR"/LocalWebSharePrototype-v*.zip; do
        [[ -f "$file" ]] || continue
        name="${file##*/}"
        version="${name#LocalWebSharePrototype-v}"
        version="${version%.zip}"
        valid_version "$version" || continue
        if [[ -z "$best_version" ]] || version_gt "$version" "$best_version"; then
            best_version="$version"
            best_file="$file"
        fi
    done
    [[ -n "$best_file" ]] && printf '%s\n' "$best_file"
}

file_stability_signature() {
    local file="$1"
    if stat -f '%m|%z' "$file" >/dev/null 2>&1; then
        stat -f '%m|%z' "$file"
    else
        stat -c '%Y|%s' "$file" 2>/dev/null || true
    fi
}

wait_until_stable() {
    local file="$1"
    local sig1 sig2

    while true; do
        sig1="$(file_stability_signature "$file")"
        sleep "$STABLE_SECONDS"
        sig2="$(file_stability_signature "$file")"

        if [[ -n "$sig1" && "$sig1" == "$sig2" ]]; then
            return 0
        fi

        printf '%b[%s]%b %b%s%b\n' "$SHAR_C_MUTED" "$(date '+%H:%M:%S')" "$SHAR_C_RESET" "$SHAR_C_YELLOW" "ZIP is still being downloaded/written..." "$SHAR_C_RESET"
    done
}

resolve_source_dir() {
    local tmp_dir="$1"
    local top_count only_item

    rm -rf "$tmp_dir/__MACOSX"

    top_count="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
    if [[ "$top_count" == "1" ]]; then
        only_item="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -print | head -n 1)"
        if [[ -d "$only_item" ]]; then
            printf '%s\n' "$only_item"
            return 0
        fi
    fi

    printf '%s\n' "$tmp_dir"
}

already_processed() {
    local signature="$1"
    [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE")" == "$signature" ]]
}

mark_processed() {
    local signature="$1"
    printf '%s\n' "$signature" > "$STATE_FILE"
}

validate_release() {
    local source_dir="$1"
    local zip_file="$2"
    local version zip_name zip_version

    [[ -f "$source_dir/VERSION" ]] || {
        shar_error "Release ZIP does not contain VERSION."
        return 1
    }
    [[ -f "$source_dir/scripts/deploy.sh" ]] || {
        shar_error "Release ZIP does not contain scripts/deploy.sh."
        return 1
    }
    [[ -f "$source_dir/scripts/app_build.sh" ]] || {
        shar_error "Release ZIP does not contain scripts/app_build.sh."
        return 1
    }
    [[ -d "$source_dir/LocalWebShare.xcodeproj" ]] || {
        shar_error "Release ZIP does not contain LocalWebShare.xcodeproj."
        return 1
    }

    version="$(tr -d '[:space:]' < "$source_dir/VERSION")"
    zip_name="${zip_file##*/}"
    zip_version="${zip_name#LocalWebSharePrototype-v}"
    zip_version="${zip_version%.zip}"

    if [[ "$version" != "$zip_version" ]]; then
        shar_error "ZIP filename says v$zip_version but VERSION says v$version."
        return 1
    fi

    printf '%s\n' "$version"
}

process_zip() {
    local zip_file="$1"
    local signature tmp_dir source_dir version

    signature="$(get_signature "$zip_file")"
    if already_processed "$signature"; then
        return 0
    fi

    shar_banner_info "New LocalWebShare package detected"
    printf '%b%s%b\n' "$SHAR_C_CYAN" "$zip_file" "$SHAR_C_RESET"

    wait_until_stable "$zip_file"
    signature="$(get_signature "$zip_file")"

    tmp_dir="$(mktemp -d /tmp/localwebshare-update.XXXXXX)"

    log "Unpacking release package..."
    if ! unzip -q "$zip_file" -d "$tmp_dir"; then
        shar_error "Could not unzip release package:"
        echo "$zip_file"
        rm -rf "$tmp_dir"
        return 1
    fi

    source_dir="$(resolve_source_dir "$tmp_dir")"
    if ! version="$(validate_release "$source_dir" "$zip_file")"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    current_version="$(current_repo_version)"
    if version_gt "$current_version" "$version"; then
        log "Ignoring older v$version because repository is already v$current_version."
        mark_processed "$signature"
        rm -rf "$tmp_dir"
        return 0
    fi

    if [[ "$version" == "$current_version" ]]; then
        log "Retrying deployment for current v$version because this ZIP has a new signature."
    else
        log "Release version: v$version (current v$current_version)"
    fi
    log "Synchronising repository"
    shar_field "FROM:" "$source_dir"
    shar_field "TO:" "$REPO_DIR"

    # The release ZIP is authoritative for repository source files.
    # Local runtime data and Git metadata are always preserved.
    if ! rsync \
        --archive \
        --checksum \
        --delete \
        --exclude='.git/' \
        --exclude='archive/' \
        --exclude='.watch-state/' \
        --exclude='build/' \
        --exclude='xcuserdata/' \
        "$source_dir/" \
        "$REPO_DIR/"; then
        shar_error "Repository rsync failed."
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"

    # Match the existing watcher behaviour: mark the package before deployment
    # so a failed build does not automatically rerun every five seconds.
    mark_processed "$signature"

    echo
    shar_success "Repository files updated"
    log "Running deployment"
    shar_field "DIR:" "$REPO_DIR"
    echo

    cd "$REPO_DIR" || return 1

    printf '%b>>>%b %s\n' "$SHAR_C_MAGENTA" "$SHAR_C_RESET" "./scripts/deploy.sh"
    ./scripts/deploy.sh || return 1

    shar_banner_success "LOCALWEBSHARE UPDATE + DEPLOYMENT COMPLETED SUCCESSFULLY"

    # The release may contain an updated watcher. Reload it after success.
    log "Reloading watcher from the updated repository..."
    cleanup
    exec "$ZSH_BIN" "$REPO_DIR/scripts/build-watch.sh"
}

report_failure() {
    shar_banner_error "LOCALWEBSHARE UPDATE FAILED"
    printf '%b%s%b\n' "$SHAR_C_YELLOW" "The failed ZIP will not auto-run again every five seconds." "$SHAR_C_RESET" >&2
    printf '%s\n' "Fix the problem, then touch/re-download this ZIP to retry, or save a newer release ZIP." >&2
}

# One-time cleanup for the obsolete LaunchAgent design.
if [[ -x "$REPO_DIR/scripts/remove-legacy-launchagent.sh" ]]; then
    "$ZSH_BIN" "$REPO_DIR/scripts/remove-legacy-launchagent.sh" || true
fi

shar_banner_info "Shar update watcher started"
shar_field "Watching:" "$WATCH_DIR/$ZIP_PATTERN"
shar_field "Repository:" "$REPO_DIR"
shar_field "Deploy:" "$REPO_DIR/scripts/deploy.sh"
shar_field "Git remote:" "git@github.com:sylwesterdigital/shar.git"
shar_field "Poll:" "every ${POLL_SECONDS}s"
shar_field "Stop:" "Ctrl+C"
echo

while true; do
    latest_zip="$(get_latest_zip)"
    if [[ -n "$latest_zip" && -f "$latest_zip" ]]; then
        process_zip "$latest_zip" || report_failure
    fi

    printf '\r%b[%s]%b %b● watching%b %s %b— Ctrl+C stops%b' "$SHAR_C_MUTED" "$(date '+%H:%M:%S')" "$SHAR_C_RESET" "$SHAR_C_GREEN" "$SHAR_C_RESET" "$ZIP_PATTERN" "$SHAR_C_MUTED" "$SHAR_C_RESET"
    sleep "$POLL_SECONDS"
done
