#!/bin/bash
# Build the libcore/dalvik compat shim: out/shim.jar plus its JNI back
# end out/libportshim.so, then run tools/ShimCheck against api-impl.
#
# What belongs in the shim and what does not is decided by an audit, not by
# guessing; shim/README.md records it and audit-shim.sh reproduces it.
#
# Usage: linux-port/build-shim.sh [--clean]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

SHIM_DIR="$PORT_DIR/shim"
CLASSES="$PORT_OUT/shim/classes"
SHIM_JAR="$PORT_OUT/shim.jar"
SHIM_LIB="$PORT_OUT/libportshim.so"
TOOLS_OUT="$PORT_OUT/tools"

for arg in "$@"; do
	case "$arg" in
	--clean) rm -rf "$PORT_OUT/shim" "$SHIM_JAR" "$SHIM_LIB" ;;
	*) echo "usage: $0 [--clean]" >&2; exit 2 ;;
	esac
done

[ -f "$ATLAS_OUT/api-impl.jar" ] ||
	{ echo "no $ATLAS_OUT/api-impl.jar: run linux-port/build-atlas.sh first" >&2; exit 1; }

# --- jar --------------------------------------------------------------------
rm -rf "$CLASSES"
mkdir -p "$CLASSES"
mapfile -t sources < <(find "$SHIM_DIR/src" -name '*.java' | sort)
echo "compiling ${#sources[@]} shim classes with $(javac -version 2>&1)"
# The shim only ever compiles against the JDK: it must not grow a dependency on
# api-impl, or the split between framework and runtime stops being real.
javac --release 21 -Xlint:-options -implicit:none -d "$CLASSES" "${sources[@]}"
# resources/ holds the service registrations that make a shim the platform
# default, the way libcore's are on ART (see shim/README.md).
jar --create --file "$SHIM_JAR" -C "$CLASSES" . -C "$SHIM_DIR/resources" .

# --- JNI back end -----------------------------------------------------------
echo "building $(basename "$SHIM_LIB")"
# The JNI back end is the one part of the shim that is not bytecode: it is built
# for the target, against the target JDK's jni.h (identical to the host's, but
# there is no reason to reach for the wrong one).
"$PORT_CC" -shared -fPIC -O2 -Wall -Wextra -std=gnu11 \
	-I"$PORT_TARGET_JAVA_HOME/include" -I"$PORT_TARGET_JAVA_HOME/include/linux" \
	-o "$SHIM_LIB" "$SHIM_DIR/native/port_shim.c"

# --- verify -----------------------------------------------------------------
for symbol in Java_libcore_util_NativeAllocationRegistry_applyFreeFunction Java_libcore_io_Posix_open; do
	symbols="$($PORT_NM -D --defined-only "$SHIM_LIB")"
	grep -q "$symbol" <<<"$symbols" || { echo "$SHIM_LIB does not export $symbol" >&2; exit 1; }
done

entries="$(unzip -l "$SHIM_JAR")"
for class in libcore/util/NativeAllocationRegistry.class dalvik/system/CloseGuard.class \
	android/system/Os.class org/xmlpull/v1/XmlPullParser.class org/json/JSONObject.class; do
	grep -q "$class" <<<"$entries" || { echo "$SHIM_JAR is missing $class" >&2; exit 1; }
done

mkdir -p "$TOOLS_OUT"
javac --release 21 -d "$TOOLS_OUT" -cp "$SHIM_JAR:$ATLAS_OUT/api-impl.jar" \
	"$PORT_DIR/tools/ShimCheck.java" "$PORT_DIR/tools/JdkRefCheck.java"

# No shim can add methods to java.*, so api-impl must not ask for libcore's
# additions to it (see tools/JdkRefCheck.java). Catch that here, not at runtime.
SCAN="$PORT_OUT/shim/api-impl-classes"
rm -rf "$SCAN"
mkdir -p "$SCAN"
unzip -qo "$ATLAS_OUT/api-impl.jar" -d "$SCAN"
(cd "$SCAN" && find . -name '*.class' | sed 's|^\./||;s|\.class$||;s|/|.|g') >"$SCAN.txt"
refs="$(xargs -a "$SCAN.txt" -n 300 javap -p -c -classpath "$SCAN" 2>/dev/null |
	grep -oP '// \w+ javax?/[^ ]*' | cut -d' ' -f3 | sort -u)"
# api-impl is on the classpath too: it ships javax.microedition itself
if ! missing="$(printf '%s\n' "$refs" | java -cp "$TOOLS_OUT:$ATLAS_OUT/api-impl.jar" JdkRefCheck)"; then
	echo "api-impl uses JDK members that only exist on ART; fix in \$ATLAS_DIR:" >&2
	printf '%s\n' "$missing" >&2
	exit 1
fi
echo "api-impl: $(wc -l <"$SCAN.txt") classes, $(printf '%s\n' "$refs" | wc -l) JDK references, all resolvable"

# ShimCheck loads libportshim.so into this JVM, so it only runs natively; a
# cross build's copy is exercised by the app's first launch on the device.
if [ "$PORT_CROSS" = 0 ]; then
	java -cp "$TOOLS_OUT:$SHIM_JAR:$ATLAS_OUT/api-impl.jar" \
		-Djava.library.path="$PORT_OUT" ShimCheck
else
	echo "(skipping ShimCheck: cannot load an $PORT_TRIPLE library here)"
fi

echo "shim: $SHIM_JAR ($(du -h "$SHIM_JAR" | cut -f1)), $SHIM_LIB"
