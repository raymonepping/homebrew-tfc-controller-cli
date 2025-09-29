#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

org_get_raw() {
  local org="$1" out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/organizations/${org}"
  )" || true
  if [[ "${http}" == "200" ]]; then
    cat "${out}"
  elif [[ "${http}" == "404" ]]; then
    err "Org not found: ${org}"; rm -f "${out}"; exit 1
  else
    err "Failed to read org (HTTP ${http})"; cat "${out}" >&2 || true; rm -f "${out}"; exit 1
  fi
  rm -f "${out}"
}

org_exists() {
  local org="$1" out http; out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "https://${TFE_HOST}/api/v2/organizations/${org}"
  )" || true
  if [[ "${http}" == "200" ]]; then rm -f "${out}"; echo "yes"
  elif [[ "${http}" == "404" ]]; then rm -f "${out}"; echo "no"
  else
    err "Unexpected status ${http} when checking org"; cat "${out}" >&2 || true; rm -f "${out}"; exit 1
  fi
}

create_org() {
  local org="$1" email="$2" out http; out="$(mktemp)"
  local payload; payload=$(jq -n --arg name "${org}" --arg email "${email}" '{
    data: { type: "organizations", attributes: { name: $name, email: $email } }
  }')
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" -H "content-type: application/vnd.api+json" \
      -X POST "https://${TFE_HOST}/api/v2/organizations" -d "${payload}"
  )" || true
  if [[ "${http}" == "201" ]]; then
    ok "Organization created: ${org}"
  elif [[ "${http}" == "422" ]]; then
    warn "Org creation failed. Name invalid or already taken."; cat "${out}" || true; rm -f "${out}"; exit 1
  elif [[ "${http}" == "403" ]]; then
    err "Forbidden. Create once in UI, then rerun."; rm -f "${out}"; exit 1
  else
    err "Unexpected status ${http} during org creation"; cat "${out}" || true; rm -f "${out}"; exit 1
  fi
  rm -f "${out}"
}

ensure_org() {
  local spec="$1" dry_run="${2:-false}"
  local org email
  org=$(json_get "${spec}" '.org.name')
  email=$(json_get "${spec}" '.org.email')
  [[ -n "${org}"   && "${org}"   != "null" ]] || { err "Missing .org.name"; exit 2; }
  [[ -n "${email}" && "${email}" != "null" ]] || { err "Missing .org.email"; exit 2; }

  echo "Host: ${TFE_HOST}"
  echo "Org:  ${org}"

  if [[ "$(org_exists "${org}")" == "yes" ]]; then ok "Org exists"; return 0; fi

  warn "Org not found. Will create."
  if [[ "${dry_run}" == "true" ]]; then
    echo "[dry-run] POST /api/v2/organizations name=${org} email=${email}"
    return 0
  fi
  create_org "${org}" "${email}"
}
