#! /bin/sh

set -ex

ARCH="$1"
SOURCE_DIR=$(echo "$(cd "$(dirname "$2")"; pwd -P)/$(basename "$2")")
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")

MINIOSVERSION="26.0"

OPT_CFLAGS="-O2 -g"

# The release tarball ships package_version; a git checkout would ask git, which fails in a copied submodule.
rm -rf "$SOURCE_DIR/.git"
echo 'PACKAGE_VERSION="1.6.1"' > "$SOURCE_DIR/package_version"

# The shared option list (nanogram-deps shared/opus/opus-options.sh, copied next to this script by the genrule). OSCE is
# its own variable so a consumer of the shared source can stay stock.
. "$(cd "$(dirname "$0")" && pwd -P)/opus-options.sh"
COMMON_ARGS="$OPUS_COMMON_ARGS $OPUS_OSCE_ARGS"
# Appended to CMAKE_C_FLAGS_RELEASE, never CMAKE_C_FLAGS: on iOS that would replace the target flags in CFLAGS.
RELEASE_CFLAGS="${OPT_CFLAGS} ${OPUS_OSCE_C_FLAGS}"

mkdir -p "$BUILD_DIR/build"
cd "$BUILD_DIR/build"

if [ "${ARCH}" = "linux_x86_64" ] || [ "${ARCH}" = "linux_arm64" ]; then
  cmake -G Ninja $COMMON_ARGS -DCMAKE_C_FLAGS_RELEASE="${RELEASE_CFLAGS}" "$SOURCE_DIR"
  ninja
  exit 0
elif [ "${ARCH}" = "x86_64" ]; then
  PLATFORM="iphonesimulator"
  PROCESSOR="AMD64"
  TARGET_FLAGS="-arch x86_64 -miphoneos-version-min=${MINIOSVERSION}"
elif [ "${ARCH}" = "sim_arm64" ]; then
  PLATFORM="iphonesimulator"
  PROCESSOR="aarch64"
  TARGET_FLAGS="-arch arm64 --target=arm64-apple-ios${MINIOSVERSION}-simulator"
elif [ "${ARCH}" = "macos_arm64" ]; then
  PLATFORM="macosx"
  PROCESSOR="aarch64"
  TARGET_FLAGS="-arch arm64 --target=arm64-apple-macosx14.0"
elif [ "${ARCH}" = "arm64" ]; then
  PLATFORM="iphoneos"
  PROCESSOR="aarch64"
  TARGET_FLAGS="-arch arm64 -miphoneos-version-min=${MINIOSVERSION}"
else
  echo "Unsupported architecture ${ARCH}"
  exit 1
fi

SDK_PATH="$(xcrun --sdk $PLATFORM --show-sdk-path 2>/dev/null)"

export CFLAGS="${TARGET_FLAGS} -fPIE -funwind-tables"

{
  echo "set(CMAKE_SYSTEM_NAME Darwin)"
  echo "set(CMAKE_SYSTEM_PROCESSOR ${PROCESSOR})"
  echo "set(CMAKE_C_COMPILER $(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang)"
} > toolchain.cmake

cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake -DCMAKE_OSX_SYSROOT="${SDK_PATH}" $COMMON_ARGS -DCMAKE_C_FLAGS_RELEASE="${RELEASE_CFLAGS}" "$SOURCE_DIR"
ninja
