#!/usr/bin/env bash
# Upload one file to Event Analysis through the TDM API and print the analysis id.
# Usage: ./event_analysis_upload.sh path/to/file.log
# SOCPRIME_API_URL overrides https://api.tdm.socprime.com.
# SOCPRIME_API_KEY is the SOC Prime API key; the script asks for it when unset.
# Needs curl 7.71 or newer, jq and gzip.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <file>" >&2
  exit 1
fi

file=$1
if [[ ! -f "$file" ]]; then
  echo "file not found: $file" >&2
  exit 1
fi

for cmd in curl gzip jq dd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 1
  fi
done
# Fails here on an older curl, not after the analysis is created.
if ! curl --retry-all-errors --version >/dev/null 2>&1; then
  echo "curl 7.71 or newer is required" >&2
  exit 1
fi

SOCPRIME_API_URL=${SOCPRIME_API_URL:-https://api.tdm.socprime.com}
SOCPRIME_API_URL=${SOCPRIME_API_URL%/}

if [[ -z "${SOCPRIME_API_KEY:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "SOC Prime API key is required" >&2
    exit 1
  fi
  read -r -s -p "SOC Prime API key: " SOCPRIME_API_KEY
  echo >&2
fi
if [[ -z "${SOCPRIME_API_KEY}" ]]; then
  echo "SOC Prime API key is empty" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
# The key and the upload token go to curl from a file, so they are not in the process list.
headers="$workdir/headers"
(umask 077 && printf 'client_secret_id: %s\n' "$SOCPRIME_API_KEY" > "$headers")

# Prints the message and the last API answer, then exits.
fail() {
  echo "$1" >&2
  cat "$workdir/response.json" >&2 2>/dev/null || true
  echo >&2
  exit 1
}

size=$(wc -c < "$file" | tr -d '[:space:]')
request=$(jq -n --arg name "${file##*/}" --argjson size "$size" '{file: {name: $name, size_bytes: $size}}')
# Not retried: a retry could create a second analysis.
code=$(curl --no-progress-meter --connect-timeout 10 --max-time 60 \
  -o "$workdir/response.json" -w "%{http_code}" \
  -H @"$headers" -H "Content-Type: application/json" --data "$request" \
  "${SOCPRIME_API_URL}/v1/event-analyses") || true
[[ "$code" == "201" ]] || fail "failed to create analysis (HTTP ${code})"

analysis_id=$(jq -r '.analysis_id' "$workdir/response.json")
chunk_size=$(jq -r '.upload.chunk_size_bytes' "$workdir/response.json")
chunks_total=$(jq -r '.upload.chunks_total' "$workdir/response.json")
# Checked before use: bash arithmetic runs a command hidden in a value like `x[$(cmd)]`.
if [[ ! "$analysis_id" =~ ^[A-Za-z0-9_-]+$ || ! "$chunk_size" =~ ^[1-9][0-9]*$ || ! "$chunks_total" =~ ^[1-9][0-9]*$ ]]; then
  fail "create response has no upload plan"
fi
jq -r '"X-Upload-Token: " + .upload.token' "$workdir/response.json" >> "$headers"

for (( seq = 0; seq < chunks_total; seq++ )); do
  dd if="$file" bs="$chunk_size" skip="$seq" count=1 2>/dev/null | gzip -c -n > "$workdir/chunk.gz"
  # A chunk may be sent twice: curl retries network errors, 429 and 5xx, waiting as Retry-After says.
  code=$(curl --no-progress-meter --connect-timeout 10 --speed-limit 1 --speed-time 120 \
    --retry 8 --retry-all-errors \
    -o "$workdir/response.json" -w "%{http_code}" \
    -H @"$headers" -H "Content-Type: application/octet-stream" -H "Content-Encoding: gzip" \
    -T "$workdir/chunk.gz" \
    "${SOCPRIME_API_URL}/v1/event-analyses/${analysis_id}/content/chunks/${seq}") || true
  [[ "$code" == "202" ]] || fail "chunk ${seq} failed (HTTP ${code})"
  echo "chunk $((seq + 1))/${chunks_total}" >&2
done

echo "$analysis_id"
