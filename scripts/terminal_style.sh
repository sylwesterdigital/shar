#!/bin/zsh
# Shared terminal presentation helpers for Shar release/build scripts.
# Colours are enabled only for an interactive terminal (or FORCE_COLOR=1)
# and are automatically disabled for redirected logs, TERM=dumb, or NO_COLOR.

if [[ -n "${SHAR_TERMINAL_STYLE_LOADED:-}" ]]; then
  return 0
fi
SHAR_TERMINAL_STYLE_LOADED=1

SHAR_C_RESET=''
SHAR_C_BOLD=''
SHAR_C_DIM=''
SHAR_C_RED=''
SHAR_C_RED_BOLD=''
SHAR_C_GREEN=''
SHAR_C_GREEN_BOLD=''
SHAR_C_YELLOW=''
SHAR_C_YELLOW_BOLD=''
SHAR_C_BLUE=''
SHAR_C_BLUE_BOLD=''
SHAR_C_MAGENTA=''
SHAR_C_CYAN=''
SHAR_C_CYAN_BOLD=''
SHAR_C_WHITE_BOLD=''
SHAR_C_MUTED=''

if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && ( -t 1 || "${FORCE_COLOR:-0}" == "1" ) ]]; then
  SHAR_C_RESET=$'\033[0m'
  SHAR_C_BOLD=$'\033[1m'
  SHAR_C_DIM=$'\033[2m'
  SHAR_C_RED=$'\033[31m'
  SHAR_C_RED_BOLD=$'\033[1;31m'
  SHAR_C_GREEN=$'\033[32m'
  SHAR_C_GREEN_BOLD=$'\033[1;32m'
  SHAR_C_YELLOW=$'\033[33m'
  SHAR_C_YELLOW_BOLD=$'\033[1;33m'
  SHAR_C_BLUE=$'\033[34m'
  SHAR_C_BLUE_BOLD=$'\033[1;34m'
  SHAR_C_MAGENTA=$'\033[35m'
  SHAR_C_CYAN=$'\033[36m'
  SHAR_C_CYAN_BOLD=$'\033[1;36m'
  SHAR_C_WHITE_BOLD=$'\033[1;37m'
  SHAR_C_MUTED=$'\033[90m'
fi

shar_section() {
  printf '\n%b==>%b %b%s%b\n' "$SHAR_C_CYAN_BOLD" "$SHAR_C_RESET" "$SHAR_C_BOLD" "$*" "$SHAR_C_RESET"
}

shar_step() {
  printf '%b→%b %s\n' "$SHAR_C_BLUE_BOLD" "$SHAR_C_RESET" "$*"
}

shar_info() {
  printf '%b•%b %s\n' "$SHAR_C_CYAN" "$SHAR_C_RESET" "$*"
}

shar_success() {
  printf '%b✓%b %b%s%b\n' "$SHAR_C_GREEN_BOLD" "$SHAR_C_RESET" "$SHAR_C_GREEN" "$*" "$SHAR_C_RESET"
}

shar_warn() {
  printf '\n%bWARNING:%b %s\n' "$SHAR_C_YELLOW_BOLD" "$SHAR_C_RESET" "$*" >&2
}

shar_error() {
  printf '\n%bERROR:%b %s\n' "$SHAR_C_RED_BOLD" "$SHAR_C_RESET" "$*" >&2
}

shar_field() {
  local label="$1"
  shift
  printf '%b%-12s%b %s\n' "$SHAR_C_MUTED" "$label" "$SHAR_C_RESET" "$*"
}

shar_banner_info() {
  printf '\n%b============================================================%b\n' "$SHAR_C_BLUE_BOLD" "$SHAR_C_RESET"
  printf '%b%s%b\n' "$SHAR_C_WHITE_BOLD" "$*" "$SHAR_C_RESET"
  printf '%b============================================================%b\n' "$SHAR_C_BLUE_BOLD" "$SHAR_C_RESET"
}

shar_banner_success() {
  printf '\n%b============================================================%b\n' "$SHAR_C_GREEN_BOLD" "$SHAR_C_RESET"
  printf '%b%s%b\n' "$SHAR_C_GREEN_BOLD" "$*" "$SHAR_C_RESET"
  printf '%b============================================================%b\n' "$SHAR_C_GREEN_BOLD" "$SHAR_C_RESET"
}

shar_banner_error() {
  printf '\n%b============================================================%b\n' "$SHAR_C_RED_BOLD" "$SHAR_C_RESET" >&2
  printf '%b%s%b\n' "$SHAR_C_RED_BOLD" "$*" "$SHAR_C_RESET" >&2
  printf '%b============================================================%b\n' "$SHAR_C_RED_BOLD" "$SHAR_C_RESET" >&2
}
