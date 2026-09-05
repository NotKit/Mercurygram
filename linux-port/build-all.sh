#!/bin/bash
# Build the whole port in dependency order: every native dependency, jar and
# launcher, from a clean checkout to a runnable app.
#
#   linux-port/build-all.sh && linux-port/run.sh
#
# Each step is one of the port's own scripts, all of them idempotent, so a
# re-run is an incremental pass and a failed run can be resumed with --from.
#
# Usage: linux-port/build-all.sh [--clean] [--from STEP] [--only STEP] [--list]
#   --clean      pass --clean to every step that has one (rebuilds skia and runs
#                a Gradle clean: ~10 minutes, against ~1 minute incremental)
#   --from STEP  start at STEP instead of the beginning
#   --only STEP  run just that step
#   --list       print the steps and exit
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

ATLAS_URL="${ATLAS_URL:-git@github.com:NotKit/atl-touch.git}"
ATLAS_BRANCH="${ATLAS_BRANCH:-master}"

# name | what it does
STEPS=(
	"sources|submodules and the atlas checkout"
	"env|toolchain smoke test"
	"boringssl|BoringSSL for x86_64-linux-gnu"
	"libvpx|libvpx (before ffmpeg: --enable-libvpx)"
	"dav1d|dav1d"
	"ffmpeg|ffmpeg"
	"tmessages|the app's JNI library, glibc, with voip"
	"classpath|app jars and app.apk from Gradle"
	"atlas|the atlas framework and both launchers"
	"shim|the libcore/dalvik compat shim"
	"checks|atlas class checks with the shim, then NativeLoader and apk extraction"
	"image|the stub native image the image-backed launcher is tested against "
)

clean=""
from=""
only=""
while [ $# -gt 0 ]; do
	case "$1" in
	--clean) clean="--clean" ;;
	--from) from="${2:-}"; shift ;;
	--only) only="${2:-}"; shift ;;
	--list)
		for s in "${STEPS[@]}"; do
			IFS='|' read -r name what <<<"$s"
			printf '%-10s %s\n' "$name" "$what"
		done
		exit 0 ;;
	*) echo "usage: $0 [--clean] [--from STEP] [--only STEP] [--list]" >&2; exit 2 ;;
	esac
	shift
done

step_names=$(for s in "${STEPS[@]}"; do echo "${s%%|*}"; done)
for want in $from $only; do
	grep -qx "$want" <<<"$step_names" ||
		{ echo "unknown step: $want (see --list)" >&2; exit 2; }
done

started=$(date +%s)
declare -a TIMINGS=()

# --- the steps --------------------------------------------------------------

step_sources() {
	# The four submodules the native build needs. td (tdlib), whisper and
	# TMessagesProj_PluginTor/* stay un-initialized on purpose (README.md).
	(cd "$REPO_DIR" && git submodule update --init \
		TMessagesProj/jni/boringssl TMessagesProj/jni/ffmpeg \
		TMessagesProj/jni/dav1d TMessagesProj/jni/libvpx)

	# atlas is a source dependency this repo does not carry: clone it when the
	# checkout is missing. On a machine that already has an atlas clone, a
	# worktree is better (shares the objects) — see README.md.
	if [ ! -f "$ATLAS_DIR/meson.build" ]; then
		echo "no atlas checkout at $ATLAS_DIR: cloning $ATLAS_URL ($ATLAS_BRANCH)"
		git clone -b "$ATLAS_BRANCH" "$ATLAS_URL" "$ATLAS_DIR"
	fi
	# Share the ~8 GB skia tree if there is one; otherwise meson downloads it.
	if [ ! -e "$ATLAS_DIR/subprojects/skia" ] && [ -d "$ATLAS_SKIA_DIR" ]; then
		ln -s "$ATLAS_SKIA_DIR" "$ATLAS_DIR/subprojects/skia"
		echo "linked subprojects/skia -> $ATLAS_SKIA_DIR"
	fi
}

step_env()       { "$PORT_DIR/check-env.sh"; }
step_boringssl() { "$PORT_DIR/native/build_boringssl_linux.sh" $clean; }
step_libvpx()    { "$PORT_DIR/native/build_libvpx_linux.sh" $clean; }
step_dav1d()     { "$PORT_DIR/native/build_dav1d_linux.sh" $clean; }
step_ffmpeg()    { "$PORT_DIR/native/build_ffmpeg_linux.sh" $clean; }
step_tmessages() { "$PORT_DIR/native/build_tmessages_linux.sh" $clean; }
step_classpath() { "$PORT_DIR/build-classpath.sh" $clean; }
step_atlas()     { "$PORT_DIR/build-atlas.sh" $clean; }
step_shim()      { "$PORT_DIR/build-shim.sh" $clean; }

step_checks() {
	# build-atlas.sh skips its app class checks (PortClassCheck,
	# ViewSignatureCheck) while out/shim.jar is missing, and on a first build it
	# always is — the shim compiles against the framework jar this step produces.
	# So come back now that both halves of the class path exist; the atlas build
	# itself is an incremental no-op.
	"$PORT_DIR/build-atlas.sh"
	# NativeLoader picks up the glibc libtmessages.so inside the real
	# launcher. Exercises the whole stack short of the UI.
	"$PORT_DIR/check-native-loader.sh"
	# A missing framework *method* is a NoSuchMethodError when the line runs,
	# not at class load, so nothing else here would catch it: it killed a call
	# halfway through VoIPService.onCreate.
	"$PORT_DIR/check-framework-api.sh"
	# The calls stack: JNI_OnLoad now runs the real tgvoipOnJNILoad, and tgcalls
	# answers for itself. Cheap, and it catches a voip build that linked but
	# registered nothing.
	"$PORT_DIR/check-voip-instance.sh"
	# webrtc's Java audio device is picky about what AudioTrack/AudioRecord
	# report; this drives them the same way, with or without a sound card.
	"$PORT_DIR/check-webrtc-audio.sh"
	# Apk content comes out of the apk, not the class path.
	# Nothing in a boot reliably posts a notification, so this path needs its own
	# check rather than a run.
	"$PORT_DIR/check-extract-apk.sh"
	# FR-1a/FR-7: the framework answers Debug.dumpHprofData, so org/telegram/**
	# needs no workaround for it. Fails if the reverted one comes back.
	"$PORT_DIR/check-dump-hprof.sh"
	# FR-4: every arm of TLClassStore instantiates. Traced by trace-metadata.sh,
	# so the image gets metadata for all of them and not just the two a session
	# happens to take.
	"$PORT_DIR/check-tlstore.sh"
	# A nine-patch drawn at alpha 0 paints nothing. Pixel-level and cheap, and
	# the bug it guards was only visible as a hairline on the phone.
	"$PORT_DIR/check-ninepatch.sh"
	# sans-serif is the bundled Roboto, not whatever fontconfig substitutes.
	# Silent otherwise: the text still draws, at the wrong size.
	"$PORT_DIR/check-fonts.sh"
}

step_image() {
	# The *stub* image only: it is ~80 s and one class, and it is what keeps
	# android-translation-layer-image honest. The real image (build-image.sh with
	# no flag) is not part of the port's build order -- it costs ~107 s and 3.5 GB,
	# and the click ships jlink (FR-2).
	# FR-6, the same guard build-image.sh itself has: native-image cannot cross
	# compile, and $GRAALVM_HOME exists on a cross host too, so testing for the
	# tool alone would walk a PORT_ARCH=arm64 build straight into that error.
	if [ "$PORT_CROSS" = 1 ]; then
		echo "cross build: no native image (native-image is x86_64-only), skipping"
		return 0
	fi
	if [ ! -x "$GRAALVM_HOME/bin/native-image" ]; then
		echo "no native-image at $GRAALVM_HOME (see check-graalvm.sh), skipping"
		return 0
	fi
	"$PORT_DIR/build-image.sh" --stub
	"$PORT_DIR/launcher/image-smoke-test.sh"
}

# --- run them ---------------------------------------------------------------

skipping=1
[ -n "$from" ] || skipping=0
for s in "${STEPS[@]}"; do
	IFS='|' read -r name what <<<"$s"
	if [ -n "$only" ]; then
		[ "$name" = "$only" ] || continue
	else
		[ "$name" = "$from" ] && skipping=0
		[ "$skipping" = 0 ] || { echo "-- skip $name"; continue; }
	fi

	echo
	echo "== $name: $what"
	t0=$(date +%s)
	"step_$name"
	TIMINGS+=("$(printf '%-10s %4ds' "$name" $(( $(date +%s) - t0 )))")
done

echo
echo "build-all: $(( $(date +%s) - started ))s"
printf '  %s\n' "${TIMINGS[@]}"
echo
echo "next: linux-port/run.sh   (linux-port/transplant-session.sh first for a logged-in session)"
