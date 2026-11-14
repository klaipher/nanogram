#! /bin/sh

set -ex

ARCH="$1"
SOURCE_DIR=$(echo "$(cd "$(dirname "$2")"; pwd -P)/$(basename "$2")")
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")

MINIOSVERSION="13.0"

OPT_CFLAGS="-O2 -g"

# The release tarball ships package_version; a git checkout would ask git, which fails in a copied submodule.
rm -rf "$SOURCE_DIR/.git"
echo 'PACKAGE_VERSION="1.6.1"' > "$SOURCE_DIR/package_version"

# configure flags: --disable-shared --enable-static -> OPUS_BUILD_SHARED_LIBRARY=OFF, --disable-extra-programs ->
# OPUS_BUILD_PROGRAMS=OFF, --disable-doc (no CMake target), --disable-asm (no CMake option; CMake has no hand-written
# asm switch, the arm64 NEON code is intrinsics) + --enable-intrinsics -> OPUS_DISABLE_INTRINSICS=OFF, floating
# point (configure default) -> OPUS_FIXED_POINT=OFF, DRED/OSCE/deep PLC (configure default off) -> OPUS_DRED=OFF,
# OPUS_OSCE=OFF, --with-pic -> CMAKE_POSITION_INDEPENDENT_CODE=ON.
COMMON_ARGS="-DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DBUILD_TESTING=OFF -DOPUS_DISABLE_INTRINSICS=OFF -DOPUS_FIXED_POINT=OFF -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"

mkdir -p "$BUILD_DIR/build"
cd "$BUILD_DIR/build"

if [ "${ARCH}" = "linux_x86_64" ] || [ "${ARCH}" = "linux_arm64" ]; then
  cmake -G Ninja $COMMON_ARGS -DCMAKE_C_FLAGS_RELEASE="${OPT_CFLAGS}" "$SOURCE_DIR"
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

cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake -DCMAKE_OSX_SYSROOT="${SDK_PATH}" $COMMON_ARGS -DCMAKE_C_FLAGS_RELEASE="${OPT_CFLAGS}" "$SOURCE_DIR"
ninja
