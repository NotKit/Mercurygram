#!/bin/bash
# Build libvpx (libvpx.a) for the host x86_64-linux-gnu target.
# Mirrors TMessagesProj/jni/build_libvpx_clang.sh's x86_64 case, minus the NDK.
#
# Usage: linux-port/native/build_libvpx_linux.sh [--clean]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

SRC_DIR="$REPO_DIR/TMessagesProj/jni/libvpx"
OUT_DIR="$PORT_NATIVE_OUT/libvpx"
BUILD_DIR="$OUT_DIR/build"

if [ "${1:-}" = "--clean" ]; then
	rm -rf "$BUILD_DIR"
fi

if [ ! -x "$SRC_DIR/configure" ]; then
	echo "libvpx submodule is not checked out at $SRC_DIR" >&2
	echo "run: git submodule update --init TMessagesProj/jni/libvpx" >&2
	exit 1
fi

# Out-of-tree build: the Android script builds in-tree and `make distclean`s,
# which would dirty the submodule.
mkdir -p "$BUILD_DIR"

export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
# -DANDROID and -fpie dropped; the rest matches the Android x86_64 case.
export CFLAGS="-O3 -march=x86-64 -mtune=generic -msse4.2 -mpopcnt -m64 -fPIC"
export CPPFLAGS="$CFLAGS"
export CXXFLAGS="$CFLAGS -std=c++11"

if [ ! -f "$BUILD_DIR/Makefile" ]; then
	(cd "$BUILD_DIR" && "$SRC_DIR/configure" \
		--prefix="$OUT_DIR" \
		--target=x86_64-linux-gcc \
		--enable-runtime-cpu-detect \
		--as=yasm \
		--enable-static \
		--enable-pic \
		--disable-docs \
		--enable-libyuv \
		--enable-small \
		--enable-optimizations \
		--enable-better-hw-compatibility \
		--disable-examples \
		--disable-tools \
		--disable-debug \
		--disable-unit-tests \
		--disable-install-docs \
		--enable-realtime-only \
		--enable-vp8 \
		--enable-vp9 \
		--disable-webm-io)
fi

make -C "$BUILD_DIR" -j"$(nproc)" install

# Symbols go into a variable first: `nm | grep -q` would SIGPIPE nm under pipefail.
syms="$(nm --defined-only "$OUT_DIR/lib/libvpx.a" 2>/dev/null)"
for sym in vpx_codec_vp9_dx vpx_codec_vp9_cx vpx_codec_vp8_dx; do
	grep -qw "T $sym" <<<"$syms" \
		|| { echo "$sym missing from libvpx.a" >&2; exit 1; }
done

echo "libvpx ready in $OUT_DIR"
