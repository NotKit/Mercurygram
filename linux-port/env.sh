#!/bin/bash
# Shared environment for the desktop OpenJDK port. Source it, don't run it:
#   source linux-port/env.sh
# Every variable can be overridden from the caller's environment.

# Absolute path of linux-port/, valid whether sourced from bash or a script.
PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PORT_DIR
export REPO_DIR="$(cd "$PORT_DIR/.." && pwd)"

# atlas (atl-touch) checkout, consumed read-only as a build dependency.
export ATLAS_DIR="${ATLAS_DIR:-/home/nekit/UT/atlas}"
export ATLAS_BUILDDIR="${ATLAS_BUILDDIR:-$ATLAS_DIR/builddir}"

# OpenJDK 21. Keep an already-correct JAVA_HOME, otherwise pick the distro path.
if [ -z "${JAVA_HOME:-}" ] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -q 'version "21\.'; then
	export JAVA_HOME="${JAVA_21_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
fi
export PATH="$JAVA_HOME/bin:$PATH"

# All build products land here; never committed.
export PORT_OUT="${PORT_OUT:-$PORT_DIR/out}"
export PORT_NATIVE_OUT="$PORT_OUT/native"

# Target triple for every native dependency built by linux-port/native/.
export PORT_TRIPLE="${PORT_TRIPLE:-x86_64-linux-gnu}"

mkdir -p "$PORT_OUT" "$PORT_NATIVE_OUT"
