#!/usr/bin/env bash
# Compile worker for the apple_prebuilt_watchos_application Bazel rule (action 1 of 2).
#
# Builds the tgwatch watch app via xcodebuild (device, Release, UNSIGNED) and zips the
# .app into the rule's intermediate archive. Before xcodebuild it builds tlottie (the Lottie renderer the
# phone uses too, submodules/tlottie/tlottie) as a no_std static library for watchOS and wraps it as
# TLottieCore.xcframework for Packages/TLottieKit (tools/build-tlottie-xcframework.sh: pinned nightly,
# -Zbuild-std; cached under ~/.cache/telegram-ios/watch-tlottie by a hash of its inputs).
#
# It bakes the values that xcodebuild must own — the api credentials and the bundle id
# (PRODUCT_BUNDLE_IDENTIFIER, from which the Info.plist derives
# WKCompanionAppBundleIdentifier via $(PRODUCT_BUNDLE_IDENTIFIER:base)) — and leaves
# the version keys as PLACEHOLDERS for prebuilt_watchos_patch.sh to rewrite. All three
# baked values are stable for a given host configuration, whereas the version changes
# on every build, so keeping the version out of this action is what makes the
# expensive xcodebuild (~1-2 min with warm package checkouts) cacheable across builds.
#
# Args:
#   $1 source_path      Execroot-relative path to the committed in-repo snapshot
#                       (Telegram/WatchApp), which contains tgwatch.xcodeproj.
#   $2 output_zip       Path (declared by Bazel) to write the unsigned .app archive to.
#   $3 api_id           TG_API_ID build setting
#   $4 api_hash         TG_API_HASH build setting
#   $5 watch_bundle_id  PRODUCT_BUNDLE_IDENTIFIER (the watch app id, "<host>.watchkitapp");
#                       empty => keep the project default.
#   $6 tlottie_source   Execroot-relative path to the tlottie crate (submodules/tlottie/tlottie);
#                       empty => the build script's default (relative to the snapshot).
set -euo pipefail

SRC="$1"; OUT_ZIP="$2"; API_ID="${3:-0}"; API_HASH="${4:-placeholder}"; WATCH_BUNDLE_ID="${5:-}"; TLOTTIE_SRC="${6:-}"

if [ ! -e "$SRC/tgwatch.xcodeproj" ]; then
  echo "error: no tgwatch.xcodeproj at $SRC (regenerate it: cd Telegram/WatchApp && xcodegen generate)" >&2
  exit 1
fi

# SwiftPM checkouts live outside the action, shared by every run on this machine: resolving
# into a fresh directory extracts TDLibFramework for all platforms (~1.3 GB) and took ~50 s
# of each uncached build. The packages are pinned exactly (TDLib's archive by checksum), and
# their checkout path does not reach the binary, so sharing the directory cannot change the
# output. Bazel does not pass HOME to actions, so ~ is resolved from the user database
# (TG_WATCH_SPM_CACHE, if set through --action_env, overrides the location).
SPM_CACHE="${TG_WATCH_SPM_CACHE:-$(cd ~ && pwd)/.cache/telegram-ios/watch-spm}"
if [ -z "${TG_WATCH_SPM_LOCKED:-}" ]; then
  # One build at a time uses the shared checkouts (another workspace may be building).
  mkdir -p "$SPM_CACHE"
  export TG_WATCH_SPM_LOCKED=1
  exec /usr/bin/lockf -k -t 3600 "$SPM_CACHE.lock" /bin/bash "$0" "$@"
fi

DD="$(mktemp -d)"
trap 'rm -rf "$DD"' EXIT

# Build from a writable copy so xcodebuild/SwiftPM never write into the source tree (it
# writes the resolved pins into Packages/TDShim/Package.resolved). Without a sandbox $SRC is
# the real directory, so copy only what Telegram/WatchApp/BUILD declares as inputs: local
# SwiftPM builds, user data and the development project would otherwise come along (and
# could change the build without changing the action key).
WORKSRC="$DD/src"
mkdir -p "$WORKSRC"
/usr/bin/rsync -a \
  --exclude '.build/' --exclude '.swiftpm/' --exclude 'xcuserdata/' --exclude 'DerivedData/' \
  --exclude '/BUILD' --exclude '.gitignore' --exclude '/Tests/' \
  --exclude '/project-dev.yml' --exclude '/tgwatch-dev.xcodeproj/' \
  --exclude '/Packages/TLottieKit/Frameworks/' \
  "$SRC/" "$WORKSRC/"

# tlottie for watchOS (arm64_32 + arm64 device, arm64 simulator) as TLottieCore.xcframework, built from the
# same crate the phone links. It must exist before the package resolve below (TLottieKit's binaryTarget path).
# A cache hit is a copy; a miss runs cargo with the pinned nightly (installed on demand, network needed once).
"$SRC/tools/build-tlottie-xcframework.sh" \
  ${TLOTTIE_SRC:+--tlottie "$TLOTTIE_SRC"} \
  --output "$WORKSRC/Packages/TLottieKit/Frameworks" 1>&2

xcodebuild_resolve() {
  xcodebuild -resolvePackageDependencies \
    -project "$WORKSRC/tgwatch.xcodeproj" \
    -scheme "tgwatch Watch App" \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    -quiet 1>&2
}
# A damaged cache (an interrupted extraction) would fail every build: start it over once.
if ! xcodebuild_resolve; then
  echo "warning: resolving watch packages failed; clearing $SPM_CACHE and retrying" >&2
  rm -rf "$SPM_CACHE"
  mkdir -p "$SPM_CACHE"
  xcodebuild_resolve
fi

# MARKETING_VERSION / CURRENT_PROJECT_VERSION are placeholders; the patch action
# overwrites CFBundleShortVersionString / CFBundleVersion afterwards. They only ever
# land in Info.plist (via $(...) substitution), never in the compiled binary, so the
# build output is independent of them. Note the nested TDLibFramework keeps these
# placeholder versions — nothing verifies a nested framework's version against the
# host, only the watch app's own Info.plist, which the patch action fixes up.
xcodebuild \
  -project "$WORKSRC/tgwatch.xcodeproj" \
  -scheme "tgwatch Watch App" \
  -configuration Release \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$SPM_CACHE" \
  -disableAutomaticPackageResolution \
  -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  TG_API_ID="$API_ID" TG_API_HASH="$API_HASH" \
  MARKETING_VERSION=0.0 CURRENT_PROJECT_VERSION=0 \
  ${WATCH_BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER="$WATCH_BUNDLE_ID"} \
  build 1>&2

APP="$(find "$DD/Build/Products" -maxdepth 2 -name 'tgwatch Watch App.app' -type d | head -1)"
if [ -z "$APP" ]; then
  echo "error: built watch .app not found under $DD/Build/Products" >&2
  exit 1
fi

# $OUT_ZIP is execroot-relative; the action's cwd is the execroot, so do NOT cd
# (that would resolve $OUT_ZIP against the DerivedData dir). --keepParent makes the
# archive root the .app itself even when $APP is an absolute path.
rm -f "$OUT_ZIP"
# No extended attributes: ditto would store them as ._ AppleDouble entries (every file
# Xcode writes carries com.apple.provenance), and rules_apple unpacks the archive with
# Python zipfile, so they would land in the bundle as files outside its code seal.
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$OUT_ZIP"
