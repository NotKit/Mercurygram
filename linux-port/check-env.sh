#!/bin/bash
# Smoke-checks the toolchain the port needs. Exits 0 only if everything is usable.
set -euo pipefail

source "$(dirname "$0")/env.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# --- JDK 21 -----------------------------------------------------------------
[ -x "$JAVA_HOME/bin/java" ] || fail "no java at \$JAVA_HOME/bin/java ($JAVA_HOME)"
java_version="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
case "$java_version" in
	*'version "21.'*) ok "$java_version" ;;
	*) fail "need OpenJDK 21, got: $java_version (set JAVA_21_HOME or JAVA_HOME)" ;;
esac

[ -x "$JAVA_HOME/bin/javac" ] || fail "no javac in $JAVA_HOME/bin (JRE-only install?)"
ok "javac: $("$JAVA_HOME/bin/javac" -version 2>&1)"

# libjvm is what linux-port/launcher/ links against.
libjvm="$JAVA_HOME/lib/server/libjvm.so"
[ -f "$libjvm" ] || fail "missing $libjvm"
ok "libjvm: $libjvm"

# --- atlas checkout ---------------------------------------------------------
[ -f "$ATLAS_DIR/meson.build" ] || fail "ATLAS_DIR=$ATLAS_DIR is not an atlas checkout"
ok "atlas: $ATLAS_DIR"
if [ -d "$ATLAS_BUILDDIR" ]; then
	ok "atlas builddir: $ATLAS_BUILDDIR"
else
	echo "note: $ATLAS_BUILDDIR not built yet (linux-port/get-atlas-artifacts.sh builds it)"
fi

# --- host build tools -------------------------------------------------------
for tool in cc c++ cmake make pkg-config unzip; do
	command -v "$tool" >/dev/null || fail "missing host tool: $tool"
done
ok "host tools: cc c++ cmake make pkg-config unzip"

# --- workspace layout -------------------------------------------------------
for d in native launcher shim; do
	[ -d "$PORT_DIR/$d" ] || fail "missing linux-port/$d"
done
[ -d "$PORT_OUT" ] || fail "missing $PORT_OUT"
ok "layout: native/ launcher/ shim/ out/"

echo "environment OK"
