#!/usr/bin/env bash
# Bulk-apply a public-read ACL to every object under one or more S3 prefixes.
#
# Needed on S3-compatible providers that don't support bucket policies (e.g. OVH
# returns "NotImplemented" for put-bucket-policy — see BACKUP.md §9 Step A). A
# bucket-level ACL only grants anonymous *list* rights; it does not make
# individual objects readable, and neither `rclone copy`/`move` nor the
# picture-worker's own S3 writes set an object ACL. Run this after any image
# restore, or any time pictures/derivates 404 on the site despite the file
# provably existing (check with `rclone lsf` or `aws s3api get-object-acl`).
#
# Usage:
#   fix-object-acls.sh <profile> <bucket> <endpoint-url> <prefix> [prefix ...]
#
# Env overrides:
#   PARALLEL=20   number of concurrent put-object-acl calls (default 20)
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <profile> <bucket> <endpoint-url> <prefix> [prefix ...]" >&2
  exit 1
fi

PROFILE=$1
BUCKET=$2
ENDPOINT=$3
shift 3
PREFIXES=("$@")

PARALLEL=${PARALLEL:-20}
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

DONE_LOG="$WORKDIR/done.log"
FAIL_LOG="$WORKDIR/failed.log"
ERROR_LOG="$WORKDIR/errors.log"
: > "$DONE_LOG"
: > "$FAIL_LOG"
: > "$ERROR_LOG"

export PROFILE BUCKET ENDPOINT DONE_LOG FAIL_LOG ERROR_LOG

fix_one() {
  key=$1
  if aws s3api put-object-acl --profile "$PROFILE" --bucket "$BUCKET" \
      --key "$key" --acl public-read --endpoint-url "$ENDPOINT" >/dev/null 2>>"$ERROR_LOG"; then
    echo "$key" >> "$DONE_LOG"
  else
    echo "$key" >> "$FAIL_LOG"
  fi
}
export -f fix_one

for prefix in "${PREFIXES[@]}"; do
  prefix=${prefix%/}
  keys_file="$WORKDIR/keys-$(echo "$prefix" | tr '/' '_').txt"

  echo "=== Listing $prefix/ ==="
  aws s3api list-objects-v2 --profile "$PROFILE" --bucket "$BUCKET" --prefix "$prefix/" \
    --endpoint-url "$ENDPOINT" --query 'Contents[].Key' --output text \
    | tr '\t' '\n' > "$keys_file"
  total=$(wc -l < "$keys_file")
  echo "$prefix: $total objects, applying public-read ACL with $PARALLEL parallel requests"

  ( while :; do
      done_n=$(wc -l < "$DONE_LOG")
      fail_n=$(wc -l < "$FAIL_LOG")
      printf '\r[%s] %d/%d ok, %d failed' "$prefix" "$done_n" "$total" "$fail_n"
      sleep 2
    done ) &
  monitor_pid=$!
  trap 'kill "$monitor_pid" 2>/dev/null || true' RETURN

  xargs -P "$PARALLEL" -I{} bash -c 'fix_one "$@"' _ {} < "$keys_file"

  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  echo
done

fail_total=$(wc -l < "$FAIL_LOG")
echo "Done. $fail_total failure(s)."
if [ "$fail_total" -gt 0 ]; then
  echo "Failed keys (safe to re-run this script — it's idempotent):"
  cat "$FAIL_LOG"
  echo "Error detail:"
  cat "$ERROR_LOG"
  exit 1
fi
