#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

list_projects() {
  local org="$1" page=1 size=100 all="[]"
  while true; do
    local tmp http; tmp="$(mktemp)"
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" \
        -H "$(auth_header)" \
        "https://${TFE_HOST}/api/v2/organizations/${org}/projects?page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
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
      err "Failed listing projects (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done
  echo "${all}"
}

create_project() {
  local org="$1" name="$2" desc="${3:-}" out http; out="$(mktemp)"
  local payload; payload=$(jq -n --arg n "${name}" --arg d "${desc}" '{
    data: { type: "projects", attributes: { name: $n, description: ($d // "") } }
  }')
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" -H "content-type: application/vnd.api+json" \
      -X POST "https://${TFE_HOST}/api/v2/organizations/${org}/projects" \
      -d "${payload}"
  )" || true
  if [[ "${http}" == "201" ]]; then
    ok "Project created: ${name}"
  elif [[ "${http}" == "409" || "${http}" == "422" ]]; then
    warn "Project create failed"
    cat "${out}" || true
    rm -f "${out}"
    exit 1
  else
    err "Unexpected status ${http} creating project"
    cat "${out}" || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# --- plan projects + their workspaces (from spec) ---
plan_projects() {
  local spec="$1"
  local org; org=$(json_get "${spec}" '.org.name')
  [[ -n "${org}" && "${org}" != "null" ]] || { err "Missing .org.name for projects"; exit 2; }

  local have; have="$(list_projects "${org}")"
  local want_count; want_count="$(jq '(.projects // []) | length' "${spec}")"

  echo "Plan (projects):"
  if [[ "${want_count}" -eq 0 ]]; then
    echo " - No desired projects in spec."
    return 0
  fi

  jq -r '.projects[] | @base64' "${spec}" | while read -r row; do
    local item name; item="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<<"${item}")"

    # project existence
    local proj_id; proj_id="$(jq -r --arg n "${name}" '
      map(select(.attributes.name == $n)) | .[0].id // empty
    ' <<<"${have}")"
    if [[ -n "${proj_id}" ]]; then
      echo " - ${name}: exists"
    else
      echo " - ${name}: create"
    fi

    # workspaces under this project
    local ws_array; ws_array="$(jq -c '(.workspaces // [])' <<<"${item}")"
    local ws_count; ws_count="$(jq 'length' <<<"${ws_array}")"
    if [[ "${ws_count}" -gt 0 ]]; then
      local have_ws="[]"
      if [[ -n "${proj_id}" ]]; then
        have_ws="$(list_project_workspaces "${org}" "${proj_id}")"
      fi

      jq -r '.[] | @base64' <<<"${ws_array}" | while read -r ws_row; do
        local ws_spec ws_name; ws_spec="$(echo "${ws_row}" | base64 --decode)"
        ws_name="$(jq -r '.name' <<<"${ws_spec}")"
        [[ -n "${ws_name}" && "${ws_name}" != "null" ]] || continue

        local exists_ws_id=""
        if [[ -n "${proj_id}" ]]; then
          exists_ws_id="$(jq -r --arg n "${ws_name}" '
            map(select(.attributes.name == $n)) | .[0].id // empty
          ' <<<"${have_ws}")"
        fi

        if [[ -n "${exists_ws_id}" ]]; then
          echo "    - ws ${ws_name}: exists"
        else
          echo "    - ws ${ws_name}: create"
        fi
      done
    fi
  done
}

# --- apply projects + their workspaces (from spec) ---
# --- apply projects + their workspaces (with agent pool support) ---
apply_projects() {
  local spec="$1" auto="${2:-}"
  if [[ "${auto}" != "--yes" ]]; then
    prompt "Apply project changes now? [y/N]: "
    read -r ans || true
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi

  local org; org=$(json_get "${spec}" '.org.name')
  local have; have="$(list_projects "${org}")"

  jq -r '.projects[]? | @base64' "${spec}" | while read -r row; do
    local item name desc
    item="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<<"${item}")"
    desc="$(jq -r '.description // ""' <<<"${item}")"

    # ensure project
    local proj_id; proj_id="$(jq -r --arg n "${name}" '
      map(select(.attributes.name == $n)) | .[0].id // empty
    ' <<<"${have}")"
    if [[ -n "${proj_id}" ]]; then
      ok "Project exists: ${name}"
    else
      create_project "${org}" "${name}" "${desc}"
      # refresh
      have="$(list_projects "${org}")"
      proj_id="$(jq -r --arg n "${name}" '
        map(select(.attributes.name == $n)) | .[0].id // empty
      ' <<<"${have}")"
    fi

    # workspaces for this project (if any)
    local ws_array; ws_array="$(jq -c '(.workspaces // [])' <<<"${item}")"
    local ws_count; ws_count="$(jq 'length' <<<"${ws_array}")"
    if [[ "${ws_count}" -gt 0 ]]; then
      local have_ws; have_ws="$(list_project_workspaces "${org}" "${proj_id}")"

      jq -r '.[] | @base64' <<<"${ws_array}" | while read -r ws_row; do
        local ws_spec ws_name
        ws_spec="$(echo "${ws_row}" | base64 --decode)"
        ws_name="$(jq -r '.name' <<<"${ws_spec}")"
        [[ -n "${ws_name}" && "${ws_name}" != "null" ]] || continue

        local exists_ws_id; exists_ws_id="$(jq -r --arg n "${ws_name}" '
          map(select(.attributes.name == $n)) | .[0].id // empty
        ' <<<"${have_ws}")"

        if [[ -n "${exists_ws_id}" ]]; then
          ok "Workspace exists in ${name}: ${ws_name}"
          continue
        fi

        # Optional fields
        local tfv emode wdir aapply
        tfv="$(jq -r '.terraform_version // .tf_version // ""' <<<"${ws_spec}")"
        emode="$(jq -r '.execution_mode // ."execution-mode" // ""' <<<"${ws_spec}")"
        wdir="$(jq -r '.working_directory // ""' <<<"${ws_spec}")"
        aapply="$(jq -r '(.auto_apply // false) | tostring' <<<"${ws_spec}")"

        # Agent pool handling (ensure/lookup before create)
        local ap_name ap_id=""
        if [[ "${emode}" == "agent" ]]; then
          ap_name="$(jq -r '.agent_pool.name // .agent_pool // ""' <<<"${ws_spec}")"
          if [[ -z "${ap_name}" ]]; then
            err "Workspace '${ws_name}' requires execution_mode=agent but no agent_pool.name provided in spec."
            exit 2
          fi
          # Ensure agent pool, get id
          ap_id="$(ensure_agent_pool "${org}" "${ap_name}" "true")"
        fi

        create_workspace "${org}" "${ws_name}" "${proj_id}" "${tfv}" "${emode}" "${wdir}" "${aapply}" "${ap_id}"
        ok "Workspace created in ${name}: ${ws_name}"

        # refresh have_ws for subsequent checks
        have_ws="$(list_project_workspaces "${org}" "${proj_id}")"
      done
    fi
  done
}
