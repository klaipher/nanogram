#!/bin/bash
set -euo pipefail

MODE="${1:-all}"
OUT="${2:-${TMPDIR:-/tmp}/MediaEditorExportOutput}"
ONLY="${3:-}"
TIMEOUT="${MEDIA_EDITOR_EXPORT_TIMEOUT:-5400}"

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
BAZEL="${MEDIA_EDITOR_EXPORT_BAZEL:-$(ls "$ROOT"/build-input/bazel-*-darwin-arm64 | tail -n 1)}"
TARGET="//submodules/TelegramUI/Components/MediaEditor:MediaEditorExportHarness"
IPA="$ROOT/bazel-bin/submodules/TelegramUI/Components/MediaEditor/MediaEditorExportHarness.ipa"
BUNDLE="org.telegram.MediaEditorExportHarness"
# The simulator OS every test runner uses (build-system/bazel-utils/test_simulator.bzl), so the harness runs on an
# installed runtime.
OS_VERSION="${MEDIA_EDITOR_EXPORT_OS:-$(sed -n 's/^TEST_SIMULATOR_OS = "\(.*\)"$/\1/p' "$ROOT/build-system/bazel-utils/test_simulator.bzl")}"
DEVICE_NAME="MediaEditorExportHarness iPhone 18 Pro $OS_VERSION"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-${OS_VERSION//./-}"

case "$MODE" in
  all|export|benchmark|compositor|entities|composer|photo|vignette) ;;
  *) echo "usage: $0 [all|export|benchmark|compositor|entities|composer|photo|vignette] [host output dir] [scenario id]" >&2; exit 2 ;;
esac

cd "$ROOT"
# The flags `tg test` passes, so the build reuses its outputs and disk cache.
"$BAZEL" build --disk_cache="$HOME/.cache/telegram-ios/bazel-disk-cache" -c dbg --ios_multi_cpus=sim_arm64 \
  --watchos_cpus=arm64_32 --define=buildNumber=10000 --features=swift.use_global_module_cache \
  --@build_bazel_rules_swift//swift:copt=-j --@build_bazel_rules_swift//swift:copt=8 "$TARGET"

UDID="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["name"] == name and device.get("isAvailable", True):
            print(device["udid"])
            sys.exit(0)
' "$DEVICE_NAME" || true)"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

STAGE="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGE"
  if [[ "${MEDIA_EDITOR_EXPORT_KEEP_BOOTED:-0}" != "1" ]]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
unzip -q -o "$IPA" -d "$STAGE"
APP="$STAGE/Payload/MediaEditorExportHarness.app"
[[ -x "$APP/MediaEditorExportHarness" ]] || { echo "no harness bundle in $IPA" >&2; exit 1; }

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
RESULT="$DATA/tmp/MediaEditorExportTests"
rm -rf "$RESULT"
LAUNCH_ARGS=(--mode "$MODE")
[[ -n "$ONLY" ]] && LAUNCH_ARGS+=(--only "$ONLY")
[[ -n "${MEDIA_EDITOR_EXPORT_RUNS:-}" ]] && LAUNCH_ARGS+=(--runs "$MEDIA_EDITOR_EXPORT_RUNS")
xcrun simctl launch "$UDID" "$BUNDLE" "${LAUNCH_ARGS[@]}" >/dev/null
echo "harness running on $UDID ($DEVICE_NAME), mode $MODE, results in $RESULT"

START=$(date +%s)
while [[ ! -f "$RESULT/status.txt" ]]; do
  if (( $(date +%s) - START > TIMEOUT )); then
    echo "timed out after ${TIMEOUT}s" >&2
    break
  fi
  SERVICES="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null || true)"
  if [[ "$SERVICES" != *"UIKitApplication:$BUNDLE"* ]]; then
    sleep 2
    [[ -f "$RESULT/status.txt" ]] || { echo "harness exited without a status file (crash?)" >&2; break; }
  fi
  sleep 5
done

rm -rf "$OUT"
mkdir -p "$OUT"
[[ -d "$RESULT" ]] && cp -R "$RESULT/." "$OUT/"
echo "results copied to $OUT"
[[ -f "$OUT/compositor.txt" ]] && cat "$OUT/compositor.txt"
[[ -f "$OUT/entities.txt" ]] && cat "$OUT/entities.txt"
[[ -f "$OUT/composer.txt" ]] && cat "$OUT/composer.txt"
[[ -f "$OUT/photo.txt" ]] && cat "$OUT/photo.txt"
[[ -f "$OUT/vignette.txt" ]] && cat "$OUT/vignette.txt"
[[ -f "$OUT/benchmark.md" ]] && cat "$OUT/benchmark.md"
if [[ -s "$OUT/failures.txt" ]]; then
  echo "failures:"
  cat "$OUT/failures.txt"
fi
[[ -f "$OUT/status.txt" ]] || exit 1
read -r _ FAILURES < "$OUT/status.txt"
[[ "$FAILURES" == "0" ]]
