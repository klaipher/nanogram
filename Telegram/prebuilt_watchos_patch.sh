#!/usr/bin/env bash
# Patch + sign worker for the apple_prebuilt_watchos_application Bazel rule (action 2 of 2).
#
# Takes the unsigned, placeholder-version watch .app archive produced by
# prebuilt_watchos_compile.sh, rewrites the two per-build Info.plist version keys
# (CFBundleShortVersionString, CFBundleVersion) — neither of which affects the compiled
# binary — then, if a provisioning profile is supplied, codesigns the app and its nested
# frameworks and its widget extension (WatchWidgetExtension.appex) with their provisioning profiles and a
# matching identity, and finally zips the .app into the rule's output archive. Without a profile the code is signed
# ad hoc with the App Group entitlements from the source tree, which an App Store export keeps when it re-signs.
#
# Only the version is patched here. The api credentials and the bundle id are baked by
# xcodebuild in the compile action (the Info.plist derives WKCompanionAppBundleIdentifier
# from PRODUCT_BUNDLE_IDENTIFIER via $(...:base), so there is no bundle-id plist
# mutation) — they are stable per host configuration, so they can sit in the cacheable
# action. The version is not: it changes on every build, and keeping it out of the
# compile is what lets Bazel reuse the (expensive, ~4-min) xcodebuild result.
#
# The signing inputs — the absolute provisioning-profile path and the keychain identity —
# are machine-specific, which is the other reason this step is a separate action: it is
# marked local + no-remote so its results are never shared across machines.
#
# The host ios_application embeds this archive under Watch/ and re-seals the host;
# it does NOT re-sign the watch app, so the watch signing must happen here.
#
# Args:
#   $1 input_zip     Compiled (unsigned, placeholder-version) .app archive from action 1
#   $2 output_zip    Path (declared by Bazel) to write the final .app archive to
#   $3 identity      Codesigning identity (SHA1 hash); empty => derived from $4's cert
#   $4 profile       Path to the watchkitapp .mobileprovision; empty => unsigned build
#   $5 infoplist_out Path (declared by Bazel) to copy the patched Info.plist to
#   $6 versions_json versions.json (key 'app' => CFBundleShortVersionString)
#   $7 build_number  CFBundleVersion
#   $8 widget_profile  Path to the widget extension .mobileprovision (<watch app id>.widget);
#                      required whenever $4 is set
#   $9 app_entitlements     WatchApp.entitlements (ad-hoc signing, when $4 is empty)
#   $10 widget_entitlements WatchWidget.entitlements (same)
set -euo pipefail

IN_ZIP="$1"; OUT_ZIP="$2"; IDENTITY="${3:-}"; PROFILE="${4:-}"; INFOPLIST_OUT="${5:-}"; VERSIONS_JSON="${6:-}"; BUILD_NUMBER="${7:-1}"
WIDGET_PROFILE="${8:-}"; APP_ENTITLEMENTS="${9:-}"; WIDGET_ENTITLEMENTS="${10:-}"
APPEX_REL="PlugIns/WatchWidgetExtension.appex"
GROUP_KEY="com.apple.security.application-groups"
SIGNING_FIX="run: python3 tools/dev/device_signing.py profiles (registers the App Group group.org.klaipher.Nanogram.watch and creates the WatchApp and WatchWidget profiles in ~/.config/telegram-ios/codesigning/profiles)"

# Match the host app's version (rules_apple requires the embedded watch app's
# CFBundleShortVersionString/CFBundleVersion to equal the parent's).
MARKETING_VERSION="0.1"
if [ -n "$VERSIONS_JSON" ]; then
  MARKETING_VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['app'])" "$VERSIONS_JSON")"
fi

DD="$(mktemp -d)"
trap 'rm -rf "$DD"' EXIT

/usr/bin/ditto -x -k "$IN_ZIP" "$DD"
APP="$(find "$DD" -maxdepth 2 -name 'tgwatch Watch App.app' -type d | head -1)"
if [ -z "$APP" ]; then
  echo "error: compiled watch .app not found inside $IN_ZIP" >&2
  exit 1
fi

# Overwrite the placeholder versions baked in at compile time. Both keys already exist
# in the compiled (binary-format) Info.plist, so PlistBuddy Set preserves their (string)
# type — matching what $(...) substitution produced.
PLIST="$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
# PlistBuddy writes XML back, but xcodebuild emitted a binary plist for Release. Restore
# the binary encoding so the shipped bundle stays byte-shaped like a plain Xcode build
# (both encodings are legal, but there is no reason for the split to change this).
/usr/bin/plutil -convert binary1 "$PLIST"

# The widget extension's versions must match the watch app's too.
APPEX="$APP/$APPEX_REL"
if [ ! -d "$APPEX" ]; then
  echo "error: the compiled watch app has no $APPEX_REL" >&2
  exit 1
fi
APPEX_PLIST="$APPEX/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APPEX_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX_PLIST"
/usr/bin/plutil -convert binary1 "$APPEX_PLIST"

# Expose the patched watch Info.plist (the host reads it to verify the companion
# bundle-id linkage and the child version). Codesigning does not alter Info.plist
# content, so capture it now.
if [ -n "$INFOPLIST_OUT" ]; then
  cp "$PLIST" "$INFOPLIST_OUT"
fi

if [ -n "$IDENTITY" ] && [ -z "$PROFILE" ]; then
  echo "error: a signing identity was given but no provisioning profile (set --watchProvisioningProfile=<abs path>)" >&2
  exit 1
fi

# Sign the watch app whenever a provisioning profile is available. When no explicit
# identity is supplied, derive it from the certificate embedded in that profile, so
# the watch app is signed with the same distribution/development identity as the host
# app (resolved from the shared codesigning material) — required for App Store, where
# every nested bundle must carry the Apple submission certificate. Without a profile
# the app is left unsigned (the host does not re-sign it).
if [ -n "$PROFILE" ] && [ -z "$WIDGET_PROFILE" ]; then
  echo "error: the watch app is signed with a profile but the widget extension has none (--watchWidgetProvisioningProfile; tools/dev/tg passes ~/.config/telegram-ios/codesigning/profiles/WatchWidget.mobileprovision when it exists). To create it, $SIGNING_FIX" >&2
  exit 1
fi
if [ -n "$WIDGET_PROFILE" ] && [ -z "$PROFILE" ]; then
  echo "error: --watchWidgetProvisioningProfile is set without --watchProvisioningProfile" >&2
  exit 1
fi

# Fails when a profile does not grant the App Group (a profile made before the group existed): the widget would
# build and install but never see the app's summary.
require_group() {
  local profile="$1" what="$2" plist
  plist="$(mktemp)"
  security cms -D -i "$profile" > "$plist"
  if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:$GROUP_KEY" "$plist" 2>/dev/null | grep -q "group.org.klaipher.Nanogram.watch"; then
    rm -f "$plist"
    echo "error: the $what provisioning profile ($profile) does not grant the App Group group.org.klaipher.Nanogram.watch. To fix it, $SIGNING_FIX" >&2
    exit 1
  fi
  rm -f "$plist"
}

if [ -n "$PROFILE" ]; then
  require_group "$PROFILE" "watch app"
  require_group "$WIDGET_PROFILE" "watch widget"
  cp "$PROFILE" "$APP/embedded.mobileprovision"
  ENT="$(mktemp)"
  trap 'rm -rf "$DD" "$ENT" "$ENT.plist"' EXIT
  security cms -D -i "$APP/embedded.mobileprovision" > "$ENT.plist"
  if ! /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$ENT.plist" > "$ENT" 2>/dev/null; then
    echo "error: provisioning profile has no Entitlements key: $PROFILE" >&2
    exit 1
  fi

  if [ -z "$IDENTITY" ]; then
    # The identity is the SHA-1 of the profile's first embedded certificate, which is
    # exactly how codesign / the keychain reference it. The matching private key must
    # be in the keychain (it is: the same cert signs the host app).
    IDENTITY="$(python3 -c "import sys,plistlib,subprocess,hashlib; d=plistlib.loads(subprocess.run(['security','cms','-D','-i',sys.argv[1]],capture_output=True).stdout); print(hashlib.sha1(d['DeveloperCertificates'][0]).hexdigest().upper())" "$APP/embedded.mobileprovision")"
    if [ -z "$IDENTITY" ]; then
      echo "error: could not derive a signing identity from the provisioning profile (no DeveloperCertificates): $PROFILE" >&2
      exit 1
    fi
    echo "note: signing watch app with identity $IDENTITY derived from $(basename "$PROFILE")" >&2
  fi

  # Distribution profiles (App Store / Ad Hoc) set get-task-allow=false and require a
  # secure timestamp; development builds set it true and can skip the timestamp (faster,
  # no round-trip to Apple's timestamp service).
  TS_FLAG="--timestamp"
  if /usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$ENT" 2>/dev/null | grep -qi '^true$'; then
    TS_FLAG="--timestamp=none"
  fi

  # Sign inside-out: nested frameworks, the widget extension (its own profile and entitlements), then the app bundle.
  if [ -d "$APP/Frameworks" ]; then
    for fw in "$APP/Frameworks/"*; do
      [ -e "$fw" ] || continue
      codesign --force "$TS_FLAG" --sign "$IDENTITY" "$fw" 1>&2
    done
  fi
  WENT="$(mktemp)"
  trap 'rm -rf "$DD" "$ENT" "$ENT.plist" "$WENT" "$WENT.plist"' EXIT
  cp "$WIDGET_PROFILE" "$APPEX/embedded.mobileprovision"
  security cms -D -i "$APPEX/embedded.mobileprovision" > "$WENT.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WENT.plist" > "$WENT"
  codesign --force "$TS_FLAG" --sign "$IDENTITY" --entitlements "$WENT" "$APPEX" 1>&2
  codesign --force "$TS_FLAG" --sign "$IDENTITY" --entitlements "$ENT" "$APP" 1>&2
  codesign --verify --deep --strict "$APP" 1>&2
else
  # No profiles: sign ad hoc with the App Group entitlements so that an App Store export (Xcode re-signs the watch app
  # and the widget with distribution profiles) keeps the group. Not installable as it is.
  if [ -z "$APP_ENTITLEMENTS" ] || [ -z "$WIDGET_ENTITLEMENTS" ]; then
    echo "error: no entitlements files were passed for the ad-hoc signature" >&2
    exit 1
  fi
  if [ -d "$APP/Frameworks" ]; then
    for fw in "$APP/Frameworks/"*; do
      [ -e "$fw" ] || continue
      codesign --force --timestamp=none --sign - "$fw" 1>&2
    done
  fi
  codesign --force --timestamp=none --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$APPEX" 1>&2
  codesign --force --timestamp=none --sign - --entitlements "$APP_ENTITLEMENTS" "$APP" 1>&2
  echo "warning: no watch provisioning profile supplied; the watch app and its widget are signed ad hoc and are only good for an App Store export (tg testflight re-signs them). To sign them for a device, $SIGNING_FIX" >&2
fi

# $OUT_ZIP is execroot-relative; the action's cwd is the execroot, so do NOT cd
# (that would resolve $OUT_ZIP against the temp dir). --keepParent makes the archive
# root the .app itself even when $APP is an absolute path.
rm -f "$OUT_ZIP"
# No extended attributes: ditto would store them as ._ AppleDouble entries (every file
# Xcode writes carries com.apple.provenance), and rules_apple unpacks the archive with
# Python zipfile, so they would land in the bundle as files outside its code seal.
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$OUT_ZIP"
