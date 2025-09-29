#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# List all private registry modules in an org (paginated).
# Returns raw array of module objects (as provided by the API under .data)
list_registry_modules() {
  local org="$1" page=1 size=100 all="[]"
  while true; do
    local tmp http; tmp="$(mktemp)"
    http="$(
      CURL -w "%{http_code}" -o "${tmp}" \
        -H "$(auth_header)" \
        "https://${TFE_HOST}/api/v2/organizations/${org}/registry-modules?page%5Bnumber%5D=${page}&page%5Bsize%5D=${size}"
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
      err "Failed listing registry modules (HTTP ${http})"
      cat "${tmp}" >&2 || true
      rm -f "${tmp}"
      exit 1
    fi
  done
  echo "${all}"
}

# List all versions for a module by module_id
# Returns raw array of version objects (under .data)
list_registry_module_versions() {
  local module_id="$1"
  local out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/registry-modules/${module_id}/versions"
  )" || true
  if [[ "${http}" == "200" ]]; then
    jq -r '.data // []' "${out}"
  elif [[ "${http}" == "404" ]]; then
    echo "[]"
  else
    err "Failed listing versions for module ${module_id} (HTTP ${http})"
    cat "${out}" >&2 || true
    echo "[]"
  fi
  rm -f "${out}"
}
