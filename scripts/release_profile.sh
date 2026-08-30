#!/bin/zsh
set -e
set -o pipefail

SHAR_RELEASE_PROFILE="${SHAR_RELEASE_PROFILE:-$HOME/.config/workwork/shar-release.env}"
RANTLIST_RELEASE_PROFILE="${RANTLIST_RELEASE_PROFILE:-$HOME/.config/workwork/rantlist-release.env}"
RANTLIST_PROFILE_LOADER="${RANTLIST_PROFILE_LOADER:-$HOME/Documents/works/rantlist-client/scripts/release_profile.sh}"

shar_write_profile() {
  mkdir -p "$(dirname "$SHAR_RELEASE_PROFILE")"
  umask 077
  {
    printf 'SHAR_REMOTE_USER=%q\n' "$SHAR_REMOTE_USER"
    printf 'SHAR_REMOTE_HOST=%q\n' "$SHAR_REMOTE_HOST"
    printf 'SHAR_REMOTE_PORT=%q\n' "$SHAR_REMOTE_PORT"
    printf 'SHAR_REMOTE_DIR=%q\n' "$SHAR_REMOTE_DIR"
    printf 'SHAR_REMOTE_OWNER=%q\n' "$SHAR_REMOTE_OWNER"
    printf 'SHAR_REMOTE_CHMOD=%q\n' "$SHAR_REMOTE_CHMOD"
    printf 'SHAR_STRIPE_SUPPORT_URL=%q\n' "${SHAR_STRIPE_SUPPORT_URL:-}"
    printf 'SHAR_STRIPE_BUY_BUTTON_ID=%q\n' "${SHAR_STRIPE_BUY_BUTTON_ID:-}"
    printf 'SHAR_STRIPE_PUBLISHABLE_KEY=%q\n' "${SHAR_STRIPE_PUBLISHABLE_KEY:-}"
  } > "$SHAR_RELEASE_PROFILE"
  chmod 600 "$SHAR_RELEASE_PROFILE"
}

shar_import_rantlist_profile() {
  if [[ ! -f "$RANTLIST_RELEASE_PROFILE" && -f "$RANTLIST_PROFILE_LOADER" ]]; then
    # The established Rantlist release setup can bootstrap its private SSH profile.
    source "$RANTLIST_PROFILE_LOADER"
    if typeset -f rantlist_load_release_profile >/dev/null 2>&1; then
      rantlist_load_release_profile >/dev/null || return 1
    fi
  fi

  [[ -f "$RANTLIST_RELEASE_PROFILE" ]] || return 1
  source "$RANTLIST_RELEASE_PROFILE"

  : "${RANTLIST_REMOTE_USER:?RANTLIST_REMOTE_USER missing}"
  : "${RANTLIST_REMOTE_HOST:?RANTLIST_REMOTE_HOST missing}"
  : "${RANTLIST_REMOTE_PORT:?RANTLIST_REMOTE_PORT missing}"

  SHAR_REMOTE_USER="$RANTLIST_REMOTE_USER"
  SHAR_REMOTE_HOST="$RANTLIST_REMOTE_HOST"
  SHAR_REMOTE_PORT="$RANTLIST_REMOTE_PORT"
  SHAR_REMOTE_DIR="/var/www/mojoworks/labs/shar"
  SHAR_REMOTE_OWNER="${RANTLIST_REMOTE_OWNER:-www-data:www-data}"
  SHAR_REMOTE_CHMOD="${RANTLIST_REMOTE_CHMOD:-Du=rwx,Dgo=rx,Fu=rw,Fgo=r}"
  SHAR_STRIPE_SUPPORT_URL="${RANTLIST_STRIPE_SUPPORT_URL:-${RANTLIST_SUPPORT_URL:-}}"
  SHAR_STRIPE_BUY_BUTTON_ID="${RANTLIST_STRIPE_BUY_BUTTON_ID:-}"
  SHAR_STRIPE_PUBLISHABLE_KEY="${RANTLIST_STRIPE_PUBLISHABLE_KEY:-}"
  shar_write_profile
  printf 'Imported Shar deployment profile from the existing Rantlist release profile: %s\n' "$SHAR_RELEASE_PROFILE"
}

shar_load_release_profile() {
  if [[ ! -f "$SHAR_RELEASE_PROFILE" ]]; then
    shar_import_rantlist_profile || {
      printf 'ERROR: Shar deployment profile is missing and the existing Rantlist profile could not be imported.\n' >&2
      return 1
    }
  fi

  source "$SHAR_RELEASE_PROFILE"
  if [[ -z "${SHAR_STRIPE_SUPPORT_URL:-}" && -f "$RANTLIST_RELEASE_PROFILE" ]]; then
    source "$RANTLIST_RELEASE_PROFILE"
    SHAR_STRIPE_SUPPORT_URL="${RANTLIST_STRIPE_SUPPORT_URL:-${RANTLIST_SUPPORT_URL:-}}"
  fi
  : "${SHAR_REMOTE_USER:?SHAR_REMOTE_USER missing from release profile}"
  : "${SHAR_REMOTE_HOST:?SHAR_REMOTE_HOST missing from release profile}"
  : "${SHAR_REMOTE_PORT:?SHAR_REMOTE_PORT missing from release profile}"
  SHAR_REMOTE_DIR="${SHAR_REMOTE_DIR:-/var/www/mojoworks/labs/shar}"
  SHAR_REMOTE_OWNER="${SHAR_REMOTE_OWNER:-www-data:www-data}"
  SHAR_REMOTE_CHMOD="${SHAR_REMOTE_CHMOD:-Du=rwx,Dgo=rx,Fu=rw,Fgo=r}"
  SHAR_STRIPE_SUPPORT_URL="${SHAR_STRIPE_SUPPORT_URL:-https://buy.stripe.com/5kQ8wO8jU0Sbg2nc9EcZa04}"
  SHAR_STRIPE_BUY_BUTTON_ID="${SHAR_STRIPE_BUY_BUTTON_ID:-buy_btn_1UA5kdC7wxoTGQU3qSQrnBTz}"
  SHAR_STRIPE_PUBLISHABLE_KEY="${SHAR_STRIPE_PUBLISHABLE_KEY:-pk_live_51OS1fPC7wxoTGQU3jLPCJmKrEOZ03kLdBpCyRKcE1DRj9xKHNdIWNbAAwMFLsi0s9cyUGw9BdYQzYDmFbsNacsrx00KDuQKgna}"
}
