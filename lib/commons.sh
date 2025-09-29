#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

: "${TFE_HOST:=app.terraform.io}"
: "${TFE_TOKEN:=}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}Missing: $1${NC}"; exit 2; }; }
need "jq"; need "curl"

ok()   { echo "${GREEN}$*${NC}"; }
warn() { echo "${YELLOW}$*${NC}"; }
err()  { echo "${RED}$*${NC}" 1>&2; }
prompt(){ printf "%s" "$*"; }

# Always call the real curl, disable [] globbing, quiet+show errors
CURL() { command curl --globoff -sS "$@"; }

auth_header() {
  [[ -n "${TFE_TOKEN}" ]] || { err "TFE_TOKEN not set. Add it to .env"; exit 2; }
  echo "Authorization: Bearer ${TFE_TOKEN}"
}

json_get() {
  local file="$1" jqpath="$2"
  jq -r "${jqpath}" "${file}"
}

# ---------- gum helpers (version-agnostic with fallbacks) ----------
has_gum() { command -v gum >/dev/null 2>&1; }

# Detect if this gum has 'progress'
has_gum_progress() {
  has_gum || return 1
  # most old g um versions will error on unknown subcommand; we check help text
  gum help 2>/dev/null | grep -qE '(^|\s)progress(\s|$)' || return 1
}

# Simple title line
gum_title() {
  local title="${1:-}"
  [[ -z "${title}" ]] && return 0
  if has_gum; then
    gum style --bold --foreground 212 "${title}" || echo "== ${title} =="
  else
    echo "== ${title} =="
  fi
}

# Spinner: start/stop (no --title usage)
GUM_SPINNER_PID=""
gum_spinner_start() {
  has_gum || return 0
  local title="${1:-Working...}"
  gum_title "${title}"
  ( gum spin -- bash -c 'sleep 999999' ) &
  GUM_SPINNER_PID=$!
}
gum_spinner_stop() {
  [[ -n "${GUM_SPINNER_PID}" ]] || return 0
  kill "${GUM_SPINNER_PID}" 2>/dev/null || true
  wait "${GUM_SPINNER_PID}" 2>/dev/null || true
  GUM_SPINNER_PID=""
}

# Progress bar: gum if available, else ASCII fallback
GUM_PROG_FIFO=""
GUM_PROG_PID=""
FB_TOTAL=0
FB_LAST=-1

gum_progress_begin() {
  local title="${1:-Working...}"
  local total="${2:-}"  # optional: pass total now for FB
  gum_title "${title}"
  if has_gum_progress; then
    local fifo; fifo="$(mktemp -u)"; mkfifo "${fifo}"
    ( cat "${fifo}" | gum progress ) &
    GUM_PROG_PID=$!
    GUM_PROG_FIFO="${fifo}"
  else
    FB_TOTAL=$(( total > 0 ? total : 100 ))
    FB_LAST=-1
    # initial line
    printf "\r[%-40s] %3d%%" "" 0
  fi
}

gum_progress_tick() {
  local current="${1:-0}" total="${2:-100}"
  (( total > 0 )) || total=1
  local percent=$(( current * 100 / total ))
  if has_gum_progress && [[ -n "${GUM_PROG_FIFO}" ]]; then
    { printf "%d\n" "${percent}" > "${GUM_PROG_FIFO}"; } 2>/dev/null || true
  else
    # ASCII fallback
    # avoid flicker by only redrawing when changed
    if [[ "${percent}" -ne "${FB_LAST}" ]]; then
      FB_LAST="${percent}"
      local filled=$(( percent * 40 / 100 ))
      local empty=$(( 40 - filled ))
      printf "\r["
      printf '%*s' "${filled}" '' | tr ' ' '#'
      printf '%*s' "${empty}" '' | tr ' ' ' '
      printf "] %3d%%" "${percent}"
    fi
  fi
}

gum_progress_end() {
  if has_gum_progress && [[ -n "${GUM_PROG_FIFO}" ]]; then
    rm -f "${GUM_PROG_FIFO}" 2>/dev/null || true
    GUM_PROG_FIFO=""
    if [[ -n "${GUM_PROG_PID}" ]]; then
      wait "${GUM_PROG_PID}" 2>/dev/null || true
      GUM_PROG_PID=""
    fi
  else
    # newline to finish ASCII bar
    printf "\n"
  fi
}
# ---------- /gum helpers ----------

