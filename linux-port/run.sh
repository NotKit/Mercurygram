#!/bin/bash
# Runs Mercurygram on the HotSpot launcher.
#
# Same launcher and class path as check-native-loader.sh, but with the real boot
# sequence: Context.createApplication -> ContentProvider.createContentProviders
# -> Application.onCreate -> Activity.createMainActivity -> GLib main loop.
#
# Usage: linux-port/run.sh [--seconds N] [--stop-file PATH] [--data-dir DIR]
#                          [--fresh] [--gpu] [--tl-dump] [--image] [-- ARGS...]
#   --image       run the image-backed launcher against $PORT_IMAGE_LIB instead
#                 of the HotSpot one. $PORT_LAUNCHER=image does the
#                 same, which is how check-*.sh select it without an edit.
#   --seconds N   quit after N seconds and check run.log (0 = run until closed)
#   --stop-file   with --seconds, quit as soon as this file appears; the timeout
#                 becomes the maximum. Lets a driving script end the run when it
#                 is done instead of waiting out a worst-case timeout.
#   --data-dir    app data dir; default out/data, kept between runs
#   --fresh       wipe the data dir first (a first-launch run)
#   --gpu         leave ATL_NO_GPU unset (see BRINGUP_NOTES.md: Ganesh crashes
#                 in skia's GL interface assembly, so CPU raster is the default)
#   --tl-dump     leave FileLog's TL dumper on (off by default here, see below).
#                 Never pass it while tracing metadata.
# Anything after -- is passed straight to the launcher.
#
# $PORT_EXTRA_JVM_ARGS is a whitespace-separated list of JVM options, each passed
# on as one `-X OPTION` (the launcher's --extra-jvm-option, one option per flag).
# It is how a driving script that does not forward `-- ARGS` -- check-*.sh -- gets
# an option in, e.g. PORT_EXTRA_JVM_ARGS="-agentlib:native-image-agent=..." for
# trace-metadata.sh. Unset means no extra options at all. Any whitespace
# separates, newlines included. An option containing a space cannot be passed this
# way -- a word that does not start with '-' is refused rather than mangled; use
# `-- -X "OPTION"`. A timed run also fails if an option never reached the VM.
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
tl_dump=0
image=0
[ "${PORT_LAUNCHER:-hotspot}" != image ] || image=1
extra_args=()

while [ $# -gt 0 ]; do
	case "$1" in
	--image) image=1; shift ;;
	--seconds) seconds="$2"; shift 2 ;;
	--stop-file) stop_file="$2"; shift 2 ;;
	--data-dir) data_dir="$2"; shift 2 ;;
	--fresh) fresh=1; shift ;;
	--gpu) gpu=1; shift ;;
	--tl-dump) tl_dump=1; shift ;;
	--) shift; extra_args=("$@"); break ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

# Empty (not unset) expands to zero words under -u, so the -X pairs below are
# simply absent when nothing asked for one. `-d ''` reads to NUL instead of to
# the first newline: a plain `read -ra` stops at one, and a variable written over
# two lines would lose everything after the first silently.
read -ra extra_jvm_args -d '' <<<"${PORT_EXTRA_JVM_ARGS:-}" || true
extra_jvm_opts=()
for opt in ${extra_jvm_args[@]+"${extra_jvm_args[@]}"}; do
	# Every JVM option starts with '-'. A word that does not is the visible half
	# of an option that was split on its own space, which would otherwise reach
	# the launcher as a broken option pair or be ignored.
	case "$opt" in
	-*) ;;
	*) echo "PORT_EXTRA_JVM_ARGS: '$opt' is not a JVM option; options cannot" \
		"contain spaces here, pass them as -- -X \"OPTION\"" >&2; exit 1 ;;
	esac
	extra_jvm_opts+=(-X "$opt")
done
[ "${#extra_jvm_opts[@]}" = 0 ] ||
	echo "extra JVM options from \$PORT_EXTRA_JVM_ARGS: ${extra_jvm_args[*]}"

# --image is $PORT_LAUNCHER=image for one run; the name is never defaulted back
# to hotspot, so a mistyped $PORT_LAUNCHER fails the -x check below instead of
# running the other launcher and proving nothing
[ "$image" = 0 ] || PORT_LAUNCHER=image
launcher="$ATLAS_OUT/android-translation-layer-$PORT_LAUNCHER"
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

if [ "$image" = 1 ]; then
	# no $JAVA_HOME/lib/server on purpose: nothing in this process may be able to
	# find a HotSpot libjvm.so even by accident, which is half of the
	# "no libjvm.so in the process" evidence
	export LD_LIBRARY_PATH="$(dirname "$PORT_IMAGE_LIB"):$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
	# libjvm.so is deliberately not in the launcher's RUNPATH
	export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# CPU raster: atlas's Ganesh path dies in skia's GrGLExtensions::init before it
# ever returns a context, on llvmpipe and on hardware GL alike. --gpu to retry.
[ "$gpu" = 1 ] || export ATL_NO_GPU=1

# liblog drops anything below INFO by default, which is most of the app's own
# logging (FileLog.d). With this, run.log is the whole picture instead of just
# tgnet's native lines plus the app's separate files/logs/ files.
export ANDROID_LOG_TAGS="${ANDROID_LOG_TAGS:-*:V}"

# FileLog's TL dumper serializes every request and update with Gson, which is
# most of run.log and most of the reflection an ahead-of-time image would have to
# declare. Off here; --tl-dump brings the JSON back for MTProto
# debugging, and must never be used while tracing metadata.
tl_dump_opts=()
[ "$tl_dump" = 1 ] || tl_dump_opts=(-X "-Dtmessages.tldump=0")

# -XX:ErrorFile is the one option in this set an image rejects, and an image
# writes no hs_err file for it to name anyway. A rejected option aborts VM
# creation with no diagnostic at all, so it is gated rather than left to luck.
launcher_opts=()
if [ "$image" = 1 ]; then
	[ -f "$PORT_IMAGE_LIB" ] ||
		{ echo "no image at $PORT_IMAGE_LIB (run build-image.sh)" >&2; exit 1; }
	launcher_opts=(--vm-library "$PORT_IMAGE_LIB")
	echo "running the image-backed launcher against $PORT_IMAGE_LIB"
else
	launcher_opts=(-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log")
fi

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
		"${launcher_opts[@]}" \
		${tl_dump_opts[@]+"${tl_dump_opts[@]}"} \
		${extra_jvm_opts[@]+"${extra_jvm_opts[@]}"} \
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
launcher_maps=""
while [ "$waited" -lt "$((seconds * 2))" ]; do
	[ -n "$stop_file" ] && [ -e "$stop_file" ] && break
	# What the process actually has mapped: ldd on the launcher cannot see a
	# dlopened image, and it is the third piece of that evidence. Taken during the run
	# and kept, because /proc/<pid>/maps is gone the moment the launcher exits --
	# read only after the loop, a run that ends early would leave the check with
	# nothing and silently skip it.
	if [ "$image" = 1 ] && ! grep -qF "$PORT_IMAGE_LIB" <<<"$launcher_maps"; then
		launcher_maps=$(cat "/proc/$launcher_pid/maps" 2>/dev/null || echo "$launcher_maps")
	fi
	kill -0 "$launcher_pid" 2>/dev/null || break
	sleep 0.5
	waited=$((waited + 1))
done
maps_now=$(cat "/proc/$launcher_pid/maps" 2>/dev/null || true)
[ -z "$maps_now" ] || launcher_maps="$maps_now"
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

# The launcher echoes every option it hands to JNI_CreateJavaVM. A requested
# option that is not there was dropped somewhere between here and the VM (a
# mis-split variable, an option the launcher rejected), and for the tracing agent
# that means a run that traces nothing while still exiting 0.
for opt in ${extra_jvm_args[@]+"${extra_jvm_args[@]}"}; do
	grep -qF "jvm option: $opt" <<<"$log_text" || {
		echo "the JVM never got '$opt' from \$PORT_EXTRA_JVM_ARGS" >&2
		grep -F 'jvm option:' <<<"$log_text" | tail -20 >&2
		exit 1
	}
done

expected_lines=(
	"JVM launched successfully"
	"boot: Application.onCreate returned"
	"boot: main activity started"
)
# On the image path, which .so provided the VM and whether the properties
# crossed into Java are the two things that cannot be taken on trust.
[ "$image" = 0 ] || expected_lines+=(
	"image: opened $PORT_IMAGE_LIB"
	"vm property: atl.apk.path=$PORT_OUT/app.apk"
)
for expected in "${expected_lines[@]}"; do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2
		tail -40 "$log" >&2
		exit 1
	}
done

if [ "$image" = 1 ]; then
	# never "no maps, so nothing to check": that is how an assertion stops
	# running without anyone noticing (FR-8)
	[ -n "$launcher_maps" ] || {
		echo "could not read /proc/$launcher_pid/maps at any point in the run," \
		     "so the no-libjvm.so evidence is missing" >&2
		exit 1
	}
	if grep -q "libjvm\.so" <<<"$launcher_maps"; then
		echo "the image run had libjvm.so mapped:" >&2
		grep "libjvm\.so" <<<"$launcher_maps" >&2
		exit 1
	fi
	grep -qF "$PORT_IMAGE_LIB" <<<"$launcher_maps" || {
		echo "$PORT_IMAGE_LIB was never mapped into the launcher process" >&2
		exit 1
	}
	echo "maps: $PORT_IMAGE_LIB mapped, no libjvm.so"
fi

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
