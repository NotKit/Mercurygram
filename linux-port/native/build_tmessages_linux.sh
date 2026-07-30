#!/bin/bash
# Build libtmessages for x86_64-linux-gnu.
#
# Mirrors TMessagesProj/jni/CMakeLists.txt through the overlay in
# linux-port/native/CMakeLists.txt — see that file for what is excluded and why.
# Depends on build_boringssl_linux.sh, build_libvpx_linux.sh,
# build_dav1d_linux.sh and build_ffmpeg_linux.sh having run first.
#
# Usage: build_tmessages_linux.sh [--clean]
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../env.sh"

CC="${CC:-clang}"
CXX="${CXX:-clang++}"

BUILD_DIR="$PORT_NATIVE_OUT/tmessages/build"
SONAME="libtmessages.49.so"

if [ "${1:-}" = "--clean" ]; then
	echo "==> removing $BUILD_DIR"
	rm -rf "$BUILD_DIR"
fi

for dep in boringssl/libssl.a boringssl/libcrypto.a ffmpeg/lib/libavcodec.a \
           libvpx/lib/libvpx.a dav1d/lib/libdav1d.a; do
	if [ ! -f "$PORT_NATIVE_OUT/$dep" ]; then
		echo "error: missing $PORT_NATIVE_OUT/$dep — run the matching build_*_linux.sh first" >&2
		exit 1
	fi
done

if [ ! -f "$JAVA_HOME/include/jni.h" ]; then
	echo "error: no jni.h under $JAVA_HOME/include — check-env.sh should have caught this" >&2
	exit 1
fi

echo "==> configuring libtmessages ($PORT_TRIPLE)"
mkdir -p "$BUILD_DIR"
cmake -S "$PORT_DIR/native" -B "$BUILD_DIR" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER="$CC" \
	-DCMAKE_CXX_COMPILER="$CXX" \
	-DPORT_NATIVE_OUT="$PORT_NATIVE_OUT" \
	-DPORT_OUT="$PORT_OUT" \
	-DATLAS_BUILDDIR="$ATLAS_BUILDDIR" \
	-DJAVA_INCLUDE_DIRS="$JAVA_HOME/include;$JAVA_HOME/include/linux"

echo "==> building"
cmake --build "$BUILD_DIR"

echo "==> installing to $PORT_OUT"
install -m 0755 "$BUILD_DIR/$SONAME" "$PORT_OUT/$SONAME"
# The PRD and the launcher refer to it as libtmessages.so; NativeLoader asks
# for "tmessages.49". Ship both names for the one file.
ln -sfn "$SONAME" "$PORT_OUT/libtmessages.so"
install -m 0755 "$BUILD_DIR/libOpenSLES.so.1" "$PORT_OUT/libOpenSLES.so.1"

echo "==> verifying"
undefined_android="$(ldd "$PORT_OUT/$SONAME" 2>&1 | grep -iE 'not found|bionic|liblog|libjnigraphics' || true)"
if [ -n "$undefined_android" ]; then
	echo "error: unresolved or Android-only dependencies:" >&2
	echo "$undefined_android" >&2
	exit 1
fi

dynsyms="$(nm -D --defined-only "$PORT_OUT/$SONAME")"
for prefix in Java_org_telegram_tgnet_ConnectionsManager_ Java_org_telegram_SQLite_ \
              Java_org_telegram_messenger_Utilities_ JNI_OnLoad; do
	count="$(echo "$dynsyms" | grep -c "$prefix" || true)"
	if [ "$count" -eq 0 ]; then
		echo "error: no $prefix* symbols exported by $SONAME" >&2
		exit 1
	fi
	echo "    $prefix*: $count symbol(s)"
done

"$CC" -o "$BUILD_DIR/dlopen_check" "$PORT_DIR/native/tools/dlopen_check.c"
"$BUILD_DIR/dlopen_check" "$PORT_OUT/$SONAME" \
	JNI_OnLoad \
	Java_org_telegram_SQLite_SQLiteCursor_columnIntValue \
	Java_org_telegram_messenger_Utilities_aesIgeEncryption \
	Java_org_telegram_tgnet_ConnectionsManager_native_1test_1AuthAuthorization

echo "==> libtmessages: $PORT_OUT/$SONAME"
ldd "$PORT_OUT/$SONAME"
