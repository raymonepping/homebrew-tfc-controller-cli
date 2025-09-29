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
    elif [[ "${http}" == "404" ]]; then rm -f "${tmp}"; break
    else err "Failed listing projects (HTTP ${http})"; cat "${tmp}" >&2 || true; rm -f "${tmp}"; exit 1
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
  if [[ "${http}" == "201" ]]; then ok "Project created: ${name}"
  elif [[ "${http}" == "409" || "${http}" == "422" ]]; then warn "Project create failed"; cat "${out}" || true; rm -f "${out}"; exit 1
  else err "Unexpected status ${http} creating project"; cat "${out}" || true; rm -f "${out}"; exit 1
  fi
  rm -f "${out}"
}

plan_projects() {
  local spec="$1" org; org=$(json_get "${spec}" '.org.name')
  [[ -n "${org}" && "${org}" != "null" ]] || { err "Missing .org.name for projects"; exit 2; }
  local have; have="$(list_projects "${org}")"
  local want_count; want_count="$(jq '(.projects // []) | length' "${spec}")"
  echo "Plan (projects):"
  if [[ "${want_count}" -eq 0 ]]; then echo " - No desired projects in spec."; return 0; fi
  jq -r '.projects[] | @base64' "${spec}" | while read -r row; do
    local item name; item="$(echo "${row}" | base64 --decode)"; name="$(jq -r '.name' <<<"${item}")"
    local exists_id; exists_id="$(jq -r --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0].id // empty' <<<"${have}")"
    [[ -n "${exists_id}" ]] && echo " - ${name}: exists" || echo " - ${name}: create"
  done
}

apply_projects() {
  local spec="$1" auto="${2:-}"
  if [[ "${auto}" != "--yes" ]]; then
    prompt "Apply project changes now? [y/N]: " && read -r ans || true
    [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]] || { echo "Aborted."; exit 1; }
  fi
  local org; org=$(json_get "${spec}" '.org.name')
  local have; have="$(list_projects "${org}")"
  jq -r '.projects[]? | @base64' "${spec}" | while read -r row; do
    local item name desc
    item="$(echo "${row}" | base64 --decode)"
    name="$(jq -r '.name' <<<"${item}")"
    desc="$(jq -r '.description // ""' <<<"${item}")"
    local exists_id; exists_id="$(jq -r --arg n "${name}" 'map(select(.attributes.name == $n)) | .[0].id // empty' <<<"${have}")"
    [[ -n "${exists_id}" ]] && ok "Project exists: ${name}" || create_project "${org}" "${name}" "${desc}"
  done
}
