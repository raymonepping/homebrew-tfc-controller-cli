#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Requires from commons.sh: CURL, auth_header, TFE_HOST, err
# Requires from teams.sh:
#   - userid_to_teamnames_from_org_teams
#   - userid_to_teamnames_via_relationships

# ---- helper: paginated GET for .data ----
__users_paged_get_data() {
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

# ---- org memberships: email + status live here ----
list_org_memberships_raw() {
  local org="$1"
  __users_paged_get_data "https://${TFE_HOST}/api/v2/organizations/${org}/organization-memberships"
}

# ---- user detail: username lives here (/users/:id) ----
get_user_detail() {
  local user_id="$1"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/users/${user_id}"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '{
      id: .data.id,
      username: (.data.attributes.username // .data.attributes."user-name" // "")
    }' "${out}"
  else
    # Fallback: return id as username if user detail not readable
    jq -n --arg id "${user_id}" '{ id:$id, username:$id }'
  fi
  rm -f "${out}"
}

# ---- Build user-id -> [team names...] using teams endpoints (robust) ----
build_userid_to_teamnames_map() {
  local org="$1"
  local m; m="$(userid_to_teamnames_from_org_teams "${org}")"
  [[ -z "${m}" || "${m}" == "null" || "${m}" == "{}" ]] && m="$(userid_to_teamnames_via_relationships "${org}")"
  [[ -z "${m}" || "${m}" == "null" ]] && m="{}"
  echo "${m}"
}

# ---- main: [{ username, email, status, teams:[name...] }] ----
list_org_users() {
  local org="$1"

  # 1) Seed from memberships (email + status + user id)
  local memberships; memberships="$(list_org_memberships_raw "${org}")"
  [[ -z "${memberships}" || "${memberships}" == "null" ]] && memberships="[]"

  # cache user detail lookups
  declare -A detail_cache=()
  # map username -> {username,email,status,teams:[]}
  local user_map="{}"

  mapfile -t __mrows < <(jq -r '.[] | @base64' <<< "${memberships}")
  for __mrow in "${__mrows[@]-}"; do
    local m uid uname uemail ustatus detail
    m="$(echo "${__mrow}" | base64 --decode)"
    uid="$(jq -r '.relationships.user.data.id // ""' <<< "${m}")"
    [[ -z "${uid}" ]] && continue

    uemail="$(jq -r '.attributes.email // .attributes."user-email" // .attributes."user_email" // ""' <<< "${m}")"
    ustatus="$(jq -r '.attributes.status // ""' <<< "${m}")"

    if [[ -z "${detail_cache[${uid}]:-}" ]]; then
      detail_cache["${uid}"]="$(get_user_detail "${uid}")"
    fi
    detail="${detail_cache[${uid}]}"
    uname="$(jq -r '.username // ""' <<< "${detail}")"
    [[ -z "${uname}" ]] && uname="${uid}"

    user_map="$(
      jq -c --arg u "${uname}" --arg e "${uemail}" --arg s "${ustatus}" '
        . + { ($u): { username:$u, email:$e, status:$s, teams:[] } }
      ' <<< "${user_map}"
    )"
  done

  # 2) Attach team names (from teams payload / relationships)
  local uid_to_teamnames; uid_to_teamnames="$(build_userid_to_teamnames_map "${org}")"
  [[ -z "${uid_to_teamnames}" || "${uid_to_teamnames}" == "null" ]] && uid_to_teamnames="{}"

  # build username -> user-id map from the cache
  local uname_to_uid="{}"
  for k in "${!detail_cache[@]}"; do
    local rec uname; rec="${detail_cache[$k]}"
    uname="$(jq -r '.username // ""' <<< "${rec}")"
    [[ -z "${uname}" ]] && uname="${k}"
    uname_to_uid="$(jq -c --arg u "${uname}" --arg id "${k}" '. + { ($u): $id }' <<< "${uname_to_uid}")"
  done

  mapfile -t __users < <(jq -r 'keys[]' <<< "${user_map}")
  for uname in "${__users[@]-}"; do
    local uid; uid="$(jq -r --arg u "${uname}" '.[$u] // ""' <<< "${uname_to_uid}")"
    [[ -z "${uid}" ]] && continue
    local names; names="$(jq -r --arg id "${uid}" '.[$id] // []' <<< "${uid_to_teamnames}")"
    [[ -z "${names}" || "${names}" == "null" ]] && names="[]"

    user_map="$(
      jq -c --arg u "${uname}" --argjson names "${names}" '
        . as $U
        | $U[$u] as $cur
        | $U + { ($u): ($cur | .teams = ($cur.teams + $names | unique)) }
      ' <<< "${user_map}"
    )"
  done

  jq -c '[ .[] ]' <<< "${user_map}"
}
