# The CMake options for libopus, sourced by build-opus-bazel.sh (iOS) and by the Mac core-xprojects libopus build.sh,
# so the two apps cannot drift. Android sets the same options in TMessagesProj/jni/CMakeLists.txt.
#
# configure flags: --disable-shared --enable-static -> OPUS_BUILD_SHARED_LIBRARY=OFF, --disable-extra-programs ->
# OPUS_BUILD_PROGRAMS=OFF, --disable-doc (no CMake target), --disable-asm (no CMake option; CMake has no hand-written
# asm switch, the arm64 NEON code is intrinsics) + --enable-intrinsics -> OPUS_DISABLE_INTRINSICS=OFF, floating
# point (configure default) -> OPUS_FIXED_POINT=OFF, DRED/OSCE/deep PLC (configure default off) -> OPUS_DRED=OFF,
# OPUS_OSCE=OFF, --with-pic -> CMAKE_POSITION_INDEPENDENT_CODE=ON.
# OPUS_PRESUME_NEON=ON: Darwin has no runtime CPU detection, so without it the NEON code is compiled but never called
# when CMAKE_SYSTEM_PROCESSOR is "arm64" (no toolchain file, as in the Mac build). Ignored on x86.
OPUS_COMMON_ARGS="-DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DBUILD_TESTING=OFF -DOPUS_DISABLE_INTRINSICS=OFF -DOPUS_PRESUME_NEON=ON -DOPUS_FIXED_POINT=OFF -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
