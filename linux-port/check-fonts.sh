#!/bin/bash
# Checks that the generic font families resolve to the bundled Roboto.
#
# The port built sans-serif from whatever the host's fontconfig substituted --
# Noto Sans on this desktop, Ubuntu on the phone, never Roboto. Same textSize,
# different metrics: Noto's line box is 1.362 em against Roboto's 1.172, so every
# line ran ~16% tall and text measured wider than on Android (BRINGUP_NOTES.md).
# atlas now ships res/fonts/ and TypefaceCollection.cpp builds those families
# from it. Runs tools/FontMetricsCheck.java inside the launcher (--run-class), so
# it needs no boot -- but atlas opens a window on start, so it needs a display.
#
# Optional: -- <extra launcher args>.
#
# Writes out/run.log. Usage: linux-port/check-fonts.sh [-- LAUNCHER ARGS]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

extra_args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--) shift; extra_args=("$@"); break ;;
	*) echo "usage: check-fonts.sh [-- LAUNCHER ARGS]" >&2; exit 2 ;;
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

# name the faces before the run: without them the framework falls back to
# fontconfig and the check fails for a reason the metrics alone do not say
faces=$(ls "${ATLAS_FONTS_DIR:-$ATLAS_OUT/system/fonts}"/Roboto-*.ttf 2>/dev/null | wc -l)
echo "bundled faces in ${ATLAS_FONTS_DIR:-$ATLAS_OUT/system/fonts}: $faces"

echo "compiling FontMetricsCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" \
	-cp "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar" \
	"$PORT_DIR/tools/FontMetricsCheck.java"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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
	--run-class FontMetricsCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")
grep -E '^(no typeface|default|sans-serif|DEFAULT_BOLD|widths:|  *expected)' <<<"$log_text" || true

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

grep -qF "font metrics check: passed" <<<"$log_text" || {
	echo "run.log has no 'font metrics check: passed'" >&2; exit 1; }

echo "font check: passed"
