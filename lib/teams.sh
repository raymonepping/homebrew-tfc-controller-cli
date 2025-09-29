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
