#! /bin/sh

# Builds the static libjpeg and libturbojpeg of a libjpeg-turbo source tree for one architecture.
# Usage: build-libjpeg-turbo-bazel.sh <arch> <source dir> <build dir>

set -e

ARCH="$1"

SOURCE_DIR="$2"
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")

if [ "$ARCH" = "arm64" ]; then
  PLATFORMDIR="$(xcode-select -p)/Platforms/iPhoneOS.platform"
  SYSROOT=($PLATFORMDIR/Developer/SDKs/iPhoneOS*.sdk)
  export CFLAGS="-Wall -arch arm64 -miphoneos-version-min=26.0 -funwind-tables"
elif [ "$ARCH" = "sim_arm64" ]; then
  PLATFORMDIR="$(xcode-select -p)/Platforms/iPhoneSimulator.platform"
  SYSROOT=($PLATFORMDIR/Developer/SDKs/iPhoneSimulator*.sdk)
  export CFLAGS="-Wall -arch arm64 --target=arm64-apple-ios26.0-simulator -miphonesimulator-version-min=26.0 -funwind-tables"
elif [ "$ARCH" = "macos_arm64" ]; then
  PLATFORMDIR="$(xcode-select -p)/Platforms/MacOSX.platform"
  SYSROOT=($PLATFORMDIR/Developer/SDKs/MacOSX*.sdk)
  export CFLAGS="-Wall -arch arm64 --target=arm64-apple-macosx14.0 -mmacosx-version-min=14.0 -funwind-tables"
else
  echo "Unsupported architecture $ARCH"
  exit 1
fi

cd "$BUILD_DIR"
mkdir build
cd build

touch toolchain.cmake
echo "set(CMAKE_SYSTEM_NAME Darwin)" >> toolchain.cmake
echo "set(CMAKE_SYSTEM_PROCESSOR aarch64)" >> toolchain.cmake
echo "set(CMAKE_C_COMPILER $(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang)" >> toolchain.cmake

# WITH_JPEG8 keeps the libjpeg v8 API the binding was written against (as the mozjpeg build had it).
cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake -DCMAKE_OSX_SYSROOT=${SYSROOT[0]} -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=FALSE -DWITH_JPEG8=1 -DWITH_TOOLS=FALSE -DWITH_TESTS=FALSE -DBUILD=10000 "$SOURCE_DIR"
cmake --build . --parallel "$(getconf _NPROCESSORS_ONLN)" --target jpeg-static turbojpeg-static
