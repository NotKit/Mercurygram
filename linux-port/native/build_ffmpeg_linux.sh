#!/bin/bash
# Build ffmpeg (libav*.a, libsw*.a) for the host x86_64-linux-gnu target.
# Mirrors TMessagesProj/jni/build_ffmpeg_clang.sh's x86_64 case, minus the NDK,
# and applies the same private-header patches as jni/patch_ffmpeg.sh.
#
# Needs libvpx first (--enable-libvpx): run build_libvpx_linux.sh.
#
# Usage: linux-port/native/build_ffmpeg_linux.sh [--clean]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

JNI_DIR="$REPO_DIR/TMessagesProj/jni"
SRC_DIR="$JNI_DIR/ffmpeg"
OUT_DIR="$PORT_NATIVE_OUT/ffmpeg"
BUILD_DIR="$OUT_DIR/build"
LIBVPX_DIR="$PORT_NATIVE_OUT/libvpx"

if [ "${1:-}" = "--clean" ]; then
	rm -rf "$BUILD_DIR"
fi

if [ ! -x "$SRC_DIR/configure" ]; then
	echo "ffmpeg submodule is not checked out at $SRC_DIR" >&2
	echo "run: git submodule update --init TMessagesProj/jni/ffmpeg" >&2
	exit 1
fi

if [ ! -f "$LIBVPX_DIR/lib/libvpx.a" ]; then
	echo "libvpx is missing at $LIBVPX_DIR; run build_libvpx_linux.sh first" >&2
	exit 1
fi

CC="${CC:-clang}"
CXX="${CXX:-clang++}"

# Out-of-tree build: the Android script builds in-tree and `make clean`s, which
# would dirty the submodule.
mkdir -p "$BUILD_DIR"

if [ ! -f "$BUILD_DIR/config.h" ]; then
	# Android's -DANDROID and the `-fPIE -pie --static` triple are dropped: the
	# static/PIE mix breaks configure's link tests against a glibc toolchain.
	(cd "$BUILD_DIR" && "$SRC_DIR/configure" \
		--cc="$CC" \
		--cxx="$CXX" \
		--enable-stripping \
		--arch=x86_64 \
		--target-os=linux \
		--prefix="$OUT_DIR" \
		--enable-pic \
		--disable-shared \
		--enable-static \
		--extra-cflags="-I$LIBVPX_DIR/include -Os -DCONFIG_LINUX_PERF=0 -fPIC -w" \
		--extra-cxxflags="-I$LIBVPX_DIR/include -Os -DCONFIG_LINUX_PERF=0 -fPIC -w" \
		--extra-ldflags="-L$LIBVPX_DIR/lib -Wl,-Bsymbolic -fPIC" \
		\
		--enable-version3 \
		--enable-gpl \
		\
		--disable-linux-perf \
		\
		--disable-doc \
		--disable-htmlpages \
		--disable-avx \
		\
		--disable-everything \
		--disable-network \
		--disable-zlib \
		--disable-bzlib \
		--disable-lzma \
		--disable-iconv \
		--disable-avfilter \
		--disable-avdevice \
		--disable-postproc \
		--disable-debug \
		--disable-programs \
		--disable-ffplay \
		--disable-ffprobe \
		\
		--enable-libvpx \
		--enable-decoder=libvpx_vp9 \
		--enable-encoder=libvpx_vp9 \
		--enable-muxer=matroska \
		--enable-bsf=vp9_superframe \
		--enable-bsf=vp9_raw_reorder \
		--enable-runtime-cpudetect \
		--enable-pthreads \
		--enable-avresample \
		--enable-swscale \
		--enable-protocol=file \
		--enable-decoder=opus \
		--enable-decoder=mp3 \
		--enable-decoder=aac \
		--enable-decoder=h264 \
		--enable-decoder=mpeg4 \
		--enable-decoder=mjpeg \
		--enable-decoder=gif \
		--enable-decoder=alac \
		--enable-demuxer=mov \
		--enable-demuxer=gif \
		--enable-demuxer=ogg \
		--enable-demuxer=matroska \
		--enable-demuxer=mp3 \
		--enable-demuxer=aac \
		--enable-hwaccels \
		--disable-asm)
fi

make -C "$BUILD_DIR" -j"$(nproc)"
make -C "$BUILD_DIR" install

# Same private headers jni/patch_ffmpeg.sh installs and patches, for the C++
# sources (gifvideo.cpp) that reach into ffmpeg internals. Copies only; the
# ffmpeg source must stay unpatched so its own C compilation still works.
install -D -m 644 "$SRC_DIR/libavformat/dv.h"        "$OUT_DIR/include/libavformat/dv.h"
install -D -m 644 "$SRC_DIR/libavformat/isom.h"      "$OUT_DIR/include/libavformat/isom.h"
install -D -m 644 "$SRC_DIR/libavcodec/bytestream.h" "$OUT_DIR/include/libavcodec/bytestream.h"
install -D -m 644 "$SRC_DIR/libavcodec/get_bits.h"   "$OUT_DIR/include/libavcodec/get_bits.h"
install -D -m 644 "$SRC_DIR/libavcodec/golomb.h"     "$OUT_DIR/include/libavcodec/golomb.h"
install -D -m 644 "$SRC_DIR/libavcodec/vlc.h"        "$OUT_DIR/include/libavcodec/vlc.h"
install -D -m 644 "$SRC_DIR/libavutil/intmath.h"     "$OUT_DIR/include/libavutil/intmath.h"

# --forward makes re-runs no-ops; the copies above are fresh each time anyway.
for p in 0001-compilation-magic 0002-compilation-magic-2; do
	(cd "$OUT_DIR/include" && patch -p1 --forward --silent < "$JNI_DIR/patches/ffmpeg/$p.patch")
done

# Symbols go into a variable first: `nm | grep -q` would SIGPIPE nm under pipefail.
check_syms() {
	local lib="$1"; shift
	local syms
	syms="$(nm --defined-only "$OUT_DIR/lib/$lib.a" 2>/dev/null)"
	for sym in "$@"; do
		grep -qw "T $sym" <<<"$syms" \
			|| { echo "$sym missing from $lib.a" >&2; exit 1; }
	done
}
check_syms libavcodec avcodec_open2 avcodec_send_packet
check_syms libavformat avformat_open_input av_read_frame
check_syms libavutil av_frame_alloc
check_syms libswscale sws_scale
check_syms libswresample swr_convert
check_syms libavresample avresample_open

echo "ffmpeg ready in $OUT_DIR"
