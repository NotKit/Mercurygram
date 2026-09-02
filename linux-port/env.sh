#!/bin/bash
# Shared environment for the desktop OpenJDK port. Source it, don't run it:
#   source linux-port/env.sh
# Every variable can be overridden from the caller's environment.

# Absolute path of linux-port/, valid whether sourced from bash or a script.
PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PORT_DIR
export REPO_DIR="$(cd "$PORT_DIR/.." && pwd)"

# atlas (atl-touch) sources the port builds itself: an in-tree checkout of
# atl-touch master, its own git repo, gitignored here. See README.md.
export ATLAS_DIR="${ATLAS_DIR:-$PORT_DIR/atlas}"

# The ~8 GB skia checkout is shared between atlas checkouts through a symlink at
# $ATLAS_DIR/subprojects/skia; build-atlas.sh creates it from here if missing.
export ATLAS_SKIA_DIR="${ATLAS_SKIA_DIR:-/home/nekit/UT/atlas/subprojects/skia}"

# OpenJDK 21. Keep an already-correct JAVA_HOME, otherwise pick the distro path.
if [ -z "${JAVA_HOME:-}" ] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -q 'version "21\.'; then
	export JAVA_HOME="${JAVA_21_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
fi
export PATH="$JAVA_HOME/bin:$PATH"

# GraalVM CE 21 for native-image and its tracing agent (tasks/prd-mercurygram-
# graalvm-native-image.md). It is a second JDK, never the port's: JAVA_HOME stays
# the OpenJDK above, because meson caches the java compiler and swapping it forces
# a skia rebuild. A tracing run opts in by exporting JAVA_HOME=$GRAALVM_HOME itself.
export GRAALVM_HOME="${GRAALVM_HOME:-/home/nekit/UT/graalvm-ce-21}"

# All build products land here; never committed.
export PORT_OUT="${PORT_OUT:-$PORT_DIR/out}"
export PORT_NATIVE_OUT="$PORT_OUT/native"

# The native-image shared library the image launcher creates its VM from
# (build-image.sh), and which launcher the run scripts pick: hotspot|image.
# Both live here rather than in each script so a driving script can select the image path
# with an environment variable instead of a patch to every check-*.sh.
export PORT_IMAGE_LIB="${PORT_IMAGE_LIB:-$PORT_OUT/image/libmercurygram.so}"
export PORT_LAUNCHER="${PORT_LAUNCHER:-hotspot}"
# a typo here must not quietly mean "hotspot": the name goes into
# $PORT_LAUNCHER_BIN below, so the run scripts fail on a launcher that is not there
case "$PORT_LAUNCHER" in
hotspot|image) ;;
*) echo "env.sh: unsupported PORT_LAUNCHER '$PORT_LAUNCHER' (hotspot or image)" >&2 ;;
esac

# atlas builds into out/, so `--clean` never touches the sources.
export ATLAS_BUILDDIR="${ATLAS_BUILDDIR:-$PORT_OUT/atlas-build}"
export ATLAS_OUT="${ATLAS_OUT:-$PORT_OUT/atlas}"

# The binary $PORT_LAUNCHER selects. A script that runs the app through run.sh
# has to name it this way: run.sh honours $PORT_LAUNCHER, so a hardcoded path
# would check one binary, run another, and kill neither.
export PORT_LAUNCHER_BIN="$ATLAS_OUT/android-translation-layer-$PORT_LAUNCHER"

# Target architecture of every native product: x86_64 is the desktop port, arm64
# the Ubuntu Touch click (linux-port/click/), which cross-compiles.
export PORT_ARCH="${PORT_ARCH:-x86_64}"
case "$PORT_ARCH" in
x86_64) export PORT_TRIPLE="${PORT_TRIPLE:-x86_64-linux-gnu}" ;;
arm64)  export PORT_TRIPLE="${PORT_TRIPLE:-aarch64-linux-gnu}" ;;
*) echo "env.sh: unsupported PORT_ARCH '$PORT_ARCH' (x86_64 or arm64)" >&2 ;;
esac

# Cross builds prefix their tools and cannot run what they produce, so every
# script that verifies a product has to skip (or defer) that check.
if [ "$PORT_TRIPLE" = "$(uname -m)-linux-gnu" ]; then
	export PORT_CROSS=0
	export PORT_TOOL_PREFIX=""
	# clang is what the Android build uses, and what the native deps were built with.
	export PORT_CC="${PORT_CC:-clang}"
	export PORT_CXX="${PORT_CXX:-clang++}"
else
	export PORT_CROSS=1
	export PORT_TOOL_PREFIX="${PORT_TRIPLE}-"
	# gcc, not clang --target: the cross gcc needs no sysroot wrangling, and
	# every build system here takes a plain compiler name without flags.
	export PORT_CC="${PORT_CC:-${PORT_TOOL_PREFIX}gcc}"
	export PORT_CXX="${PORT_CXX:-${PORT_TOOL_PREFIX}g++}"
fi
export PORT_AR="${PORT_AR:-${PORT_TOOL_PREFIX}ar}"
export PORT_RANLIB="${PORT_RANLIB:-${PORT_TOOL_PREFIX}ranlib}"
export PORT_STRIP="${PORT_STRIP:-${PORT_TOOL_PREFIX}strip}"
export PORT_NM="${PORT_NM:-${PORT_TOOL_PREFIX}nm}"
export PORT_PKG_CONFIG="${PORT_PKG_CONFIG:-${PORT_TOOL_PREFIX}pkg-config}"

# The JDK the target runs on. Same version as JAVA_HOME, other architecture:
# jni.h for the JNI libraries, lib/server/libjvm.so for the launcher. Equal to
# JAVA_HOME on a native build.
export PORT_TARGET_JAVA_HOME="${PORT_TARGET_JAVA_HOME:-$JAVA_HOME}"

mkdir -p "$PORT_OUT" "$PORT_NATIVE_OUT"
