#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Write a one-liner or block to a file
__out() { printf '%s\n' "$*" ; }
__hr()  { printf '\n'; }

# Fancy bool icons
__bicon() { [[ "${1:-false}" == "true" ]] && echo "✅" || echo "❌"; }
__lock()  { [[ "${1:-false}" == "true" ]] && echo "🔒" || echo "—"; }
__nz()    { local v="${1:-}"; [[ -z "$v" || "$v" == "null" ]] && echo "—" || echo "$v"; }

# Build a TSV table (data rows only) and prepend a header
# Usage: __emit_table "Header1|Header2" <tsv_rows> > out.md
__emit_table() {
  local header="$1"
  IFS='|' read -r -a H <<<"$header"
  # Header
  printf '|%s|\n' "$(IFS='|'; echo "${H[*]}")"
  # Rule row
  local rules=()
  for _ in "${H[@]}"; do rules+=('---'); done
  printf '|%s|\n' "$(IFS='|'; echo "${rules[*]}")"
  # Data
  awk -F'\t' '{
    for(i=1;i<=NF;i++){ if($i==""||$i=="null") $i="—" }
    line="|" $1
    for(i=2;i<=NF;i++) line=line "|" $i
    print line "|"
  }'
}

# ---------- Sections (each writes to a temp file) ----------

__sec_org_header() {
  local f="$1"
  local org_name org_email sso generated
  org_name="$(jq -r '.org.name // ""' "$SRC")"
  org_email="$(jq -r '.org.email // ""' "$SRC")"
  sso="$(jq -r 'if (.org.sso.enforced // false) then "enforced" else "not enforced" end' "$SRC")"
  generated="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  {
    __out "# Terraform Cloud Organization Report"
    __hr
    __out "**Organization:** ${org_name}  "
    __out "**Email:** ${org_email}  "
    __out "**Generated:** ${generated}"
  } > "$f"
}

__sec_toc() {
  local f="$1"
  cat > "$f" <<'MD'
## Table of Contents
- [Organization](#organization)
- [Summary](#summary)
- [Projects](#projects)
- [Workspaces](#workspaces)
- [Workspace Variables (keys only)](#workspace-variables-keys-only)
- [Variable Sets](#variable-sets)
  - [Varset Scopes](#varset-scopes)
  - [Varset Variables (keys only)](#varset-variables-keys-only)
- [Private Registry](#private-registry)
  - [Modules](#modules)
  - [Module Versions](#module-versions)
- [Reserved Tag Keys](#reserved-tag-keys)
- [Users](#users)
- [Teams](#teams)
  - [Core](#core)
  - [Team ↔ Project Access](#team--project-access)
MD
}

__sec_org_table() {
  local f="$1"
  local org_name org_email sso
  org_name="$(jq -r '.org.name // ""' "$SRC")"
  org_email="$(jq -r '.org.email // ""' "$SRC")"
  sso="$(jq -r 'if (.org.sso.enforced // false) then "enforced" else "not enforced" end' "$SRC")"

  {
    __out "## Organization"
    __hr
    printf "Name\tEmail\tSSO\n"
    printf "%s\t%s\t%s\n" "$org_name" "$org_email" "$sso" \
      | __emit_table "Name|Email|SSO"
  } > "$f"
}

__sec_summary() {
  local f="$1"
  local np nw nu nt nv nm
  np="$(jq -r '( .projects // [] ) | length' "$SRC")"
  nw="$(jq -r '( .workspaces // [] ) | length' "$SRC")"
  nu="$(jq -r '( .users // [] ) | length' "$SRC")"
  nt="$(jq -r '( .teams.core // [] ) | length' "$SRC")"
  nv="$(jq -r '( .varsets // [] ) | length' "$SRC")"
  nm="$(jq -r '( .registry.modules // [] ) | length' "$SRC")"

  {
    __out "## Summary"
    __hr
    printf "Projects\tWorkspaces\tUsers\tTeams\tVarsets\tModules\n"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$np" "$nw" "$nu" "$nt" "$nv" "$nm" \
      | __emit_table "Projects|Workspaces|Users|Teams|Varsets|Modules"
  } > "$f"
}

__sec_projects() {
  local f="$1"
  {
    __out "## Projects"
    __hr
    jq -r '
      ( .projects // [] ) | sort_by(.name)
      | .[] | [ .id, .name, (.description // "") ] | @tsv
    ' "$SRC" | __emit_table "ID|Name|Description"
  } > "$f"
}

__sec_workspaces() {
  local f="$1"
  {
    __out "## Workspaces"
    __hr
    jq -r '
      ( .workspaces // [] ) | sort_by(.project_name, .name)
      | .[] | [
          .id, .name, (.project_name // ""),
          (.execution_mode // ""),
          (.terraform_version // ""),
          (if .auto_apply then "✅" else "❌" end),
          (if .queue_all_runs then "✅" else "❌" end),
          (.agent_pool.name // ""),
          (.vcs.repo_identifier // ""),
          (.vcs.branch // "")
        ] | @tsv
    ' "$SRC" | __emit_table "WS ID|Name|Project|Exec Mode|TF Ver|Auto-apply|Queue-all|Agent Pool|VCS Repo|Branch"
  } > "$f"
}

__sec_workspace_vars() {
  local f="$1"
  {
    __out "## Workspace Variables (keys only)"
    __hr
    jq -r '
      ( .workspace_variables // [] )
      | [ .[] as $w
          | ($w.workspace_name // "") as $wn
          | ($w.variables // []) | .[]
          | {
              wn: $wn,
              key: (.key // ""),
              category: (.category // ""),
              hcl: (if (.hcl // false) then "✅" else "❌" end),
              sensitive: (if (.sensitive // false) then "🔒" else "—" end)
            }
        ]
      | sort_by(.wn, .category, .key)
      | .[] | [ .wn, .key, .category, .hcl, .sensitive ] | @tsv
    ' "$SRC" | __emit_table "Workspace|Key|Category|HCL|Sensitive"
  } > "$f"
}

__sec_varsets() {
  local f="$1"
  {
    __out "## Variable Sets"
    __hr
    if jq -e '(.varsets // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .varsets // [] ) | sort_by(.name)
        | .[] | [
          .id, .name, (.description // ""),
          (if (.scope.is_global // false) then "global" else "scoped" end)
        ] | @tsv
      ' "$SRC" | __emit_table "ID|Name|Description|Scope"
    else
      __out "_No variable sets found._"
    fi

    __hr
    __out "### Varset Scopes"
    __hr
    if jq -e '(.varsets // []) | map(.scope.project_ids[]?, .scope.workspace_ids[]?) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .varsets // [] ) | sort_by(.name)
        | .[] as $vs
        | ( ($vs.scope.project_ids // []) | map([ $vs.name, "project", . ]) | .[]? ),
          ( ($vs.scope.workspace_ids // []) | map([ $vs.name, "workspace", . ]) | .[]? )
        | @tsv
      ' "$SRC" | __emit_table "Varset|Type|ID"
    else
      __out "_No varset scopes found._"
    fi

    __hr
    __out "### Varset Variables (keys only)"
    __hr
    if jq -e '(.varsets // []) | map(.variables[]?) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .varsets // [] ) | sort_by(.name)
        | .[] as $vs
        | ($vs.variables // []) | sort_by(.key)
        | .[]? | [
            $vs.name, (.key // ""), (.category // ""),
            (if (.hcl // false) then "✅" else "❌" end),
            (if (.sensitive // false) then "🔒" else "—" end)
          ] | @tsv
      ' "$SRC" | __emit_table "Varset|Key|Category|HCL|Sensitive"
    else
      __out "_No varset variables found (keys)._"
    fi
  } > "$f"
}

__sec_registry() {
  local f="$1"
  {
    __out "## Private Registry"
    __hr
    __out "### Modules"
    __hr
    if jq -e '(.registry.modules // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .registry.modules // [] ) | sort_by(.namespace, .name)
        | .[] | [
            (.name // ""), (.provider // ""), (.namespace // ""),
            (.latest // "—"),
            ((.versions // []) | length),
            (.vcs_repo // "")
          ] | @tsv
      ' "$SRC" | __emit_table "Name|Provider|Namespace|Latest|Versions|VCS Repo"
    else
      __out "_No registry modules found._"
    fi

    __hr
    __out "### Module Versions"
    __hr
    if jq -e '(.registry.modules // []) | map(.versions[]?) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .registry.modules // [] ) | sort_by(.name)
        | .[] as $m
        | ($m.versions // []) | .[]? | [ ($m.name // ""), . ] | @tsv
      ' "$SRC" | __emit_table "Module|Version"
    else
      __out "_No module versions found._"
    fi
  } > "$f"
}

__sec_tags() {
  local f="$1"
  {
    __out "## Reserved Tag Keys"
    __hr
    if jq -e '(.tags.reserved_keys // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .tags.reserved_keys // [] ) | sort_by(.key)
        | .[] | [ (.key // ""), (.created_at // "") ] | @tsv
      ' "$SRC" | __emit_table "Key|Created"
    else
      __out "_No reserved tag keys found._"
    fi
  } > "$f"
}

__sec_users() {
  local f="$1"
  {
    __out "## Users"
    __hr
    if jq -e '(.users // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .users // [] ) | sort_by(.username)
        | .[] | [
            (.username // ""), (.email // ""), (.status // ""),
            ((.teams // []) | join(", "))
          ] | @tsv
      ' "$SRC" | __emit_table "Username|Email|Status|Teams"
    else
      __out "_No users found._"
    fi
  } > "$f"
}

__sec_teams() {
  local f="$1"
  {
    __out "## Teams"
    __hr
    __out "### Core"
    __hr
    if jq -e '(.teams.core // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        ( .teams.core // [] ) | sort_by(.name)
        | .[] | [
           (.id // ""),
           (.name // ""),
           ((.users_count // 0) | tostring),
           (.visibility // ""),
           ( ( .sso_team_id // "" ) | tostring ),
           (if (.allow_member_token_management // false) then "✅" else "❌" end),
           ( ( .organization_access // {} )
             | to_entries | map(select(.value == true) | .key)
             | sort | join(", ")
           )
        ] | @tsv
      ' "$SRC" | __emit_table "Team ID|Name|Users|Visibility|SSO Team ID|Allow Member Tokens|Org Access"
    else
      __out "_No teams found._"
    fi

    __hr
    __out "### Team Memberships"
    __hr
    if jq -e '(.teams.memberships // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        . as $R
        | ($R.teams.core // [])
          | map({key:.id, value:(.name // "")}) | from_entries as $T
        | ($R.teams.memberships // [])
        | map([ ($T[.team_id] // .team_id), .user_id ])
        | sort_by(.[0], .[1]) | .[]
        | @tsv
      ' "$SRC" | __emit_table "Team|User ID"
    else
      __out "_No team memberships found._"
    fi

    __hr
    __out "### Team ↔ Project Access"
    __hr
    if jq -e '(.teams.project_access // []) | length > 0' "$SRC" >/dev/null; then
      jq -r '
        . as $R
        | ($R.teams.core // [])
          | map({key:.id, value:(.name // "")}) | from_entries as $T
        | ($R.projects // [])
          | map({key:.id, value:(.name // "")}) | from_entries as $P
        | ($R.teams.project_access // [])
        | map([ ($P[.project_id] // .project_id),
                ($T[.team_id] // .team_id),
                (.access // "") ])
        | sort_by(.[0], .[1]) | .[]
        | @tsv
      ' "$SRC" | __emit_table "Project|Team|Access"
    else
      __out "_No team ↔ project access found._"
    fi
  } > "$f"
}

# Render using a template file with line markers
# Markers (line-only): {{ORG_HEADER}} {{TOC}} {{ORG_TABLE}} {{SUMMARY_TABLE}} {{PROJECTS_TABLE}}
# {{WORKSPACES_TABLE}} {{WORKSPACE_VARS_TABLE}} {{VARSETS_BLOCK}} {{REGISTRY_BLOCK}} {{TAGS_TABLE}} {{USERS_TABLE}} {{TEAMS_BLOCK}}
__render_with_template() {
  local tpl="$1" out="$2"
  while IFS= read -r line; do
    case "$line" in
      "{{ORG_HEADER}}")         cat "$TMP_DIR/org_header.md" ;;
      "{{TOC}}")                cat "$TMP_DIR/toc.md" ;;
      "{{ORG_TABLE}}")          cat "$TMP_DIR/org_table.md" ;;
      "{{SUMMARY_TABLE}}")      cat "$TMP_DIR/summary.md" ;;
      "{{PROJECTS_TABLE}}")     cat "$TMP_DIR/projects.md" ;;
      "{{WORKSPACES_TABLE}}")   cat "$TMP_DIR/workspaces.md" ;;
      "{{WORKSPACE_VARS_TABLE}}") cat "$TMP_DIR/ws_vars.md" ;;
      "{{VARSETS_BLOCK}}")      cat "$TMP_DIR/varsets.md" ;;
      "{{REGISTRY_BLOCK}}")     cat "$TMP_DIR/registry.md" ;;
      "{{TAGS_TABLE}}")         cat "$TMP_DIR/tags.md" ;;
      "{{USERS_TABLE}}")        cat "$TMP_DIR/users.md" ;;
      "{{TEAMS_BLOCK}}")        cat "$TMP_DIR/teams.md" ;;
      *)                        printf '%s\n' "$line" ;;
    esac
  done < "$tpl" > "$out"
}

# Default assembly (no template)
__render_default() {
  local out="$1"
  {
    cat "$TMP_DIR/org_header.md"
    __hr
    cat "$TMP_DIR/toc.md"
    __hr
    cat "$TMP_DIR/org_table.md"
    __hr
    cat "$TMP_DIR/summary.md"
    __hr
    cat "$TMP_DIR/projects.md"
    __hr
    cat "$TMP_DIR/workspaces.md"
    __hr
    cat "$TMP_DIR/ws_vars.md"
    __hr
    cat "$TMP_DIR/varsets.md"
    __hr
    cat "$TMP_DIR/registry.md"
    __hr
    cat "$TMP_DIR/tags.md"
    __hr
    cat "$TMP_DIR/users.md"
    __hr
    cat "$TMP_DIR/teams.md"
  } > "$out"
}

# Public API
# 1: export.json, 2: out.md, 3: template (optional)
doc_render_from_export() {
  export SRC="$1"
  local out="$2"
  local tpl="${3:-}"

  [[ -f "$SRC" ]] || { echo "doc_render_from_export: export file not found: $SRC" >&2; exit 2; }

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Build sections
  __sec_org_header   "$TMP_DIR/org_header.md"
  __sec_toc          "$TMP_DIR/toc.md"
  __sec_org_table    "$TMP_DIR/org_table.md"
  __sec_summary      "$TMP_DIR/summary.md"
  __sec_projects     "$TMP_DIR/projects.md"
  __sec_workspaces   "$TMP_DIR/workspaces.md"
  __sec_workspace_vars "$TMP_DIR/ws_vars.md"
  __sec_varsets      "$TMP_DIR/varsets.md"
  __sec_registry     "$TMP_DIR/registry.md"
  __sec_tags         "$TMP_DIR/tags.md"
  __sec_users        "$TMP_DIR/users.md"
  __sec_teams        "$TMP_DIR/teams.md"

  # If template not provided, try $TFC_ROOT/tpl/report.md.tpl
  if [[ -z "$tpl" && -f "${TFC_ROOT:-.}/tpl/report.md.tpl" ]]; then
    tpl="${TFC_ROOT}/tpl/report.md.tpl"
  fi

  if [[ -n "$tpl" ]]; then
    [[ -f "$tpl" ]] || { echo "Template not found: $tpl" >&2; exit 2; }
    __render_with_template "$tpl" "$out"
  else
    __render_default "$out"
  fi
}
