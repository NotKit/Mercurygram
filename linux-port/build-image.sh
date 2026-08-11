#!/bin/bash
# Build a GraalVM native-image shared library the image launcher can create its
# VM from. See BRINGUP_NOTES.md for the measured cost and the jlink comparison.
#
#   --stub   a one-class image, just the JNI Invocation API plus
#            tools/VmCheck.java. It is what proves the launcher's VM backend
#            without any of the framework, and it takes ~30 s instead of
#            however long the real analysis turns out to take.
#   (none)   the real image over api-impl.jar + shim.jar +
#            out/classpath/*, with the traced metadata in out/ni-config.
#
# The image is a *shared library*, never an executable: the launcher stays the
# executable because libtranslation_layer_main.so imports apk_path, atl_window,
# get_app_data_dir and the bionic_* calls from it (FR-5).
#
# Built by GraalVM ($GRAALVM_HOME), not by the port's JDK ($JAVA_HOME): they are
# two separate JDKs on purpose, and atlas must keep being compiled by the latter.
#
# A full build is tens of minutes and gigabytes of builder heap, so it is capped
# and measured here rather than left to native-image's defaults:
#   PORT_IMAGE_XMX            builder heap, default 12g (see build_full)
#   PORT_IMAGE_PARALLELISM    builder threads, default 8 of the host's cores
#   PORT_IMAGE_INIT_AT_RUNTIME  comma-separated classes for --initialize-at-run-time.
#                             Empty by default: every entry must be justified by an
#                             error or a class-initialization report line, never by
#                             a guess, and named in BRINGUP_NOTES.md.
#   PORT_IMAGE_EXTRA_ARGS     whitespace-separated extra native-image arguments,
#                             e.g. --diagnostics-mode for one debugging build.
#
# Usage: linux-port/build-image.sh [--stub] [--clean]
#   --clean deletes this build's own products (the .so, the log, the argv, the
#   stats and reports/), never the directory holding them: $PORT_IMAGE_LIB is an
#   override, so its dirname can be $PORT_OUT itself.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

mode="full"
clean=0
for arg in "$@"; do
	case "$arg" in
	--stub) mode="stub" ;;
	--clean) clean=1 ;;
	*) echo "usage: $0 [--stub] [--clean]" >&2; exit 2 ;;
	esac
done

# FR-6: native-image cannot cross-compile, and the click ships jlink.
[ "$PORT_CROSS" = 0 ] ||
	{ echo "build-image.sh is x86_64-only: native-image cannot cross-compile (FR-6)" >&2; exit 1; }

native_image="$GRAALVM_HOME/bin/native-image"
[ -x "$native_image" ] ||
	{ echo "no native-image at $native_image (see check-graalvm.sh)" >&2; exit 1; }

# --- shared helpers ---------------------------------------------------------

# The launcher dlopens the .so and looks these three up by name (vm_image.c), so
# an image that is missing one is useless however well it built. --no-fallback
# makes this meaningful: a fallback image also exports them, but needs a JVM.
assert_jni_invocation_api() {
	local so="$1"
	[ -f "$so" ] || { echo "native-image produced no $so" >&2; exit 1; }

	local exports
	exports=$("$PORT_NM" -D --defined-only "$so")
	for sym in JNI_CreateJavaVM JNI_GetCreatedJavaVMs JNI_GetDefaultJavaVMInitArgs; do
		grep -qE " T $sym\$" <<<"$exports" ||
			{ echo "$so does not export $sym" >&2; exit 1; }
	done
}

# Sum of RSS over a process tree, in kB. native-image is a launcher that forks
# the builder JVM, so the interesting number is never the pid we started; and
# /usr/bin/time is not installed on this host, so a 1 Hz poll is the measurement.
tree_rss_kb() {
	local pids=("$1") next=() total=0 kb children
	while [ "${#pids[@]}" -gt 0 ]; do
		next=()
		for p in "${pids[@]}"; do
			kb=$(ps -o rss= -p "$p" 2>/dev/null || true)
			[ -z "$kb" ] || total=$((total + kb))
			mapfile -t children < <(pgrep -P "$p" 2>/dev/null || true)
			next+=(${children[@]+"${children[@]}"})
		done
		pids=(${next[@]+"${next[@]}"})
	done
	echo "$total"
}

# Run native-image in the background and poll the tree while it works: the wall
# clock and the peak RSS are reported numbers, not decoration, and a build
# that drives this host into its (already full) swap has to be visible as such.
# Writes $peak_rss_kb and $elapsed_s; the log is the caller's.
run_native_image() {
	local log="$1"; shift

	# The argv is evidence (FR-8). A build argument leaves no trace in the .so
	# and native-image echoes only some of it back: --add-opens in particular is
	# invisible afterwards, and it is the difference between atlas reading
	# FileDescriptor.fd and a null field at run time. Beside the log rather than
	# in it, so a grep of the log still describes the build and not the argv.
	local argv_file="${log%.log}-argv.txt"
	printf '%q\n' "$@" >"$argv_file"
	# a rejected build's log is the only record of it -- the reports/ CSVs
	# survive the next attempt, the log does not
	[ ! -f "$log" ] || mv -f "$log" "$log.prev"

	local started peak=0 now
	started=$(date +%s)
	"$@" >"$log" 2>&1 &
	local ni_pid=$!

	while kill -0 "$ni_pid" 2>/dev/null; do
		now=$(tree_rss_kb "$ni_pid")
		[ "$now" -le "$peak" ] || peak="$now"
		sleep 1
	done
	local status=0
	wait "$ni_pid" || status=$?

	peak_rss_kb="$peak"
	elapsed_s=$(( $(date +%s) - started ))
	return "$status"
}

# --clean for the full image removes this build's products one by one and never
# the directory: $PORT_IMAGE_LIB is an environment override by design, so
# `dirname` of it can be $PORT_OUT itself -- where out/ni-config, the classpath
# jars and the apks live. `rm -rf` there would delete the traced metadata this
# script exists to consume (FR-4). The stub cleans a literal path and does not
# need this.
clean_image_products() {
	local dir="$1" name="$2"
	rm -rf "$dir/reports"
	rm -f "$dir/$name.so" "$dir/build.log" "$dir/build.log.prev" \
		"$dir/build-argv.txt" "$dir/build-stats.env" "$dir/.build-started" \
		"$dir/graal_isolate.h" "$dir/graal_isolate_dynamic.h"
}

# --- the stub image ---------------------------------------------------------

build_stub() {
	local dir="$PORT_OUT/image-stub"
	local classes="$dir/classes"
	local config="$dir/jni-config.json"
	# deliberately not libmercurygram.so: a stub must never be mistaken for the
	# real image, by a person or by $PORT_IMAGE_LIB
	local name="libatl-vm-stub"

	[ "$clean" = 0 ] || rm -rf "$dir"
	rm -rf "$classes"
	mkdir -p "$classes"
	"$JAVA_HOME/bin/javac" -d "$classes" "$PORT_DIR/tools/VmCheck.java"

	# A hand-written fixture, not metadata: FR-4 governs the app's config in
	# out/ni-config, which is generated by trace-metadata.sh and never edited.
	# This file only says which classes the *launcher* looks up by name --
	# VmCheck because --vm-check calls its main(), java.lang.System.getProperty
	# because vm_verify_properties reads the properties back through it, and
	# java.lang.String because that is the array element type of main's argument.
	cat >"$config" <<'EOF'
[
  {
    "name": "VmCheck",
    "methods": [{ "name": "main", "parameterTypes": ["java.lang.String[]"] }]
  },
  {
    "name": "java.lang.System",
    "methods": [{ "name": "getProperty", "parameterTypes": ["java.lang.String"] }]
  },
  { "name": "java.lang.String" }
]
EOF

	echo "building the stub image with $("$native_image" --version | head -1)"
	local started
	started=$(date +%s)
	"$native_image" \
		--shared \
		-o "$dir/$name" \
		-cp "$classes" \
		-H:JNIConfigurationFiles="$config" \
		--no-fallback \
		--add-opens=java.base/java.io=ALL-UNNAMED
	echo "stub image built in $(( $(date +%s) - started ))s"

	# --- verification (FR-8) ---
	local so="$dir/$name.so"
	assert_jni_invocation_api "$so"

	echo "stub image: $so ($(stat -c%s "$so") bytes), exports the JNI Invocation API"
	echo "run it with: $ATLAS_OUT/android-translation-layer-image --vm-library $so --vm-check VmCheck ..."
	echo "(linux-port/launcher/image-smoke-test.sh does exactly that)"
}

# --- the real image ---------------------------------------------------------

# The class path, in the order vm_hotspot.c assembles it: the framework first,
# then the shim, then the app jars. Order decides which jar wins a duplicate
# class, and api-impl has to win. The jars are listed one by one rather than as
# "dir/*" -- that is the `java` launcher's expansion, and neither
# JNI_CreateJavaVM nor native-image does it (append_class_path() in vm_hotspot.c
# exists for exactly that trap); a literal "*" entry would contribute nothing
# and the image would come out missing the whole app, silently.
image_class_path() {
	local jars=()
	mapfile -t jars < <(find "$PORT_OUT/classpath" -maxdepth 1 -name '*.jar' | sort)
	[ "${#jars[@]}" -gt 0 ] ||
		{ echo "no jars in $PORT_OUT/classpath (run build-classpath.sh)" >&2; exit 1; }

	local IFS=":"
	echo "$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar:${jars[*]}"
}

# The three classes whose *build-time* initialisation would be wrong rather than
# merely different: each reads a -D property that only the running process can
# answer, and SDK_INT is a static final int, so a build-time value is constant
# folded into every "SDK_INT >= N" branch in the app and no run-time -D can
# undo it. Measured RUN_TIME on a probe over api-impl + shim + TMessagesProj,
# so this is a regression check on the full classpath, not a workaround.
init_hazards=(
	"android.os.Build\$VERSION"
	"android.os.SystemProperties"
	"org.telegram.messenger.FileLog"
)

# -H:+PrintClassInitialization writes reports/class_initialization_report_*.csv:
# "Class Name, Initialization Kind, Reason". It is the only machine-readable
# answer to "did FileLog end up on --initialize-at-build-time", and nothing in
# out/ni-config can warn about it (FR-8).
check_class_initialization() {
	local dir="$1" stamp="$2"
	local reports=()
	mapfile -t reports < <(find "$dir/reports" -name 'class_initialization_report_*.csv' \
		-newer "$stamp" 2>/dev/null | sort)
	if [ "${#reports[@]}" = 0 ]; then
		echo "no class-initialization report under $dir/reports" >&2
		return 1
	fi
	local report="${reports[-1]}" report_text
	report_text=$(cat "$report")

	local failed=0 line nested
	for class in "${init_hazards[@]}"; do
		# Exact match on the first column. The Reason column contains class names
		# too ("... and super type of com.oracle.svm.core.jni.headers..."), so a
		# substring match plus head -1 could read some other class's row as this
		# class's verdict -- and this gate is the only evidence there is.
		line=$(awk -F', ' -v c="$class" '$1 == c { print; exit }' <<<"$report_text")

		# --initialize-at-run-time moves exactly the class it names: the nested
		# classes and lambdas of $class keep whatever kind the heuristic gave
		# them, and the loop above cannot see them. Reported, not gated: none of
		# them reads a -D property today, and naming one needs an observed report
		# line like every other entry (FR-4).
		nested=$(awk -F', ' -v p="$class\$" \
			'index($1, p) == 1 && $2 != "RUN_TIME" && $2 != "RERUN"' \
			<<<"$report_text" | wc -l)
		[ "$nested" = 0 ] ||
			echo "class init: $nested nested classes of $class are build-time" \
				"(--initialize-at-run-time moves the outer class only)"

		case "$line" in
		"") echo "class init: $class not in the report (unreachable in this image)" ;;
		*", RUN_TIME,"*|*", RERUN,"*) echo "class init: $line" ;;
		*)
			echo "class init: $line" >&2
			echo "  -> $class must not be initialised at build time: it reads a -D" >&2
			echo "     property that only the running process can answer. Add it to" >&2
			echo "     \$PORT_IMAGE_INIT_AT_RUNTIME and say why in BRINGUP_NOTES.md." >&2
			failed=1 ;;
		esac
	done

	# AssetManager is BUILD_TIME by native-image's own "proven side-effect free"
	# heuristic and that is survivable while its static state stays empty: what
	# fails a build is a live JarFile reaching the image heap (openApk() caching
	# one during build-time initialisation). Reported, not gated, because gating
	# it would fail every build over a hazard that has not happened.
	line=$(awk -F', ' '$1 == "android.content.res.AssetManager" { print; exit }' <<<"$report_text")
	[ -z "$line" ] || echo "class init: $line"

	echo "class-initialization report: $report"
	return "$failed"
}

build_full() {
	local dir; dir="$(dirname "$PORT_IMAGE_LIB")"
	# $PORT_IMAGE_LIB is what run.sh --image opens, so it is the name here too:
	# native-image appends .so to -o under --shared (the stub proves it).
	local name; name="$(basename "$PORT_IMAGE_LIB" .so)"
	local log="$dir/build.log"
	local stamp="$dir/.build-started"

	mkdir -p "$dir"
	[ "$clean" = 0 ] || clean_image_products "$dir" "$name"

	# artifacts.env names the framework jar and records which atlas revision it
	# came from -- worth having in the log beside the numbers (run.sh does the same).
	[ -f "$ATLAS_OUT/artifacts.env" ] ||
		{ echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
	source "$ATLAS_OUT/artifacts.env"

	[ -f "$ATLAS_API_IMPL_JAR" ] ||
		{ echo "no $ATLAS_API_IMPL_JAR (run build-atlas.sh)" >&2; exit 1; }
	[ -f "$PORT_OUT/shim.jar" ] ||
		{ echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
	# A -cp entry that does not exist is *not* an error to native-image: it warns
	# nothing, builds an image without those classes and exits 0. Every input is
	# therefore checked here rather than left to the build to notice.
	local config="$PORT_OUT/ni-config"
	for file in jni-config.json reflect-config.json proxy-config.json \
		resource-config.json serialization-config.json; do
		[ -f "$config/$file" ] ||
			{ echo "no $config/$file (run trace-metadata.sh -- FR-4)" >&2; exit 1; }
	done

	# declared first and assigned on its own line: `local x=$(f)` would take
	# `local`'s exit status and swallow a failure inside f
	local class_path
	class_path=$(image_class_path)

	# --initialize-at-run-time. Every entry answers an observed report line or an
	# observed build error, never a guess; each is listed in
	# BRINGUP_NOTES.md with the line that justifies it. $PORT_IMAGE_INIT_AT_RUNTIME
	# adds to this list for a one-off debugging build, it does not replace it.
	#
	#   org.telegram.messenger.FileLog -- the first full build reported
	#   "org.telegram.messenger.FileLog, BUILD_TIME, class proven as side-effect
	#   free before analysis", which fails check_class_initialization below. Its
	#   <clinit> is in fact property-free today (the TL-dump work moved the
	#   tmessages.tldump read into the mutable `tlDump` field, read on first
	#   use), so this pins a class whose statics must keep answering for the
	#   running process rather than the build host.
	local init_classes="org.telegram.messenger.FileLog"
	[ -z "${PORT_IMAGE_INIT_AT_RUNTIME:-}" ] ||
		init_classes="$init_classes,$PORT_IMAGE_INIT_AT_RUNTIME"
	local init_opts=("--initialize-at-run-time=$init_classes")
	local extra_args=()
	read -ra extra_args -d '' <<<"${PORT_IMAGE_EXTRA_ARGS:-}" || true

	local argv=(
		"$native_image"
		# a shared library, never an executable: the launcher is the executable
		# and libtranslation_layer_main.so imports apk_path/atl_window/bionic_*
		# from it (FR-5). With --shared the JNI Invocation API is the entry point
		# and the analysis roots are exactly what out/ni-config registers.
		--shared
		-o "$dir/$name"
		-cp "$class_path"
		# One directory, so a config file added by a later trace is picked up
		# without a change here. -H:ConfigurationFileDirectories is the only
		# non-experimental spelling of this (the per-file
		# -H:JNIConfigurationFiles etc. all warn about needing
		# -H:+UnlockExperimentalVMOptions), and it reads all six names.
		-H:ConfigurationFileDirectories="$config"
		# Without it native-image "succeeds" by emitting a fallback image that
		# needs a JVM at run time -- which would export JNI_CreateJavaVM, pass
		# every check below and be worthless.
		--no-fallback
		# atlas reads java.io.FileDescriptor's private fd (FileDescriptorUtils).
		# On an image this has to be a *build* argument: passed at VM creation it
		# is accepted and ignored, FD_FIELD stays null, and AssetManager.openFd,
		# Parcel and ParcelFileDescriptor all throw. Nothing in out/ni-config
		# mentions FileDescriptor, so nothing else would warn.
		--add-opens=java.base/java.io=ALL-UNNAMED
		# The two -H:+ options below are experimental in 21.0.2 and only warn;
		# unlocking them keeps the build quiet now and working when it becomes
		# an error.
		-H:+UnlockExperimentalVMOptions
		# The first error is the one worth reading, and a bare message often does
		# not say which class path element dragged the failure in.
		-H:+ReportExceptionStackTraces
		# Writes reports/class_initialization_report_*.csv, which
		# check_class_initialization() reads: the only evidence that FileLog and
		# Build$VERSION were not initialised at build time.
		-H:+PrintClassInitialization
		# Off by default, and this config was traced against HotSpot: an entry
		# naming a class the image classpath does not have is a real signal about
		# the image run's missing-metadata errors, not noise.
		-H:+WarnAboutMissingReflectionOrJNIMetadataElements
		# The host has 31 GB and its swap is already full, so the builder is
		# capped rather than left to take 80% of RAM: a build that swaps takes
		# the machine with it. Raise it if the builder dies with an
		# OutOfMemoryError; that ceiling is itself a reported number.
		"-J-Xmx${PORT_IMAGE_XMX:-12g}"
		# 12 cores, but each analysis/compiler thread holds graphs, so threads
		# cost memory as much as they save time. 8 leaves the machine usable.
		"--parallelism=${PORT_IMAGE_PARALLELISM:-8}"
		${init_opts[@]+"${init_opts[@]}"}
		${extra_args[@]+"${extra_args[@]}"}
	)

	# app.apk and framework-res.apk are deliberately NOT on -cp. Under the image
	# they reach Java as -Datl.apk.path / -Datl.framework.res.path and are read as
	# files: AssetManager was moved off the class path scan (atlas eaa62f9e)
	# and extractFromAPK onto its own JarFile (6d5bd6f5). app.apk holds 0 .class
	# entries -- its code is 24 classes*.dex, which native-image cannot read
	# anyway -- so putting 64 MB of apk on -cp would add nothing but analysis
	# time and a risk of resource-config patterns matching apk entries.
	echo "building the full image with $("$native_image" --version | head -1)"
	echo "  atlas ${ATLAS_BRANCH:-?} ${ATLAS_REV:-?}, $(wc -w <<<"${class_path//:/ }") class path entries"
	echo "  metadata $config, log $log"
	# a failed build must not leave the previous image looking current: run.sh
	# --image would boot it and the run would describe the wrong sources. Same
	# for the stats file, which is the only record of what an image cost.
	rm -f "$dir/$name.so" "$dir/build-stats.env"
	: >"$stamp"
	local status=0
	run_native_image "$log" "${argv[@]}" || status=$?
	if [ "$status" != 0 ]; then
		echo "native-image failed (exit $status) after ${elapsed_s}s," \
			"peak RSS $((peak_rss_kb / 1024)) MB; last lines of $log:" >&2
		tail -40 "$log" >&2
		exit 1
	fi
	echo "image built in ${elapsed_s}s, peak RSS $((peak_rss_kb / 1024)) MB"

	# --- verification (FR-8) ---
	local so="$dir/$name.so"
	assert_jni_invocation_api "$so"
	# native-image writes the .so before this gate runs, and nothing else marks
	# an image as rejected -- run.sh --image opens $PORT_IMAGE_LIB if the file is
	# there and never reads build-stats.env. So a rejected image is deleted.
	if ! check_class_initialization "$dir" "$stamp"; then
		rm -f "$so"
		echo "removed $so: it failed the class-initialization gate" >&2
		exit 1
	fi

	# The numbers this build has to report, in a file so a later step can read them
	# back instead of re-running the build (PRD success metric 1).
	cat >"$dir/build-stats.env" <<-EOF
		PORT_IMAGE_LIB="$so"
		PORT_IMAGE_BYTES=$(stat -c%s "$so")
		PORT_IMAGE_BUILD_SECONDS=$elapsed_s
		PORT_IMAGE_PEAK_RSS_KB=$peak_rss_kb
		PORT_IMAGE_XMX="${PORT_IMAGE_XMX:-12g}"
		PORT_IMAGE_PARALLELISM="${PORT_IMAGE_PARALLELISM:-8}"
		PORT_IMAGE_INIT_AT_RUNTIME="$init_classes"
		ATLAS_REV="${ATLAS_REV:-}"
	EOF

	echo "image: $so ($(stat -c%s "$so") bytes), exports the JNI Invocation API"
	echo "stats: $dir/build-stats.env, argv: $dir/build-argv.txt"
	echo "run it with: linux-port/run.sh --image --seconds 25"
}

case "$mode" in
stub) build_stub ;;
full) build_full ;;
esac
