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

#------------------------------------------------------------------------------
# Version: prefer env from Homebrew wrapper; else .version; else 'dev'
#------------------------------------------------------------------------------
if [[ -n "${TFC_VERSION:-}" ]]; then
  VERSION="${TFC_VERSION}"
elif [[ -f "${TFC_ROOT}/.version" ]]; then
  VERSION="$(sed 's/^v//' "${TFC_ROOT}/.version")"
else
  VERSION="dev"
fi

# Global prescan for startup flags; strip them from argv
VERBOSE="${VERBOSE:-0}"
NO_COLOR="${NO_COLOR:-}"

declare -a ARGS=()
for a in "$@"; do
  case "$a" in
  -v | --verbose) VERBOSE=1 ;;
  --no-color) NO_COLOR=1 ;;
  *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]}"

# Feature toggles / general flags
export SET_ALIASES="${SET_ALIASES:-0}"
export DRY_RUN="${DRY_RUN:-0}"
export VERBOSE="${VERBOSE:-0}"
export PARALLEL="${PARALLEL:-1}"

# Homebrew noise control
export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"

# Debug helper
debug() { [[ "${VERBOSE}" == "1" ]] && echo "[debug] $*" >&2; }

# Doctor command: check TFE_TOKEN, API reachability, and required tools
doctor() {
  init_colors
  local ok=0

  # 1. Check if token is available
  if [[ -n "${TFE_TOKEN:-}" ]]; then
    echo "${GREEN}OK${NC}: TFE_TOKEN loaded"
  else
    echo "${RED}FAIL${NC}: TFE_TOKEN not set (check your .env)"
    ok=1
  fi

  # 2. Check curl
  if command -v curl >/dev/null 2>&1; then
    echo "${GREEN}OK${NC}: curl installed"
  else
    echo "${RED}FAIL${NC}: curl not found in PATH"
    ok=1
  fi

  # 3. Check jq
  if command -v jq >/dev/null 2>&1; then
    echo "${GREEN}OK${NC}: jq installed"
  else
    echo "${RED}FAIL${NC}: jq not found in PATH"
    ok=1
  fi

  # 4. Check if API responds
  local host="${TFE_HOST:-app.terraform.io}"
  debug "Checking API on https://${host}"

  if [[ -n "${TFE_TOKEN:-}" ]] && curl -fsS -H "Authorization: Bearer ${TFE_TOKEN}" \
    "https://${host}/api/v2/organizations" >/dev/null; then
    echo "${GREEN}OK${NC}: API reachable at https://${host}"
  else
    echo "${RED}FAIL${NC}: API not reachable at https://${host}"
    ok=1
  fi

  # Final summary
  if [[ $ok -eq 0 ]]; then
    echo -e "\n${GREEN}Doctor finished: all checks passed ✔${NC}"
    return 0
  else
    echo -e "\n${RED}Doctor finished: some checks failed ✘${NC}"
    return 2
  fi
}

# Minimal color helpers (no side-effects)
supports_color() {
  # Only if stdout is a TTY
  [[ -t 1 ]] || return 1
  # TERM must be set and not dumb
  [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] || return 1
  # tput must exist and report >=8 colors
  command -v tput >/dev/null 2>&1 || return 1
  local colors
  colors="$(tput colors 2>/dev/null || echo 0)"
  [[ "${colors}" =~ ^[0-9]+$ && "${colors}" -ge 8 ]] || return 1
  # Respect NO_COLOR
  [[ -z "${NO_COLOR:-}" ]]
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
    BOLD=""
    DIM=""
    CYAN=""
    GREEN=""
    YELLOW=""
    NC=""
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
  ${GREEN}plan${NC} <spec.json>                Plan org + agent pools + projects + teams/users.
  ${GREEN}apply${NC} <spec.json> [--yes]       Apply org + agent pools + projects + teams/users.

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
        ${YELLOW}--agent-pools${NC}       Agent pools
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
if [[ -z "${cmd}" || "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${cmd}" == "-V" || "${cmd}" == "--version" ]]; then
  echo "tfc_controller v${VERSION}"
  exit 0
fi

#------------------------------------------------------------------------------
# Load .env (prefer current working directory, then TFC_ROOT)
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# Load env: TFC_ENV_FILE > ./.env > ${TFC_ROOT}/.env (whitelist keys only)
#------------------------------------------------------------------------------
load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  debug "Loading env file: $file"

  # Accept only these prefixes (add more if you need)
  local allowed='^(TFE_|TFC_|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)'

  # Read simple KEY=VALUE lines; ignore comments/blank lines
  # Supports unquoted or single/double-quoted values
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # Skip blanks and comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    # Must look like KEY=VALUE
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue

    local key="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"

    # Only accept whitelisted keys
    [[ "$key" =~ $allowed ]] || continue

    # Strip surrounding quotes if present (basic dotenv handling)
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi

    # Export without eval
    printf -v "$key" '%s' "$val"
    export "${key?}" # dynamic export; assert key is non-empty for ShellCheck

  done <"$file"
  return 0
}

if [[ -n "${TFC_ENV_FILE:-}" ]] && load_env_file "${TFC_ENV_FILE}"; then
  :
elif load_env_file ".env"; then
  :
elif load_env_file "${TFC_ROOT}/.env"; then
  :
else
  debug "No .env found (TFC_ENV_FILE, CWD, or TFC_ROOT)"
fi

#------------------------------------------------------------------------------
# Source libs (after fast path)
#------------------------------------------------------------------------------
libs=(
  commons
  org
  projects
  agent_pools
  workspaces
  varsets
  registry
  tags
  teams
  users
  document
  export
  show
)

for lib in "${libs[@]}"; do
  f="${TFC_LIB}/${lib}.sh"
  [[ -r "$f" ]] || {
    echo "Missing library: $f" >&2
    exit 1
  }

  # shellcheck disable=SC1090
  source "$f"

done

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
  usage
  exit 0
fi
if [[ "${cmd}" == "-V" || "${cmd}" == "--version" ]]; then
  echo "tfc_controller v${VERSION}"
  exit 0
fi

case "${cmd}" in
validate)
  spec="${2:-}"
  [[ -f "${spec}" ]] || {
    usage
    exit 2
  }
  name=$(json_get "${spec}" '.org.name')
  email=$(json_get "${spec}" '.org.email')
  [[ -n "${name}" && "${name}" != "null" ]] || {
    err "Invalid or missing .org.name"
    exit 2
  }
  [[ -n "${email}" && "${email}" != "null" ]] || {
    err "Invalid or missing .org.email"
    exit 2
  }
  ok "Spec OK"
  ;;
doctor)
  doctor
  ;;
plan)
  spec="${2:-}"
  [[ -f "${spec}" ]] || {
    usage
    exit 2
  }
  if [[ "$(org_exists "$(json_get "${spec}" '.org.name')")" == "yes" ]]; then
    echo "Plan (org): No changes. Org exists."
  else
    echo "Plan (org): Create organization"
  fi
  echo
  plan_agent_pools "${spec}"
  echo
  plan_projects "${spec}"
  echo
  plan_identities "${spec}"
  ;;
apply)
  spec="${2:-}"
  [[ -f "${spec}" ]] || {
    usage
    exit 2
  }
  auto="${3:-}"
  if [[ "${auto}" != "--yes" ]]; then
    prompt "Apply org changes now? [y/N]: "
    read -r ans || true
    if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
  ensure_org "${spec}" "false"
  echo
  apply_agent_pools "${spec}" "${auto:-}"
  echo
  apply_projects "${spec}" "${auto:-}"
  echo
  apply_identities "${spec}" "${auto:-}"
  ;;

ensure-org)
  spec="${2:-}"
  [[ -f "${spec}" ]] || {
    usage
    exit 2
  }
  flag="${3:-}"
  dry="false"
  [[ "${flag}" == "--dry-run" ]] && dry="true"
  ensure_org "${spec}" "${dry}"
  ;;

plan-projects)
  spec="${2:-}"
  [[ -f "${spec}" ]] || {
    usage
    exit 2
  }
  plan_projects "${spec}"
  ;;

apply-projects)
  spec="${2:-}"
  [[ -f "${spec}" ]] || {
    usage
    exit 2
  }
  apply_projects "${spec}" "${3:-}"
  ;;

export)
  shift
  org_from="" spec_from="" out_file="" profile="minimal" doc_out="" doc_tpl=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --org)
      org_from="$2"
      shift 2
      ;;
    --spec)
      spec_from="$2"
      shift 2
      ;;
    -o | --out)
      out_file="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --doc-out)
      doc_out="$2"
      shift 2
      ;;
    --doc-tpl)
      doc_tpl="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "Unknown flag: $1"
      usage
      exit 2
      ;;
    esac
  done
  [[ -n "${out_file}" ]] || {
    err "Missing -o|--out <file>"
    usage
    exit 2
  }
  if [[ -n "${spec_from}" ]]; then
    [[ -f "${spec_from}" ]] || {
      err "Spec not found: ${spec_from}"
      exit 2
    }
    org_from="$(json_get "${spec_from}" '.org.name')"
  fi
  [[ -n "${org_from}" ]] || {
    err "Provide --org <name> or --spec <spec.json>"
    exit 2
  }
  gum_reminder
  export_live "${org_from}" "${out_file}" "${profile}" "${doc_out}" "${doc_tpl}"
  ;;

document)
  # Standalone doc generation from an existing export
  shift
  file="" out="" tpl=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f | --file)
      file="$2"
      shift 2
      ;;
    -o | --out)
      out="$2"
      shift 2
      ;;
    --template)
      tpl="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "Unknown flag: $1"
      usage
      exit 2
      ;;
    esac
  done
  [[ -f "${file}" ]] || {
    err "Missing or unreadable -f|--file ${file}"
    exit 2
  }
  [[ -n "${out}" ]] || {
    err "Missing -o|--out <doc.md>"
    exit 2
  }
  gum_reminder
  doc_render_from_export "${file}" "${out}" "${tpl:-}"
  ok "Document written to ${out}"
  ;;

show)
  shift
  file=""
  do_projects=0
  do_agent_pools=0
  do_workspaces=0
  do_variables=0
  do_varsets=0
  do_registry=0
  do_tags=0
  do_users=0
  do_teams=0
  f_project=""
  f_workspace=""
  f_tag=""
  f_module=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f | --file)
      file="$2"
      shift 2
      ;;
    --projects)
      do_projects=1
      shift
      ;;
    --agent-pools)
      do_agent_pools=1
      shift
      ;;      
    --workspaces)
      do_workspaces=1
      shift
      ;;
    --variables)
      do_variables=1
      shift
      ;;
    --varsets)
      do_varsets=1
      shift
      ;;
    --registry)
      do_registry=1
      shift
      ;;
    --tags)
      do_tags=1
      shift
      ;;
    --users)
      do_users=1
      shift
      ;;
    --teams)
      do_teams=1
      shift
      ;;
    -p | --project)
      f_project="$2"
      shift 2
      ;;
    -w | --workspace)
      f_workspace="$2"
      shift 2
      ;;
    -t | --tag)
      f_tag="$2"
      shift 2
      ;;
    -m | --module)
      f_module="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "Unknown flag: $1"
      usage
      exit 2
      ;;
    esac
  done

  [[ -f "${file}" ]] || {
    err "Missing or unreadable -f|--file ${file}"
    exit 2
  }

  # Default view if nothing specified: projects + workspaces
  if ((do_projects == 0 && do_agent_pools == 0 && do_workspaces == 0 && do_variables == 0 && do_varsets == 0 && do_registry == 0 && do_tags == 0 && do_users == 0 && do_teams == 0)); then
     do_projects=1
     do_workspaces=1
  fi
  
  #if ((do_projects == 0 && do_workspaces == 0 && do_variables == 0 && do_varsets == 0 && do_registry == 0 && do_tags == 0 && do_users == 0 && do_teams == 0)); then
  #  do_projects=1
  #  do_workspaces=1
  #fi

  gum_reminder
  echo
  ((do_projects)) && show_projects "${file}" "${f_project}" && echo
  ((do_agent_pools)) && show_agent_pools "${file}" && echo
  ((do_workspaces)) && show_workspaces "${file}" "${f_project}" "${f_tag}" && echo
  ((do_variables)) && show_workspace_variables "${file}" "${f_workspace}" && echo
  ((do_varsets)) && show_varsets "${file}" "${f_project}" && echo
  ((do_registry)) && show_registry "${file}" "${f_module}" && echo
  ((do_tags)) && show_tags "${file}" && echo
  ((do_users)) && show_users "${file}" && echo
  ((do_teams)) && show_teams "${file}" && echo
  ;;

*)
  usage
  exit 2
  ;;
esac
