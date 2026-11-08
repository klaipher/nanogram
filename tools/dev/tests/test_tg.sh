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
        *device_signing.py\ testflight*) echo upload >> "$TMP/calls"; echo "$*" > "$TMP/upload_args"; return "$upload_status" ;;
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

# tf_notes.py exits 4 when App Store Connect rejected the build: no notes command can help.
test_build_rejected_after_upload() {
  run_testflight 0 4
  check "a rejected build exits 4" [ "$STATUS" -eq 4 ]
  check "it says to upload a new build" grep -q "build rejected by Apple; upload a new build" "$TMP/err"
  check "it does not offer the notes command" not grep -q "notes not set" "$TMP/err"
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
  check "the build's commit is recorded next to its dSYMs" grep -q "^commit [0-9a-f]\{40\}$" "$TMP/dsyms/202611031200/BUILD-INFO.txt"
  check "the build number is recorded" grep -q "^build 202611031200$" "$TMP/dsyms/202611031200/BUILD-INFO.txt"
  check "the upload requires Enhanced Security by default" not grep -q -- "--enhanced-security" "$TMP/upload_args"
  TG_TF_ENHANCED_SECURITY=0 run_testflight 0 0
  check "the opt-out reaches the re-sign and upload step" grep -q -- "--enhanced-security off" "$TMP/upload_args"
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
    make_py() { echo "$*" > "$TMP/make_args"; }
    archive_dsyms() { echo "$1" >> "$TMP/archived_ipa"; return "${ARCHIVE_STATUS:-0}"; }
    profile_aps_environment() { echo "$profile_aps"; }
    profile_has_enhanced_security() { [ "${ES_PROFILES:-all}" = "all" ] || [ "$(basename "$1")" != "${ES_PROFILES}.mobileprovision" ]; }
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

# make_build <dir>: <dir>/Telegram.ipa holding Nanogram.app (an app, an extension, a framework and a framework stub
# without its executable, build 202611031200)
# with the dSYMs Make.py leaves next to it, plus one from another build (Stale.appex.dSYM).
make_build() {
  local dir="$1" bin="$1/bin" app="$1/Payload/Nanogram.app"
  mkdir -p "$app/PlugIns/Share.appex" "$app/Frameworks/TelegramUIFramework.framework"
  make_binary "$bin/Nanogram" 1 && make_binary "$bin/Share" 2 && make_binary "$bin/TelegramUIFramework" 3 \
    && make_binary "$bin/Stale" 4 || return 1
  cp "$bin/Nanogram" "$app/Nanogram"
  cp "$bin/Share" "$app/PlugIns/Share.appex/Share"
  cp "$bin/TelegramUIFramework" "$app/Frameworks/TelegramUIFramework.framework/TelegramUIFramework"
  plutil -create xml1 "$app/Info.plist"
  plutil -insert CFBundleExecutable -string Nanogram "$app/Info.plist"
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
  mv "$bin/Nanogram.dSYM" "$dir/Telegram.app.dSYM"
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

  TG_DSYM_KEEP=20 run_archive_dsyms "$build"
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

  # Ranked by build number, not by when a folder was last touched: touch the oldest builds last.
  rm -rf "$TMP/archive"
  mkdir -p "$TMP/archive"
  for i in $(seq 10 34); do
    mkdir -p "$TMP/archive/2026100100$i"
    echo uuids > "$TMP/archive/2026100100$i/uuids.txt"
    touch -t "2026110300$((70 - i))" "$TMP/archive/2026100100$i"
  done
  # A newer build number than this one (built earlier on another branch) and a folder with no uuids.txt.
  mkdir -p "$TMP/archive/202612010000" "$TMP/archive/202612020000"
  echo uuids > "$TMP/archive/202612010000/uuids.txt"
  TG_DSYM_KEEP=20 run_archive_dsyms "$build"
  check "archive_dsyms succeeds again" [ "$STATUS" -eq 0 ]
  check "the builds with the highest numbers are kept" [ -d "$TMP/archive/202610010034" ]
  check "the lowest build numbers are removed, however recently touched" [ ! -e "$TMP/archive/202610010015" ]
  check "the build just archived is kept" [ -d "$TMP/archive/202611031200" ]
  check "a folder without uuids.txt is ignored" [ -d "$TMP/archive/202612020000" ]
  builds="$(cd "$TMP/archive" && ls -d 2*/ | wc -l | tr -d ' ')"
  check "20 builds plus the ignored folder remain (found $builds)" [ "$builds" -eq 21 ]

  # The default and TG_DSYM_KEEP=0 keep every build's dSYMs forever.
  run_archive_dsyms "$build"
  check "archive_dsyms with the default keep succeeds" [ "$STATUS" -eq 0 ]
  check "the default keeps the build just archived" [ -d "$TMP/archive/202611031200" ]
  check "the default removes nothing" [ -d "$TMP/archive/202612010000" ]
  TG_DSYM_KEEP=0 run_archive_dsyms "$build"
  check "TG_DSYM_KEEP=0 removes nothing" [ -d "$TMP/archive/202610010034" ]

  # The app's dSYM from another build: refuse, and still clean up.
  rm -rf "$build/Telegram.app.dSYM"; cp -R "$build/Stale.appex.dSYM" "$build/Telegram.app.dSYM"
  run_archive_dsyms "$build"
  check "an app dSYM of another build fails" [ "$STATUS" -ne 0 ]
  check "the temporary directory is removed after a failure" tmpdir_empty
}

not() { ! "$@"; }

# Every tg device build keeps its dSYMs, keyed by build number, like tg testflight does: a Time
# Profiler recording of a device build is anonymous without them. tg testflight archives them itself.
test_device_archives_dsyms() {
  rm -f "$TMP/archived_ipa"
  run_device production
  check "a device build archives its dSYMs" grep -q "bazel-bin/Telegram/Telegram.ipa$" "$TMP/archived_ipa"
  rm -f "$TMP/archived_ipa"
  run_device production --app-store
  check "an App Store build leaves the archiving to tg testflight" [ ! -e "$TMP/archived_ipa" ]
  # A device build without dSYMs is still a usable build: warn, do not fail, and install.
  ARCHIVE_STATUS=1 run_device production
  check "a failed dSYM archive does not fail the device build" [ "$STATUS" -eq 0 ]
  check "it warns that the build has no archived dSYMs" grep -q "dSYMs were not archived" "$TMP/err"
}

# Enhanced Security: a TestFlight build gets it only when the app, NotificationService and Share profiles
# grant it; otherwise it stops before building. TG_TF_ENHANCED_SECURITY=0 ships without it on purpose.
test_enhanced_security_testflight() {
  run_device production --app-store
  check "a TestFlight build with all three profiles builds with Enhanced Security" grep -q -- "--//Telegram:enhancedSecurity" "$TMP/make_args"
  ES_PROFILES=Share run_device production --app-store
  check "a TestFlight build stops when the Share profile lacks it" [ "$STATUS" -ne 0 ]
  check "it names the profile" grep -q "profiles of Share do not grant it" "$TMP/err"
  ES_PROFILES=Telegram TG_TF_ENHANCED_SECURITY=0 run_device production --app-store
  check "the opt-out builds without it" [ "$STATUS" -eq 0 ]
  check "the opt-out passes no enhancedSecurity flag" not grep -q -- "enhancedSecurity" "$TMP/make_args"
  ES_PROFILES=Share run_device production
  check "a development build with a missing profile still builds, without it" [ "$STATUS" -eq 0 ]
  check "it says it stays off" grep -q "Enhanced Security stays off" "$TMP/err"
}

# archive_dsyms names the TelegramUI UUID, the one a trace needs to match.
test_archive_prints_telegramui_uuid() {
  local build="$TMP/build-uuid" uuid
  make_build "$build" > "$TMP/fixture.log" 2>&1 || return 0
  rm -rf "$TMP/archive"
  run_archive_dsyms "$build"
  uuid="$(dwarfdump --uuid "$build/TelegramUIFramework.framework.dSYM" | awk '{ print $2 }')"
  check "archive_dsyms prints the TelegramUI UUID" grep -q "TelegramUI UUID $uuid" "$TMP/out"
}

test_notes_failure_after_upload
test_build_rejected_after_upload
test_upload_failure
test_success
test_device_push_environment
test_enhanced_security_testflight
test_archive_dsyms
test_device_archives_dsyms
test_archive_prints_telegramui_uuid

# record_build_info with a long Unreleased section and a commit on many remote branches: under pipefail a
# pipeline whose reader stops early (head -1, grep -q) kills the writer with SIGPIPE (141), and set -e then stopped
# tg testflight after the build and before the upload (2026-11-06, build 202611060158).
mkdir -p "$TMP/bigrepo"
git -C "$TMP/bigrepo" init -q
{ echo "# Changelog"; echo; echo "## Unreleased"; echo; for i in $(seq 1 30000); do echo "- entry $i with enough text to fill the pipe buffer"; done; echo; echo "## 1.0 (1)"; } > "$TMP/bigrepo/CHANGELOG.md"
git -C "$TMP/bigrepo" add CHANGELOG.md
git -C "$TMP/bigrepo" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$TMP/bigdsyms"
(
  # shellcheck source=../tg
  source "$TG"
  ROOT="$TMP/bigrepo"
  record_build_info "$TMP/bigdsyms" 7 2> "$TMP/big_err"
)
big_status=$?
check "record_build_info survives a long Unreleased section (no SIGPIPE exit)" test "$big_status" -eq 0
check "the long Unreleased section is still reported" grep -q "Unreleased entries" "$TMP/big_err"
check "BUILD-INFO is written with a long Unreleased section" grep -q "^build 7$" "$TMP/bigdsyms/BUILD-INFO.txt"

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
