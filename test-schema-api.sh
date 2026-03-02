#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test-schema-api.sh [--base-url <url>] [--out-dir <path>] [--apply]

Environment:
  WP_API_USER           Required WordPress username for API auth
  WP_API_APP_PASSWORD   Required WordPress Application Password
  ACF_SCHEMA_API_HMAC_SECRET  Optional HMAC secret for sites that still require signed push requests

This script performs:
1) Pull schema
2) Build dry-run push payload using pulled groups + expected_hash
3) Push dry-run
4) Optional real push when --apply is provided

Output files:
- Pretty JSON files for easy reading
- Raw JSON copies for exact wire response
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
}

BASE_URL="https://api-gordon-acf-demo.roostergrintemplates.com"
OUT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime"
APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      [[ $# -ge 2 ]] || fail "Missing value for --base-url"
      BASE_URL="${2%/}"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || fail "Missing value for --out-dir"
      OUT_DIR="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_command curl
require_command jq

[[ -n "${WP_API_USER:-}" ]] || fail "WP_API_USER is required"
[[ -n "${WP_API_APP_PASSWORD:-}" ]] || fail "WP_API_APP_PASSWORD is required"
if [[ -n "${ACF_SCHEMA_API_HMAC_SECRET:-}" ]]; then
  require_command openssl
fi

mkdir -p "${OUT_DIR}"

PULL_URL="${BASE_URL}/wp-json/acf-schema/v1/pull"
PUSH_URL="${BASE_URL}/wp-json/acf-schema/v1/push"
PULL_RESPONSE="${OUT_DIR}/pull-response.json"
PULL_RESPONSE_RAW="${OUT_DIR}/pull-response.raw.json"
PUSH_DRY_RESPONSE="${OUT_DIR}/push-dry-run-response.json"
PUSH_DRY_RESPONSE_RAW="${OUT_DIR}/push-dry-run-response.raw.json"
PUSH_APPLY_RESPONSE="${OUT_DIR}/push-apply-response.json"
PUSH_APPLY_RESPONSE_RAW="${OUT_DIR}/push-apply-response.raw.json"
PAYLOAD_FILE="${OUT_DIR}/push-payload.json"

build_push_headers() {
  local payload_file="$1"
  PUSH_HEADERS=()
  [[ -n "${ACF_SCHEMA_API_HMAC_SECRET:-}" ]] || return 0

  local timestamp
  local nonce
  local body_hash
  local canonical
  local signature

  timestamp="$(date +%s)"
  nonce="$(openssl rand -hex 16)"
  body_hash="$(openssl dgst -sha256 "${payload_file}" | awk '{print $NF}')"
  canonical="$(printf 'POST\n/acf-schema/v1/push\n%s\n%s\n%s' "${timestamp}" "${nonce}" "${body_hash}")"
  signature="$(printf '%s' "${canonical}" | openssl dgst -sha256 -hmac "${ACF_SCHEMA_API_HMAC_SECRET}" | awk '{print $NF}')"

  PUSH_HEADERS=(
    -H "X-ACF-Schema-Timestamp: ${timestamp}"
    -H "X-ACF-Schema-Nonce: ${nonce}"
    -H "X-ACF-Schema-Signature: ${signature}"
  )
}

echo "Calling pull endpoint..."
pull_tmp="$(mktemp)"
curl -sS --fail --show-error \
  --user "${WP_API_USER}:${WP_API_APP_PASSWORD}" \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{"include_groups": true}' \
  "${PULL_URL}" > "${pull_tmp}"

cp "${pull_tmp}" "${PULL_RESPONSE_RAW}"
jq '.' "${pull_tmp}" > "${PULL_RESPONSE}"
rm -f "${pull_tmp}"

jq -e '.schema_hash and (.field_groups|type=="array") and (.group_count|type=="number")' "${PULL_RESPONSE}" >/dev/null \
  || fail "Pull response missing required fields."

SCHEMA_HASH="$(jq -r '.schema_hash' "${PULL_RESPONSE}")"
GROUP_COUNT="$(jq -r '.group_count' "${PULL_RESPONSE}")"
echo "Pull ok. schema_hash=${SCHEMA_HASH} group_count=${GROUP_COUNT}"

groups_tmp="$(mktemp)"
jq '.field_groups' "${PULL_RESPONSE}" > "${groups_tmp}"
jq -n \
  --arg expected_hash "${SCHEMA_HASH}" \
  --slurpfile field_groups "${groups_tmp}" \
  '{expected_hash: $expected_hash, dry_run: true, field_groups: $field_groups[0]}' > "${PAYLOAD_FILE}"
rm -f "${groups_tmp}"

echo "Calling push dry-run endpoint..."
dry_tmp="$(mktemp)"
build_push_headers "${PAYLOAD_FILE}"

curl -sS --fail --show-error \
  --user "${WP_API_USER}:${WP_API_APP_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${PUSH_HEADERS[@]}" \
  -X POST \
  --data-binary "@${PAYLOAD_FILE}" \
  "${PUSH_URL}" > "${dry_tmp}"

cp "${dry_tmp}" "${PUSH_DRY_RESPONSE_RAW}"
jq '.' "${dry_tmp}" > "${PUSH_DRY_RESPONSE}"
rm -f "${dry_tmp}"

jq -e '.dry_run == true and .plan and .current_hash and .incoming_hash' "${PUSH_DRY_RESPONSE}" >/dev/null \
  || fail "Push dry-run response missing required fields."

echo "Dry-run ok."
echo "Dry-run plan summary:"
jq '.plan' "${PUSH_DRY_RESPONSE}"

if [[ "${APPLY}" -eq 1 ]]; then
  jq '.dry_run = false' "${PAYLOAD_FILE}" > "${PAYLOAD_FILE}.tmp"
  mv "${PAYLOAD_FILE}.tmp" "${PAYLOAD_FILE}"

  echo "Calling push apply endpoint..."
  apply_tmp="$(mktemp)"
  build_push_headers "${PAYLOAD_FILE}"

  curl -sS --fail --show-error \
    --user "${WP_API_USER}:${WP_API_APP_PASSWORD}" \
    -H "Content-Type: application/json" \
    "${PUSH_HEADERS[@]}" \
    -X POST \
    --data-binary "@${PAYLOAD_FILE}" \
    "${PUSH_URL}" > "${apply_tmp}"

  cp "${apply_tmp}" "${PUSH_APPLY_RESPONSE_RAW}"
  jq '.' "${apply_tmp}" > "${PUSH_APPLY_RESPONSE}"
  rm -f "${apply_tmp}"

  jq -e '.applied == true and .schema_hash_after' "${PUSH_APPLY_RESPONSE}" >/dev/null \
    || fail "Push apply response missing required fields."

  echo "Apply ok."
  echo "apply response: ${PUSH_APPLY_RESPONSE}"
fi

echo "Done."
echo "pull response (pretty): ${PULL_RESPONSE}"
echo "pull response (raw): ${PULL_RESPONSE_RAW}"
echo "dry-run response (pretty): ${PUSH_DRY_RESPONSE}"
echo "dry-run response (raw): ${PUSH_DRY_RESPONSE_RAW}"
if [[ "${APPLY}" -eq 1 ]]; then
  echo "apply response (pretty): ${PUSH_APPLY_RESPONSE}"
  echo "apply response (raw): ${PUSH_APPLY_RESPONSE_RAW}"
fi
echo "payload: ${PAYLOAD_FILE}"
