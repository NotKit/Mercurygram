#!/bin/bash
# Checks that the tgcalls/webrtc JNI bridge works in the port.
#
# jni/voip/ is built into libtmessages.so here (native/voip.cmake), so this
# runs the real bridge rather than the old no-op stub: it loads the library,
# reads the versions out of tgcalls and calls a method libtgvoip registers
# from tgvoipOnJNILoad. Making a call instance needs an application context,
# so that half is covered by a boot. Runs tools/VoipInstanceCheck.java inside
# the launcher (--run-class), so it needs no boot — but atlas opens a window
# on start, so it needs a display.
#
# Optional: -- <extra launcher args>.
#
# Writes out/run.log. Usage: linux-port/check-voip-instance.sh [-- LAUNCHER ARGS]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

extra_args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--) shift; extra_args=("$@"); break ;;
	*) echo "usage: check-voip-instance.sh [-- LAUNCHER ARGS]" >&2; exit 2 ;;
	esac
done

launcher="$ATLAS_OUT/android-translation-layer-hotspot"
tools_out="$PORT_OUT/tools"
log="$PORT_OUT/run.log"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

echo "compiling VoipInstanceCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" \
	-cp "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar:$(echo "$PORT_OUT"/classpath/*.jar | tr ' ' ':')" \
	"$PORT_DIR/tools/VoipInstanceCheck.java"

export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# The microphone gate is what the audio device module needs; the camera one is
# for the capturer (click/run.sh sets both on the device).
export ATL_UGLY_ENABLE_MICROPHONE=1
export ATL_UGLY_ENABLE_CAMERA="${ATL_UGLY_ENABLE_CAMERA:-1}"

port_start_display

echo "running the check in the launcher, log in $log"
status=0
timeout 180 "$launcher" \
	--api-impl-jar "$ATLAS_API_IMPL_JAR" \
	--framework-res "$ATLAS_FRAMEWORK_RES" \
	--natives-dir "$ATLAS_NATIVES_DIR" \
	--classpath "$PORT_OUT/shim.jar:$PORT_OUT/classpath/*:$tools_out" \
	-X "-Dtmessages.native.path=$PORT_OUT/libtmessages.so" \
	-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
	"${extra_args[@]}" \
	--run-class VoipInstanceCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")
grep -E '^(library loaded|tgcalls versions: |libtgvoip |FAIL: )' <<<"$log_text" || true

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

grep -qF "voip instance check: passed" <<<"$log_text" || {
	echo "run.log has no 'voip instance check: passed'" >&2; exit 1; }

echo "voip instance check: passed"
