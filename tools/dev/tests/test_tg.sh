#!/usr/bin/env bash
# Tests for tools/dev/tg's TestFlight steps. Nothing is built or uploaded: each test sources tg in a
# subshell and replaces the build, the upload and App Store Connect with shell functions.
#
#   tools/dev/tests/test_tg.sh
set -uo pipefail

TG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

check() {
  local description="$1"; shift
  if "$@"; then
    echo "ok - $description"
  else
    echo "FAIL - $description"
    failures=$((failures + 1))
  fi
}

# run_testflight <upload status> <notes status>: tg testflight with a stub build, dSYM archive,
# upload (device_signing.py) and notes step (tf_notes.py). Sets STATUS; output in $TMP/out, $TMP/err.
run_testflight() {
  local upload_status="$1" notes_status="$2"
  rm -f "$TMP/calls"
  printf 'Fixes.\n' > "$TMP/notes.txt"
  (
    # shellcheck source=../tg
    source "$TG"
    cmd_device() { :; }
    archive_dsyms() { ARCHIVED_DSYM_DIR="$TMP/dsyms/202611031200"; mkdir -p "$ARCHIVED_DSYM_DIR"; }
    python3() {
      case "$*" in
        *tf_notes.py\ --check*) return 0 ;;
        *device_signing.py\ testflight*) echo upload >> "$TMP/calls"; return "$upload_status" ;;
        *tf_notes.py\ IOS*) echo notes >> "$TMP/calls"; return "$notes_status" ;;
        *) echo "unexpected python3 $*" >&2; return 99 ;;
      esac
    }
    cmd_testflight --notes "$TMP/notes.txt"
  ) > "$TMP/out" 2> "$TMP/err"
  STATUS=$?
}

test_notes_failure_after_upload() {
  run_testflight 0 1
  check "notes failing after an upload exits 3" [ "$STATUS" -eq 3 ]
  check "it says the build was uploaded" grep -q "UPLOADED; notes not set; run:" "$TMP/err"
  check "it prints the notes command for that build" grep -q "tf_notes.py IOS 202611031200 .*WhatToTest.txt" "$TMP/err"
}

test_upload_failure() {
  run_testflight 1 0
  check "a failed upload is not reported as exit 3" [ "$STATUS" -ne 0 -a "$STATUS" -ne 3 ]
  check "a failed upload sets no notes" [ "$(cat "$TMP/calls")" = "upload" ]
}

test_success() {
  run_testflight 0 0
  check "upload and notes succeeding exits 0" [ "$STATUS" -eq 0 ]
  check "upload then notes" [ "$(tr '\n' ' ' < "$TMP/calls")" = "upload notes " ]
}

test_notes_failure_after_upload
test_upload_failure
test_success

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
