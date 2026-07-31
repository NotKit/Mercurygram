#!/bin/bash
# Runs Mercurygram on the HotSpot launcher.
#
# Same launcher and class path as check-native-loader.sh, but with the real boot
# sequence: Context.createApplication -> ContentProvider.createContentProviders
# -> Application.onCreate -> Activity.createMainActivity -> GLib main loop.
#
# Usage: linux-port/run.sh [--seconds N] [--stop-file PATH] [--data-dir DIR]
#                          [--fresh] [--gpu] [-- ARGS...]
#   --seconds N   quit after N seconds and check run.log (0 = run until closed)
#   --stop-file   with --seconds, quit as soon as this file appears; the timeout
#                 becomes the maximum. Lets a driving script end the run when it
#                 is done instead of waiting out a worst-case timeout.
#   --data-dir    app data dir; default out/data, kept between runs
#   --fresh       wipe the data dir first (a first-launch run)
#   --gpu         leave ATL_NO_GPU unset (see BRINGUP_NOTES.md: Ganesh crashes
#                 in skia's GL interface assembly, so CPU raster is the default)
# Anything after -- is passed straight to the launcher.
#
# Writes out/run.log and, with --seconds, out/screenshots/run.png.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

seconds=0
stop_file=""
data_dir="${ANDROID_APP_DATA_DIR:-$PORT_OUT/data}"
fresh=0
gpu=0
extra_args=()

while [ $# -gt 0 ]; do
	case "$1" in
	--seconds) seconds="$2"; shift 2 ;;
	--stop-file) stop_file="$2"; shift 2 ;;
	--data-dir) data_dir="$2"; shift 2 ;;
	--fresh) fresh=1; shift ;;
	--gpu) gpu=1; shift ;;
	--) shift; extra_args=("$@"); break ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

launcher="$ATLAS_OUT/android-translation-layer-hotspot"
native_lib="$PORT_OUT/libtmessages.so"
log="$PORT_OUT/run.log"
shots="$PORT_OUT/screenshots"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$native_lib" ] || { echo "no $native_lib (run native/build_tmessages_linux.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

mkdir -p "$shots"
[ "$fresh" = 1 ] && rm -rf "$data_dir"
mkdir -p "$data_dir"
export ANDROID_APP_DATA_DIR="$data_dir"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# CPU raster: atlas's Ganesh path dies in skia's GrGLExtensions::init before it
# ever returns a context, on llvmpipe and on hardware GL alike. --gpu to retry.
[ "$gpu" = 1 ] || export ATL_NO_GPU=1

# liblog drops anything below INFO by default, which is most of the app's own
# logging (FileLog.d). With this, run.log is the whole picture instead of just
# tgnet's native lines plus the app's separate files/logs/ files.
export ANDROID_LOG_TAGS="${ANDROID_LOG_TAGS:-*:V}"

port_start_display

run_launcher() {
	# exec, so that backgrounding this function gives $! the launcher's own pid
	# and not that of the subshell wrapping it -- a kill aimed at the subshell
	# leaves the launcher running until something else notices.
	exec "$launcher" \
		--api-impl-jar "$ATLAS_API_IMPL_JAR" \
		--framework-res "$ATLAS_FRAMEWORK_RES" \
		--natives-dir "$ATLAS_NATIVES_DIR" \
		--classpath "$PORT_OUT/shim.jar:$PORT_OUT/classpath/*" \
		--library-path "$PORT_OUT" \
		--launch-activity org.telegram.ui.LaunchActivity \
		-X "-Dtmessages.native.path=$native_lib" \
		-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
		"${extra_args[@]}" \
		"$PORT_OUT/app.apk"
}

# Interactive run: no timeout, no checks, the window is the output.
if [ "$seconds" = 0 ]; then
	echo "running Mercurygram, log in $log (close the window to quit)"
	run_launcher 2>&1 | tee "$log"
	exit "${PIPESTATUS[0]}"
fi

if [ -n "$stop_file" ]; then
	rm -f "$stop_file"
	echo "running Mercurygram for up to ${seconds}s (until $stop_file), log in $log"
else
	echo "running Mercurygram for ${seconds}s, log in $log"
fi
status=0
started_marker="$PORT_OUT/.run-started"
touch "$started_marker"
run_launcher >"$log" 2>&1 &
launcher_pid=$!

# The screenshot is the last thing before the kill, so the UI has had the whole
# run to draw.
waited=0
while [ "$waited" -lt "$((seconds * 2))" ]; do
	[ -n "$stop_file" ] && [ -e "$stop_file" ] && break
	kill -0 "$launcher_pid" 2>/dev/null || break
	sleep 0.5
	waited=$((waited + 1))
done
port_screenshot "$shots/run.png"
# SIGTERM first, but do not leave a launcher behind if it ignores it: the next
# build would fail to overwrite the running binary.
kill "$launcher_pid" 2>/dev/null || true
for _ in $(seq 20); do
	kill -0 "$launcher_pid" 2>/dev/null || break
	sleep 0.5
done
kill -9 "$launcher_pid" 2>/dev/null || true
# 2>/dev/null: bash announces the killed job here, which is not news
wait "$launcher_pid" 2>/dev/null || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

# The kill above is how a timed run ends: 143 if SIGTERM took, 137 when it did
# not and the SIGKILL had to (see BRINGUP_NOTES.md -- the launcher does not
# currently stop on SIGTERM). Anything else is a real exit status.
if [ "$status" != 0 ] && [ "$status" != 143 ] && [ "$status" != 137 ]; then
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
fi

for expected in \
	"JVM launched successfully" \
	"boot: Application.onCreate returned" \
	"boot: main activity started"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2
		tail -40 "$log" >&2
		exit 1
	}
done

if grep -qF "A fatal error has been detected" <<<"$log_text"; then
	echo "the JVM crashed:" >&2
	grep -A 10 "A fatal error has been detected" <<<"$log_text" >&2
	exit 1
fi

# An uncaught exception on the main looper is not fatal to the process, so the
# log is the only place it shows. atlas prints them as "uncaught exception".
uncaught=$(grep -cE '^(error: exception during|Exception in thread|uncaught exception)' <<<"$log_text" || true)
[ "$uncaught" = 0 ] || {
	echo "$uncaught uncaught exceptions in $log:" >&2
	grep -E -A 12 '^(error: exception during|Exception in thread|uncaught exception)' <<<"$log_text" | head -60 >&2
	exit 1
}

# The app's own verdict. BuildVars installs an uncaught-exception handler that
# writes FATAL and, on this DEBUG_PRIVATE_VERSION build, calls System.exit(2) --
# which the launcher hangs in, leaving a dead JVM with its window still up. That
# looks like a frozen app here and like nothing at all in run.log, so the check
# is the app's log file.
mapfile -t app_logs < <(find "$data_dir" -path '*/files/logs/*.txt' -newer "$started_marker" \
	! -name '*_net.txt' ! -name '*_mtproto.txt' 2>/dev/null)
if [ "${#app_logs[@]}" -gt 0 ] && grep -q 'FATAL/tmessages' "${app_logs[@]}"; then
	echo "the app hit a fatal exception (and killed itself):" >&2
	grep -h -A 12 'FATAL/tmessages' "${app_logs[@]}" | head -30 >&2
	exit 1
fi

echo "run ok: booted to the main activity, no uncaught exceptions in $((waited / 2))s"
[ -f "$shots/run.png" ] && echo "screenshot: $shots/run.png"
exit 0
