#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# List variable sets for the org
list_varsets() {
  local org="$1" page=1 size=100 all="[]"
  while true; do
    local tmp http; tmp="$(mktemp)"
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" \
        -H "$(auth_header)" \
        "https://${TFE_HOST}/api/v2/organizations/${org}/varsets?page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
    )" || true
    if [[ "${http}" == "200" ]]; then
      local chunk; chunk="$(jq '.data // []' "${tmp}")"
      local count; count="$(jq 'length' <<<"${chunk}")"
      all="$(jq -c --argjson a "${all}" --argjson b "${chunk}" -n '$a + $b')"
      rm -f "${tmp}"
      [[ "${count}" -lt "${size}" ]] && break
      page=$((page+1))
    elif [[ "${http}" == "404" ]]; then
      rm -f "${tmp}"; break
    else
      err "Failed listing varsets (HTTP ${http})"; cat "${tmp}" >&2 || true; rm -f "${tmp}"; exit 1
    fi
  done
  echo "${all}"
}

# Variables inside a varset (safe: do not export values)
list_varset_vars() {
  local vs_id="$1"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/varsets/${vs_id}/variables"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '.data // [] | map({
      key: .attributes.key,
      category: .attributes.category,
      hcl: (.attributes.hcl // false),
      sensitive: (.attributes.sensitive // false)
    })' "${out}"
  else
    echo "[]"
  fi
  rm -f "${out}"
}

# Scopes for a varset (global / projects / workspaces)
# Best-effort: grab relationships for projects & workspaces, and the is-global flag.
get_varset_scope() {
  local vs="$1"
  local is_global; is_global="$(jq -r '.attributes."is-global" // false' <<<"${vs}")"
  local prj_ids; prj_ids="$(jq -r '[.relationships.projects.data[]?.id] // []' <<<"${vs}")"
  local ws_ids;  ws_ids="$(jq -r '[.relationships.workspaces.data[]?.id] // []' <<<"${vs}")"
  jq -n --argjson g "${is_global}" --argjson p "${prj_ids}" --argjson w "${ws_ids}" \
    '{ is_global: $g, project_ids: $p, workspace_ids: $w }'
}
