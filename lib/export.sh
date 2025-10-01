#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Expects commons.sh to define: CURL, auth_header, gum_* helpers
# Expects the following libs to be sourced by the controller:
#   org.sh               -> org_get_raw
#   projects.sh          -> list_projects
#   workspaces.sh        -> list_workspace_tags list_workspace_vars
#   varsets.sh           -> list_varsets get_varset_scope
#   registry.sh          -> list_registry_modules list_registry_module_versions
#   tags.sh              -> list_reserved_tag_keys
#   users.sh             -> list_org_users
#   teams.sh             -> list_org_teams_raw

# local helper: generic paginated .data fetch (kept private to this file)
__export_paged_get_data() {
  local url_base="$1" page=1 size=100 all="[]"
  while true; do
    local tmp http sep
    tmp="$(mktemp)"
    if [[ "$url_base" == *\?* ]]; then sep="&"; else sep="?"; fi
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" -H "$(auth_header)" \
        "${url_base}${sep}page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
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
      err "GET ${url_base} failed (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done
  echo "${all}"
}

export_live() {
  # local org="$1" out_file="$2" profile="${3:-minimal}"
  local org="$1" out_file="$2" profile="${3:-minimal}" doc_out="${4:-}" doc_tpl="${5:-}"
  export ORG="${org}"

  # 1) Organization
  gum_spinner_start "Reading organization"
  local org_raw; org_raw="$(org_get_raw "${org}")"
  gum_spinner_stop
  local org_obj; org_obj="$(
    jq -r '{
      org: {
        name:        .data.attributes.name,
        email:       .data.attributes.email,
        sso:         { enforced: (.data.attributes."sso-enabled" // false) }
      }
    }' <<< "${org_raw}"
  )"

  # 2) Projects
  gum_spinner_start "Fetching projects"
  local projects_raw; projects_raw="$(list_projects "${org}")"
  gum_spinner_stop
  local projects; projects="$(
    jq -r '[ .[] | { id: .id, name: .attributes.name, description: (.attributes.description // "") } ]' <<< "${projects_raw}"
  )"
  local prj_map; prj_map="$(jq -r '[ .[] | {key: .id, value: .name} ] | from_entries' <<< "${projects}")"

  # 2a) Agent Pools (list once, shape for export, and build id->name map)
  gum_spinner_start "Listing agent pools"
  local agent_pools_raw
  if command -v ap_list_agent_pools >/dev/null 2>&1; then
    agent_pools_raw="$(ap_list_agent_pools "${org}")"
  else
    # Fallback, in case agent_pools.sh is not sourced for some reason
    agent_pools_raw="$(__export_paged_get_data "https://${TFE_HOST}/api/v2/organizations/${org}/agent-pools")"
  fi
  gum_spinner_stop

# Shape agent pools into export-friendly form and a map for quick lookups
  local agent_pools
  agent_pools="$(
    jq -r --argjson mp "${prj_map}" '
      [ .[] |
        {
          id: .id,
          name: (.attributes.name // ""),
          organization_scoped: (.attributes["organization-scoped"] // true),
          allowed_projects: (
            (.relationships["allowed-projects"].data // [])
            | map(.id)
            | map($mp[.] // .)
          )
        }
      ]' <<< "${agent_pools_raw}"
  )"
  # Build pool id -> name map for workspace shaping
  local ap_map; ap_map="$(jq -r '[ .[] | {key: .id, value: .name} ] | from_entries' <<< "${agent_pools}")"






  # 3) Workspaces (org-wide pagination)
  gum_spinner_start "Listing workspaces"
  local page=1 size=100 all_ws="[]"
  while true; do
    local tmp http; tmp="$(mktemp)"
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/organizations/${org}/workspaces?page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
    )" || true
    if [[ "${http}" == "200" ]]; then
      local chunk; chunk="$(jq '.data // []' "${tmp}")"
      local count; count="$(jq 'length' <<<"${chunk}")"
      all_ws="$(jq -c --argjson a "${all_ws}" --argjson b "${chunk}" -n '$a + $b')"
      rm -f "${tmp}"
      [[ "${count}" -lt "${size}" ]] && break
      page=$((page+1))
    elif [[ "${http}" == "404" ]]; then
      rm -f "${tmp}"; break
    else
      err "Failed listing org workspaces (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done
  gum_spinner_stop

  # 3a) Shape workspaces (progress)
  local workspaces_all="[]"
  mapfile -t __ws_rows < <(jq -r '.[] | @base64' <<< "${all_ws}")
  local ws_total="${#__ws_rows[@]}"
  local ws_count=0
  (( ws_total > 0 )) && gum_progress_begin "Shaping workspaces" "${ws_total}"
  for __wrow in "${__ws_rows[@]}"; do
    ws_count=$((ws_count+1))
    gum_progress_tick "${ws_count}" "${ws_total}"

    local w ws_id ws_name exec_mode auto_apply tfv queue_all project_id project_name
    w="$(echo "${__wrow}" | base64 --decode)"
    ws_id="$(jq -r '.id' <<< "${w}")"
    ws_name="$(jq -r '.attributes.name' <<< "${w}")"
    exec_mode="$(jq -r '.attributes."execution-mode" // "remote"' <<< "${w}")"
    auto_apply="$(jq -r '.attributes."auto-apply" // false' <<< "${w}")"
    tfv="$(jq -r '.attributes."terraform-version" // ""' <<< "${w}")"
    queue_all="$(jq -r '.attributes."queue-all-runs" // false' <<< "${w}")"
    project_id="$(jq -r '.relationships.project.data.id // ""' <<< "${w}")"
    project_name="$(jq -r --arg pid "${project_id}" -n --argjson mp "${prj_map}" '$mp[$pid] // "Unknown Project"')"

    local pool_id pool_name vcs vcs_obj
    pool_id="$(jq -r '.relationships."agent-pool".data.id // ""' <<< "${w}")"
    # pool_name="$(get_agent_pool_name "${pool_id}")"
    pool_name="$(jq -r --arg pid "${pool_id}" -n --argjson mp "${ap_map}" '$mp[$pid] // ""')"
    vcs="$(jq -r '.attributes."vcs-repo" // {}' <<< "${w}")"

    if [[ "${profile}" == "minimal" ]]; then
      vcs_obj="$(
        jq -n \
          --arg rid "$(jq -r '.identifier // ""' <<< "${vcs}")" \
          --arg branch "$(jq -r '.branch // ""' <<< "${vcs}")" \
          '{ repo_identifier: $rid, branch: $branch }'
      )"
      local ws_obj; ws_obj="$(
        jq -n \
          --arg project_name "${project_name}" \
          --arg id "${ws_id}" \
          --arg name "${ws_name}" \
          --arg exec_mode "${exec_mode}" \
          --arg tfv "${tfv}" \
          --argjson auto "${auto_apply}" \
          --argjson queue "${queue_all}" \
          --argjson vcs "${vcs_obj}" \
          --arg agent_pool_name "${pool_name}" \
          --argjson tags "$(list_workspace_tags "${ws_id}")" \
          '{
            project_name: $project_name,
            id: $id,
            name: $name,
            execution_mode: $exec_mode,
            auto_apply: $auto,
            terraform_version: $tfv,
            queue_all_runs: $queue,
            agent_pool: { name: $agent_pool_name },
            vcs: $vcs,
            tags: $tags
          }'
      )"
      workspaces_all="$(jq -c --argjson a "${workspaces_all}" --argjson b "${ws_obj}" -n '$a + [$b]')"
    else
      vcs_obj="$(
        jq -n \
          --arg rid "$(jq -r '.identifier // ""' <<< "${vcs}")" \
          --arg branch "$(jq -r '.branch // ""' <<< "${vcs}")" \
          --arg oauth "$(jq -r '."oauth-token-id" // ""' <<< "${vcs}")" \
          '{ repo_identifier: $rid, branch: $branch, oauth_token_id: $oauth }'
      )"
      local agent_obj; agent_obj="$(jq -n --arg id "${pool_id}" --arg name "${pool_name}" '{ id: ($id // ""), name: ($name // "") }')"
      local tags; tags="$(list_workspace_tags "${ws_id}")"
      local ws_obj; ws_obj="$(
        jq -n \
          --arg project_name "${project_name}" \
          --arg id "${ws_id}" \
          --arg name "${ws_name}" \
          --arg exec_mode "${exec_mode}" \
          --argjson auto "${auto_apply}" \
          --arg tfv "${tfv}" \
          --argjson queue "${queue_all}" \
          --argjson tags "${tags}" \
          --argjson agent "${agent_obj}" \
          --argjson vcs "${vcs_obj}" \
          '{
            project_name: $project_name,
            id: $id,
            name: $name,
            execution_mode: $exec_mode,
            auto_apply: $auto,
            terraform_version: $tfv,
            queue_all_runs: $queue,
            agent_pool: $agent,
            vcs: $vcs,
            tags: $tags
          }'
      )"
      workspaces_all="$(jq -c --argjson a "${workspaces_all}" --argjson b "${ws_obj}" -n '$a + [$b]')"
    fi
  done
  (( ws_total > 0 )) && gum_progress_end

  # 3b) Workspace variables (keys only; progress)
  local workspace_variables="[]"
  local var_count=0
  (( ws_total > 0 )) && gum_progress_begin "Collecting workspace variables" "${ws_total}"
  for __wrow in "${__ws_rows[@]}"; do
    var_count=$((var_count+1))
    gum_progress_tick "${var_count}" "${ws_total}"

    local w ws_id ws_name vars_meta
    w="$(echo "${__wrow}" | base64 --decode)"
    ws_id="$(jq -r '.id' <<< "${w}")"
    ws_name="$(jq -r '.attributes.name' <<< "${w}")"
    vars_meta="$(list_workspace_vars "${ws_id}")"
    vars_meta="$(jq 'map({key, category, hcl, sensitive})' <<<"${vars_meta}")"
    local wsv; wsv="$(
      jq -n --arg id "${ws_id}" --arg name "${ws_name}" --argjson vars "${vars_meta}" \
        '{ workspace_id: $id, workspace_name: $name, variables: $vars }'
    )"
    workspace_variables="$(jq -c --argjson a "${workspace_variables}" --argjson b "${wsv}" -n '$a + [$b]')"
  done
  (( ws_total > 0 )) && gum_progress_end

  # 4) Variable sets (progress)
  gum_spinner_start "Listing variable sets"
  local varsets_raw; varsets_raw="$(list_varsets "${org}")"
  gum_spinner_stop
  local varsets="[]"
  mapfile -t __vs_rows < <(jq -r '.[] | @base64' <<< "${varsets_raw}")
  local vs_total="${#__vs_rows[@]}"
  local vs_count=0
  (( vs_total > 0 )) && gum_progress_begin "Fetching varset keys" "${vs_total}"
  for __vsrow in "${__vs_rows[@]}"; do
    vs_count=$((vs_count+1))
    gum_progress_tick "${vs_count}" "${vs_total}"

    local vs vs_id vs_name vs_desc scope vars_meta
    vs="$(echo "${__vsrow}" | base64 --decode)"
    vs_id="$(jq -r '.id' <<< "${vs}")"
    vs_name="$(jq -r '.attributes.name // ""' <<< "${vs}")"
    vs_desc="$(jq -r '.attributes.description // ""' <<< "${vs}")"
    scope="$(get_varset_scope "${vs}")"
    vars_meta="$(list_varset_vars "${vs_id}")"  # keys only

    local vs_obj; vs_obj="$(
      jq -n \
        --arg id "${vs_id}" \
        --arg name "${vs_name}" \
        --arg desc "${vs_desc}" \
        --argjson scope "${scope}" \
        --argjson vars "${vars_meta}" \
        '{ id: $id, name: $name, description: $desc, scope: $scope, variables: $vars }'
    )"
    varsets="$(jq -c --argjson a "${varsets}" --argjson b "${vs_obj}" -n '$a + [$b]')"
  done
  (( vs_total > 0 )) && gum_progress_end

  # 5) Private Registry (modules + versions)
  gum_spinner_start "Listing registry modules"
  local reg_modules_raw; reg_modules_raw="$(list_registry_modules "${org}")"
  gum_spinner_stop

  local registry_modules="[]"
  mapfile -t __rm_rows < <(jq -r '.[] | @base64' <<< "${reg_modules_raw}")
  local rm_total="${#__rm_rows[@]}"
  local rm_count=0
  (( rm_total > 0 )) && gum_progress_begin "Fetching module versions" "${rm_total}"
  for __rmrow in "${__rm_rows[@]}"; do
    rm_count=$((rm_count+1))
    gum_progress_tick "${rm_count}" "${rm_total}"

    local m m_id m_name m_provider m_namespace m_vcs versions_raw versions_arr latest
    m="$(echo "${__rmrow}" | base64 --decode)"
    m_id="$(jq -r '.id' <<< "${m}")"
    m_name="$(jq -r '.attributes.name // ""' <<< "${m}")"
    m_provider="$(jq -r '.attributes.provider // ""' <<< "${m}")"
    m_namespace="$(jq -r '.attributes.namespace // ""' <<< "${m}")"
    m_vcs="$(jq -r '.attributes."vcs-repo".identifier // ""' <<< "${m}")"

    versions_raw="$(list_registry_module_versions "${m_id}")"
    versions_arr="$(jq -r '[ .[] | .attributes.version // empty ]' <<< "${versions_raw}")"
    latest="$(jq -r '.[0] // ""' <<< "${versions_arr}")"

    local mod_obj
    mod_obj="$(
      jq -n \
        --arg id "${m_id}" \
        --arg name "${m_name}" \
        --arg provider "${m_provider}" \
        --arg namespace "${m_namespace}" \
        --arg vcs "${m_vcs}" \
        --arg latest "${latest}" \
        --argjson versions "${versions_arr}" \
        '{ id:$id, name:$name, provider:$provider, namespace:$namespace, vcs_repo:$vcs, latest:$latest, versions:$versions }'
    )"
    registry_modules="$(jq -c --argjson a "${registry_modules}" --argjson b "${mod_obj}" -n '$a + [$b]')"
  done
  (( rm_total > 0 )) && gum_progress_end
  local registry_obj; registry_obj="$(jq -n --argjson modules "${registry_modules}" '{ modules: $modules }')"

  # 6) Org Tag Management: Reserved Keys
  gum_spinner_start "Fetching org reserved tag keys"
  local reserved_keys; reserved_keys="$(list_reserved_tag_keys "${org}")"
  gum_spinner_stop
  local tags_obj; tags_obj="$(jq -n --argjson keys "${reserved_keys}" '{ reserved_keys: $keys }')"

  # 7) Users (with team memberships)
  gum_spinner_start "Fetching users"
  local users; users="$(list_org_users "${org}")"
  gum_spinner_stop

  # 8) Teams (full)
  gum_spinner_start "Fetching teams"
  local teams_raw; teams_raw="$(list_org_teams_raw "${org}")"
  gum_spinner_stop

  # 8a) teams.core
  local teams_core="[]"
  if [[ -n "${teams_raw}" && "${teams_raw}" != "null" ]]; then
    teams_core="$(
      jq -r '[ .[] | {
        id: .id,
        name: (.attributes.name // ""),
        users_count: (.attributes."users-count" // 0),
        visibility: (.attributes.visibility // ""),
        sso_team_id: (.attributes."sso-team-id"),
        allow_member_token_management: (.attributes."allow-member-token-management" // false),
        organization_access: (.attributes."organization-access" // {})
      } ]' <<< "${teams_raw}"
    )"
  fi

  # 8b) teams.memberships (edges)
  local teams_memberships="[]"
  if [[ -n "${teams_raw}" && "${teams_raw}" != "null" ]]; then
    teams_memberships="$(
      jq -r '[ .[] as $t
               | ($t.id // "") as $tid
               | ($t.relationships.users.data // [])
               | map({ team_id: $tid, user_id: (.id // "") })
             ] | add // []' <<< "${teams_raw}"
    )"
  fi

  # 8c) teams.project_access (edges) via /team-projects?filter[project][id]=...
  # iterate over projects we already fetched
  local team_projects_edges="[]"
  mapfile -t __prj_rows < <(jq -r '.[] | @base64' <<< "${projects}")
  local pr_total="${#__prj_rows[@]}"
  local pr_count=0
  (( pr_total > 0 )) && gum_progress_begin "Fetching team-project access" "${pr_total}"
  for __prow in "${__prj_rows[@]}"; do
    pr_count=$((pr_count+1))
    gum_progress_tick "${pr_count}" "${pr_total}"

    local p pid
    p="$(echo "${__prow}" | base64 --decode)"
    pid="$(jq -r '.id' <<< "${p}")"
    [[ -z "${pid}" ]] && continue

    local url="https://${TFE_HOST}/api/v2/team-projects?filter%5Bproject%5D%5Bid%5D=${pid}"
    local tprj; tprj="$(__export_paged_get_data "${url}")"
    if [[ -n "${tprj}" && "${tprj}" != "null" ]]; then
      local edges
      edges="$(
        jq -r --arg pid "${pid}" '[
          .[] | {
            project_id: $pid,
            team_id: (.relationships.team.data.id // ""),
            access: (.attributes.access // ""),
            project_access: (.attributes."project-access" // {}),
            workspace_access: (.attributes."workspace-access" // {})
          }
        ]' <<< "${tprj}"
      )"
      team_projects_edges="$(jq -c --argjson A "${team_projects_edges}" --argjson B "${edges}" -n '$A + $B')"
    fi
  done
  (( pr_total > 0 )) && gum_progress_end

  local teams_full; teams_full="$(
    jq -n \
      --argjson core "${teams_core}" \
      --argjson memberships "${teams_memberships}" \
      --argjson projacc "${team_projects_edges}" \
      '{ core: $core, memberships: $memberships, project_access: $projacc }'
  )"

  # Final assembly
  local assembled; assembled="$(
    jq -n \
      --argjson org        "${org_obj}" \
      --argjson projects   "${projects}" \
      --argjson agent_pools "${agent_pools}" \
      --argjson workspaces "${workspaces_all}" \
      --argjson wvars      "${workspace_variables}" \
      --argjson varsets    "${varsets}" \
      --argjson registry   "${registry_obj}" \
      --argjson tags       "${tags_obj}" \
      --argjson users      "${users}" \
      --argjson teams      "${teams_full}" \
      '$org + {
        projects: $projects,
        agent_pools: $agent_pools,
        workspaces: $workspaces,
        workspace_variables: $wvars,
        varsets: $varsets,
        registry: $registry,
        tags: $tags,
        users: $users,
        teams: $teams
      }'
  )"

  # Write to disk
  mkdir -p "$(dirname "${out_file}")"
  printf '%s\n' "${assembled}" | jq '.' > "${out_file}"
  ok "Exported to ${out_file}"

  # Optional: emit markdown document
  if [[ -n "${doc_out}" ]]; then
    if command -v doc_render_from_export >/dev/null 2>&1; then
      gum_spinner_start "Rendering markdown document"
      doc_render_from_export "${out_file}" "${doc_out}" "${doc_tpl:-}"
      gum_spinner_stop
      ok "Document written to ${doc_out}"
    else
      warn "document.sh not loaded; skipping markdown render"
    fi
  fi
}