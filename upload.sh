#!/usr/bin/env bash
set -euo pipefail

# Hexium / Thunderstore-compatible package uploader.
#
# Uploads a package ZIP via the experimental multipart upload API:
#   initiate-upload -> PUT presigned parts -> finish-upload -> submit
#
# Auth uses `Authorization: Bearer <token>` on the JSON endpoints only. The
# presigned part URLs carry their own signature and must NOT receive the header.

: "${INPUT_COMMUNITY:?community input is required}"
: "${INPUT_FILE:?file input is required}"
: "${INPUT_TOKEN:?token input is required}"
: "${INPUT_NAMESPACE:?namespace input is required}"

HOST="${INPUT_HOST:-hexium.gg}"
COMMUNITY="${INPUT_COMMUNITY}"
FILE="${INPUT_FILE}"
TOKEN="${INPUT_TOKEN}"
NAMESPACE="${INPUT_NAMESPACE}"
CATEGORIES="${INPUT_CATEGORIES:-}"
NSFW="${INPUT_NSFW:-false}"

# Prepend "Bearer " when the raw key has no scheme yet.
if [[ "$TOKEN" != *" "* ]]; then
  TOKEN="Bearer $TOKEN"
fi

if [ -n "${INPUT_BASE_URL:-}" ]; then
  BASE="${INPUT_BASE_URL%/}"
else
  BASE="https://${COMMUNITY}.${HOST}"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required but not installed" >&2
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "::error::package file not found: $FILE" >&2
  exit 1
fi

FILENAME="$(basename "$FILE")"
SIZE="$(wc -c < "$FILE" | tr -d '[:space:]')"

case "${NSFW,,}" in
  true | 1 | yes | on) NSFW_JSON="true" ;;
  *) NSFW_JSON="false" ;;
esac

# --- helpers ----------------------------------------------------------------

# POST a JSON body to an API endpoint, print the response body, fail loudly on HTTP errors.
api_post() {
  local url="$1" data="$2"
  local body headers code
  headers="$(mktemp "${TMPDIR:-/tmp}/hexium.XXXXXX")"
  body="$(curl -sS -X POST "$url" \
    -H "Authorization: $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$data" -D "$headers")"
  code="$(awk 'NR==1 { print $2 }' "$headers")"
  rm -f "$headers"
  if [ -z "$code" ] || [ "$code" -ge 400 ]; then
    echo "::error::POST $url -> HTTP ${code:-?}: $body" >&2
    return 1
  fi
  printf '%s' "$body"
}

CLEANUP=()
cleanup() {
  local f
  for f in "${CLEANUP[@]:-}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

tmpfile() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/hexium.XXXXXX")"
  CLEANUP+=("$f")
  printf '%s' "$f"
}

# --- 1. initiate upload -----------------------------------------------------

echo "::group::Initiate upload"
INITIATE="$(api_post "$BASE/api/experimental/usermedia/initiate-upload/" \
  "{\"filename\":\"$FILENAME\",\"file_size_bytes\":$SIZE}")"

UUID="$(jq -r '.user_media.uuid' <<<"$INITIATE")"
PARTS="$(jq -r '.upload_urls | length' <<<"$INITIATE")"

if [ -z "$UUID" ] || [ "$UUID" = "null" ]; then
  echo "::error::initiate-upload response missing user_media.uuid: $INITIATE" >&2
  exit 1
fi
if [ "$PARTS" -lt 1 ]; then
  echo "::error::initiate-upload returned no upload parts" >&2
  exit 1
fi

echo "upload_uuid=$UUID parts=$PARTS size=$SIZE"
echo "::endgroup::"

abort_upload() {
  api_post "$BASE/api/experimental/usermedia/$UUID/abort-upload/" '{}' >/dev/null 2>&1 || true
}

# --- 2. upload parts --------------------------------------------------------

echo "::group::Upload parts"
ETAGS=()
PNUMS=()
for ((i = 0; i < PARTS; i++)); do
  part_number="$(jq -r ".upload_urls[$i].part_number" <<<"$INITIATE")"
  offset="$(jq -r ".upload_urls[$i].offset" <<<"$INITIATE")"
  length="$(jq -r ".upload_urls[$i].length" <<<"$INITIATE")"
  url="$(jq -r ".upload_urls[$i].url" <<<"$INITIATE")"

  if [ "$offset" -eq 0 ] && [ "$length" -eq "$SIZE" ]; then
    part_file="$FILE"
  else
    part_file="$(tmpfile)"
    if ! dd if="$FILE" of="$part_file" bs=1 skip="$offset" count="$length" 2>/dev/null; then
      echo "::error::failed to extract part $part_number" >&2
      abort_upload
      exit 1
    fi
  fi

  headers="$(tmpfile)"
  if ! curl -sS -f -X PUT --data-binary @"$part_file" -D "$headers" -o /dev/null "$url"; then
    echo "::error::PUT part $part_number to presigned URL failed" >&2
    abort_upload
    exit 1
  fi

  etag="$(tr -d '\r' < "$headers" | awk 'BEGIN{IGNORECASE=1} /^etag:/{sub(/^etag:[[:space:]]*/,""); print; exit}')"
  etag="${etag#\"}"
  etag="${etag%\"}"
  if [ -z "$etag" ]; then
    echo "::error::part $part_number returned no ETag header" >&2
    abort_upload
    exit 1
  fi

  echo "part $part_number/$PARTS etag=\"$etag\""
  ETAGS+=("\"$etag\"")
  PNUMS+=("$part_number")
done
echo "::endgroup::"

# --- 3. finish upload -------------------------------------------------------

echo "::group::Finish upload"
parts_json="["
for idx in "${!ETAGS[@]}"; do
  [ "$idx" -gt 0 ] && parts_json+=","
  parts_json+="{\"ETag\":${ETAGS[$idx]},\"PartNumber\":${PNUMS[$idx]}}"
done
parts_json+="]"

FINISH="$(api_post "$BASE/api/experimental/usermedia/$UUID/finish-upload/" "{\"parts\":$parts_json}")"
echo "finish-upload: $(jq -r '.uuid // "ok"' <<<"$FINISH")"
echo "::endgroup::"

# --- 4. submit --------------------------------------------------------------

echo "::group::Submit package"
categories_json="[]"
if [ -n "$CATEGORIES" ]; then
  categories_json="$(jq -n -c --arg c "$CATEGORIES" '$c | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))')"
fi

SUBMIT="$(api_post "$BASE/api/experimental/submission/submit/" \
  "{\"author_name\":\"$NAMESPACE\",\"categories\":$categories_json,\"communities\":[\"$COMMUNITY\"],\"has_nsfw_content\":$NSFW_JSON,\"upload_uuid\":\"$UUID\"}")"

full_name="$(jq -r '.package_version.full_name // empty' <<<"$SUBMIT")"
version="$(jq -r '.package_version.version_number // empty' <<<"$SUBMIT")"

echo "published: ${full_name:-?} ${version:-?}"
echo "::endgroup::"

{
  echo "package=${full_name}"
  echo "version=${version}"
} >> "$GITHUB_OUTPUT"
