#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Workspace + Agent Pool helpers
# ------------------------------------------------------------------------------

# List all workspaces in the org, then filter those belonging to a specific project_id.
# Signature: list_project_workspaces <org> <project_id>
list_project_workspaces() {
  local org="${1:-}"; local project_id="${2:-}"
  if [[ -z "$org" || -z "$project_id" ]]; then
    err "Internal: list_project_workspaces requires <org> and <project_id>"
    exit 2
  fi
  local page=1 size=100
  local all="[]"

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

# --- workspace variables (safe redaction) ---
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

# --- workspace tags ---
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

# --- agent pool lookups/creation ---
list_agent_pools() {
  local org="$1" page=1 size=100 all="[]"
  while true; do
    local tmp http; tmp="$(mktemp)"
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" \
        -H "$(auth_header)" \
        "https://${TFE_HOST}/api/v2/organizations/${org}/agent-pools?page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
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
      err "Failed listing agent pools (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done
  echo "${all}"
}

get_agent_pool_id_by_name() {
  local org="$1" ap_name="$2"
  local pools; pools="$(list_agent_pools "${org}")"
  jq -r --arg n "${ap_name}" '
    map(select(.attributes.name == $n)) | .[0].id // empty
  ' <<<"${pools}"
}

create_agent_pool() {
  local org="$1" ap_name="$2" org_scoped="${3:-true}"
  local payload
  payload="$(jq -n \
    --arg name "${ap_name}" \
    --argjson scoped "$( [[ "${org_scoped}" == "true" ]] && echo true || echo false )" \
    '{
      data: {
        type: "agent-pools",
        attributes: {
          name: $name,
          "organization-scoped": $scoped
        }
      }
    }'
  )"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" -H "content-type: application/vnd.api+json" \
      -X POST "https://${TFE_HOST}/api/v2/organizations/${org}/agent-pools" \
      -d "${payload}"
  )" || true
  if [[ "${http}" == "201" ]]; then
    ok "Agent pool created: ${ap_name}"
    jq -r '.data.id' "${out}"
  elif [[ "${http}" == "422" || "${http}" == "409" ]]; then
    err "Agent pool create failed (${http})."
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  else
    err "Unexpected status ${http} creating agent pool '${ap_name}'"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# Keep for export path: resolve ID -> name
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

# --- Create/read helpers ------------------------------------------------------

# Return workspace JSON if it exists (200), empty string if 404, else error
get_workspace_by_name() {
  local org="$1" name="$2"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/organizations/${org}/workspaces/${name}"
  )" || true

  if [[ "${http}" == "200" ]]; then
    cat "${out}"
  elif [[ "${http}" == "404" ]]; then
    :
  else
    err "Failed to read workspace '${name}' (HTTP ${http})"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

workspace_exists_by_name() {
  local org="$1" name="$2"
  local j; j="$(get_workspace_by_name "${org}" "${name}")"
  [[ -n "${j}" ]] && echo "yes" || echo "no"
}

workspace_id_from_json() {
  jq -r '.data.id // empty'
}

# Create a workspace under org and attach to project + optional agent pool
# Accepts optional attributes when present in the spec (best-effort)
# If execution-mode=agent and agent_pool.name is provided:
#   - resolve the pool ID; create an org-scoped pool if not found.
create_workspace() {
  local org="$1" ws_name="$2" project_id="$3"
  local tf_version="${4:-}" exec_mode="${5:-}" working_dir="${6:-}" auto_apply="${7:-}"
  local agent_pool_name="${8:-}"

  local agent_pool_rel=''
  if [[ "${exec_mode}" == "agent" ]]; then
    if [[ -n "${agent_pool_name}" ]]; then
      local ap_id
      ap_id="$(get_agent_pool_id_by_name "${org}" "${agent_pool_name}")"
      if [[ -z "${ap_id}" ]]; then
        # Create it org-scoped by default
        ap_id="$(create_agent_pool "${org}" "${agent_pool_name}" "true")"
      fi
      agent_pool_rel="$(jq -c --arg ap "${ap_id}" '{ "agent-pool": { data: { type:"agent-pools", id:$ap } } }')"
    else
      warn "Workspace '${ws_name}' requests execution-mode=agent but no agent_pool.name provided; will create without an agent-pool relation."
    fi
  fi

  local attributes relationships payload
  attributes="$(jq -n \
    --arg name "${ws_name}" \
    --arg tfv "${tf_version}" \
    --arg emode "${exec_mode}" \
    --arg wdir "${working_dir}" \
    --argjson aapply "$( [[ "${auto_apply}" == "true" ]] && echo true || echo false )" \
    '{
      name: $name
    }
    + (if $tfv   != "" then { terraform_version: $tfv } else {} end)
    + (if $emode != "" then { "execution-mode": $emode } else {} end)
    + (if $wdir  != "" then { working_directory: $wdir } else {} end)
    + { "auto-apply": $aapply }')"

  relationships="$(jq -n --arg pid "${project_id}" \
    '{ project: { data: { type:"projects", id:$pid } } }')"

  if [[ -n "${agent_pool_rel}" ]]; then
    relationships="$(jq -c --argjson r "${relationships}" --argjson ap "${agent_pool_rel}" -n '$r + $ap')"
  fi

  payload="$(jq -c --argjson attrs "${attributes}" --argjson rel "${relationships}" \
    '{ data: { type:"workspaces", attributes: $attrs, relationships: $rel } }')"

  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      -H "content-type: application/vnd.api+json" \
      -X POST "https://${TFE_HOST}/api/v2/organizations/${org}/workspaces" \
      -d "${payload}"
  )" || true

  if [[ "${http}" == "201" ]]; then
    ok "Workspace created: ${ws_name}"
  elif [[ "${http}" == "422" ]]; then
    err "Workspace create failed (422)."
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  else
    err "Unexpected status ${http} creating workspace '${ws_name}'"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# Attach an existing workspace to a project (no-op if already attached)
attach_workspace_to_project() {
  local ws_id="$1" project_id="$2"
  local payload
  payload="$(jq -n --arg pid "${project_id}" \
    '{ data: { type: "projects", id: $pid } }'
  )"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      -H "content-type: application/vnd.api+json" \
      -X PATCH "https://${TFE_HOST}/api/v2/workspaces/${ws_id}/relationships/project" \
      -d "${payload}"
  )" || true
  if [[ "${http}" == "204" ]]; then
    ok "Workspace attached to project"
  else
    err "Failed attaching workspace to project (HTTP ${http})"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# --- Spec readers -------------------------------------------------------------

# Iterate all workspaces for a given project name from spec; one JSON line/object each:
# Normalizes:
#   "workspaces": ["a","b"]     -> {name:"a"}, {name:"b"}
#   "workspaces": [{name:"a"}, {name:"b", tf_version:"1.7.5"}]
# Supports:
#   execution_mode or "execution-mode"
#   agent_pool.name (optional)
each_spec_workspace_for_project() {
  local spec="$1" project_name="$2"
  jq -c --arg pname "${project_name}" '
    (.projects // [])
    | map(select(.name == $pname))
    | .[0] // {}
    | (.workspaces // [])
    | map(
        if type=="string" then {name: .}
        else .
        end
      )
    | map(
        . as $w
        | $w
        | (.execution_mode // .["execution-mode"] // null) as $emode
        | if $emode != null then
            . + {"execution-mode": $emode} | del(.execution_mode)
          else
            .
          end
      )
    | .[]
  ' "${spec}"
}

# --- Planner / applier for workspaces ----------------------------------------

plan_workspaces_for_project() {
  local spec="$1" project_name="$2" project_id="$3"
  local org="${ORG:-${ORG_NAME:-}}"
  [[ -n "${org}" ]] || { err "Internal: ORG not set"; exit 2; }

  local any=0
  while IFS= read -r ws; do
    any=1
    local name emode
    name="$(jq -r '.name' <<<"$ws")"
    emode="$(jq -r '."execution-mode" // ""' <<<"$ws")"

    if [[ "$(workspace_exists_by_name "${org}" "${name}")" == "yes" ]]; then
      echo "Plan (workspace): ${name} — no changes (exists)"
    else
      if [[ "${emode}" == "agent" ]]; then
        local ap_name; ap_name="$(jq -r '.agent_pool.name // ""' <<<"$ws")"
        if [[ -z "${ap_name}" ]]; then
          warn "Plan (workspace): ${name} — create (agent mode) BUT no agent_pool.name specified"
        else
          echo "Plan (workspace): ${name} — create (agent: ${ap_name})"
        fi
      else
        echo "Plan (workspace): ${name} — create"
      fi
    fi
  done < <(each_spec_workspace_for_project "${spec}" "${project_name}")

  [[ $any -eq 1 ]] || true
}

apply_workspaces_for_project() {
  local spec="$1" project_name="$2" project_id="$3"
  local org="${ORG:-${ORG_NAME:-}}"
  [[ -n "${org}" ]] || { err "Internal: ORG not set"; exit 2; }

  while IFS= read -r ws; do
    local name tfv emode wdir aapply ap_name
    name="$(jq -r '.name' <<<"$ws")"
    tfv="$(jq -r '.tf_version // ""' <<<"$ws")"
    emode="$(jq -r '."execution-mode" // ""' <<<"$ws")"
    wdir="$(jq -r '.working_directory // ""' <<<"$ws")"
    aapply="$(jq -r '(.auto_apply // false) | tostring' <<<"$ws")"
    ap_name="$(jq -r '.agent_pool.name // ""' <<<"$ws")"

    if [[ "$(workspace_exists_by_name "${org}" "${name}")" == "yes" ]]; then
      # Attach to project if needed
      local ws_json ws_id cur_pid
      ws_json="$(get_workspace_by_name "${org}" "${name}")"
      ws_id="$(workspace_id_from_json <<<"${ws_json}")"
      cur_pid="$(jq -r '.data.relationships.project.data.id // empty' <<<"${ws_json}")"
      if [[ -n "${ws_id}" && "${cur_pid}" != "${project_id}" ]]; then
        attach_workspace_to_project "${ws_id}" "${project_id}"
      else
        ok "Workspace '${name}' already up-to-date"
      fi
    else
      create_workspace "${org}" "${name}" "${project_id}" "${tfv}" "${emode}" "${wdir}" "${aapply}" "${ap_name}"
      ok "Workspace created in ${project_name}: ${name}"
    fi
  done < <(each_spec_workspace_for_project "${spec}" "${project_name}")
}