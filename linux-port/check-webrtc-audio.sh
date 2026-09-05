#!/bin/bash
# Checks android.media is honest enough for org.webrtc's Java audio device.
#
# webrtc builds a 48 kHz mono 16-bit AudioTrack through AudioTrack.Builder,
# writes 10 ms direct ByteBuffers with WRITE_BLOCKING and calls a short write a
# fatal error; it builds an AudioRecord the same way. Both bail out unless
# getState() is STATE_INITIALIZED, so tools/WebRtcAudioCheck.java asserts the
# accessors either way — on a machine with no ALSA device it asserts the failure
# path (STATE_UNINITIALIZED, no exception) instead of the playing one. Runs in
# the launcher (--run-class), so it needs no boot, but atlas opens a window on
# start and therefore needs a display.
#
# PORT_ALSA_NULL=1 points ALSA at a null "default" device (and enables capture),
# so the playing and reading paths can be exercised on a machine with no sound
# card. That proves the writes, not the audio.
#
# Optional: -- <extra launcher args>.
#
# Writes out/run.log. Usage: linux-port/check-webrtc-audio.sh [-- LAUNCHER ARGS]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

extra_args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--) shift; extra_args=("$@"); break ;;
	*) echo "usage: check-webrtc-audio.sh [-- LAUNCHER ARGS]" >&2; exit 2 ;;
	esac
done

# the HotSpot launcher by name: this drives it with a class path, which an image
# has no notion of
launcher="$ATLAS_OUT/android-translation-layer-hotspot"
tools_out="$PORT_OUT/tools"
log="$PORT_OUT/run.log"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

echo "compiling WebRtcAudioCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" \
	-cp "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar" \
	"$PORT_DIR/tools/WebRtcAudioCheck.java"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ "${PORT_ALSA_NULL:-0}" = 1 ]; then
	alsa_conf="$PORT_OUT/alsa-null.conf"
	cat >"$alsa_conf" <<-EOF
	</usr/share/alsa/alsa.conf>

	pcm.!default {
		type null
	}

	ctl.!default {
		type null
	}
	EOF
	export ALSA_CONFIG_PATH="$alsa_conf"
	export ATL_UGLY_ENABLE_MICROPHONE=1
	echo "using a null ALSA device ($alsa_conf)"
fi

port_start_display

echo "running the check in the launcher, log in $log"
status=0
timeout 120 "$launcher" \
	--api-impl-jar "$ATLAS_API_IMPL_JAR" \
	--framework-res "$ATLAS_FRAMEWORK_RES" \
	--natives-dir "$ATLAS_NATIVES_DIR" \
	--classpath "$PORT_OUT/shim.jar:$PORT_OUT/classpath/*:$tools_out" \
	-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
	"${extra_args[@]}" \
	--run-class WebRtcAudioCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")
grep -E '^(AudioManager: |AudioTrack: |AudioRecord: |audiofx: |FAIL: )' <<<"$log_text" || true

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

grep -qF "webrtc audio check: passed" <<<"$log_text" || {
	echo "run.log has no 'webrtc audio check: passed'" >&2; exit 1; }

echo "webrtc audio check: passed"
