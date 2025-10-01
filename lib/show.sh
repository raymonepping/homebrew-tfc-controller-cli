#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

has_cmd() { command -v "$1" >/dev/null 2>&1; }
_has_gum() { command -v gum >/dev/null 2>&1; }

gum_title() {
  local title="${1:-}"
  [[ -z "${title}" ]] && return 0
  if _has_gum; then
    gum style --bold --foreground 212 "${title}" || echo "== ${title} =="
  else
    echo "== ${title} =="
  fi
}

# ---------------- Projects ----------------
show_projects() {
  local file="$1"
  local filter_name="${2:-}"
  local jq_base='.projects[] | {id, name, description: (.description // "")}'
  if [[ -n "${filter_name}" ]]; then
    jq_base=".projects[] | select(.name == \"${filter_name}\") | {id, name, description: (.description // \"\")}"
  fi

  if _has_gum; then
    gum_title "Projects"
    jq -r "${jq_base} | [ .id, .name, .description ] | @csv" "${file}" \
      | gum table --columns "ID,Name,Description" --print
  else
    echo "Projects"
    {
      echo -e "ID\tName\tDescription"
      jq -r "${jq_base} | [ .id, .name, .description ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ---------------- Workspaces ----------------
show_workspaces() {
  local file="$1"
  local filter_project="${2:-}"
  local filter_tag="${3:-}"

  local sel='.workspaces[]'
  [[ -n "${filter_project}" ]] && sel="${sel} | select(.project_name == \"${filter_project}\")"
  [[ -n "${filter_tag}"     ]] && sel="${sel} | select(.tags[]? == \"${filter_tag}\")"

  local jq_row="${sel} | {
      id,
      name,
      project_name,
      execution_mode,
      terraform_version,
      auto_apply,
      queue_all_runs,
      agent_pool: (.agent_pool.name // \"\"),
      vcs_repo:   (.vcs.repo_identifier // \"\"),
      branch:     (.vcs.branch // \"\")
    }"

  if _has_gum; then
    gum_title "Workspaces"
    jq -r "${jq_row}
      | [ .id, .name, .project_name, .execution_mode, .terraform_version,
          (if .auto_apply then \"true\" else \"false\" end),
          (if .queue_all_runs then \"true\" else \"false\" end),
          .agent_pool, .vcs_repo, .branch ] | @csv" "${file}" \
      | gum table --columns "WS ID,Name,Project,Exec Mode,TF Ver,Auto-apply,Queue-all,Agent Pool,VCS Repo,Branch" --print
  else
    echo "Workspaces"
    {
      echo -e "WS ID\tName\tProject\tExec Mode\tTF Ver\tAuto-apply\tQueue-all\tAgent Pool\tVCS Repo\tBranch"
      jq -r "${jq_row}
        | [ .id, .name, .project_name, .execution_mode, .terraform_version,
            (if .auto_apply then \"true\" else \"false\" end),
            (if .queue_all_runs then \"true\" else \"false\" end),
            .agent_pool, .vcs_repo, .branch ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ---------------- Workspace variables (keys only) ----------------
show_workspace_variables() {
  local file="$1"
  local filter_workspace="${2:-}"

  local root='.workspace_variables[] as $w | $w | {workspace_name: .workspace_name, variables: .variables}'
  [[ -n "${filter_workspace}" ]] && root=".workspace_variables[] as \$w | select(.workspace_name == \"${filter_workspace}\") | {workspace_name: .workspace_name, variables: .variables}"

  if _has_gum; then
    gum_title "Workspace Variables (keys only)"
    jq -r "${root}
      | . as \$R
      | .variables[]
      | [ \$R.workspace_name, .key, .category,
          (if .hcl then \"true\" else \"false\" end),
          (if .sensitive then \"true\" else \"false\" end) ] | @csv" "${file}" \
      | gum table --columns "Workspace,Key,Category,HCL,Sensitive" --print
  else
    echo "Workspace Variables (keys only)"
    {
      echo -e "Workspace\tKey\tCategory\tHCL\tSensitive"
      jq -r "${root}
        | . as \$R
        | .variables[]
        | [ \$R.workspace_name, .key, .category,
            (if .hcl then \"true\" else \"false\" end),
            (if .sensitive then \"true\" else \"false\" end) ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ---------------- Varsets (keys only + scope) ----------------
show_varsets() {
  local file="$1"
  local filter_name="${2:-}"

  local root='.varsets[]'
  [[ -n "${filter_name}" ]] && root=".varsets[] | select(.name == \"${filter_name}\")"

  if _has_gum; then
    gum_title "Varsets"
    jq -r "${root}
      | [ .id, .name, (.description // \"\"), (if .scope.is_global then \"global\" else \"scoped\" end) ] | @csv" "${file}" \
      | gum table --columns "ID,Name,Description,Scope" --print
  else
    echo "Varsets"
    {
      echo -e "ID\tName\tDescription\tScope"
      jq -r "${root}
        | [ .id, .name, (.description // \"\"), (if .scope.is_global then \"global\" else \"scoped\" end) ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi

  if _has_gum; then
    gum_title "Varset Scopes"
    jq -r "${root}
      | . as \$vs
      | ( .scope.project_ids[]?   | [ \$vs.name, \"project\", . ] | @csv ),
        ( .scope.workspace_ids[]? | [ \$vs.name, \"workspace\", . ] | @csv )" "${file}" \
      | gum table --columns "Varset,Type,ID" --print
  else
    echo "Varset Scopes"
    {
      echo -e "Varset\tType\tID"
      jq -r "${root}
        | . as \$vs
        | ( .scope.project_ids[]?   | [ \$vs.name, \"project\", . ] | @tsv ),
          ( .scope.workspace_ids[]? | [ \$vs.name, \"workspace\", . ] | @tsv )" "${file}"
    } | column -t -s $'\t'
  fi

  if _has_gum; then
    gum_title "Varset Variables (keys only)"
    jq -r "${root}
      | . as \$vs
      | .variables[]
      | [ \$vs.name, .key, .category,
          (if .hcl then \"true\" else \"false\" end),
          (if .sensitive then \"true\" else \"false\" end) ] | @csv" "${file}" \
      | gum table --columns "Varset,Key,Category,HCL,Sensitive" --print
  else
    echo "Varset Variables (keys only)"
    {
      echo -e "Varset\tKey\tCategory\tHCL\tSensitive"
      jq -r "${root}
        | . as \$vs
        | .variables[]
        | [ \$vs.name, .key, .category,
            (if .hcl then \"true\" else \"false\" end),
            (if .sensitive then \"true\" else \"false\" end) ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ---------------- Registry (modules + versions count) ----------------
show_registry() {
  local file="$1"
  local filter_module="${2:-}"

  local base='.registry.modules[]'
  [[ -n "${filter_module}" ]] && base="${base} | select(.name == \"${filter_module}\")"

  if _has_gum; then
    gum_title "Registry Modules"
    jq -r "${base}
      | [ .name, .provider, .namespace, (.latest // \"\"), ((.versions | length)|tostring), (.vcs_repo // \"\") ]
      | @csv" "${file}" \
      | gum table --columns "Name,Provider,Namespace,Latest,Versions,VCS Repo" --print
  else
    echo "Registry Modules"
    {
      echo -e "Name\tProvider\tNamespace\tLatest\tVersions\tVCS Repo"
      jq -r "${base}
        | [ .name, .provider, .namespace, (.latest // \"\"), ( .versions | length ), (.vcs_repo // \"\") ]
        | @tsv" "${file}"
    } | column -t -s $'\t'
  fi

  if _has_gum; then
    gum_title "Module Versions"
    jq -r "${base}
      | . as \$m
      | .versions[]? as \$v
      | [ \$m.name, \$v ] | @csv" "${file}" \
      | gum table --columns "Module,Version" --print
  else
    echo "Module Versions"
    {
      echo -e "Module\tVersion"
      jq -r "${base}
        | . as \$m
        | .versions[]? as \$v
        | [ \$m.name, \$v ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ---------------- Org Tags (Reserved Keys) ----------------
show_tags() {
  local file="$1"
  local base='.tags.reserved_keys[]? | { key: .key, created_at: (.created_at // "") }'

  if _has_gum; then
    gum_title "Reserved Tag Keys"
    jq -r "${base} | [ .key, .created_at ] | @csv" "${file}" \
      | gum table --columns "Key,Created" --print
  else
    echo "Reserved Tag Keys"
    {
      echo -e "Key\tCreated"
      jq -r "${base} | [ .key, .created_at ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ---------------- Users (with team memberships) ----------------
show_users() {
  local file="$1"
  local base='.users[]? | {
    username: (.username // ""),
    email:    (.email // ""),
    status:   (.status // ""),
    teams:    ((.teams // []) | join(", "))
  }'

  if _has_gum; then
    gum_title "Users"
    jq -r "${base} | [ .username, .email, .status, .teams ] | @tsv" "${file}" \
      | gum table --separator=$'\t' --columns "Username,Email,Status,Teams" --print
  else
    echo "Users"
    {
      echo -e "Username\tEmail\tStatus\tTeams"
      jq -r "${base} | [ .username, .email, .status, .teams ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# ======================= TEAMS (FULL) =========================

# Build maps we need (team_id->name, project_id->name) without --argfile
__teams_maps() {
  local file="$1"
  local J
  J="$(cat "${file}")"
  jq -n --argjson J "${J}" '
    {
      team_id_to_name:
        ( ($J.teams.core // [])
          | map({key: .id, value: (.name // "")})
          | from_entries ),
      project_id_to_name:
        ( ($J.projects // [])
          | map({key: .id, value: (.name // "")})
          | from_entries )
    }'
}

# Teams (core)
show_teams_core() {
  local file="$1"
  local base='.teams.core[]? | {
    id, name,
    users_count: (.users_count // 0 | tostring),
    visibility: (.visibility // ""),
    sso_team_id: (.sso_team_id // ""),
    allow_member_token_management: (if .allow_member_token_management then "true" else "false" end),
    org_access:
      ( (.organization_access // {})
        | to_entries
        | map(select(.value == true) | .key)
        | sort
        | join(", ")
      )
  }'

  if _has_gum; then
    gum_title "Teams (core)"
    jq -r "${base}
      | [ .id, .name, .users_count, .visibility, .sso_team_id, .allow_member_token_management, .org_access ] | @tsv" "${file}" \
      | gum table --separator=$'\t' \
                  --columns "Team ID,Name,Users,Visibility,SSO Team ID,Allow Member Tokens,Org Access" \
                  --print
  else
    echo "Teams (core)"
    {
      echo -e "Team ID\tName\tUsers\tVisibility\tSSO Team ID\tAllow Member Tokens\tOrg Access"
      jq -r "${base}
        | [ .id, .name, .users_count, .visibility, .sso_team_id, .allow_member_token_management, .org_access ] | @tsv" "${file}"
    } | column -t -s $'\t'
  fi
}

# Team Memberships (team -> user)
show_team_memberships() {
  local file="$1"
  local maps; maps="$(__teams_maps "${file}")"

  if _has_gum; then
    gum_title "Team Memberships"
    jq -r --argjson M "${maps}" '
      (.teams.memberships // [])
      | map([ ($M.team_id_to_name[.team_id] // .team_id), .user_id ])
      | .[]
      | @tsv
    ' "${file}" \
    | gum table --separator=$'\t' --columns "Team,User ID" --print
  else
    echo "Team Memberships"
    {
      echo -e "Team\tUser ID"
      jq -r --argjson M "${maps}" '
        (.teams.memberships // [])
        | map([ ($M.team_id_to_name[.team_id] // .team_id), .user_id ])
        | .[]
        | @tsv
      ' "${file}"
    } | column -t -s $'\t'
  fi
}

# Team ↔ Project Access
show_team_project_access() {
  local file="$1"
  local maps; maps="$(__teams_maps "${file}")"

  if _has_gum; then
    gum_title "Team ↔ Project Access"
    jq -r --argjson M "${maps}" '
      (.teams.project_access // [])
      | map([
          ($M.project_id_to_name[.project_id] // .project_id),
          ($M.team_id_to_name[.team_id] // .team_id),
          (.access // "")
        ])
      | .[]
      | @tsv
    ' "${file}" \
    | gum table --separator=$'\t' --columns "Project,Team,Access" --print
  else
    echo "Team ↔ Project Access"
    {
      echo -e "Project\tTeam\tAccess"
      jq -r --argjson M "${maps}" '
        (.teams.project_access // [])
        | map([
            ($M.project_id_to_name[.project_id] // .project_id),
            ($M.team_id_to_name[.team_id] // .team_id),
            (.access // "")
          ])
        | .[]
        | @tsv
      ' "${file}"
    } | column -t -s $'\t'
  fi
}

# Convenience: show all Teams sections
show_teams() {
  local file="$1"
  show_teams_core "${file}"
  echo
  show_team_memberships "${file}"
  echo
  show_team_project_access "${file}"
}

# ---------------- Agent Pools ----------------
 show_agent_pools() {
   local file="$1"
  local base='.agent_pools[]? | {
    name,
    organization_scoped: (if .organization_scoped then "true" else "false" end),
    allowed: ((.allowed_projects // []) | join(", "))
  }'
  if _has_gum; then
     gum_title "Agent Pools"
    jq -r "${base} | [ .name, .organization_scoped, .allowed ] | @csv" "${file}" \
      | gum table --columns "Name,Org-scoped,Allowed Projects" --print
   else
     echo "Agent Pools"
     {

      echo -e "Name\tOrg-scoped\tAllowed Projects"
      jq -r "${base} | [ .name, .organization_scoped, .allowed ] | @tsv" "${file}"
     } | column -t -s $'\t'
   fi
 }