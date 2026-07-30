#!/bin/bash
# Boots the HotSpot launcher far enough to prove the runtime
# is alive, without running any of Mercurygram's code.
#
# --smoke-test stops the launcher after the window exists: the JVM is up, the
# framework jar and the compat shim are on the class path,
# libtranslation_layer_main.so is registered with the class loader that owns the
# framework, one of its Java_android_* entry points resolves, and an ATLWindow
# is on screen. Everything after that (createApplication onwards) is run.sh's job.
#
# Writes out/run.log and, when a screenshot tool is available, a shot of the
# window to out/screenshots/.
#
# Usage: linux-port/launcher/smoke-test.sh [SECONDS]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

seconds="${1:-5}"
launcher="$ATLAS_OUT/android-translation-layer-hotspot"
log="$PORT_OUT/run.log"
shots="$PORT_OUT/screenshots"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

mkdir -p "$shots"

# libjvm.so is not on the default loader path and baking the JDK into the
# launcher's RUNPATH would pin it to this machine.
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# a fresh data dir each run, so a stale one can never be what made this pass
export ANDROID_APP_DATA_DIR="$PORT_OUT/smoke-data"
rm -rf "$ANDROID_APP_DATA_DIR"
mkdir -p "$ANDROID_APP_DATA_DIR"

run_launcher() {
	"$launcher" \
		--api-impl-jar "$ATLAS_API_IMPL_JAR" \
		--framework-res "$ATLAS_FRAMEWORK_RES" \
		--natives-dir "$ATLAS_NATIVES_DIR" \
		--classpath "$PORT_OUT/shim.jar:$PORT_OUT/classpath/*" \
		--library-path "$PORT_OUT" \
		-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
		--smoke-test "$seconds" \
		"$PORT_OUT/app.apk"
}

screenshot() {
	if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v grim >/dev/null; then
		grim "$shots/launcher-smoke.png" && return 0
	elif [ -n "${DISPLAY:-}" ] && command -v import >/dev/null; then
		import -window root "$shots/launcher-smoke.png" && return 0
	fi
	echo "note: no screenshot tool for this session, skipping the screenshot"
	return 0
}

# A session of our own when there is none: the point is the window, so a
# headless run still has to have somewhere to put it.
xvfb_pid=""
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
	command -v Xvfb >/dev/null || { echo "no display and no Xvfb to make one" >&2; exit 1; }
	for display in $(seq 90 99); do
		Xvfb ":$display" -screen 0 960x540x24 >/dev/null 2>&1 &
		xvfb_pid=$!
		sleep 1
		if kill -0 "$xvfb_pid" 2>/dev/null; then
			export DISPLAY=":$display"
			break
		fi
		xvfb_pid=""
	done
	[ -n "$xvfb_pid" ] || { echo "could not start Xvfb" >&2; exit 1; }
	trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT
	echo "started Xvfb on $DISPLAY"
fi

echo "running the launcher for ${seconds}s, log in $log"
status=0
run_launcher >"$log" 2>&1 &
launcher_pid=$!
sleep $((seconds > 2 ? seconds - 2 : 1))
screenshot
wait "$launcher_pid" || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -30 "$log" >&2
	exit 1
}

for expected in \
	"JVM launched successfully" \
	"libtranslation_layer_main.so" \
	"ATLWindow: GLFW platform" \
	"SystemClock.uptimeMillis() resolved" \
	"smoke test: passed"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2; exit 1; }
done

# a JVM crash log means the process died in native code, whatever the exit status
if grep -qF "A fatal error has been detected" <<<"$log_text"; then
	echo "the JVM crashed:" >&2
	grep -A 10 "A fatal error has been detected" <<<"$log_text" >&2
	exit 1
fi

width=$(sed -n 's/^smoke test: window is \([0-9]*\)px wide$/\1/p' <<<"$log_text")
[ -n "$width" ] && [ "$width" -gt 0 ] || { echo "the window never got a size" >&2; exit 1; }

echo "smoke test passed: JVM booted, translation layer loaded, ${width}px window, clean exit"
[ -f "$shots/launcher-smoke.png" ] && echo "screenshot: $shots/launcher-smoke.png"
exit 0
