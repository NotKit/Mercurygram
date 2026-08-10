#!/bin/bash
# Checks that AssetManager.extractFromAPK reads the apk, not the class path.
#
# Compiles tools/ExtractFromApkCheck.java and runs it inside the launcher
# (--run-class) against a fresh data dir, so the mtime guard cannot hide a copy
# that never happened. The check asserts the three behaviours callers depend on:
# real apk bytes for an entry that exists, a silent no-op for one that does not,
# and a working directory branch. It also holds the line the phase 1-2 review
# drew: a miss (including an apk that cannot be opened at all) must neither throw
# into the exception-blind native caller nor re-parse a central directory.
#
# Optional: -- <extra launcher args>, e.g. -X "-agentlib:native-image-agent=..."
# to record what the extraction reaches for.
#
# Writes out/run.log. Usage: linux-port/check-extract-apk.sh [-- LAUNCHER ARGS]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

extra_args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--) shift; extra_args=("$@"); break ;;
	*) echo "usage: check-extract-apk.sh [-- LAUNCHER ARGS]" >&2; exit 2 ;;
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

echo "compiling ExtractFromApkCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" \
	-cp "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar" \
	"$PORT_DIR/tools/ExtractFromApkCheck.java"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# a fresh data dir: the extraction is guarded by an mtime check, so a leftover
# file from an earlier run would make the whole check vacuous
export ANDROID_APP_DATA_DIR="$PORT_OUT/extract-apk-data"
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
	-X "-Dcheck.apk=$PORT_OUT/app.apk" \
	-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
	"${extra_args[@]}" \
	--run-class ExtractFromApkCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

for expected in \
	"single file: res/drawable-mdpi-v4/notification.webp extracted" \
	"missing entry: 'sound_in' threw nothing and created nothing" \
	"directory: " \
	"framework resource: res/drawable-mdpi-v4/stat_sys_upload_anim0.png extracted from framework-res.apk" \
	"unreadable apk: '/nonexistent/no-such.apk' threw nothing and created nothing" \
	"misses: " \
	"extract-from-apk check: passed"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2; exit 1; }
done

echo "extract-from-apk check passed: apk content came from the apk, not the class path"
exit 0
