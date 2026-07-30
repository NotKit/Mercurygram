#!/bin/bash
# Build dav1d (libdav1d.a) for the host x86_64-linux-gnu target.
# Mirrors TMessagesProj/jni/build_dav1d.sh, minus the meson cross file.
#
# Usage: linux-port/native/build_dav1d_linux.sh [--clean]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

SRC_DIR="$REPO_DIR/TMessagesProj/jni/dav1d"
OUT_DIR="$PORT_NATIVE_OUT/dav1d"
BUILD_DIR="$OUT_DIR/build"

if [ "${1:-}" = "--clean" ]; then
	rm -rf "$BUILD_DIR"
fi

if [ ! -f "$SRC_DIR/meson.build" ]; then
	echo "dav1d submodule is not checked out at $SRC_DIR" >&2
	echo "run: git submodule update --init TMessagesProj/jni/dav1d" >&2
	exit 1
fi

for tool in meson ninja nasm; do
	command -v "$tool" >/dev/null \
		|| { echo "$tool not found; install it (apt install meson ninja-build nasm)" >&2; exit 1; }
done

# --libdir lib: meson would otherwise use Debian's lib/x86_64-linux-gnu layout.
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
	meson setup \
		--prefix "$OUT_DIR" \
		--libdir lib \
		--default-library static \
		--buildtype release \
		-Dc_args="-fPIC -D_LARGEFILE_SOURCE=1 -Wno-builtin-macro-redefined -D__FILE__=__FILE_NAME__" \
		-Dc_link_args=-fPIC \
		-Denable_tools=false \
		-Denable_tests=false \
		-Denable_docs=false \
		"$BUILD_DIR" \
		"$SRC_DIR"
fi

ninja -C "$BUILD_DIR"
meson install -C "$BUILD_DIR" --no-rebuild

# Symbols go into a variable first: `nm | grep -q` would SIGPIPE nm under pipefail.
syms="$(nm --defined-only "$OUT_DIR/lib/libdav1d.a" 2>/dev/null)"
for sym in dav1d_open dav1d_send_data dav1d_get_picture; do
	grep -qw "T $sym" <<<"$syms" \
		|| { echo "$sym missing from libdav1d.a" >&2; exit 1; }
done

echo "dav1d ready in $OUT_DIR"
