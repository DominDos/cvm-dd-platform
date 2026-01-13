#!/usr/bin/env bash
set -euo pipefail

: "${DD_BASE_URL:?DD_BASE_URL is required (e.g. https://defectdojo.<YOUR_DOMAIN>)}"

CURL_INSECURE_ARGS=()
if [[ "${DD_INSECURE_TLS:-false}" == "true" ]]; then
  CURL_INSECURE_ARGS=(-k)
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

login_url="${DD_BASE_URL%/}/login"
api_url="${DD_BASE_URL%/}/api/v2/"

"$SCRIPT_DIR/wait_for_url.sh" "$login_url" 600 10

login_code=$(curl -sS -o /dev/null -w "%{http_code}" "${CURL_INSECURE_ARGS[@]}" "$login_url" || true)
if [[ "$login_code" != "200" && "$login_code" != "302" ]]; then
  echo "Expected /login to return 200 or 302, got: $login_code" >&2
  exit 1
fi

echo "/login OK (HTTP $login_code)"

api_code=$(curl -sS -o /dev/null -w "%{http_code}" "${CURL_INSECURE_ARGS[@]}" "$api_url" || true)
if [[ "$api_code" != "401" ]]; then
  echo "Expected /api/v2/ to return 401 when unauthenticated, got: $api_code" >&2
  exit 1
fi

echo "/api/v2/ OK (HTTP $api_code)"
