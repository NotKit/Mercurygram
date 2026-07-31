#!/bin/bash
# Build libvpx (libvpx.a) for $PORT_TRIPLE (see env.sh).
# Mirrors TMessagesProj/jni/build_libvpx_clang.sh's case for that arch, minus
# the NDK.
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

export CC="$PORT_CC"
export CXX="$PORT_CXX"
# libvpx's own build system prefixes its tools with $CROSS, so a cross build
# needs nothing else to find ar/ranlib/as.
[ "$PORT_CROSS" = 1 ] && export CROSS="$PORT_TOOL_PREFIX"

# -DANDROID and -fpie dropped; the rest matches the Android case for the arch.
case "$PORT_ARCH" in
x86_64)
	export CFLAGS="-O3 -march=x86-64 -mtune=generic -msse4.2 -mpopcnt -m64 -fPIC"
	vpx_target=x86_64-linux-gcc
	# yasm is x86-only; on arm64 libvpx assembles NEON with the C compiler.
	vpx_arch_args=(--enable-runtime-cpu-detect --as=yasm)
	;;
arm64)
	export CFLAGS="-O3 -march=armv8-a -fPIC"
	vpx_target=arm64-linux-gcc
	# --disable-neon-{asm,dotprod} as the Android build does for every arch:
	# the intrinsics paths stay, the hand-written .S files go.
	vpx_arch_args=(--disable-runtime-cpu-detect --disable-neon-asm --disable-neon-dotprod)
	;;
esac
export CPPFLAGS="$CFLAGS"
export CXXFLAGS="$CFLAGS -std=c++11"

if [ ! -f "$BUILD_DIR/Makefile" ]; then
	(cd "$BUILD_DIR" && "$SRC_DIR/configure" \
		--prefix="$OUT_DIR" \
		--target="$vpx_target" \
		"${vpx_arch_args[@]}" \
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
