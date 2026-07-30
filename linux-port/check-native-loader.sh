#!/bin/bash
# Checks that NativeLoader loads the port's glibc libtmessages.so.
#
# Compiles tools/NativeLoaderCheck.java against the port class path and runs it
# inside the launcher (--run-class), with -Dtmessages.native.path set to the
# library built by native/build_tmessages_linux.sh. The check calls
# NativeLoader.initNativeLibs(null) and then one method from each JNI lookup
# path, so a pass means JNI_OnLoad ran and registered everything.
#
# Writes out/run.log. Usage: linux-port/check-native-loader.sh
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

launcher="$ATLAS_OUT/android-translation-layer-hotspot"
native_lib="$PORT_OUT/libtmessages.so"
tools_out="$PORT_OUT/tools"
log="$PORT_OUT/run.log"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$native_lib" ] || { echo "no $native_lib (run native/build_tmessages_linux.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

class_path="$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar:$PORT_OUT/classpath/*"

echo "compiling NativeLoaderCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" -cp "$class_path" \
	"$PORT_DIR/tools/NativeLoaderCheck.java"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# a fresh data dir, so nothing left by an earlier run can be what made this pass
export ANDROID_APP_DATA_DIR="$PORT_OUT/native-loader-data"
rm -rf "$ANDROID_APP_DATA_DIR"
mkdir -p "$ANDROID_APP_DATA_DIR"

port_start_display

echo "running the check in the launcher, log in $log"
status=0
timeout 120 "$launcher" \
	--api-impl-jar "$ATLAS_API_IMPL_JAR" \
	--framework-res "$ATLAS_FRAMEWORK_RES" \
	--natives-dir "$ATLAS_NATIVES_DIR" \
	--classpath "$PORT_OUT/shim.jar:$PORT_OUT/classpath/*:$tools_out" \
	--library-path "$PORT_OUT" \
	-X "-Dtmessages.native.path=$native_lib" \
	-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
	--run-class NativeLoaderCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

for expected in \
	"NativeLoader.initNativeLibs loaded $native_lib" \
	"JNI_OnLoad succeeded" \
	"statically named entry points resolve" \
	"native loader check: passed"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2; exit 1; }
done

if grep -qF "A fatal error has been detected" <<<"$log_text"; then
	echo "the JVM crashed:" >&2
	grep -A 10 "A fatal error has been detected" <<<"$log_text" >&2
	exit 1
fi

# the apk-extraction path must not have run at all: it would mean the hook was
# skipped and an Android .so got unpacked somewhere
extracted=$(find "$ANDROID_APP_DATA_DIR" -name 'libtmessages.*.so' -print -quit)
[ -z "$extracted" ] || {
	echo "an apk-extracted library appeared at $extracted: the escape hatch did not take" >&2
	exit 1; }

echo "native loader check passed: $native_lib loaded through -Dtmessages.native.path"
exit 0
