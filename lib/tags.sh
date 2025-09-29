#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# list_reserved_tag_keys <org>
# Returns: JSON array of { key, created_at } (ISO if API provides it; else "")
list_reserved_tag_keys() {
  local org="$1"

# helper: GET -> prints "<http>\n<outfile>"
__try_get() {
  local url="$1"
  local out http
  out="$(mktemp)"
  http="$(
    CURL -w "%{http_code}" -o "${out}" \
      -H "$(auth_header)" \
      "${url}"
  )" || true
  printf "%s\n%s\n" "${http}" "${out}"
}

  local base="https://${TFE_HOST}/api/v2/organizations/${org}"
  # order matters: first 200 wins
  local candidates=(
    "${base}/tag-keys"
    "${base}/tags/keys"
    "${base}/tags/reserved-keys"
    "${base}/reserved-tag-keys"
    # fallback (may be mixed, we’ll filter)
    "${base}/tags"
  )

  local path=""
  local matched_url=""
  for url in "${candidates[@]}"; do
    # SAFER SPLIT: read two separate lines, not words
    local resp http out
    resp="$(__try_get "${url}")"
    http="$(printf "%s\n" "${resp}" | sed -n '1p')"
    out="$( printf "%s\n" "${resp}" | sed -n '2p')"

    if [[ "${http}" == "200" ]]; then
      path="${out}"
      matched_url="${url}"
      [[ -n "${TFC_DEBUG:-}" ]] && echo "tags.sh: matched endpoint: ${matched_url}" >&2
      break
    else
      [[ -n "${TFC_DEBUG:-}" ]] && echo "tags.sh: ${url} -> HTTP ${http} ${out}" >&2
      rm -f "${out}" || true
    fi
  done

  if [[ -z "${path}" ]]; then
    [[ -n "${TFC_DEBUG:-}" ]] && echo "tags.sh: no tags endpoint matched; returning []" >&2
    echo "[]"
    return 0
  fi

  # Normalize to [{key, created_at}]
  # Handle common shapes:
  #   .data[].attributes.key / .data[].key / .data[].attributes.name / .data[].name
  #   .data[].attributes."created-at" / .data[]."created-at" / created_at
  #
  # If fallback /tags returns mixed objects, we try to keep only "key-like" items.
  local jq_prog='
    def k: .attributes.key // .key // .attributes.name // .name // empty;
    def c: .attributes."created-at" // ."created-at" // .attributes.created_at // .created_at // "";

    ( .data // [] )
    | map(select((.attributes? and (.attributes.key? or .attributes.name?)) or (.key? or .name?)))
    | map({ key: (k // ""), created_at: (c // "") })
    | map(select(.key != ""))
    | unique_by(.key)
  '

  local normalized; normalized="$(jq -r "${jq_prog}" "${path}")"
  rm -f "${path}" || true

  printf '%s\n' "${normalized}"
}
