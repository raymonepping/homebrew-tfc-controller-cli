#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Agent Pools — namespaced functions (ap_*) to avoid collisions
# Requires commons helpers: CURL, auth_header, json_get, ok, warn, err, prompt
# Requires projects helpers: list_projects
# ------------------------------------------------------------------------------

# List all agent pools for an org (paginated)
ap_list_agent_pools() {
  local org="$1"
  local page=1 size=100 all="[]"
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
      rm -f "${tmp}"; break
    else
      err "Failed listing agent pools (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done
  echo "${all}"
}

# Get a single agent pool JSON by name (or empty)
ap_get_agent_pool_by_name() {
  local org="$1" name="$2"
  local pools; pools="$(ap_list_agent_pools "${org}")"
  jq -c --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0] // empty' <<<"${pools}"
}

# Get agent pool ID by name (or empty)
ap_agent_pool_id_by_name() {
  local org="$1" name="$2"
  [[ -n "${name}" ]] || { echo ""; return 0; }
  local j; j="$(ap_get_agent_pool_by_name "${org}" "${name}")"
  [[ -n "${j}" ]] && jq -r '.id' <<<"${j}" || echo ""
}

# Create an agent pool. Returns new ID on stdout.
# arg3 org_scoped: "true" or "false"
# arg4 allowed_project_ids_json: JSON array of project IDs, e.g. ["prj-...","prj-..."]
ap_create_agent_pool() {
  local org="$1" name="$2" org_scoped="${3:-true}" allowed_project_ids_json="${4:-[]}"

  local payload; payload="$(
    jq -n \
      --arg name "${name}" \
      --argjson scoped "$([[ "${org_scoped}" == "true" ]] && echo true || echo false)" \
      --argjson ap_ids "${allowed_project_ids_json}" '
      {
        data: {
          type: "agent-pools",
          attributes: {
            name: $name,
            "organization-scoped": $scoped
          },
          relationships:
            ( if ($ap_ids|length) > 0 then
                { "allowed-projects": { data: ($ap_ids | map({type:"projects", id:.})) } }
              else
                {}
              end
            )
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
    jq -r '.data.id' "${out}"
  elif [[ "${http}" == "404" || "${http}" == "422" || "${http}" == "409" ]]; then
    err "Agent pool create failed (HTTP ${http})"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  else
    err "Unexpected status ${http} creating agent pool '${name}'"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# Update an existing agent pool by ID (PATCH).
# Quiet: no stdout on success; caller prints user-facing messages.
# Provide org_scoped as "true"/"false" and allowed_project_ids_json as JSON array of IDs
ap_update_agent_pool() {
  local pool_id="$1" name="$2" org_scoped="${3:-true}" allowed_project_ids_json="${4:-[]}"

  local payload; payload="$(
    jq -n \
      --arg id "${pool_id}" \
      --arg name "${name}" \
      --argjson scoped "$([[ "${org_scoped}" == "true" ]] && echo true || echo false)" \
      --argjson ap_ids "${allowed_project_ids_json}" '
      {
        data: {
          id: $id,
          type: "agent-pools",
          attributes: {
            name: $name,
            "organization-scoped": $scoped
          },
          relationships:
            ( if ($ap_ids|length) > 0 then
                { "allowed-projects": { data: ($ap_ids | map({type:"projects", id:.})) } }
              else
                { "allowed-projects": { data: [] } }
              end
            )
        }
      }'
  )"

  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" -H "content-type: application/vnd.api+json" \
      -X PATCH "https://${TFE_HOST}/api/v2/agent-pools/${pool_id}" \
      -d "${payload}"
  )" || true

  if [[ "${http}" == "200" ]]; then
    :
  elif [[ "${http}" == "404" || "${http}" == "422" ]]; then
    err "Agent pool update failed (HTTP ${http})"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  else
    err "Unexpected status ${http} updating agent pool '${name}'"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# Ensure by name, return pool ID. Does not reconcile scope/allowed projects.
ensure_agent_pool() {
  local org="$1" name="$2" org_scoped="${3:-true}"
  local id; id="$(ap_agent_pool_id_by_name "${org}" "${name}")"
  if [[ -n "${id}" ]]; then
    echo "${id}"
  else
    ap_create_agent_pool "${org}" "${name}" "${org_scoped}" "[]"
  fi
}

# ------------------------------------------------------------------------------
# PLAN
# Spec shape:
# {
#   "org": { "name": "acme" },
#   "agent_pools": [
#     { "name":"local-pool", "organization_scoped":true },
#     { "name":"limited-pool", "organization_scoped":false, "allowed_projects":["Platform","Demo"] }
#   ]
# }
# ------------------------------------------------------------------------------
plan_agent_pools() {
  local spec="$1"
  local org; org="$(json_get "${spec}" '.org.name')"
  [[ -n "${org}" && "${org}" != "null" ]] || { err "Missing .org.name for agent pools"; exit 2; }

  echo "Plan (agent pools):"
  local want_count; want_count="$(jq '(.agent_pools // []) | length' "${spec}")"
  if [[ "${want_count}" -eq 0 ]]; then
    echo " - No desired agent pools in spec."
    return 0
  fi

  local have; have="$(ap_list_agent_pools "${org}")"

  jq -r '.agent_pools[] | @base64' "${spec}" | while read -r row; do
    local item name want_scoped want_allowed
    item="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<<"${item}")"
    [[ -n "${name}" && "${name}" != "null" ]] || continue
    want_scoped="$(jq -r '(.organization_scoped // true) | tostring' <<<"${item}")"
    want_allowed="$(jq -c '(.allowed_projects // [])' <<<"${item}")"

    local have_row have_id have_scoped have_allowed_ids
    have_row="$(jq -c --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0] // {}' <<<"${have}")"
    have_id="$(jq -r '.id // ""' <<<"${have_row}")"
    have_scoped="$(jq -r '(.attributes["organization-scoped"] // true) | tostring' <<<"${have_row}")"
    have_allowed_ids="$(jq -c '(.relationships["allowed-projects"].data // []) | map(.id)' <<<"${have_row}")"

    if [[ -z "${have_id}" ]]; then
      local names; names="$(jq -r 'if length==0 then "-" else join(",") end' <<<"${want_allowed}")"
      echo " - ${name}: create (scoped=${want_scoped}, allowed_projects=${names})"
      continue
    fi

    local changes=0
    if [[ "${have_scoped}" != "${want_scoped}" ]]; then
      echo " - ${name}: update scope ${have_scoped} -> ${want_scoped}"
      changes=1
    fi

    if [[ "$(jq 'length' <<<"${want_allowed}")" -gt 0 ]]; then
      echo " - ${name}: ensure allowed_projects names: $(jq -r 'join(",")' <<<"${want_allowed}")"
      if [[ "$(jq 'length' <<<"${have_allowed_ids}")" -gt 0 ]]; then
        echo "     current allowed_projects IDs: $(jq -r 'join(",")' <<<"${have_allowed_ids}")"
      fi
      changes=1
    fi

    [[ "${changes}" -eq 0 ]] && echo " - ${name}: exists"
  done
}

# ------------------------------------------------------------------------------
# APPLY
# Creates or updates pools to match spec. Only reconciles:
#  - name (idempotent, same name)
#  - organization_scoped
#  - allowed_projects (replaced with exact set from spec if provided)
# ------------------------------------------------------------------------------
apply_agent_pools() {
  local spec="$1"

  # Ask confirmation unless caller already did
  local auto="${2:-}"
  if [[ "${auto}" != "--yes" ]]; then
    prompt "Apply agent pool changes now? [y/N]: "
    read -r ans || true
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi

  local org; org="$(json_get "${spec}" '.org.name')"
  [[ -n "${org}" && "${org}" != "null" ]] || { err "Missing .org.name for agent pools"; exit 2; }

  local have; have="$(ap_list_agent_pools "${org}")"

  # Build a project name->id map for ID lookup
  local projs; projs="$(list_projects "${org}")"
  local name_to_id; name_to_id="$(
    jq -r '[ .[] | {key: .attributes.name, value: .id} ] | from_entries' <<<"${projs}"
  )"

  jq -r '.agent_pools[]? | @base64' "${spec}" | while read -r row; do
    local item name want_scoped want_allowed_names want_allowed_ids
    item="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<<"${item}")"
    [[ -n "${name}" && "${name}" != "null" ]] || continue
    want_scoped="$(jq -r '(.organization_scoped // true) | tostring' <<<"${item}")"
    want_allowed_names="$(jq -c '(.allowed_projects // [])' <<<"${item}")"

    # Resolve names -> IDs, drop unknowns
    want_allowed_ids="$(
      jq -r --argjson MP "${name_to_id}" --argjson WANT "${want_allowed_names}" '
        [ $WANT[]? as $n | ($MP[$n] // null) ] | map(select(. != null))
      '
    )"

    # Optional: warn if some project names couldn’t be resolved
    local want_names_count want_ids_count
    want_names_count="$(jq -r 'length' <<<"${want_allowed_names}")"
    want_ids_count="$(jq -r 'length' <<<"${want_allowed_ids}")"
    if [[ "${want_ids_count}" -lt "${want_names_count}" ]]; then
      local lost
      lost="$(
        jq -r --argjson MP "${name_to_id}" --argjson WANT "${want_allowed_names}" '
          [ $WANT[]? | select(($MP[.] // null) == null) ] | join(", ")
        '
      )"
      [[ -n "${lost}" ]] && warn "Agent pool '${name}': some allowed_projects not found: ${lost}"
    fi

    # Current state
    local have_row have_id have_scoped have_allowed_ids
    have_row="$(jq -c --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0] // {}' <<<"${have}")"
    have_id="$(jq -r '.id // ""' <<<"${have_row}")"
    have_scoped="$(jq -r '(.attributes["organization-scoped"] // true) | tostring' <<<"${have_row}")"
    have_allowed_ids="$(jq -c '(.relationships["allowed-projects"].data // []) | map(.id)' <<<"${have_row}")"

    if [[ -z "${have_id}" ]]; then
      # Create with desired scope and allowed projects
      local new_id
      new_id="$(ap_create_agent_pool "${org}" "${name}" "${want_scoped}" "${want_allowed_ids:-[]}")"
      ok "Agent pool created: ${name} (${new_id})"
      # refresh have cache for potential later lookups by name
      have="$(ap_list_agent_pools "${org}")"
      continue
    fi

    # Determine if update needed
    local need_update=0
    if [[ "${have_scoped}" != "${want_scoped}" ]]; then
      need_update=1
    fi
    if [[ "$(jq -c 'sort' <<<"${have_allowed_ids}")" != "$(jq -c 'sort' <<<"${want_allowed_ids}")" ]]; then
      need_update=1
    fi

    if [[ "${need_update}" -eq 0 ]]; then
      ok "Agent pool up-to-date: ${name}"
      continue
    fi

    ap_update_agent_pool "${have_id}" "${name}" "${want_scoped}" "${want_allowed_ids:-[]}"
    ok "Agent pool updated: ${name}"
  done
}
