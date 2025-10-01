#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Requires from commons.sh: CURL, auth_header, TFE_HOST, err
# Requires from users.sh:  get_user_detail   # used to resolve usernames

# ---- helper: paginated GET that stitches .data arrays ----
__teams_paged_get_data() {
  local url_base="$1" page=1 size=100 all="[]"
  while true; do
    local tmp http sep
    tmp="$(mktemp)"
    # If url_base already has a query, append with &, else start with ?
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

# ---- list all teams for org (raw .data objects stitched; may be empty) ----
list_org_teams_raw() {
  local org="$1"
  __teams_paged_get_data "https://${TFE_HOST}/api/v2/organizations/${org}/teams"
}

# ---- single team detail -> { id, name } (or {}) ----
get_team_detail() {
  local team_id="$1"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/teams/${team_id}"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '{ id: .data.id, name: (.data.attributes.name // "") }' "${out}"
  else
    echo "{}"
  fi
  rm -f "${out}"
}

# ---- user-id -> [team-id...] via org-scoped team-memberships ----
# Uses filter[organization][name]=<org> which works even if you can't list teams org-wide
org_user_to_team_ids_map() {
  local org="$1"
  local base="https://${TFE_HOST}/api/v2/team-memberships?filter%5Borganization%5D%5Bname%5D=${org}"
  local all; all="$(__teams_paged_get_data "${base}")"
  [[ -z "${all}" ]] && { echo "{}"; return; }
  jq -r '
    reduce (.[] // []) as $m (
      {};
      . as $A
      | ($m.relationships.user.data.id // empty) as $uid
      | ($m.relationships.team.data.id // empty) as $tid
      | if ($uid != "" and $tid != "")
        then $A + { ($uid): ((($A[$uid] // []) + [$tid]) | unique) }
        else $A
        end
    )
  ' <<< "${all}"
}

# ---- robust teams list WITH names [{id,name},...] ----
# 1) Try org teams.
# 2) If empty, derive unique team IDs from memberships and resolve each via /teams/:id.
list_org_teams_with_names() {
  local org="$1"
  local teams_raw; teams_raw="$(list_org_teams_raw "${org}")"
  local count; count="$(jq -r 'length' <<< "${teams_raw:-[]}")"
  if [[ "${count}" -gt 0 ]]; then
    jq -r '[ .[] | { id: .id, name: (.attributes.name // "") } ]' <<< "${teams_raw}"
    return
  fi

  # Fallback: memberships -> unique team ids -> /teams/:id lookups
  local base="https://${TFE_HOST}/api/v2/team-memberships?filter%5Borganization%5D%5Bname%5D=${org}"
  local memberships; memberships="$(__teams_paged_get_data "${base}")"
  [[ -z "${memberships}" ]] && { echo "[]"; return; }
  local tids; tids="$(jq -r '[ .[] | .relationships.team.data.id ] | map(select(. != null)) | unique' <<< "${memberships}")"

  local arr="[]"
  mapfile -t __ids < <(jq -r '.[]' <<< "${tids}")
  for tid in "${__ids[@]-}"; do
    [[ -z "${tid}" ]] && continue
    local d name; d="$(get_team_detail "${tid}")"
    name="$(jq -r '.name // ""' <<< "${d}")"
    [[ -z "${name}" ]] && continue
    arr="$(jq -c --arg id "${tid}" --arg n "${name}" --argjson a "${arr}" -n '$a + [{id:$id, name:$n}]')"
  done
  echo "${arr}"
}

# ---- team-id -> team-name map { id: name, ... } from normalized [{id,name},...] ----
team_id_name_map() {
  local teams_arr="${1:-[]}"
  jq -r '[ .[] | {key:.id, value:(.name // "")} ] | from_entries' <<< "${teams_arr}"
}

# ---- list user ids for a team (used as per-user fallback) ----
list_team_user_ids() {
  local team_id="$1"
  local url="https://${TFE_HOST}/api/v2/teams/${team_id}/relationships/users"
  local data; data="$(__teams_paged_get_data "${url}")"
  [[ -z "${data}" ]] && { echo "[]"; return; }
  jq -r '[ .[] | .id ]' <<< "${data}"
}

# ---- Build: user-id -> [team-name,...] directly from org teams payload ----
# Falls back to empty object if nothing.
userid_to_teamnames_from_org_teams() {
  local org="$1"
  local teams; teams="$(list_org_teams_raw "${org}")"
  [[ -z "${teams}" || "${teams}" == "null" ]] && { echo "{}"; return; }
  jq -r '
    reduce (.[] // []) as $t ({}; 
      . as $M
      | ($t.attributes.name // "") as $name
      | ($t.relationships.users.data // []) as $uids
      | reduce $uids[]? as $u ($M;
          . + { ($u.id): ( (( $M[$u.id] // [] ) + [ $name ]) | unique ) }
        )
    )
  ' <<< "${teams}"
}

# ---- Fallback: user-id -> [team-name,...] via explicit per-team relationships/users calls ----
userid_to_teamnames_via_relationships() {
  local org="$1"
  local teams_raw; teams_raw="$(list_org_teams_raw "${org}")"
  [[ -z "${teams_raw}" || "${teams_raw}" == "null" ]] && { echo "{}"; return; }

  local map="{}"
  mapfile -t __teams < <(jq -r '.[] | @base64' <<< "${teams_raw}")
  for __t in "${__teams[@]-}"; do
    local t tid tname uids
    t="$(echo "${__t}" | base64 --decode)"
    tid="$(jq -r '.id // ""' <<< "${t}")"
    tname="$(jq -r '.attributes.name // ""' <<< "${t}")"
    [[ -z "${tid}" || -z "${tname}" ]] && continue

    uids="$(list_team_user_ids "${tid}")"
    [[ -z "${uids}" || "${uids}" == "null" ]] && uids="[]"

    map="$(
      jq -c --arg tname "${tname}" --argjson uids "${uids}" --argjson M "${map}" -n '
        ($M // {}) as $m
        | ($uids // []) as $U
        | reduce $U[] as $uid ($m;
            . + { ($uid): (( ($m[$uid] // []) + [$tname]) | unique) }
          )
      '
    )"
  done
  [[ -z "${map}" || "${map}" == "null" ]] && map="{}"
  echo "${map}"
}

# ---- Compact team object from a raw team item ----
# {
#   id, name, visibility, users_count, sso_team_id,
#   org_permissions: { ...organization-access... },
#   members: [ "username", ... ]     # resolved via get_user_detail
# }
team_compact_from_raw() {
  local team_json="$1"

  local id name vis ucount sso org_access
  id="$(jq -r '.id' <<< "${team_json}")"
  name="$(jq -r '.attributes.name // ""' <<< "${team_json}")"
  vis="$(jq -r '.attributes.visibility // ""' <<< "${team_json}")"
  ucount="$(jq -r '.attributes."users-count" // 0' <<< "${team_json}")"
  sso="$(jq -r '.attributes."sso-team-id" // ""' <<< "${team_json}")"
  org_access="$(jq -r '.attributes."organization-access" // {}' <<< "${team_json}")"

  # member user IDs from relationships (if present)
  local ids; ids="$(jq -r '[.relationships.users.data[]?.id] // []' <<< "${team_json}")"

  # resolve usernames (best-effort, empty array if none)
  local usernames="[]"
  mapfile -t __ids < <(jq -r '.[]' <<< "${ids}")
  for uid in "${__ids[@]-}"; do
    [[ -z "${uid}" || "${uid}" == "null" ]] && continue
    local detail; detail="$(get_user_detail "${uid}")" || detail='{"username":""}'
    local uname; uname="$(jq -r '.username // ""' <<< "${detail}")"
    [[ -z "${uname}" || "${uname}" == "null" ]] && uname="${uid}"
    usernames="$(jq -c --arg u "${uname}" --argjson a "${usernames}" -n '($a + [ $u ]) | unique')"
  done

  jq -n \
    --arg id "${id}" \
    --arg name "${name}" \
    --arg vis "${vis}" \
    --argjson ucount "${ucount}" \
    --arg sso "${sso}" \
    --argjson orgp "${org_access}" \
    --argjson members "${usernames}" \
    '{
      id: $id,
      name: $name,
      visibility: $vis,
      users_count: $ucount,
      sso_team_id: $sso,
      org_permissions: $orgp,
      members: $members
    }'
}

# ---- Convenience: return full compact teams array for an org ----
list_org_teams_full() {
  local org="$1"
  local raw; raw="$(list_org_teams_raw "${org}")"
  [[ -z "${raw}" || "${raw}" == "null" ]] && { echo "[]"; return; }

  local out="[]"
  mapfile -t __rows < <(jq -r '.[] | @base64' <<< "${raw}")
  for __r in "${__rows[@]-}"; do
    local t compact
    t="$(echo "${__r}" | base64 --decode)"
    compact="$(team_compact_from_raw "${t}")"
    out="$(jq -c --argjson a "${out}" --argjson b "${compact}" -n '$a + [$b]')"
  done
  echo "${out}"
}

# ===================== TEAMS + USERS: PLAN/APPLY =====================

# --- Team lookups/ensure ---

team_get_by_name() {
  local org="$1" name="$2"
  local raw; raw="$(list_org_teams_raw "${org}")"
  [[ -z "${raw}" || "${raw}" == "null" ]] && { echo "{}"; return; }
  jq -c --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0] // {}' <<< "${raw}"
}

team_create() {
  local org="$1" name="$2" visibility="${3:-secret}" allow_member_tokens="${4:-false}" org_access_json="${5:-{}}"

  # ✅ Validate and normalize org_access_json to a compact JSON object; fallback to {}
  local org_access_compact
  if org_access_compact="$(jq -c . <<<"${org_access_json}" 2>/dev/null)"; then
    : # ok
  else
    org_access_compact="{}"
  fi

  local payload
  payload="$(
    jq -n \
      --arg name "${name}" \
      --arg vis "${visibility}" \
      --argjson allow "$([[ "${allow_member_tokens}" == "true" ]] && echo true || echo false)" \
      --argjson orgp "${org_access_compact}" '
      {
        data: {
          type: "teams",
          attributes: {
            name: $name,
            visibility: $vis,
            "allow-member-token-management": $allow,
            "organization-access": ($orgp // {})
          }
        }
      }'
  )"

  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      -H "content-type: application/vnd.api+json" \
      -H "accept: application/vnd.api+json" \
      -X POST "https://${TFE_HOST}/api/v2/organizations/${org}/teams" \
      -d "${payload}"
  ) " || true

  if [[ "${http}" == "201" ]]; then
    jq -r '.data.id' "${out}"
  else
    if [[ "${http}" == "404" ]]; then
      err "Team create failed (${name}) HTTP 404. This usually means your token cannot create teams (not an org owner / lacks 'manage teams'). Use a user PAT with org-owner rights."
    else
      err "Team create failed (${name}) HTTP ${http}"
    fi
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

team_update() {
  local team_id="$1" visibility="${2:-secret}" allow_member_tokens="${3:-false}" org_access_json="${4:-{}}"

  local org_access_compact
  if org_access_compact="$(jq -c . <<<"${org_access_json}" 2>/dev/null)"; then
    : 
  else
    org_access_compact="{}"
  fi

  local payload
  payload="$(
    jq -n \
      --arg id "${team_id}" \
      --arg vis "${visibility}" \
      --argjson allow "$([[ "${allow_member_tokens}" == "true" ]] && echo true || echo false)" \
      --argjson orgp "${org_access_compact}" '
      {
        data: {
          id: $id,
          type: "teams",
          attributes: {
            visibility: $vis,
            "allow-member-token-management": $allow,
            "organization-access": ($orgp // {})
          }
        }
      }'
  )"

  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" -H "content-type: application/vnd.api+json" \
      -X PATCH "https://${TFE_HOST}/api/v2/teams/${team_id}" \
      -d "${payload}"
  )" || true

  if [[ "${http}" == "200" ]]; then
    :
  else
    err "Team update failed (${team_id}) HTTP ${http}"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# --- Membership ensure (existing users only, matched by email) ---

# Build email -> user_id map from org memberships
__org_email_to_userid_map() {
  local org="$1"
  local memberships; memberships="$(list_org_memberships_raw "${org}")"
  [[ -z "${memberships}" || "${memberships}" == "null" ]] && { echo "{}"; return; }
  jq -r '[ .[] | {
           key: (.attributes.email // .attributes."user-email" // .attributes."user_email" // ""),
           value: (.relationships.user.data.id // "")
         } ] 
         | map(select(.key != "" and .value != "")) 
         | from_entries' <<< "${memberships}"
}

# For a given team, return array of user IDs currently in team
__team_user_ids() {
  local team_id="$1"
  list_team_user_ids "${team_id}"
}

# Add a user to a team (no-op if already a member)
__ensure_team_membership() {
  local org="$1" team_id="$2" user_id="$3"

  # Using team-memberships create endpoint
  local payload; payload="$(
    jq -n \
      --arg tid "${team_id}" \
      --arg uid "${user_id}" '
      {
        data: {
          type: "team-memberships",
          relationships: {
            team: { data: { type:"teams",  id: $tid } },
            user: { data: { type:"users",  id: $uid } }
          }
        }
      }'
  )"

  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" -H "content-type: application/vnd.api+json" \
      -X POST "https://${TFE_HOST}/api/v2/team-memberships" \
      -d "${payload}"
  )" || true

  # 201 created, 409 conflict (already a member) are both fine
  if [[ "${http}" == "201" || "${http}" == "409" ]]; then
    :
  else
    err "Add membership failed (team=${team_id}, user=${user_id}) HTTP ${http}"
    cat "${out}" >&2 || true
    rm -f "${out}"
    exit 1
  fi
  rm -f "${out}"
}

# --- PLAN: teams + memberships (users) ---
plan_identities() {
  local spec="$1"
  local org; org="$(json_get "${spec}" '.org.name')"
  [[ -n "${org}" && "${org}" != "null" ]] || { err "Missing .org.name for identities"; exit 2; }

  echo "Plan (teams + users):"

  # Desired teams (from spec.teams.core[])
  local want_teams_arr; want_teams_arr="$(jq -c '(.teams.core // [])' "${spec}")"
  local want_team_count; want_team_count="$(jq 'length' <<< "${want_teams_arr}")"
  if [[ "${want_team_count}" -eq 0 ]]; then
    echo " - No desired teams provided."
  fi

  # Existing teams raw
  local have_teams_raw; have_teams_raw="$(list_org_teams_raw "${org}")"

  # Teams plan
  jq -r '.[] | @base64' <<< "${want_teams_arr}" | while read -r row; do
    local t name vis allow orgp have_row tid cur_vis cur_allow
    t="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<< "${t}")"
    [[ -z "${name}" || "${name}" == "null" ]] && continue
    vis="$(jq -r '(.visibility // "secret")' <<< "${t}")"
    allow="$(jq -r '(.allow_member_token_management // false) | tostring' <<< "${t}")"
    orgp="$(jq -c '(.organization_access // {})' <<< "${t}")"

    have_row="$(jq -c --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0] // {}' <<< "${have_teams_raw}")"
    tid="$(jq -r '.id // ""' <<< "${have_row}")"

    if [[ -z "${tid}" ]]; then
      echo " - Team '${name}': create (visibility=${vis}, allow_member_tokens=${allow})"
      continue
    fi

    cur_vis="$(jq -r '.attributes.visibility // "secret"' <<< "${have_row}")"
    cur_allow="$(jq -r '(.attributes["allow-member-token-management"] // false) | tostring' <<< "${have_row}")"

    local change=0
    [[ "${cur_vis}"   != "${vis}"   ]] && { echo " - Team '${name}': update visibility ${cur_vis} -> ${vis}"; change=1; }
    [[ "${cur_allow}" != "${allow}" ]] && { echo " - Team '${name}': update allow_member_token_management ${cur_allow} -> ${allow}"; change=1; }

    # org access compare: collapse to sorted true-keys for a human diff
    local have_access want_access
    have_access="$(jq -c '(.attributes["organization-access"] // {})' <<< "${have_row}")"
    want_access="${orgp}"
    if [[ "$(jq -r 'to_entries|map(select(.value==true)|.key)|sort|join(",")' <<< "${have_access}")" != \
          "$(jq -r 'to_entries|map(select(.value==true)|.key)|sort|join(",")' <<< "${want_access}")" ]]; then
      echo " - Team '${name}': update organization-access"
      change=1
    fi
    [[ "${change}" -eq 0 ]] && echo " - Team '${name}': exists"
  done

  # Memberships plan (spec.users[].teams[])
  local want_users; want_users="$(jq -c '(.users // [])' "${spec}")"
  local email_to_id; email_to_id="$(__org_email_to_userid_map "${org}")"

  jq -r '.[] | @base64' <<< "${want_users}" | while read -r row; do
    local u email uname teams user_id
    u="$(echo "${row}" | base64 --decode)"
    email="$(jq -r '.email // ""' <<< "${u}")"
    uname="$(jq -r '.username // ""' <<< "${u}")"
    teams="$(jq -c '(.teams // [])' <<< "${u}")"

    [[ -z "${email}" ]] && { warn " - User '${uname}': missing email in spec; skip membership checks"; continue; }

    user_id="$(jq -r --arg e "${email}" '.[$e] // ""' <<< "${email_to_id}")"
    if [[ -z "${user_id}" ]]; then
      echo " - User ${email}: NOT IN ORG (invite manually), will skip memberships."
      continue
    fi

    # For each desired team, check membership
    mapfile -t __teams < <(jq -r '.[]' <<< "${teams}")
    for tname in "${__teams[@]-}"; do
      [[ -z "${tname}" ]] && continue
      local have; have="$(team_get_by_name "${org}" "${tname}")"
      local tid; tid="$(jq -r '.id // ""' <<< "${have}")"
      if [[ -z "${tid}" ]]; then
        echo " - Team '${tname}' (for ${email}): team missing (will be created if in spec.teams.core)"
        continue
      fi
      local ids; ids="$(__team_user_ids "${tid}")"
      if jq -e --arg id "${user_id}" 'index($id)' <<< "${ids}" >/dev/null 2>&1; then
#     if jq -e --arg id "${user_id}" 'index($id)' <<< "$(jq -r '.[ ]' <<< "${ids}" 2>/dev/null || echo '[]')" >/dev/null 2>&1; then
        echo " - Membership: ${email} ∈ ${tname}: exists"
      else
        echo " - Membership: ${email} → ${tname}: add"
      fi
    done
  done
}

# --- APPLY: teams + memberships (existing users only) ---
apply_identities() {
  local spec="$1"
  local auto="${2:-}"

  if [[ "${auto}" != "--yes" ]]; then
    prompt "Apply teams + users changes now? [y/N]: "
    read -r ans || true
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi

  local org; org="$(json_get "${spec}" '.org.name')"
  [[ -n "${org}" && "${org}" != "null" ]] || { err "Missing .org.name for identities"; exit 2; }

  # 1) Ensure teams (create/update)
  local want_teams_arr; want_teams_arr="$(jq -c '(.teams.core // [])' "${spec}")"
  local have_teams_raw; have_teams_raw="$(list_org_teams_raw "${org}")"
  jq -r '.[] | @base64' <<< "${want_teams_arr}" | while read -r row; do
    local t name vis allow orgp have_row tid
    t="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<< "${t}")"
    [[ -z "${name}" || "${name}" == "null" ]] && continue
    vis="$(jq -r '(.visibility // "secret")' <<< "${t}")"
    allow="$(jq -r '(.allow_member_token_management // false) | tostring' <<< "${t}")"
    orgp="$(jq -c '(.organization_access // {})' <<< "${t}")"

    have_row="$(jq -c --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0] // {}' <<< "${have_teams_raw}")"
    tid="$(jq -r '.id // ""' <<< "${have_row}")"

    if [[ -z "${tid}" ]]; then
      tid="$(team_create "${org}" "${name}" "${vis}" "${allow}" "${orgp}")"
      ok "Team created: ${name} (${tid})"
      # refresh cache for later lookups
      have_teams_raw="$(list_org_teams_raw "${org}")"
    else
      # compare + update if needed
      local cur_vis cur_allow cur_orgp
      cur_vis="$(jq -r '.attributes.visibility // "secret"' <<< "${have_row}")"
      cur_allow="$(jq -r '(.attributes["allow-member-token-management"] // false) | tostring' <<< "${have_row}")"
      cur_orgp="$(jq -c '(.attributes["organization-access"] // {})' <<< "${have_row}")"

      local need=0
      [[ "${cur_vis}"   != "${vis}"   ]] && need=1
      [[ "${cur_allow}" != "${allow}" ]] && need=1
      if [[ "$(jq -r 'to_entries|map(select(.value==true)|.key)|sort|join(",")' <<< "${cur_orgp}")" != \
            "$(jq -r 'to_entries|map(select(.value==true)|.key)|sort|join(",")' <<< "${orgp}")" ]]; then
        need=1
      fi

      if [[ "${need}" -eq 1 ]]; then
        team_update "${tid}" "${vis}" "${allow}" "${orgp}"
        ok "Team updated: ${name}"
      else
        ok "Team up-to-date: ${name}"
      fi
    fi
  done

  # 2) Ensure memberships for existing users (by email)
  local email_to_id; email_to_id="$(__org_email_to_userid_map "${org}")"
  local want_users; want_users="$(jq -c '(.users // [])' "${spec}")"

  jq -r '.[] | @base64' <<< "${want_users}" | while read -r row; do
    local u email teams
    u="$(echo "${row}" | base64 --decode)"
    email="$(jq -r '.email // ""' <<< "${u}")"
    teams="$(jq -c '(.teams // [])' <<< "${u}")"
    [[ -z "${email}" ]] && continue

    local uid; uid="$(jq -r --arg e "${email}" '.[$e] // ""' <<< "${email_to_id}")"
    if [[ -z "${uid}" ]]; then
      warn "User ${email} not found in org; invite manually, skipping memberships."
      continue
    fi

    mapfile -t __teams < <(jq -r '.[]' <<< "${teams}")
    for tname in "${__teams[@]-}"; do
      [[ -z "${tname}" ]] && continue
      local have_t tid; have_t="$(team_get_by_name "${org}" "${tname}")"
      tid="$(jq -r '.id // ""' <<< "${have_t}")"
      if [[ -z "${tid}" ]]; then
        warn "Team '${tname}' (for ${email}) not found; ensure it is in spec.teams.core"
        continue
      fi

      local ids; ids="$(__team_user_ids "${tid}")"
      if jq -e --arg id "${uid}" 'index($id)' <<< "$(jq -r '.[ ]' <<< "${ids}" 2>/dev/null || echo '[]')" >/dev/null 2>&1; then
        ok "Membership exists: ${email} ∈ ${tname}"
      else
        __ensure_team_membership "${org}" "${tid}" "${uid}"
        ok "Membership added: ${email} → ${tname}"
      fi
    done
  done
}
