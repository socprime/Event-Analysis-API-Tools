#!/usr/bin/env bash
# Download the tagged-events file of one analysis from Event Analysis.
# Usage: ./event_analysis_download.sh <analysis_id> [output]
# SOCPRIME_API_URL overrides https://api.tdm.socprime.com.
# SOCPRIME_API_KEY is the SOC Prime API key; the script asks for it when unset.
# Needs curl 7.71 or newer, jq and gzip.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <analysis_id> [output]" >&2
  exit 1
fi

analysis_id=$1
# It becomes part of the URL and of the default file name.
if [[ ! "$analysis_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  echo "invalid analysis id: $analysis_id" >&2
  exit 1
fi
out=${2:-${analysis_id}.ndjson}
out=${out%.gz}
# Next to the output, not in /tmp: a run that gives up is resumed by running it again.
partial="${out}.gz.part"

for cmd in curl jq gzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 1
  fi
done

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

base_url="${SOCPRIME_API_URL}/v1/event-analyses/${analysis_id}/tagged-events"
status_url="${base_url}/state"
content_url="${base_url}/content"
echo "analysis ${analysis_id} at ${SOCPRIME_API_URL}" >&2
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
# The key goes to curl from a file, so it is not in the process list during a long download.
key_header="$workdir/key.hdr"
(umask 077 && printf 'client_secret_id: %s\n' "$SOCPRIME_API_KEY" > "$key_header")

# Seconds from the Retry-After header in the given header dump, 3 without one.
retry_after() {
  local retry=""
  if [[ -f "$1" ]]; then
    retry=$(tr -d '\r' < "$1" | awk 'tolower($1)=="retry-after:" {print $2}')
  fi
  # It may also be an HTTP date.
  [[ "$retry" =~ ^[0-9]+$ ]] || retry=3
  echo "$retry"
}

while true; do
  # curl retries network errors, 429 and 5xx, waiting as Retry-After says.
  code=$(curl --no-progress-meter --connect-timeout 10 --max-time 30 --retry 5 --retry-all-errors \
    -o "$workdir/status.json" -w "%{http_code}" \
    -H @"$key_header" \
    "$status_url") || true
  if [[ "$code" != "200" ]]; then
    echo "status request failed (HTTP ${code})" >&2
    cat "$workdir/status.json" >&2 2>/dev/null || true
    echo >&2
    exit 1
  fi
  state=$(jq -r '.state // empty' "$workdir/status.json")
  echo "state=${state}"
  if [[ "$state" == "ready" ]]; then
    break
  fi
  if [[ "$state" == "unavailable" ]]; then
    echo "tagged events file is unavailable" >&2
    exit 1
  fi
  sleep 3
done

# -C - resumes from what is already saved; -f keeps an error body out of the file.
# A transfer that stalls for a minute is dropped and resumed rather than left hanging.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  rm -f "$workdir/content.hdr"
  if code=$(curl -fS -# -C - --connect-timeout 10 --speed-limit 1 --speed-time 60 \
    -o "$partial" -D "$workdir/content.hdr" -w "%{http_code}" \
    -H @"$key_header" \
    "$content_url"); then
    break
  fi
  case "$code" in
    416)
      # Nothing is left past what is already saved.
      break
      ;;
    000 | 200 | 206 | 429 | 5??)
      if (( attempt == 10 )); then
        echo "download failed (HTTP ${code}); run again to resume" >&2
        exit 1
      fi
      retry=$(retry_after "$workdir/content.hdr")
      echo "download interrupted (HTTP ${code}), resuming in ${retry}s" >&2
      sleep "$retry"
      ;;
    *)
      echo "download failed: HTTP ${code}" >&2
      exit 1
      ;;
  esac
done

# gzip checks the CRC, so a resume onto a rebuilt file is caught here.
if ! gzip -dc "$partial" > "$out"; then
  rm -f "$out" "$partial"
  echo "the download is corrupt and was removed; run again" >&2
  exit 1
fi
rm -f "$partial"
echo "saved ${out}"
