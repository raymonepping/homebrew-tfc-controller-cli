#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# Paths (work both locally and when installed via Homebrew)
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Project-scoped env
export TFC_ROOT="${TFC_ROOT:-$ROOT_DIR}"
export TFC_CONF="${TFC_CONF:-$TFC_ROOT/configuration}"
export TFC_LIB="${TFC_LIB:-$TFC_ROOT/lib}"
export TFC_LOGS="${TFC_LOGS:-$TFC_ROOT/logs}"
export TFC_STATE="${TFC_STATE:-$TFC_ROOT/state}"

# Version: prefer env from Homebrew wrapper; else .version; else 'dev'
VERSION="${TFC_VERSION:-$( ( [ -f "${TFC_ROOT}/.version" ] && sed 's/^v//' "${TFC_ROOT}/.version" ) || echo dev)}"

# Feature toggles / general flags
export SET_ALIASES="${SET_ALIASES:-0}"
export DRY_RUN="${DRY_RUN:-0}"
export VERBOSE="${VERBOSE:-0}"
export PARALLEL="${PARALLEL:-1}"

# Homebrew noise control
export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"

# Minimal color helpers (no side-effects)
supports_color() {
  [[ -t 1 ]] && command -v tput >/dev/null 2>&1 \
    && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]] \
    && [[ -z "${NO_COLOR:-}" ]]
}
init_colors() {
  if supports_color; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; NC=$'\e[0m'
  else
    BOLD=""; DIM=""; CYAN=""; GREEN=""; YELLOW=""; NC=""
  fi
}

usage() {
  init_colors
  cat <<EOF
${BOLD}${CYAN}tfc_controller v${VERSION}${NC} — Manage & export Terraform Cloud org data

${BOLD}${CYAN}USAGE${NC}
  ${GREEN}tfc_controller${NC} <command> [options]

${BOLD}${CYAN}COMMANDS${NC}
  ${GREEN}validate${NC} <spec.json>            Validate a spec file (.org.name + .org.email).
  ${GREEN}plan${NC} <spec.json>                Plan org + project changes.
  ${GREEN}apply${NC} <spec.json> [--yes]       Apply org + project changes.
  ${GREEN}ensure-org${NC} <spec.json> [--dry-run]
                               Ensure org exists (optionally dry-run).
  ${GREEN}plan-projects${NC} <spec.json>       Plan changes for projects only.
  ${GREEN}apply-projects${NC} <spec.json> [--yes]
                               Apply projects only.

  ${GREEN}export${NC} [--org <name> | --spec <spec.json>] -o|--out <file> [--profile minimal|full] [--doc-out <doc.md>] [--doc-tpl <tpl>]
      Export org data to JSON.
        ${YELLOW}--org <name>${NC}        Org name
        ${YELLOW}--spec <file>${NC}       Spec file with .org.name
        ${YELLOW}-o, --out <file>${NC}    Output JSON (required)
        ${YELLOW}--profile${NC}           minimal (default) or full
        ${YELLOW}--doc-out <file>${NC}    Also write Markdown document during export
        ${YELLOW}--doc-tpl <file>${NC}    Optional template (reserved)

  ${GREEN}show${NC} -f|--file <export.json> [SECTIONS...] [FILTERS...]
      Pretty-print an export.
      Sections:
        ${YELLOW}--projects${NC}          Projects
        ${YELLOW}--workspaces${NC}        Workspaces
        ${YELLOW}--variables${NC}         Workspace variables
        ${YELLOW}--varsets${NC}           Variable sets
        ${YELLOW}--registry${NC}          Registry modules
        ${YELLOW}--tags${NC}              Reserved tag keys
        ${YELLOW}--users${NC}             Users + team memberships
        ${YELLOW}--teams${NC}             Teams (core, memberships, project access)
      Filters:
        ${YELLOW}-p, --project "<name>"${NC}   Filter by project
        ${YELLOW}-w, --workspace "<name>"${NC} Filter by workspace
        ${YELLOW}-t, --tag "<tag>"${NC}        Filter by workspace tag
        ${YELLOW}-m, --module "<name>"${NC}    Filter by registry module

  ${GREEN}document${NC} -f|--file <export.json> -o|--out <doc.md> [--template <tpl>]
      Generate a Markdown document from an existing export.

${BOLD}${CYAN}GLOBAL FLAGS${NC}
  ${YELLOW}-h, --help${NC}               Show this help
  ${YELLOW}-V, --version${NC}            Show version
  ${YELLOW}--no-color${NC}               Disable ANSI colors (or set NO_COLOR=1)

${DIM}Notes:${NC}
  • Reads TFE_TOKEN and TFE_HOST from .env
  • 'export' supports profiles: minimal (default) or full
  • 'show' defaults to projects + workspaces if no section given
EOF
}

# --- Fast path for help/version (no sourcing, no env side-effects)
cmd="${1:-}"
if [[ -z "${cmd}" || "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then usage; exit 0; fi
if [[ "${cmd}" == "-V" || "${cmd}" == "--version" ]]; then echo "tfc_controller v${VERSION}"; exit 0; fi

#------------------------------------------------------------------------------
# Load .env if present
#------------------------------------------------------------------------------
if [[ -f "${TFC_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${TFC_ROOT}/.env"
  set +o allexport
fi

#------------------------------------------------------------------------------
# Source libs (after fast path)
#------------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${TFC_LIB}/commons.sh"
source "${TFC_LIB}/org.sh"
source "${TFC_LIB}/projects.sh"
source "${TFC_LIB}/workspaces.sh"
source "${TFC_LIB}/varsets.sh"
source "${TFC_LIB}/registry.sh"
source "${TFC_LIB}/tags.sh"
source "${TFC_LIB}/teams.sh"
source "${TFC_LIB}/users.sh"
source "${TFC_LIB}/document.sh"
source "${TFC_LIB}/export.sh"
source "${TFC_LIB}/show.sh"

#------------------------------------------------------------------------------
# Colors
#------------------------------------------------------------------------------
supports_color() {
  [[ -t 1 ]] && command -v tput >/dev/null 2>&1 \
    && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]] \
    && [[ -z "${NO_COLOR:-}" ]]
}

init_colors() {
  if supports_color; then
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    CYAN=$'\e[36m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    NC=$'\e[0m'
  else
    BOLD=""; DIM=""; CYAN=""; GREEN=""; YELLOW=""; NC=""
  fi
}

#------------------------------------------------------------------------------
# Usage / Help
#------------------------------------------------------------------------------
usage() {
  init_colors
  cat <<EOF
${BOLD}${CYAN}tfc_controller v${VERSION}${NC} — Manage & export Terraform Cloud org data

${BOLD}${CYAN}USAGE${NC}
  ${GREEN}tfc_controller${NC} <command> [options]

${BOLD}${CYAN}COMMANDS${NC}
  ${GREEN}validate${NC} <spec.json>            Validate a spec file (.org.name + .org.email).
  ${GREEN}plan${NC} <spec.json>                Plan org + project changes.
  ${GREEN}apply${NC} <spec.json> [--yes]       Apply org + project changes.
  ${GREEN}ensure-org${NC} <spec.json> [--dry-run]
                               Ensure org exists (optionally dry-run).
  ${GREEN}plan-projects${NC} <spec.json>       Plan changes for projects only.
  ${GREEN}apply-projects${NC} <spec.json> [--yes]
                               Apply projects only.

  ${GREEN}export${NC} [--org <name> | --spec <spec.json>] -o|--out <file> [--profile minimal|full] [--doc-out <doc.md>] [--doc-tpl <tpl>]
      Export org data to JSON.
        ${YELLOW}--org <name>${NC}        Org name
        ${YELLOW}--spec <file>${NC}       Spec file with .org.name
        ${YELLOW}-o, --out <file>${NC}    Output JSON (required)
        ${YELLOW}--profile${NC}           minimal (default) or full
        ${YELLOW}--doc-out <file>${NC}    Also write Markdown document during export
        ${YELLOW}--doc-tpl <file>${NC}    Optional template (reserved)

  ${GREEN}show${NC} -f|--file <export.json> [SECTIONS...] [FILTERS...]
      Pretty-print an export.
      Sections:
        ${YELLOW}--projects${NC}          Projects
        ${YELLOW}--workspaces${NC}        Workspaces
        ${YELLOW}--variables${NC}         Workspace variables
        ${YELLOW}--varsets${NC}           Variable sets
        ${YELLOW}--registry${NC}          Registry modules
        ${YELLOW}--tags${NC}              Reserved tag keys
        ${YELLOW}--users${NC}             Users + team memberships
        ${YELLOW}--teams${NC}             Teams (core, memberships, project access)
      Filters:
        ${YELLOW}-p, --project "<name>"${NC}   Filter by project
        ${YELLOW}-w, --workspace "<name>"${NC} Filter by workspace
        ${YELLOW}-t, --tag "<tag>"${NC}        Filter by workspace tag
        ${YELLOW}-m, --module "<name>"${NC}    Filter by registry module

  ${GREEN}document${NC} -f|--file <export.json> -o|--out <doc.md> [--template <tpl>]
      Generate a Markdown document from an existing export.

${BOLD}${CYAN}GLOBAL FLAGS${NC}
  ${YELLOW}-h, --help${NC}               Show this help
  ${YELLOW}-V, --version${NC}            Show version
  ${YELLOW}--no-color${NC}               Disable ANSI colors (or set NO_COLOR=1)

${DIM}Notes:${NC}
  • Reads TFE_TOKEN and TFE_HOST from .env
  • 'export' supports profiles: minimal (default) or full
  • 'show' defaults to projects + workspaces if no section given
EOF
}

#------------------------------------------------------------------------------
# Gum reminder
#------------------------------------------------------------------------------
GUM_NAGGED=0
gum_reminder() {
  if command -v has_gum >/dev/null 2>&1; then
    if ! has_gum && [[ "${GUM_NAGGED}" -eq 0 ]]; then
      echo "Tip: Install gum for richer UI: https://github.com/charmbracelet/gum" >&2
      GUM_NAGGED=1
    fi
  else
    if ! command -v gum >/dev/null 2>&1 && [[ "${GUM_NAGGED}" -eq 0 ]]; then
      echo "Tip: Install gum for richer UI: https://github.com/charmbracelet/gum" >&2
      GUM_NAGGED=1
    fi
  fi
}

#------------------------------------------------------------------------------
# Dispatch
#------------------------------------------------------------------------------
cmd="${1:-}"

# Global help/version
if [[ -z "${cmd}" || "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then
  usage; exit 0
fi
if [[ "${cmd}" == "-V" || "${cmd}" == "--version" ]]; then
  echo "tfc_controller v${VERSION}"
  exit 0
fi

case "${cmd}" in
  validate)
    spec="${2:-}"; [[ -f "${spec}" ]] || { usage; exit 2; }
    name=$(json_get "${spec}" '.org.name')
    email=$(json_get "${spec}" '.org.email')
    [[ -n "${name}"  && "${name}"  != "null" ]] || { err "Invalid or missing .org.name"; exit 2; }
    [[ -n "${email}" && "${email}" != "null" ]] || { err "Invalid or missing .org.email"; exit 2; }
    ok "Spec OK"
    ;;

  plan)
    spec="${2:-}"; [[ -f "${spec}" ]] || { usage; exit 2; }
    if [[ "$(org_exists "$(json_get "${spec}" '.org.name')")" == "yes" ]]; then
      echo "Plan (org): No changes. Org exists."
    else
      echo "Plan (org): Create organization"
    fi
    echo
    plan_projects "${spec}"
    ;;

  apply)
    spec="${2:-}"; [[ -f "${spec}" ]] || { usage; exit 2; }
    auto="${3:-}"
    if [[ "${auto}" != "--yes" ]]; then
      prompt "Apply org changes now? [y/N]: " && read -r ans || true
      [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]] || { echo "Aborted."; exit 1; }
    fi
    ensure_org "${spec}" "false"
    echo
    apply_projects "${spec}" "${auto:-}"
    ;;

  ensure-org)
    spec="${2:-}"; [[ -f "${spec}" ]] || { usage; exit 2; }
    flag="${3:-}"; dry="false"; [[ "${flag}" == "--dry-run" ]] && dry="true"
    ensure_org "${spec}" "${dry}"
    ;;

  plan-projects)
    spec="${2:-}"; [[ -f "${spec}" ]] || { usage; exit 2; }
    plan_projects "${spec}"
    ;;

  apply-projects)
    spec="${2:-}"; [[ -f "${spec}" ]] || { usage; exit 2; }
    apply_projects "${spec}" "${3:-}"
    ;;

  export)
    shift
    org_from="" spec_from="" out_file="" profile="minimal" doc_out="" doc_tpl=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --org)       org_from="$2"; shift 2 ;;
        --spec)      spec_from="$2"; shift 2 ;;
        -o|--out)    out_file="$2"; shift 2 ;;
        --profile)   profile="$2"; shift 2 ;;
        --doc-out)   doc_out="$2"; shift 2 ;;
        --doc-tpl)   doc_tpl="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) err "Unknown flag: $1"; usage; exit 2 ;;
      esac
    done
    [[ -n "${out_file}" ]] || { err "Missing -o|--out <file>"; usage; exit 2; }
    if [[ -n "${spec_from}" ]]; then
      [[ -f "${spec_from}" ]] || { err "Spec not found: ${spec_from}"; exit 2; }
      org_from="$(json_get "${spec_from}" '.org.name')"
    fi
    [[ -n "${org_from}" ]] || { err "Provide --org <name> or --spec <spec.json>"; exit 2; }
    gum_reminder
    export_live "${org_from}" "${out_file}" "${profile}" "${doc_out}" "${doc_tpl}"
    ;;

  document)
    # Standalone doc generation from an existing export
    shift
    file="" out="" tpl=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--file)   file="$2"; shift 2 ;;
        -o|--out)    out="$2"; shift 2 ;;
        --template)  tpl="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) err "Unknown flag: $1"; usage; exit 2 ;;
      esac
    done
    [[ -f "${file}" ]] || { err "Missing or unreadable -f|--file ${file}"; exit 2; }
    [[ -n "${out}"   ]] || { err "Missing -o|--out <doc.md>"; exit 2; }
    gum_reminder
    doc_render_from_export "${file}" "${out}" "${tpl:-}"
    ok "Document written to ${out}"
    ;;

  show)
    shift
    file=""
    do_projects=0; do_workspaces=0; do_variables=0; do_varsets=0; do_registry=0; do_tags=0; do_users=0; do_teams=0
    f_project=""; f_workspace=""; f_tag=""; f_module=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--file)      file="$2"; shift 2 ;;
        --projects)     do_projects=1; shift ;;
        --workspaces)   do_workspaces=1; shift ;;
        --variables)    do_variables=1; shift ;;
        --varsets)      do_varsets=1; shift ;;
        --registry)     do_registry=1; shift ;;
        --tags)         do_tags=1; shift ;;
        --users)        do_users=1; shift ;;
        --teams)        do_teams=1; shift ;;
        -p|--project)   f_project="$2"; shift 2 ;;
        -w|--workspace) f_workspace="$2"; shift 2 ;;
        -t|--tag)       f_tag="$2"; shift 2 ;;
        -m|--module)    f_module="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) err "Unknown flag: $1"; usage; exit 2 ;;
      esac
    done

    [[ -f "${file}" ]] || { err "Missing or unreadable -f|--file ${file}"; exit 2; }

    # Default view if nothing specified: projects + workspaces
    if (( do_projects == 0 && do_workspaces == 0 && do_variables == 0 && do_varsets == 0 && do_registry == 0 && do_tags == 0 && do_users == 0 && do_teams == 0 )); then
      do_projects=1; do_workspaces=1
    fi

    gum_reminder
    echo
    (( do_projects ))   && show_projects "${file}" "${f_project}" && echo
    (( do_workspaces )) && show_workspaces "${file}" "${f_project}" "${f_tag}" && echo
    (( do_variables ))  && show_workspace_variables "${file}" "${f_workspace}" && echo
    (( do_varsets ))    && show_varsets "${file}" "${f_project}" && echo
    (( do_registry ))   && show_registry "${file}" "${f_module}" && echo
    (( do_tags ))       && show_tags "${file}" && echo
    (( do_users ))      && show_users "${file}" && echo
    (( do_teams ))      && show_teams "${file}" && echo
    ;;

  *)
    usage; exit 2 ;;
esac
