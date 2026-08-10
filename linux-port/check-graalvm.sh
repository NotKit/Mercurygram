#!/bin/bash
# Smoke-checks the GraalVM toolchain the native image needs.
# Reads nothing and writes nothing; exits 0 only if native-image is usable.
set -euo pipefail

source "$(dirname "$0")/env.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

hint="set GRAALVM_HOME to a GraalVM CE 21 install (see linux-port/README.md)"

# --- GraalVM is a JDK 21 ----------------------------------------------------
[ -d "$GRAALVM_HOME" ] || fail "no GraalVM at \$GRAALVM_HOME ($GRAALVM_HOME); $hint"
[ -x "$GRAALVM_HOME/bin/java" ] || fail "no java at $GRAALVM_HOME/bin/java; $hint"

graal_version="$("$GRAALVM_HOME/bin/java" -version 2>&1 | head -1)"
case "$graal_version" in
	*'version "21.'*) ok "GRAALVM_HOME: $GRAALVM_HOME" ;;
	*) fail "need a JDK 21 at \$GRAALVM_HOME, got: $graal_version; $hint" ;;
esac
ok "$graal_version"

# jmods are absent from some distributions, and native-image needs none of them,
# but javac is how we tell a JDK from a JRE.
[ -x "$GRAALVM_HOME/bin/javac" ] || fail "no javac in $GRAALVM_HOME/bin (JRE-only install?); $hint"

# --- native-image -----------------------------------------------------------
ni="$GRAALVM_HOME/bin/native-image"
[ -x "$ni" ] || fail "missing $ni; install the native-image component into $GRAALVM_HOME"
ni_version="$("$ni" --version 2>&1 | head -1)"
ok "native-image: $ni_version"
ok "native-image path: $ni"

# Merges and inspects the traced configs.
[ -x "$GRAALVM_HOME/bin/native-image-configure" ] ||
	echo "note: no native-image-configure in $GRAALVM_HOME/bin; config merging is agent-side only"

# --- tracing agent ----------------------------------------------------------
# -agentlib:native-image-agent resolves against $GRAALVM_HOME/lib, so this is the
# file a traced run loads. Only a run under GRAALVM_HOME's own java finds it.
agent="$GRAALVM_HOME/lib/libnative-image-agent.so"
[ -f "$agent" ] || fail "missing tracing agent $agent; $hint"
ok "agent: $agent"

# --- host toolchain native-image links with ---------------------------------
# The image is linked by the system cc against glibc and zlib; a missing zlib
# header only shows up at the end of a long build, so catch it here.
for tool in cc ld objcopy; do
	command -v "$tool" >/dev/null || fail "missing host tool: $tool (native-image links with it)"
done
ok "host tools: cc ld objcopy"

zlib_found=0
for inc in /usr/include /usr/include/"$PORT_TRIPLE"; do
	[ -f "$inc/zlib.h" ] && zlib_found=1
done
[ "$zlib_found" = 1 ] || fail "no zlib.h; install zlib1g-dev (native-image links against it)"
ok "zlib.h present"

# --- JAVA_HOME is untouched -------------------------------------------------
# env.sh must never point the port's build at GraalVM: meson caches the java
# compiler, so a swap forces a full skia rebuild (linux-port/CLAUDE.md).
[ -x "$JAVA_HOME/bin/java" ] || fail "no java at \$JAVA_HOME/bin/java ($JAVA_HOME); run check-env.sh"
if [ "$(readlink -f "$JAVA_HOME")" = "$(readlink -f "$GRAALVM_HOME")" ]; then
	echo "note: JAVA_HOME is GRAALVM_HOME; fine for a tracing run, but do not build atlas like this"
else
	ok "JAVA_HOME unshadowed: $JAVA_HOME"
fi

echo "GraalVM OK"
