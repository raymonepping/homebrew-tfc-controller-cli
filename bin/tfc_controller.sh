#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2034
VERSION="1.0.0"

#------------------------------------------------------------------------------
# Paths & .env
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env (tokens, host, etc.) if present
if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${ROOT_DIR}/.env"
  set +o allexport
fi

#------------------------------------------------------------------------------
# Source libs
#------------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/commons.sh"

source "${ROOT_DIR}/lib/org.sh"
source "${ROOT_DIR}/lib/projects.sh"
source "${ROOT_DIR}/lib/workspaces.sh"
source "${ROOT_DIR}/lib/varsets.sh"
source "${ROOT_DIR}/lib/registry.sh"
source "${ROOT_DIR}/lib/tags.sh"
source "${ROOT_DIR}/lib/teams.sh"
source "${ROOT_DIR}/lib/users.sh"

source "${ROOT_DIR}/lib/export.sh"
source "${ROOT_DIR}/lib/show.sh"

supports_color() {
  # color if stdout is a TTY, tput is present with >=8 colors, and NO_COLOR not set
  [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]] && [[ -z "${NO_COLOR:-}" ]]
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

  ${GREEN}export${NC} [--org <name> | --spec <spec.json>] -o|--out <file> [--profile minimal|full]
      Export org data to JSON.
        ${YELLOW}--org <name>${NC}        Org name
        ${YELLOW}--spec <file>${NC}       Spec file with .org.name
        ${YELLOW}-o, --out <file>${NC}    Output file (required)
        ${YELLOW}--profile${NC}           minimal (default) or full

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
if [[ "${cmd}" == "--version" ]]; then
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
    org_from="" spec_from="" out_file="" profile="minimal"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --org)     org_from="$2"; shift 2 ;;
        --spec)    spec_from="$2"; shift 2 ;;
        -o|--out)  out_file="$2"; shift 2 ;;
        --profile) profile="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
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
    export_live "${org_from}" "${out_file}" "${profile}"
    ;;

  show)
    shift
    file=""
    do_projects=0 do_workspaces=0 do_variables=0 do_varsets=0 do_registry=0 do_tags=0 do_users=0 do_teams=0
    f_project="" f_workspace="" f_tag="" f_module=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--file)     file="$2"; shift 2 ;;
        --projects)    do_projects=1; shift ;;
        --workspaces)  do_workspaces=1; shift ;;
        --variables)   do_variables=1; shift ;;
        --varsets)     do_varsets=1; shift ;;
        --registry)    do_registry=1; shift ;;
        --tags)        do_tags=1; shift ;;
        --users)       do_users=1; shift ;;
        --teams)       do_teams=1; shift ;;
        -p|--project)  f_project="$2"; shift 2 ;;
        -w|--workspace)f_workspace="$2"; shift 2 ;;
        -t|--tag)      f_tag="$2"; shift 2 ;;
        -m|--module)   f_module="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) err "Unknown flag: $1"; usage; exit 2 ;;
      esac
    done

    [[ -f "${file}" ]] || { err "Missing or unreadable -f|--file ${file}"; exit 2; }

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
