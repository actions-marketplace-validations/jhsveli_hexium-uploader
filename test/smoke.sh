#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
PORT="${PORT:-8790}"

TMP="$(mktemp -d)"
LOG="$(mktemp)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
  rm -f "$LOG"
}
trap cleanup EXIT

ZIP="$TMP/MockMod-1.0.0.zip"
head -c 2500 /dev/urandom > "$ZIP"
MD5="$(md5sum "$ZIP" | awk '{print $1}')"

EXPECT_MD5="$MD5" PORT="$PORT" PART_SIZE=1000 node "$here/mock-server.mjs" > "$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -s "http://127.0.0.1:$PORT/nope" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

OUT="$TMP/github-output.txt"
INPUT_COMMUNITY=valheim \
  INPUT_FILE="$ZIP" \
  INPUT_TOKEN=dummy-token \
  INPUT_NAMESPACE=TestTeam \
  INPUT_CATEGORIES="client-side,utility" \
  INPUT_NSFW=false \
  INPUT_BASE_URL="http://127.0.0.1:$PORT" \
  GITHUB_OUTPUT="$OUT" \
  bash "$root/upload.sh"

grep -q '^package=TestTeam-MockMod$' "$OUT"
grep -q '^version=1.0.0$' "$OUT"
grep -q "reassembled 2500/2500 bytes md5=$MD5" "$LOG"

echo "smoke test passed"
