#!/bin/sh
# Device launcher: run Mercurygram on the bundled OpenJDK 21 through atlas's
# HotSpot launcher. The click is unconfined, so this may use external tools.
#
# Mirrors linux-port/run.sh (the desktop boot loop) with device paths.

APP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PKG_NAME=mercurygram-jvm.nekit

# Prefer the version-independent 'current' path: it is stable across upgrades.
PKG_ROOT="/opt/click.ubuntu.com/${PKG_NAME}/current"
[ -x "${PKG_ROOT}/lib/android-translation-layer-hotspot" ] || PKG_ROOT="${APP_DIR}"

# Lomiri starts a click app with XDG_RUNTIME_DIR=~/.cache and
# WAYLAND_DISPLAY=wayland-0, and the compositor's socket is in neither: it is in
# /run/user/<uid>. libwayland accepts an absolute WAYLAND_DISPLAY, so point it
# straight at the socket rather than moving XDG_RUNTIME_DIR, which the app uses
# for other things. Without this GLFW aborts the launch with
# "Wayland: Failed to connect to display" before the first frame.
if [ ! -S "${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY:-wayland-0}" ]; then
    for _sock in "/run/user/$(id -u)/${WAYLAND_DISPLAY:-wayland-0}" "/run/user/$(id -u)/wayland-0"; do
        [ -S "${_sock}" ] && { export WAYLAND_DISPLAY="${_sock}"; break; }
    done
fi

export JAVA_HOME="${PKG_ROOT}/jvm"

# libjvm.so is deliberately not in the launcher's RUNPATH (linux-port/CLAUDE.md).
# lib/ holds every native object the click carries — atlas's framework natives,
# libtmessages and the art support libraries — so $ORIGIN covers them too.
export LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${PKG_ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# Keep app data in one dedicated place, as the ART packaging does. atlas appends
# "<apk basename>_" to this, so the app's own dir is <this>/app.apk_.
export ANDROID_APP_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/${PKG_NAME}"
mkdir -p "${ANDROID_APP_DATA_DIR}"

# liblog drops anything below INFO without this, which is most of the app's own
# logging; on the device the journal is the only log there is.
export ANDROID_LOG_TAGS="${ANDROID_LOG_TAGS:-*:V}"

# Lomiri never marks the app surface "maximized", so atlas's heuristic would
# report multi-window and Telegram would never store the keyboard height it
# measured (the sibling ART packaging carries the same line).
export ATL_MULTI_WINDOW=0

# Wayland app_id must match the desktop file id (<pkg>_<app>_<version>) for
# Lomiri to associate the window with the launcher entry.
if [ -z "${APP_ID:-}" ] && [ -L "/opt/click.ubuntu.com/${PKG_NAME}/current" ]; then
    PKG_VERSION="$(basename "$(readlink -f "/opt/click.ubuntu.com/${PKG_NAME}/current")")"
    export APP_ID="${PKG_NAME}_mercurygram-jvm_${PKG_VERSION}"
fi

# MERCURYGRAM_NO_GPU=1 falls back to CPU raster, which is what the desktop port
# runs (atlas's Ganesh path crashes in skia there, on every driver). On device
# GLES is real, so the GPU path is the default — this is the knob to flip first
# if it dies in skia.
[ -n "${MERCURYGRAM_NO_GPU:-}" ] && export ATL_NO_GPU=1

exec "${PKG_ROOT}/lib/android-translation-layer-hotspot" \
    --api-impl-jar "${PKG_ROOT}/atlas/api-impl.jar" \
    --framework-res "${PKG_ROOT}/atlas/framework-res.apk" \
    --natives-dir "${PKG_ROOT}/lib" \
    --classpath "${PKG_ROOT}/classpath/shim.jar:${PKG_ROOT}/classpath/*" \
    --library-path "${PKG_ROOT}/lib" \
    --launch-activity org.telegram.ui.LaunchActivity \
    -X "-Dtmessages.native.path=${PKG_ROOT}/lib/libtmessages.so" \
    "$@" \
    "${PKG_ROOT}/app.apk"
