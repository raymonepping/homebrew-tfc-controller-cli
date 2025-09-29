#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# List all workspaces in the org, then filter those belonging to a specific project_id.
list_project_workspaces() {
  local project_id="$1"
  local page=1 size=100
  local all="[]"

  # We rely on ORG being exported by export_live()
  local org="${ORG:-${ORG_NAME:-}}"
  if [[ -z "${org}" ]]; then
    err "Internal: ORG not set for list_project_workspaces"; exit 2
  fi

  while true; do
    local tmp http; tmp="$(mktemp)"
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" \
        -H "$(auth_header)" \
        "https://${TFE_HOST}/api/v2/organizations/${org}/workspaces?page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
    )" || true
    if [[ "${http}" == "200" ]]; then
      local chunk; chunk="$(jq '.data // []' "${tmp}")"
      local count; count="$(jq 'length' <<<"${chunk}")"
      all="$(jq -c --argjson a "${all}" --argjson b "${chunk}" -n '$a + $b')"
      rm -f "${tmp}"
      [[ "${count}" -lt "${size}" ]] && break
      page=$((page+1))
    elif [[ "${http}" == "404" ]]; then
      rm -f "${tmp}"
      break
    else
      err "Failed listing org workspaces (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done

  # Filter to only those whose relationship project id matches
  echo "${all}" | jq -c --arg pid "${project_id}" '
    map(select(.relationships.project.data.id == $pid))
  '
}

# --- NEW: workspace variables (safe redaction) ---
list_workspace_vars() {
  local ws_id="$1"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/workspaces/${ws_id}/vars"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '.data // [] | map({
      key: .attributes.key,
      category: .attributes.category,
      hcl: (.attributes.hcl // false),
      sensitive: (.attributes.sensitive // false),
      value: (if (.attributes.sensitive // false) then null else (.attributes.value // null) end),
      value_ref: (if (.attributes.sensitive // false) then "vault:UNKNOWN" else null end)
    })' "${out}"
  else
    echo "[]"
  fi
  rm -f "${out}"
}

# --- NEW: workspace tags ---
list_workspace_tags() {
  local ws_id="$1"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/workspaces/${ws_id}/tags"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '[.data[]?.attributes.name] // []' "${out}"
  else
    echo "[]"
  fi
  rm -f "${out}"
}

# --- NEW: agent pool name lookup (best-effort) ---
get_agent_pool_name() {
  local pool_id="$1"
  [[ -z "${pool_id}" || "${pool_id}" == "null" ]] && { echo ""; return 0; }
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/agent-pools/${pool_id}"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '.data.attributes.name // ""' "${out}"
  else
    echo ""
  fi
  rm -f "${out}"
}
