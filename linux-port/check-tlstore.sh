#!/bin/bash
# FR-4 coverage: every arm of TLClassStore can be instantiated reflectively.
#
# TLClassStore.TLdeserialize (TLClassStore.java:58) does `objClass.newInstance()`
# over a SparseArray of 20 constructor ids -- updates, secret-chat messages,
# TL_error, TL_null. A traced run only ever registers the arms the server
# happened to send (the four-check trace found two of them), and in an image a
# class with no metadata fails newInstance(), gets swallowed by that method's
# `catch (Throwable)` and returns null: a silently dropped update. So take every
# arm on purpose instead of hand-editing reflect-config.json.
#
# Two ends, like check-dump-hprof.sh: the class list is read out of the built
# jar's own bytecode (so it cannot drift from what the store holds), and the
# instantiation runs inside the launcher (--run-class), where a trace records it.
#
# Optional: -- <extra launcher args>, e.g. -X "-agentlib:native-image-agent=..."
# to record the arms into a config. trace-metadata.sh does exactly that.
#
# Writes out/run.log. Usage: linux-port/check-tlstore.sh [-- LAUNCHER ARGS]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

extra_args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--) shift; extra_args=("$@"); break ;;
	*) echo "usage: check-tlstore.sh [-- LAUNCHER ARGS]" >&2; exit 2 ;;
	esac
done

# the HotSpot launcher by name, not $PORT_LAUNCHER_BIN: this one drives the
# launcher directly with a class path, which an image has no notion of
launcher="$ATLAS_OUT/android-translation-layer-hotspot"
tools_out="$PORT_OUT/tools"
app_jar="$PORT_OUT/classpath/TMessagesProj.jar"
log="$PORT_OUT/run.log"

[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
[ -f "$app_jar" ] || { echo "no $app_jar (run build-classpath.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

# --- the arms, out of the store's own bytecode ------------------------------
# javac folds `TLRPC.TL_x.constructor` into an int, so the constructor's code is
# a run of `ldc <int>; ldc <class literal>; SparseArray.put`. The class literals
# are the list; reading them here is what keeps this check in step with a
# TLClassStore that upstream adds an arm to.

echo "reading the store's arms out of $(basename "$app_jar")"
work="$PORT_OUT/tlstore-check"
rm -rf "$work"
mkdir -p "$work"
(cd "$work" && "$JAVA_HOME/bin/jar" -xf "$app_jar" org/telegram/tgnet/TLClassStore.class)
disasm=$("$JAVA_HOME/bin/javap" -p -c "$work/org/telegram/tgnet/TLClassStore.class")
ctor=$(awk '/^  public org.telegram.tgnet.TLClassStore\(\);/ {f=1} f {print} f && /^$/ {exit}' \
	<<<"$disasm")
[ -n "$ctor" ] || { echo "javap shows no TLClassStore() constructor" >&2; exit 1; }

puts=$(grep -cE 'Method android/util/SparseArray\.put' <<<"$ctor" || true)
literals=$(grep -cE '// class org/telegram/tgnet/' <<<"$ctor" || true)
[ "$puts" -gt 0 ] || { echo "TLClassStore() has no SparseArray.put calls" >&2; exit 1; }
# One class literal per entry, or the extraction below missed some arm.
[ "$puts" = "$literals" ] || {
	echo "TLClassStore() has $puts entries but $literals TLRPC class literals" >&2
	echo "(the store's shape changed; check-tlstore.sh reads it from bytecode)" >&2
	exit 1; }

classes=$(grep -oE '// class org/telegram/tgnet/[A-Za-z0-9_$]+' <<<"$ctor" \
	| sed 's|// class ||; s|/|.|g' | sort -u)
n_classes=$(grep -c . <<<"$classes")
class_list=$(paste -sd, <<<"$classes")
echo "store: $puts entries, $n_classes distinct classes"

# --- instantiate them inside the launcher -----------------------------------

echo "compiling TLClassStoreCheck"
mkdir -p "$tools_out"
"$JAVA_HOME/bin/javac" -nowarn -d "$tools_out" \
	-cp "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar:$PORT_OUT/classpath/*" \
	"$PORT_DIR/tools/TLClassStoreCheck.java"

# libjvm.so is deliberately not in the launcher's RUNPATH
export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ANDROID_APP_DATA_DIR="$PORT_OUT/tlstore-data"
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
	-X "-Dcheck.tlclasses=$class_list" \
	-X "-XX:ErrorFile=$PORT_OUT/hs_err_pid%p.log" \
	"${extra_args[@]}" \
	--run-class TLClassStoreCheck \
	"$PORT_OUT/app.apk" >"$log" 2>&1 || status=$?

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

[ "$status" = 0 ] || {
	echo "the launcher exited $status:" >&2
	tail -40 "$log" >&2
	exit 1
}

# Every arm, by name: a helper that quietly skipped one would still pass on the
# summary line alone.
while read -r class; do
	[ -n "$class" ] || continue
	grep -qF "  instantiated $class" <<<"$log_text" || {
		echo "run.log does not say '$class' was instantiated" >&2; exit 1; }
done <<<"$classes"

for expected in \
	"store: TLClassStore.Instance() built" \
	"tl-class-store: $n_classes classes instantiated" \
	"tl-class-store check: passed"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2; exit 1; }
done

echo "tl-class-store check passed: all $n_classes classes in the store instantiate"
exit 0
