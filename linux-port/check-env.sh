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
[ -f "$ATLAS_DIR/meson.build" ] || fail "ATLAS_DIR=$ATLAS_DIR is not an atlas checkout (see README.md)"
atlas_branch="$(git -C "$ATLAS_DIR" branch --show-current 2>/dev/null || true)"
[ -n "$atlas_branch" ] || fail "$ATLAS_DIR is not a git checkout"
ok "atlas: $ATLAS_DIR on $atlas_branch ($(git -C "$ATLAS_DIR" rev-parse --short HEAD))"
# The port builds atl-touch master. The local branch name is free, because a
# worktree cannot check out a branch another worktree already holds, so it is
# the upstream that has to match.
atlas_upstream="$(git -C "$ATLAS_DIR" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
[ "$atlas_upstream" = origin/master ] ||
	echo "note: atlas tracks '${atlas_upstream:-nothing}', the port builds atl-touch origin/master"

# skia is shared between checkouts; building it from scratch is the one long step.
# Without a tree to share, meson downloads the wrap (~8 GB) on the first build,
# so this is a note and not a failure.
if [ -f "$ATLAS_DIR/subprojects/skia/BUILD.gn" ]; then
	ok "atlas skia: $(readlink -f "$ATLAS_DIR/subprojects/skia")"
else
	echo "note: no skia sources at $ATLAS_DIR/subprojects/skia; meson will download" \
		"the wrap (~8 GB) unless ATLAS_SKIA_DIR=$ATLAS_SKIA_DIR is symlinked there"
fi

if [ -f "$ATLAS_BUILDDIR/build.ninja" ]; then
	ok "atlas builddir: $ATLAS_BUILDDIR"
else
	echo "note: $ATLAS_BUILDDIR not configured yet (linux-port/build-atlas.sh does it)"
fi

# --- host build tools -------------------------------------------------------
# meson/ninja build atlas; gn + clang build its skia subproject.
for tool in cc c++ cmake make pkg-config unzip meson ninja gn clang clang++; do
	command -v "$tool" >/dev/null || fail "missing host tool: $tool"
done
ok "host tools: cc c++ cmake make pkg-config unzip meson ninja gn clang clang++"

# --- workspace layout -------------------------------------------------------
for d in native launcher shim; do
	[ -d "$PORT_DIR/$d" ] || fail "missing linux-port/$d"
done
[ -d "$PORT_OUT" ] || fail "missing $PORT_OUT"
ok "layout: native/ launcher/ shim/ out/"

echo "environment OK"
