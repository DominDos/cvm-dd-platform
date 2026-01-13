#!/usr/bin/env bash
set -euo pipefail

URL="${1:-}"
TIMEOUT_SECONDS="${2:-300}"
SLEEP_SECONDS="${3:-5}"

if [[ -z "$URL" ]]; then
  echo "Usage: $0 <url> [timeout_seconds] [sleep_seconds]" >&2
  exit 2
fi

CURL_INSECURE_ARGS=()
if [[ "${DD_INSECURE_TLS:-false}" == "true" ]]; then
  CURL_INSECURE_ARGS=(-k)
fi

start=$(date +%s)

while true; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "${CURL_INSECURE_ARGS[@]}" "$URL" || true)
  if [[ "$code" != "000" ]]; then
    echo "URL reachable: $URL (HTTP $code)"
    exit 0
  fi

  now=$(date +%s)
  elapsed=$((now - start))
  if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
    echo "Timed out waiting for URL: $URL" >&2
    exit 1
  fi

  echo "Waiting for URL ($elapsed/${TIMEOUT_SECONDS}s): $URL"
  sleep "$SLEEP_SECONDS"
done
