#!/bin/bash
# Checks that the image-backed launcher creates a VM from a GraalVM
# native-image shared library and calls into a class inside it.
#
# What this can and cannot prove, stated up front so nobody reads more into a
# green run than is there. atlas's own --smoke-test (the sibling smoke-test.sh)
# is NOT reachable with a stub image: it fires only after FindClass
# android/view/Display, android/atl/ATLRuntime + System.load of
# libtranslation_layer_main.so, set_up_handle_cache, atl_window_new and
# prepare_main_looper, and then calls android.os.SystemClock.uptimeMillis() --
# every one of which needs api-impl classes inside the image. That is the real
# image's job, not the stub's.
#
# What a stub does prove, and it is the whole VM backend:
#   - the launcher dlopens the image and finds JNI_CreateJavaVM in it,
#   - JNI_CreateJavaVM accepts (or does not) the launcher's option set, with the
#     answer in the log rather than assumed,
#   - every -D property the framework needs is readable from Java, with the same
#     value it was passed (the launcher only reads them back, never repairs one),
#   - FindClass + GetStaticMethodID + CallStaticVoidMethod work against the
#     image isolate,
#   - no libjvm.so is mapped in the process, read from inside it.
#
# The identical --vm-check run is made against the HotSpot launcher first, so a
# failure separates "the harness is wrong" from "the image is wrong" before any
# image debugging starts.
#
# Usage: linux-port/launcher/image-smoke-test.sh [--rebuild]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

rebuild=0
for arg in "$@"; do
	case "$arg" in
	--rebuild) rebuild=1 ;;
	*) echo "usage: $0 [--rebuild]" >&2; exit 2 ;;
	esac
done

hotspot_launcher="$ATLAS_OUT/android-translation-layer-hotspot"
image_launcher="$ATLAS_OUT/android-translation-layer-image"
stub="$PORT_OUT/image-stub/libatl-vm-stub.so"
native_lib="$PORT_OUT/libtmessages.so"
log_hotspot="$PORT_OUT/image-smoke-hotspot.log"
log_image="$PORT_OUT/image-smoke.log"

[ -x "$image_launcher" ] || { echo "no image launcher at $image_launcher (run build-atlas.sh)" >&2; exit 1; }
[ -x "$hotspot_launcher" ] || { echo "no launcher at $hotspot_launcher (run build-atlas.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/app.apk" ] || { echo "no $PORT_OUT/app.apk (run build-classpath.sh)" >&2; exit 1; }
[ -f "$native_lib" ] || { echo "no $native_lib (run native/build_tmessages_linux.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

if [ "$rebuild" = 1 ] || [ ! -f "$stub" ]; then
	"$PORT_DIR/build-image.sh" --stub
fi

# the HotSpot arm needs VmCheck on a class path; the image already contains it
mkdir -p "$PORT_OUT/tools"
"$JAVA_HOME/bin/javac" -d "$PORT_OUT/tools" "$PORT_DIR/tools/VmCheck.java"

# a data dir of its own, so nothing a previous run left can be what made this pass
export ANDROID_APP_DATA_DIR="$PORT_OUT/image-smoke-data"
rm -rf "$ANDROID_APP_DATA_DIR"
mkdir -p "$ANDROID_APP_DATA_DIR"

# no display: --vm-check exits before atl_window_new, on both launchers

# --- the harness, on HotSpot ------------------------------------------------

echo "== HotSpot launcher, --vm-check VmCheck (the harness itself)"
(
	export LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	"$hotspot_launcher" \
		--api-impl-jar "$ATLAS_API_IMPL_JAR" \
		--framework-res "$ATLAS_FRAMEWORK_RES" \
		--natives-dir "$ATLAS_NATIVES_DIR" \
		--classpath "$PORT_OUT/tools:$PORT_OUT/shim.jar" \
		--library-path "$PORT_OUT" \
		--vm-check VmCheck \
		-X "-Dtmessages.native.path=$native_lib" \
		-X "-Dtmessages.tldump=0" \
		"$PORT_OUT/app.apk"
) >"$log_hotspot" 2>&1 || {
	echo "the HotSpot --vm-check run failed; the harness is wrong, not the image:" >&2
	tail -30 "$log_hotspot" >&2
	exit 1
}

hotspot_text=$(cat "$log_hotspot")
for expected in \
	"JVM launched successfully" \
	"vm property: atl.apk.path=$PORT_OUT/app.apk (from -D)" \
	"vm check: all 5 required properties reached Java" \
	"vm check: VmCheck.main() returned"
do
	grep -qF "$expected" <<<"$hotspot_text" || {
		echo "$log_hotspot has no '$expected'" >&2; tail -30 "$log_hotspot" >&2; exit 1; }
done
echo "   ok: the same class, the same options and the same assertions pass on libjvm.so"

# --- the image launcher -----------------------------------------------------

echo "== image launcher, --vm-library $stub"
(
	# deliberately NOT $JAVA_HOME/lib/server: nothing in this process may be
	# able to find a HotSpot libjvm.so even by accident
	export LD_LIBRARY_PATH="$(dirname "$stub"):$ATLAS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	# --api-impl-jar and --classpath are deliberately passed too: one argv has to
	# drive both launchers, so the image path must warn about them, not refuse
	"$image_launcher" \
		--api-impl-jar "$ATLAS_API_IMPL_JAR" \
		--framework-res "$ATLAS_FRAMEWORK_RES" \
		--natives-dir "$ATLAS_NATIVES_DIR" \
		--classpath "$PORT_OUT/tools:$PORT_OUT/shim.jar" \
		--library-path "$PORT_OUT" \
		--vm-library "$stub" \
		--vm-check VmCheck \
		-X "-Dtmessages.native.path=$native_lib" \
		-X "-Dtmessages.tldump=0" \
		"$PORT_OUT/app.apk"
) >"$log_image" 2>&1 || {
	echo "the image --vm-check run failed:" >&2
	tail -40 "$log_image" >&2
	exit 1
}

image_text=$(cat "$log_image")

# --- verification -----------------------------------------------------------

for expected in \
	"image: opened $stub" \
	"JVM launched successfully" \
	"vm property: atl.apk.path=$PORT_OUT/app.apk" \
	"vm property: Build.VERSION.SDK_INT=28" \
	"vm property: tmessages.tldump=0" \
	"vm check: alive on " \
	"vm check: libjvm.so mapped: no" \
	"vm check: all 5 required properties reached Java" \
	"vm check: VmCheck.main() returned"
do
	grep -qF "$expected" <<<"$image_text" || {
		echo "$log_image has no '$expected'" >&2; tail -40 "$log_image" >&2; exit 1; }
done

# The image must not have been given a class path, an agent or an -XX: option:
# The acceptance criterion, checked against what the launcher echoed.
forbidden=$(grep -E '^jvm option: (-Djava\.class\.path|-agentlib:|-XX:|-Xcheck:jni|--add-opens)' \
	<<<"$image_text" || true)
[ -z "$forbidden" ] || {
	echo "the image launcher assembled JVM-only options:" >&2; echo "$forbidden" >&2; exit 1; }

# The stub really was the VM: it is mapped, and it is the only VM library that is.
grep -qF "vm check: mapped: $stub" <<<"$image_text" || {
	echo "$stub is not mapped in the image process:" >&2
	grep -F 'vm check: mapped:' <<<"$image_text" >&2; exit 1; }

# The PRD's first open question -- does the Invocation API accept the option set
# the launcher passes, or does the launcher have to filter down to nothing --
# is answered by these two numbers, so print them rather than assume them.
created=$(sed -n 's/^image: VM created with //p' <<<"$image_text")
[ -n "$created" ] || { echo "the log does not say how the VM was created" >&2; exit 1; }

# Asserted, not just printed: "-D works, all of it" is the answer this test
# exists to produce, so one -D that the image accepted and did not deliver has
# to fail the run rather than change a number nobody reads.
passed=$(grep -c '^jvm option: -D' <<<"$image_text" || true)
arrived=$(grep -c '^vm property: .*(from -D)' <<<"$image_text" || true)
[ "$passed" = "$arrived" ] || {
	echo "$passed -D options went in, $arrived arrived in Java as themselves:" >&2
	grep -E '^(jvm option: -D|vm property: )' <<<"$image_text" >&2
	exit 1
}

echo
echo "image smoke test passed"
echo "  VM created with $created"
echo "  properties: $passed passed as -D, all $arrived readable from Java as themselves"
echo "  logs: $log_hotspot (HotSpot harness), $log_image (image)"
exit 0
