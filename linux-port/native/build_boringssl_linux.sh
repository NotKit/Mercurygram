#!/bin/bash
# Build BoringSSL (libssl.a + libcrypto.a) for the host x86_64-linux-gnu target.
# Mirrors TMessagesProj/jni/build_boringssl.sh, minus the NDK toolchain file.
#
# Usage: linux-port/native/build_boringssl_linux.sh [--clean]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

JNI_DIR="$REPO_DIR/TMessagesProj/jni"
SRC_DIR="$JNI_DIR/boringssl"
BUILD_DIR="$PORT_NATIVE_OUT/boringssl/build"
OUT_DIR="$PORT_NATIVE_OUT/boringssl"

if [ "${1:-}" = "--clean" ]; then
	rm -rf "$BUILD_DIR"
fi

if [ ! -f "$SRC_DIR/CMakeLists.txt" ]; then
	echo "boringssl submodule is not checked out at $SRC_DIR" >&2
	echo "run: git submodule update --init TMessagesProj/jni/boringssl" >&2
	exit 1
fi

# Same AES-IGE patch the Android build applies; the script is itself idempotent.
(cd "$JNI_DIR" && ./patch_boringssl.sh)

# PIC is required because libtmessages.so links these archives into a .so.
# The __FILE__ redefinition matches the Android build (shorter paths in errors).
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -GNinja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_TESTING=OFF \
	"-DCMAKE_C_FLAGS=-Wno-builtin-macro-redefined -D__FILE__=__FILE_NAME__" \
	"-DCMAKE_CXX_FLAGS=-Wno-builtin-macro-redefined -D__FILE__=__FILE_NAME__"

cmake --build "$BUILD_DIR" --target ssl crypto

for lib in libssl libcrypto; do
	# BoringSSL declares both targets at its top level, but don't hardcode that.
	built="$(find "$BUILD_DIR" -name "$lib.a" -print -quit)"
	[ -n "$built" ] || { echo "$lib.a not produced by the build" >&2; exit 1; }
	install -m 644 "$built" "$OUT_DIR/$lib.a"
done

# Ship the headers next to the archives so the libtmessages build can point at
# one prefix.
rm -rf "$OUT_DIR/include"
cp -a "$SRC_DIR/include" "$OUT_DIR/include"

# Symbols are read into a variable first: piping nm into `grep -q` would kill nm
# with SIGPIPE and trip pipefail.
# AES_ige_encrypt lives in libssl.a because the patch adds ssl/aes_ige.c to
# SSL_SOURCES, not to the crypto sources.
check_syms() {
	local lib="$1"; shift
	local syms
	# stderr is dropped: the archives carry empty per-arch .S objects.
	syms="$(nm --defined-only "$OUT_DIR/$lib.a" 2>/dev/null)"
	for sym in "$@"; do
		grep -qw "T $sym" <<<"$syms" \
			|| { echo "$sym missing from $lib.a" >&2; exit 1; }
	done
}
check_syms libssl SSL_new SSL_free AES_ige_encrypt
check_syms libcrypto AES_set_encrypt_key SHA256_Init

echo "BoringSSL ready in $OUT_DIR"
