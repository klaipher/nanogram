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
    cmd_device() { echo "$*" > "$TMP/device_args"; }
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
  check "the TestFlight build is marked for the App Store" grep -q -- "--app-store" "$TMP/device_args"
}

# run_device <aps-environment of the app's profile> [tg device options]: tg device --no-install with
# a stub build and profile. Sets STATUS; output in $TMP/out, $TMP/err.
run_device() {
  local profile_aps="$1"; shift
  mkdir -p "$TMP/signing/profiles"
  : > "$TMP/signing/profiles/Telegram.mobileprovision"
  echo '{}' > "$TMP/device-configuration.json"
  (
    export TG_DEVICE_CONFIG="$TMP/device-configuration.json" TG_DEVICE_CODESIGNING="$TMP/signing"
    # shellcheck source=../tg
    source "$TG"
    make_py() { :; }
    profile_aps_environment() { echo "$profile_aps"; }
    cmd_device --no-install ${@+"$@"}
  ) > "$TMP/out" 2> "$TMP/err"
  STATUS=$?
}

# A development profile makes the push token a sandbox one, while release_arm64 registers it as
# production: Telegram's pushes, calls included, never reach that install.
test_device_push_environment() {
  run_device development
  check "a development-signed device build succeeds" [ "$STATUS" -eq 0 ]
  check "it warns that pushes and calls will not arrive" grep -q "NO PUSH NOTIFICATIONS OR INCOMING CALLS" "$TMP/err"
  run_device production
  check "a production-signed build does not warn" not grep -q "NO PUSH" "$TMP/err"
  run_device development --app-store
  check "an App Store build (re-signed for distribution) does not warn" not grep -q "NO PUSH" "$TMP/err"
  run_device ""
  check "a profile without push warns too" grep -q "NO PUSH NOTIFICATIONS OR INCOMING CALLS" "$TMP/err"
}

# make_binary <path> <exit code>: a small Mach-O with its own UUID, and its dSYM at <path>.dSYM.
make_binary() {
  mkdir -p "$(dirname "$1")"
  printf 'int main(void) { return %s; }\n' "$2" > "$1.c"
  clang -g -o "$1" "$1.c" && dsymutil "$1" -o "$1.dSYM" && rm -f "$1.c"
}

# make_build <dir>: <dir>/Telegram.ipa (an app, an extension, a framework and a framework stub
# without its executable, build 202611031200)
# with the dSYMs Make.py leaves next to it, plus one from another build (Stale.appex.dSYM).
make_build() {
  local dir="$1" bin="$1/bin" app="$1/Payload/Telegram.app"
  mkdir -p "$app/PlugIns/Share.appex" "$app/Frameworks/TelegramUIFramework.framework"
  make_binary "$bin/Telegram" 1 && make_binary "$bin/Share" 2 && make_binary "$bin/TelegramUIFramework" 3 \
    && make_binary "$bin/Stale" 4 || return 1
  cp "$bin/Telegram" "$app/Telegram"
  cp "$bin/Share" "$app/PlugIns/Share.appex/Share"
  cp "$bin/TelegramUIFramework" "$app/Frameworks/TelegramUIFramework.framework/TelegramUIFramework"
  plutil -create xml1 "$app/Info.plist"
  plutil -insert CFBundleExecutable -string Telegram "$app/Info.plist"
  plutil -insert CFBundleVersion -string 202611031200 "$app/Info.plist"
  plutil -create xml1 "$app/PlugIns/Share.appex/Info.plist"
  plutil -insert CFBundleExecutable -string Share "$app/PlugIns/Share.appex/Info.plist"
  plutil -create xml1 "$app/Frameworks/TelegramUIFramework.framework/Info.plist"
  plutil -insert CFBundleExecutable -string TelegramUIFramework "$app/Frameworks/TelegramUIFramework.framework/Info.plist"
  # A static framework's stub (the watch app's TDLibFramework): an Info.plist, no executable.
  mkdir -p "$app/Watch/Watch.app/Frameworks/TDLibFramework.framework"
  plutil -create xml1 "$app/Watch/Watch.app/Frameworks/TDLibFramework.framework/Info.plist"
  plutil -insert CFBundleExecutable -string TDLibFramework "$app/Watch/Watch.app/Frameworks/TDLibFramework.framework/Info.plist"
  (cd "$dir" && zip -qr Telegram.ipa Payload) || return 1
  mv "$bin/Telegram.dSYM" "$dir/Telegram.app.dSYM"
  mv "$bin/Share.dSYM" "$dir/Share.appex.dSYM"
  mv "$bin/TelegramUIFramework.dSYM" "$dir/TelegramUIFramework.framework.dSYM"
  mv "$bin/Stale.dSYM" "$dir/Stale.appex.dSYM"
}

# run_archive_dsyms <build dir>: archive_dsyms on its ipa into $TMP/archive, with mktemp under
# $TMP/tmpdir. Sets STATUS; output in $TMP/out, $TMP/err.
run_archive_dsyms() {
  mkdir -p "$TMP/tmpdir"
  (
    export TG_DSYM_DIR="$TMP/archive" TMPDIR="$TMP/tmpdir"
    # shellcheck source=../tg
    source "$TG"
    archive_dsyms "$1/Telegram.ipa"
  ) > "$TMP/out" 2> "$TMP/err"
  STATUS=$?
}

archived() { [ -f "$TMP/archive/202611031200/$1.zip" ]; }
not_archived() { [ ! -e "$TMP/archive/202611031200/$1.zip" ]; }
tmpdir_empty() { [ -z "$(ls -A "$TMP/tmpdir")" ]; }

test_archive_dsyms() {
  local build="$TMP/build"
  if ! make_build "$build" > "$TMP/fixture.log" 2>&1; then
    echo "FAIL - building the fixture (clang, dsymutil): $(cat "$TMP/fixture.log")"
    failures=$((failures + 1))
    return
  fi

  # An earlier attempt at the same build number left a dSYM this build does not have.
  mkdir -p "$TMP/archive/202611031200"
  echo stale > "$TMP/archive/202611031200/Leftover.appex.dSYM.zip"
  # 25 older builds, oldest first, and a directory that is not a build.
  local i
  for i in $(seq 10 34); do
    mkdir -p "$TMP/archive/2026100100$i"
    echo uuids > "$TMP/archive/2026100100$i/uuids.txt"
    touch -t "2026100100$i" "$TMP/archive/2026100100$i"
  done
  mkdir -p "$TMP/archive/not-a-build"
  touch -t 202601010000 "$TMP/archive/not-a-build"

  run_archive_dsyms "$build"
  check "archive_dsyms succeeds" [ "$STATUS" -eq 0 ]
  check "the app's dSYM is archived" archived Telegram.app.dSYM
  check "the extension's dSYM is archived" archived Share.appex.dSYM
  check "the framework's dSYM is archived" archived TelegramUIFramework.framework.dSYM
  check "a dSYM of no binary in the ipa is not archived" not_archived Stale.appex.dSYM
  check "uuids.txt lists only this build's dSYMs" [ "$(grep -c . "$TMP/archive/202611031200/uuids.txt")" -eq 3 ]
  check "uuids.txt does not list the stale dSYM" not grep -q Stale "$TMP/archive/202611031200/uuids.txt"
  check "the build's folder is cleared first" not_archived Leftover.appex.dSYM
  check "the temporary directory is removed" tmpdir_empty
  local builds
  builds="$(cd "$TMP/archive" && ls -d 2*/ | wc -l | tr -d ' ')"
  check "only the newest 20 builds are kept (found $builds)" [ "$builds" -eq 20 ]
  check "this build is kept" [ -d "$TMP/archive/202611031200" ]
  check "the oldest builds are removed" [ ! -e "$TMP/archive/202610010010" ]
  check "the newest older build is kept" [ -d "$TMP/archive/202610010034" ]
  check "a directory that is not a build is kept" [ -d "$TMP/archive/not-a-build" ]

  # The app's dSYM from another build: refuse, and still clean up.
  rm -rf "$build/Telegram.app.dSYM"; cp -R "$build/Stale.appex.dSYM" "$build/Telegram.app.dSYM"
  run_archive_dsyms "$build"
  check "an app dSYM of another build fails" [ "$STATUS" -ne 0 ]
  check "the temporary directory is removed after a failure" tmpdir_empty
}

not() { ! "$@"; }

test_notes_failure_after_upload
test_upload_failure
test_success
test_device_push_environment
test_archive_dsyms

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
