# The FFmpeg configure flags that both apps share: what is compiled in (decoders, demuxers, parsers, the file
# protocol) and what is switched off (the network stack and the Apple frameworks FFmpeg would otherwise
# autodetect and link). Sourced by build-ffmpeg-bazel.sh (iOS) and, through submodules/telegram-ios, by
# core-xprojects/ffmpeg/ffmpeg/build.sh (Mac). A change here changes both apps; per-platform extras (iOS muxers
# and encoders, the AudioToolbox decoders) stay in the two scripts and tools/dev/tests/test_ffmpeg_flags_parity.py
# lists the allowed differences. Plain assignment only: it is read by both sh and bash.
FFMPEG_COMMON_FLAGS="--enable-cross-compile --disable-programs \
                 --disable-armv5te --disable-armv6 --disable-armv6t2 \
                 --disable-doc --enable-pic --disable-all --disable-everything \
                 --enable-avcodec \
                 --enable-swresample \
                 --enable-avformat \
                 --disable-xlib \
                 --enable-libopus \
                 --enable-libvpx \
                 --enable-libdav1d \
                 --enable-bsf=aac_adtstoasc,vp9_superframe,h264_mp4toannexb \
                 --enable-decoder=h264,hevc,libvpx_vp9,libopus,mp3,flac,pcm_s16le,pcm_s24le,pcm_f32le,vorbis,libdav1d,av1 \
                 --enable-demuxer=aac,mov,m4v,mp3,ogg,flac,wav,aiff,matroska,mpegts \
                 --enable-parser=aac,h264,mp3 \
                 --enable-protocol=file \
                 --disable-network --disable-securetransport --disable-bzlib --disable-iconv \
                 --disable-appkit --disable-avfoundation --disable-coreimage --disable-metal --disable-sdl2 \
                 "
