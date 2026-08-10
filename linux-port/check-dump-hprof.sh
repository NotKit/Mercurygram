#!/bin/bash
# Verification: android.os.Debug.dumpHprofData exists and fails catchably.
#
# FileLog.dumpMemory() calls it inside `catch (Exception)`. While atlas had no
# such method the call raised NoSuchMethodError, which that catch cannot catch,
# and the port carried an uncommitted widening to `catch (Throwable)` in
# org/telegram/** instead of a framework fix (FR-1a).
#
# Compiles tools/DumpHprofCheck.java and runs it inside the launcher
# (--run-class), which is the cheapest way to run one piece of the framework.
# It also greps the built app jar for the call site, so the check fails if the
# app stops being the reason this stub exists.
#
# Optional: -- <extra launcher args>.
#
# Writes out/run.log. Usage: linux-port/check-dump-hprof.sh [-- LAUNCHER ARGS]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

extra_args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--) shift; extra_args=("$@"); break ;;
	*) echo "usage: check-dump-hprof.sh [-- LAUNCHER ARGS]" >&2; exit 2 ;;
	esac
done

launcher="$ATLAS_OUT/android-translation-layer-hotspot"
tools_out="$PORT_OUT/tools"
app_jar="$PORT_OUT/classpath/TMessagesProj.jar"
log="$PORT_OUT/run.log"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
[ -f "$app_jar" ] || { echo "no $app_jar (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

# --- the call site this stub exists for ------------------------------------

echo "checking the app's own call site in $(basename "$app_jar")"
work="$PORT_OUT/dump-hprof-check"
rm -rf "$work"
mkdir -p "$work"
(cd "$work" && "$JAVA_HOME/bin/jar" -xf "$app_jar" org/telegram/messenger/FileLog.class)
filelog_refs=$("$JAVA_HOME/bin/javap" -p -c "$work/org/telegram/messenger/FileLog.class")
dump_memory=$(awk '/^  public void dumpMemory\(boolean\);/ {f=1} f {print} f && /^$/ {exit}' \
	<<<"$filelog_refs")

if [ -z "$dump_memory" ]; then
	echo "javap shows no 'public void dumpMemory(boolean)' in FileLog" >&2; exit 1
fi
if ! grep -qF 'android/os/Debug.dumpHprofData:(Ljava/lang/String;)V' <<<"$dump_memory"; then
	echo "FileLog.dumpMemory no longer calls android.os.Debug.dumpHprofData(String)" >&2; exit 1
fi
# FR-7: the app must carry no workaround for this; the catch is upstream's
if grep -qF 'Class java/lang/Throwable' <<<"$dump_memory"; then
	echo "FileLog.dumpMemory catches Throwable: the app-side workaround is back" >&2; exit 1
fi
if ! grep -qF 'Class java/lang/Exception' <<<"$dump_memory"; then
	echo "FileLog.dumpMemory has no 'catch (Exception)' handler" >&2; exit 1
fi
echo "call site: FileLog.dumpMemory invokes android/os/Debug.dumpHprofData(Ljava/lang/String;)V"
echo "           inside a catch (Exception) handler, as upstream wrote it"

# --- the framework side, in the launcher ------------------------------------

echo "compiling DumpHprofCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" \
	-cp "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar" \
	"$PORT_DIR/tools/DumpHprofCheck.java"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ANDROID_APP_DATA_DIR="$PORT_OUT/dump-hprof-data"
rm -rf "$ANDROID_APP_DATA_DIR"
mkdir -p "$ANDROID_APP_DATA_DIR"

port_start_display

echo "running the check in the launcher, log in $log"
status=0
timeout 120 "$launcher" \
	--api-impl-jar "$ATLAS_API_IMPL_JAR" \
	--framework-res "$ATLAS_FRAMEWORK_RES" \
	--natives-dir "$ATLAS_NATIVES_DIR" \
	--classpath "$PORT_OUT/shim.jar:$tools_out" \
	-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
	"${extra_args[@]}" \
	--run-class DumpHprofCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

for expected in \
	"signature: " \
	"dump-hprof check: passed"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2; exit 1; }
done

if grep -q "NoSuchMethodError" <<<"$log_text"; then
	echo "run.log still reports a NoSuchMethodError" >&2; exit 1
fi

echo "dump-hprof check passed: the framework answers Debug.dumpHprofData, app-side catch (Exception) is enough"
exit 0
