#!/usr/bin/env bash
# Builds tlottie (the same source the phone links: submodules/tlottie/tlottie) as a no_std static
# library for the Apple Watch and wraps it as TLottieCore.xcframework for Packages/TLottieKit.
#
#   tools/build-tlottie-xcframework.sh [--tlottie DIR] [--output DIR] [--macos] [--force]
#
#   --tlottie DIR  the tlottie crate (default: <repo>/submodules/tlottie/tlottie)
#   --output DIR   where TLottieCore.xcframework is written (default: Packages/TLottieKit/Frameworks)
#   --macos        also add an aarch64-apple-darwin slice, so `swift test` of Packages/TLottieKit
#                  runs on the Mac (off for the embedded app build)
#   --force        ignore the cache
#
# Targets (Rust tier 3, hence a pinned nightly and -Zbuild-std=core,alloc):
#   arm64_32-apple-watchos     device, Series 4-8 / SE / Ultra-era ILP32 slice
#   aarch64-apple-watchos      device, 64-bit slice
#   aarch64-apple-watchos-sim  Apple Silicon watchOS simulator
# The two device libraries are merged with lipo into one `watchos` slice.
#
# Build flags are the ones Android uses for its tlottie archive (TMessagesProj/jni/prebuild/build_tlottie.sh):
# --no-default-features --features cpu,no-std,c-api, profile release-nostd (panic=abort, fat LTO). The crate's
# own no_std runtime (src/no_std_runtime.rs) provides the global allocator (forwards to the C malloc/free
# that the app links) and an aborting panic handler, so the archive links into a Swift app with no Rust std.
#
# Caching: the result is stored under ~/.cache/telegram-ios/watch-tlottie/<key>, where <key> hashes the
# tlottie sources (Cargo.toml, Cargo.lock, src/, include/), this script, the toolchain pin and the deployment
# target. An unchanged input is a copy, not a build. TG_WATCH_TLOTTIE_CACHE overrides the directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_DIR="$(cd "$HERE/.." && pwd)"
TLOTTIE_DIR="$WATCH_DIR/../../submodules/tlottie/tlottie"
OUTPUT_DIR="$WATCH_DIR/Packages/TLottieKit/Frameworks"
WITH_MACOS=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tlottie) TLOTTIE_DIR="$2"; shift ;;
    --output) OUTPUT_DIR="$2"; shift ;;
    --macos) WITH_MACOS=1 ;;
    --force) FORCE=1 ;;
    *) echo "usage: $0 [--tlottie DIR] [--output DIR] [--macos] [--force]" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$TLOTTIE_DIR/Cargo.toml" ]; then
  echo "error: tlottie sources are missing at $TLOTTIE_DIR" >&2
  echo "       git submodule update --init --depth 1 submodules/tlottie/tlottie" >&2
  exit 1
fi
TLOTTIE_DIR="$(cd "$TLOTTIE_DIR" && pwd)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

TOOLCHAIN="$(grep -v '^#' "$HERE/tlottie-toolchain.txt" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
# Same as the Swift packages (.watchOS(.v10)); set explicitly because rustc's default is much older.
DEPLOYMENT_TARGET="${WATCHOS_DEPLOYMENT_TARGET:-10.0}"
MACOS_DEPLOYMENT_TARGET="${TLOTTIE_MACOS_DEPLOYMENT_TARGET:-14.0}"
TARGETS="arm64_32-apple-watchos aarch64-apple-watchos aarch64-apple-watchos-sim"
[ "$WITH_MACOS" = 1 ] && TARGETS="$TARGETS aarch64-apple-darwin"

# Bazel does not pass HOME to actions: resolve it from the user database.
USER_HOME="$(cd ~ && pwd)"
CACHE_ROOT="${TG_WATCH_TLOTTIE_CACHE:-$USER_HOME/.cache/telegram-ios/watch-tlottie}"

hash_inputs() {
  {
    echo "toolchain=$TOOLCHAIN watchos=$DEPLOYMENT_TARGET macos=$MACOS_DEPLOYMENT_TARGET targets=$TARGETS"
    (cd "$TLOTTIE_DIR" && find Cargo.toml Cargo.lock src include -type f | LC_ALL=C sort | xargs /usr/bin/shasum -a 256)
    /usr/bin/shasum -a 256 "${BASH_SOURCE[0]}" "$HERE/tlottie-toolchain.txt"
  } | /usr/bin/shasum -a 256 | cut -c1-32
}
KEY="$(hash_inputs)"
ENTRY="$CACHE_ROOT/$KEY"

install_result() {
  rm -rf "$OUTPUT_DIR/TLottieCore.xcframework"
  /usr/bin/ditto "$ENTRY/TLottieCore.xcframework" "$OUTPUT_DIR/TLottieCore.xcframework"
  echo "TLottieCore.xcframework ready in $OUTPUT_DIR (cache key $KEY)"
}

if [ "$FORCE" = 0 ] && [ -d "$ENTRY/TLottieCore.xcframework" ]; then
  install_result
  exit 0
fi

# --- toolchain -----------------------------------------------------------------------------------------
# Only rustup is needed (the script runs `rustup run $TOOLCHAIN cargo`, never a bare cargo). Bazel actions may not get
# the user's PATH, so look in the usual places: PATH, Homebrew (Apple Silicon and Intel), ~/.cargo/bin.
if ! command -v rustup >/dev/null 2>&1; then
  for d in /opt/homebrew/bin /usr/local/bin "$USER_HOME/.cargo/bin"; do
    if [ -x "$d/rustup" ]; then export PATH="$d:$PATH"; break; fi
  done
fi
command -v rustup >/dev/null 2>&1 || {
  echo "error: rustup not found (needed for the pinned nightly $TOOLCHAIN). Install: brew install rustup  or" >&2
  echo "       curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal" >&2
  exit 1
}
if ! rustup run "$TOOLCHAIN" rustc --version >/dev/null 2>&1 \
   || ! { COMPONENTS="$(rustup component list --toolchain "$TOOLCHAIN" --installed 2>/dev/null || true)"; printf '%s\n' "$COMPONENTS" | grep '^rust-src' >/dev/null; }; then
  echo "Installing $TOOLCHAIN with rust-src (needed for -Zbuild-std)"
  rustup toolchain install "$TOOLCHAIN" --profile minimal --component rust-src
fi
RUSTC="$(rustup which --toolchain "$TOOLCHAIN" rustc)"
export RUSTC
SYSROOT="$("$RUSTC" --print sysroot)"

# Identical virtual paths on every machine, no per-machine flags (same approach as Android's script).
unset RUSTFLAGS MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
mkdir -p "$CACHE_ROOT"
WORK="$(mktemp -d "$CACHE_ROOT/.work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$TLOTTIE_DIR=/tlottie$(printf '\037')--remap-path-prefix=$WORK=/tlottie-target$(printf '\037')--remap-path-prefix=$SYSROOT=/rust-sysroot$(printf '\037')-Cdebuginfo=0"
export CARGO_ENCODED_RUSTFLAGS
export CARGO_INCREMENTAL=0 SOURCE_DATE_EPOCH=1 TZ=UTC LC_ALL=C
export CARGO_TARGET_DIR="$WORK/target"

echo "Building tlottie for the Apple Watch"
echo "  source:    $TLOTTIE_DIR"
echo "  rustc:     $("$RUSTC" --version)"
echo "  targets:   $TARGETS"

# Fetch the crate's two dependencies (hashbrown, and foldhash through it) once, honouring Cargo.lock.
(cd "$TLOTTIE_DIR" && rustup run "$TOOLCHAIN" cargo fetch --locked --manifest-path Cargo.toml >/dev/null)

for target in $TARGETS; do
  echo "== $target"
  case "$target" in
    *-watchos*) dt_env=(WATCHOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET") ;;
    *-darwin) dt_env=(MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET") ;;
  esac
  (cd "$TLOTTIE_DIR" && env "${dt_env[@]}" rustup run "$TOOLCHAIN" cargo rustc \
    --manifest-path Cargo.toml \
    --locked \
    --profile release-nostd \
    --target "$target" \
    --lib \
    --no-default-features \
    --features cpu,no-std,c-api \
    --crate-type staticlib \
    -Zbuild-std=core,alloc \
    -- -C metadata=tlottie-staticlib) 1>&2
  lib="$CARGO_TARGET_DIR/$target/release-nostd/libtlottie.a"
  [ -f "$lib" ] || { echo "error: cargo did not emit $lib" >&2; exit 1; }
  # The C entry points must be there (names from include/tlottie.h).
  # Read all of nm's output (grep -q would exit early and nm would die of SIGPIPE under pipefail).
  NM_OUT="$(/usr/bin/nm -gU "$lib" 2>/dev/null || true)"
  printf '%s\n' "$NM_OUT" | grep ' _tlottie_new_with_options$' >/dev/null \
    || { echo "error: $lib does not export tlottie_new_with_options" >&2; exit 1; }
done

# --- xcframework -----------------------------------------------------------------------------------------
LIBS="$WORK/libs"
mkdir -p "$LIBS/watchos" "$LIBS/watchos-simulator" "$LIBS/macos"
t() { echo "$CARGO_TARGET_DIR/$1/release-nostd/libtlottie.a"; }
/usr/bin/lipo -create "$(t arm64_32-apple-watchos)" "$(t aarch64-apple-watchos)" -output "$LIBS/watchos/libtlottie.a"
cp "$(t aarch64-apple-watchos-sim)" "$LIBS/watchos-simulator/libtlottie.a"

HEADERS="$WORK/Headers"
mkdir -p "$HEADERS"
cp "$TLOTTIE_DIR/include/tlottie.h" "$HEADERS/tlottie.h"
cat > "$HEADERS/module.modulemap" <<'MAP'
module TLottieCore {
    header "tlottie.h"
    export *
}
MAP

XC_ARGS=(-library "$LIBS/watchos/libtlottie.a" -headers "$HEADERS"
         -library "$LIBS/watchos-simulator/libtlottie.a" -headers "$HEADERS")
if [ "$WITH_MACOS" = 1 ]; then
  cp "$(t aarch64-apple-darwin)" "$LIBS/macos/libtlottie.a"
  XC_ARGS+=(-library "$LIBS/macos/libtlottie.a" -headers "$HEADERS")
fi
mkdir -p "$WORK/out"
xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "$WORK/out/TLottieCore.xcframework" 1>&2

# Publish into the cache atomically, then into the package.
mkdir -p "$ENTRY"
rm -rf "$ENTRY/TLottieCore.xcframework"
mv "$WORK/out/TLottieCore.xcframework" "$ENTRY/TLottieCore.xcframework"
install_result
