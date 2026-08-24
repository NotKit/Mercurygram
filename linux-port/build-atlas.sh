#!/bin/bash
# Build the atlas framework from the in-tree checkout and install what the port
# runs against into out/atlas/. Replaces get-atlas-artifacts.sh.
#
# $ATLAS_DIR (linux-port/atlas) is a source dependency, not a place to copy
# prebuilt files from: edit a framework source there, re-run this, and the new
# out/atlas/api-impl.jar is what the launcher boots.
#
# Which artifact is which, from atlas meson.build (do not guess these names):
#
#   src/api-impl/hax.jar    javac product of the framework sources
#                           (src/api-impl/meson.build:885 jar(), or :871 via ant)
#                           -- THIS is the jar the port puts on the classpath
#   hax-stripped.jar        the above minus three compile-only stubs
#                           (meson.build:274), dropped because ART rejects an
#                           app's oat file when a class is defined twice. A JVM
#                           class path has no such check and nothing else
#                           provides them, so the port keeps them.
#   api-impl.jar            hax-stripped.jar run through `dx --dex`
#                           (meson.build:279) -- a classes.dex, useless here
#
# So out/atlas/api-impl.jar is a copy of hax.jar, not of atlas's identically
# named dexed jar. The verification below asserts that.
#
# Usage: linux-port/build-atlas.sh [--clean] [--reconfigure]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

reconfigure=0
for arg in "$@"; do
	case "$arg" in
	--clean) rm -rf "$ATLAS_BUILDDIR" "$ATLAS_OUT" ;;
	--reconfigure) reconfigure=1 ;;
	*) echo "usage: $0 [--clean] [--reconfigure]" >&2; exit 2 ;;
	esac
done

[ -f "$ATLAS_DIR/meson.build" ] ||
	{ echo "no atlas checkout at $ATLAS_DIR (see linux-port/README.md)" >&2; exit 1; }

# $PORT_SKIA_PREBUILT points at a directory holding a libskia.so built for the
# target and skia's include/ tree. With it, atlas links that instead of building
# the skia subproject — the only way to get a cross build (linux-port/click/).
skia_prebuilt="${PORT_SKIA_PREBUILT:-}"

tools="meson ninja"
[ -n "$skia_prebuilt" ] || tools="$tools gn clang"
for tool in $tools; do
	command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done

if [ -n "$skia_prebuilt" ]; then
	for f in libskia.so include/core/SkCanvas.h; do
		[ -e "$skia_prebuilt/$f" ] ||
			{ echo "PORT_SKIA_PREBUILT=$skia_prebuilt has no $f" >&2; exit 1; }
	done
fi

# The skia subproject is the shared ~8 GB checkout; never download it again.
if [ -n "$skia_prebuilt" ]; then
	: # not used at all in this configuration
elif [ ! -e "$ATLAS_DIR/subprojects/skia" ]; then
	[ -d "$ATLAS_SKIA_DIR" ] ||
		{ echo "no skia sources: set ATLAS_SKIA_DIR (tried $ATLAS_SKIA_DIR)" >&2; exit 1; }
	ln -s "$ATLAS_SKIA_DIR" "$ATLAS_DIR/subprojects/skia"
	echo "linked subprojects/skia -> $ATLAS_SKIA_DIR"
fi

# meson copies subprojects/packagefiles/skia/ into the checkout once, when it
# extracts the wrap, and the shared checkout was extracted long ago. Copy them
# again when atlas changes them, or a skia build option committed on the atlas
# branch would never reach the build.
if [ -z "$skia_prebuilt" ]; then
	for f in "$ATLAS_DIR"/subprojects/packagefiles/skia/*; do
		dst="$ATLAS_DIR/subprojects/skia/$(basename "$f")"
		cmp -s "$f" "$dst" || { cp "$f" "$dst"; echo "updated subprojects/skia/$(basename "$f")"; }
	done
fi

# builddir-relative source | destination name | ninja target | required
artifacts=(
	"src/api-impl/hax.jar|api-impl.jar|src/api-impl/hax.jar|yes"
	"libtranslation_layer_main.so|libtranslation_layer_main.so|libtranslation_layer_main.so|yes"
	"libandroid.so.0|libandroid.so.0|libandroid.so.0|yes"
	"res/framework-res/framework-res.apk|framework-res.apk|res/framework-res/framework-res.apk|yes"
	"android-translation-layer-hotspot|android-translation-layer-hotspot|android-translation-layer-hotspot|yes"
	"libatl_webview_qt.so|libatl_webview_qt.so|libatl_webview_qt.so|no"
)
# The same launcher with the native-image VM backend. It is native-only
# because a native image cannot be cross-compiled (FR-6), and it has to be
# `required=yes`: only required entries go into the ninja target list below, so
# an "optional" artifact is simply never built.
[ "$PORT_CROSS" = 1 ] ||
	artifacts+=("android-translation-layer-image|android-translation-layer-image|android-translation-layer-image|yes")
# The subproject builds libskia.so into the builddir; a prebuilt one is copied
# from where it was found instead (below), so it is not a ninja target here.
[ -n "$skia_prebuilt" ] ||
	artifacts+=("subprojects/skia/libskia.so|libskia.so|subprojects/skia/libskia.so|yes")

# --- configure --------------------------------------------------------------

# meson picks the JDK for its `jni` dependency and for javac from JAVA_HOME/PATH
# at setup time, so a builddir remembers the JDK it was configured with. The
# framework must be compiled by the same JDK the port runs on (21), and the
# system default here is 25 -- hence the stamp and the forced reconfigure.
setup_args=()
if [ -n "$skia_prebuilt" ]; then
	setup_args+=("-Dskia-prebuilt=$skia_prebuilt")
fi
if [ "$PORT_CROSS" = 1 ]; then
	cross_file="$PORT_OUT/meson-cross.ini"
	"$PORT_DIR/native/write-meson-cross.sh" "$cross_file"
	setup_args+=(--cross-file "$cross_file")
fi

# The stamp covers the target too: a cross file and a prebuilt skia are as
# baked into coredata as the compiler is, and out/ is per-arch anyway.
jdk_stamp="$ATLAS_BUILDDIR/.port-jdk"
stamp_value="$JAVA_HOME $PORT_TRIPLE ${setup_args[*]+${setup_args[*]}}"
if [ -f "$ATLAS_BUILDDIR/build.ninja" ] &&
   [ "$(cat "$jdk_stamp" 2>/dev/null || true)" != "$stamp_value" ]; then
	echo "builddir was configured differently ($stamp_value), reconfiguring"
	reconfigure=1
fi

if [ ! -f "$ATLAS_BUILDDIR/build.ninja" ]; then
	meson setup "${setup_args[@]+"${setup_args[@]}"}" "$ATLAS_BUILDDIR" "$ATLAS_DIR"
	echo "$stamp_value" >"$jdk_stamp"
elif [ "$reconfigure" = 1 ]; then
	# --wipe, not --reconfigure: the java compiler is cached in coredata, so a JDK
	# change only takes effect on a from-scratch configure. It costs a full rebuild
	# including skia, so the stamp above exists to make this happen at most once.
	meson setup --wipe "${setup_args[@]+"${setup_args[@]}"}" "$ATLAS_BUILDDIR" "$ATLAS_DIR"
	echo "$stamp_value" >"$jdk_stamp"
fi

# --- build ------------------------------------------------------------------

# The click's build container mounts this repository and nothing else, and the
# atlas checkout there is a worktree whose .git file points outside it — so git
# is simply unavailable, and the working-tree check and the provenance below
# have to cope. A native build always has it.
if git -C "$ATLAS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	atlas_git=1
else
	atlas_git=0
	echo "note: no usable git for $ATLAS_DIR, skipping the working-tree check"
fi

# javac writes generated JNI headers back into the atlas source tree
# (src/api-impl/meson.build's -h flag). Those belong on the atlas branch, so the
# build is allowed to touch them -- but nothing else.
tree_before=""
[ "$atlas_git" = 0 ] || tree_before=$(git -C "$ATLAS_DIR" status --porcelain)

targets=()
for entry in "${artifacts[@]}"; do
	IFS='|' read -r _src _dst target required <<<"$entry"
	[ "$required" = yes ] && targets+=("$target")
done
ninja -C "$ATLAS_BUILDDIR" "${targets[@]}"

tree_after=""
[ "$atlas_git" = 0 ] || tree_after=$(git -C "$ATLAS_DIR" status --porcelain)
if [ "$tree_before" != "$tree_after" ]; then
	echo "the atlas build changed its own working tree:"
	diff <(echo "$tree_before") <(echo "$tree_after") || true
	unexpected=$(comm -13 <(echo "$tree_before" | sed 's/^...//' | sort) \
	                      <(echo "$tree_after" | sed 's/^...//' | sort) |
		grep -v '^src/api-impl-jni/generated_headers/' || true)
	if [ -n "$unexpected" ]; then
		echo "unexpected changes in $ATLAS_DIR (not generated headers):" >&2
		echo "$unexpected" >&2
		exit 1
	fi
	echo "note: commit the regenerated headers on the atlas branch"
fi

# --- install ----------------------------------------------------------------

mkdir -p "$ATLAS_OUT"

for entry in "${artifacts[@]}"; do
	IFS='|' read -r src dst _target required <<<"$entry"
	if [ ! -f "$ATLAS_BUILDDIR/$src" ]; then
		[ "$required" = yes ] && { echo "missing $ATLAS_BUILDDIR/$src" >&2; exit 1; }
		echo "skipping optional $src (not built)"
		continue
	fi
	cp "$ATLAS_BUILDDIR/$src" "$ATLAS_OUT/$dst"
done

# A prebuilt libskia.so is not a build product, but it is still what the natives
# resolve through their $ORIGIN/ RUNPATH, so it has to sit here with them.
[ -z "$skia_prebuilt" ] || cp "$skia_prebuilt/libskia.so" "$ATLAS_OUT/libskia.so"

# DT_NEEDED of libtranslation_layer_main.so is the soname; the RUNPATH's leading
# $ORIGIN/ is why libskia.so and libandroid.so.0 work from this one flat dir.
ln -sfn libandroid.so.0 "$ATLAS_OUT/libandroid.so"

# fonts.xml lives in the atlas source tree, not the builddir (meson.build installs
# res/fonts.xml to <datadir>/atl/system/etc). Mirror that suffix so the same path
# tail works if the launcher ever needs to point at it.
mkdir -p "$ATLAS_OUT/system/etc"
cp "$ATLAS_DIR/res/fonts.xml" "$ATLAS_OUT/system/etc/fonts.xml"

# The bundled Roboto faces, which the framework does read: TypefaceCollection.cpp
# finds them at system/fonts next to its own library, so the flat natives dir has
# to carry this subdirectory too.
mkdir -p "$ATLAS_OUT/system/fonts"
cp "$ATLAS_DIR"/res/fonts/*.ttf "$ATLAS_DIR/res/fonts/NOTICE" "$ATLAS_OUT/system/fonts/"

if [ "$atlas_git" = 1 ]; then
	atlas_branch=$(git -C "$ATLAS_DIR" branch --show-current)
	atlas_rev=$(git -C "$ATLAS_DIR" rev-parse --short HEAD)
	atlas_dirty=""
	# The suffix goes into ATLAS_REV itself, not only into the human-readable
	# lines: build-image.sh stamps that value into out/image/build-stats.env,
	# and a bare hash there claims a revision that cannot rebuild the artifact.
	atlas_rev_suffix=""
	if [ -n "$(git -C "$ATLAS_DIR" status --porcelain)" ]; then
		atlas_dirty=" (working tree dirty)"
		atlas_rev_suffix="-dirty"
	fi
else
	atlas_branch="unknown"
	atlas_rev="unknown"
	atlas_rev_suffix=""
	atlas_dirty=" (no git here; see the host build's ARTIFACTS.md for the revision)"
fi
jdk_version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)

# --- verification -----------------------------------------------------------

jar_listing=$(unzip -l "$ATLAS_OUT/api-impl.jar")
for entry in android/view/View.class android/os/Looper.class android/content/Context.class; do
	grep -q " $entry\$" <<<"$jar_listing" || {
		echo "$ATLAS_OUT/api-impl.jar has no $entry" >&2; exit 1; }
done
if grep -q "classes.dex" <<<"$jar_listing"; then
	echo "$ATLAS_OUT/api-impl.jar is dexed: install hax.jar, not api-impl.jar" >&2
	exit 1
fi

# The stubs hax-stripped.jar drops for ART's sake: nothing on the app class path
# defines them, so on a JVM they have to come from here.
for entry in android/view/OnReceiveContentListener.class android/window/OnBackInvokedCallback.class; do
	grep -q " $entry\$" <<<"$jar_listing" || {
		echo "$ATLAS_OUT/api-impl.jar has no $entry: this is hax-stripped.jar, not hax.jar" >&2
		exit 1; }
done
class_count=$(grep -cE "\.class\$" <<<"$jar_listing")
[ "$class_count" -ge 1000 ] || { echo "only $class_count classes in the jar" >&2; exit 1; }

# Proves the JDK parses these class files. atlas compiles with -source/-target 1.8
# (major 52); anything above 65 would be unloadable on 21.
major=$("$JAVA_HOME/bin/javap" -verbose -cp "$ATLAS_OUT/api-impl.jar" android.os.Looper |
	sed -n 's/.*major version: *//p')
[ -n "$major" ] && [ "$major" -ge 45 ] && [ "$major" -le 65 ] || {
	echo "unexpected class file major version '$major'" >&2; exit 1; }

# ldd from the destination dir: an unresolved library here is a missing artifact.
# It only works natively — the host loader cannot read a foreign-arch object —
# so on a cross build the click's own staging check does this instead
# (linux-port/click/build.sh).
if [ "$PORT_CROSS" = 0 ]; then
	tl_ldd=$(cd "$ATLAS_OUT" && ldd libtranslation_layer_main.so)
	if grep -q "not found" <<<"$tl_ldd"; then
		echo "unresolved dependencies of the installed libtranslation_layer_main.so:" >&2
		grep "not found" <<<"$tl_ldd" >&2
		exit 1
	fi
fi

# The symbols the boot sequence and libtmessages call into.
tl_syms=$("$PORT_NM" -D --defined-only "$ATLAS_OUT/libtranslation_layer_main.so")
for sym in Java_android_os_MessageQueue_nativeInit Java_android_content_Context_native_1get_1apk_1path; do
	grep -q " T $sym\$" <<<"$tl_syms" || {
		echo "libtranslation_layer_main.so does not export $sym" >&2; exit 1; }
done
android_syms=$("$PORT_NM" -D --defined-only "$ATLAS_OUT/libandroid.so.0")
for sym in AndroidBitmap_lockPixels AAssetManager_open; do
	grep -q " T $sym\$" <<<"$android_syms" || {
		echo "libandroid.so.0 does not export $sym" >&2; exit 1; }
done

# The launcher is the other half of libtranslation_layer_main.so's link graph:
# the library imports these from whatever executable loads it, so a missing one
# is not a link error, it is a crash at startup.
#
# The list comes out of the library, not out of this script: a hardcoded set
# stops covering an import the framework adds later, and reads as complete when
# it is not. Five of the bionic_egl* ones are answered by libandroid.so.0, a
# DT_NEEDED of the library, rather than by the executable -- either provider is
# fine, no provider is a startup crash.
tl_undef=$("$PORT_NM" -D --undefined-only "$ATLAS_OUT/libtranslation_layer_main.so" | awk '{print $2}')
launcher_imports=$(grep -E '^(apk_path|atl_window|get_app_data_dir|bionic_)' <<<"$tl_undef" | sort -u)
for launcher_name in android-translation-layer-hotspot android-translation-layer-image; do
	launcher="$ATLAS_OUT/$launcher_name"
	# the image launcher does not exist on a cross build (FR-6)
	[ -x "$launcher" ] || continue

	launcher_syms=$("$PORT_NM" -D --defined-only "$launcher")
	for sym in $launcher_imports; do
		if grep -qE " [BTD] $sym\$" <<<"$launcher_syms"; then continue; fi
		if grep -qE " [BTD] $sym\$" <<<"$android_syms"; then continue; fi
		echo "libtranslation_layer_main.so imports $sym, and neither $launcher_name" >&2
		echo "nor libandroid.so.0 defines it" >&2
		exit 1
	done
done

if [ "$PORT_CROSS" = 0 ]; then
	# everything but libjvm.so, which the run scripts add to LD_LIBRARY_PATH
	launcher_ldd=$(cd "$ATLAS_OUT" && ldd android-translation-layer-hotspot || true)
	missing=$(grep "not found" <<<"$launcher_ldd" | grep -v libjvm || true)
	[ -z "$missing" ] || { echo "unresolved launcher dependencies:" >&2; echo "$missing" >&2; exit 1; }

	# The image launcher's defining property, asserted at build time. It
	# gets its VM from a dlopened .so, so libjvm.so must be neither a DT_NEEDED
	# nor an undefined symbol's provider -- and unlike the hotspot binary,
	# nothing at all may be missing from its ldd.
	if [ -x "$ATLAS_OUT/android-translation-layer-image" ]; then
		image_ldd=$(cd "$ATLAS_OUT" && ldd android-translation-layer-image || true)
		jvm_linked=$(grep libjvm <<<"$image_ldd" || true)
		[ -z "$jvm_linked" ] ||
			{ echo "android-translation-layer-image links libjvm.so:" >&2
			  echo "$jvm_linked" >&2; exit 1; }
		missing=$(grep "not found" <<<"$image_ldd" || true)
		[ -z "$missing" ] ||
			{ echo "unresolved image launcher dependencies:" >&2; echo "$missing" >&2; exit 1; }

		image_undef=$("$PORT_NM" -D --undefined-only "$ATLAS_OUT/android-translation-layer-image")
		if grep -q "JNI_CreateJavaVM" <<<"$image_undef"; then
			echo "android-translation-layer-image imports JNI_CreateJavaVM;" \
			     "it is supposed to dlsym it out of the image" >&2
			exit 1
		fi
	fi
fi

res_listing=$(unzip -l "$ATLAS_OUT/framework-res.apk")
grep -q "resources.arsc" <<<"$res_listing" || {
	echo "framework-res.apk has no resources.arsc" >&2; exit 1; }

[ -s "$ATLAS_OUT/system/etc/fonts.xml" ] || { echo "missing fonts.xml" >&2; exit 1; }

# 12 faces: the sans-serif family of res/fonts.xml, which is what
# TypefaceCollection.cpp's table names. A missing one silently drops a weight.
font_count=$(ls "$ATLAS_OUT/system/fonts"/Roboto-*.ttf 2>/dev/null | wc -l)
[ "$font_count" = 12 ] || {
	echo "system/fonts has $font_count Roboto faces, expected 12" >&2; exit 1; }

# What this jar is for: the app's android.* superclasses, the one thing the
# classpath check could not resolve. Needs build-classpath.sh and build-shim.sh
# to have run: the app's own classes name shim classes too (org.json), so
# checking against half a class path only produces false hits. On a first build
# the shim cannot exist yet — it compiles against this jar — so build-all.sh
# comes back here once it does.
if [ -d "$PORT_OUT/classpath" ] && [ -f "$PORT_OUT/shim.jar" ]; then
	mkdir -p "$PORT_OUT/tools"
	"$JAVA_HOME/bin/javac" -d "$PORT_OUT/tools" "$PORT_DIR/tools/PortClassCheck.java"
	"$JAVA_HOME/bin/java" -cp "$PORT_OUT/tools:$ATLAS_OUT/api-impl.jar:$PORT_OUT/classpath/*" \
		PortClassCheck \
		org.telegram.messenger.ApplicationLoader \
		org.telegram.ui.LaunchActivity \
		org.telegram.ui.IntroActivity

	# Views whose method signatures name a class api-impl lacks: atlas asks
	# every view for its declared methods before drawing it, so one missing
	# parameter type kills the frame, not just that method.
	"$JAVA_HOME/bin/javac" -d "$PORT_OUT/tools" "$PORT_DIR/tools/ViewSignatureCheck.java"
	"$JAVA_HOME/bin/java" -cp "$PORT_OUT/tools:$ATLAS_OUT/api-impl.jar:$PORT_OUT/shim.jar:$PORT_OUT/classpath/*" \
		ViewSignatureCheck "$PORT_OUT"/classpath/*.jar
else
	echo "note: out/classpath/ or out/shim.jar is missing, skipping the app" \
		"class-resolution check (run build-classpath.sh and build-shim.sh," \
		"or build-all.sh, which re-runs this script afterwards)"
fi

# --- provenance -------------------------------------------------------------

jar_sha=$(sha256sum "$ATLAS_OUT/api-impl.jar" | cut -c1-16)

# Sourced by run.sh / build-all.sh so the paths live in one place.
cat >"$ATLAS_OUT/artifacts.env" <<EOF
# Generated by linux-port/build-atlas.sh
# atlas $atlas_branch $atlas_rev$atlas_dirty, built with $jdk_version
ATLAS_ARTIFACTS_DIR="$ATLAS_OUT"
ATLAS_API_IMPL_JAR="$ATLAS_OUT/api-impl.jar"
ATLAS_LAUNCHER="$ATLAS_OUT/android-translation-layer-hotspot"
ATLAS_IMAGE_LAUNCHER="$ATLAS_OUT/android-translation-layer-image"
ATLAS_NATIVES_DIR="$ATLAS_OUT"
ATLAS_FRAMEWORK_RES="$ATLAS_OUT/framework-res.apk"
ATLAS_FONTS_XML="$ATLAS_OUT/system/etc/fonts.xml"
ATLAS_FONTS_DIR="$ATLAS_OUT/system/fonts"
ATLAS_BRANCH="$atlas_branch"
ATLAS_REV="$atlas_rev$atlas_rev_suffix"
ATLAS_API_IMPL_SHA="$jar_sha"
EOF

cat >"$ATLAS_OUT/ARTIFACTS.md" <<EOF
# atlas artifacts for the OpenJDK port

Generated by \`linux-port/build-atlas.sh\`; do not edit, do not commit.

| | |
| --- | --- |
| atlas sources | \`$ATLAS_DIR\` |
| atlas branch | \`$atlas_branch\` at \`$atlas_rev\`$atlas_dirty |
| build dir | \`$ATLAS_BUILDDIR\` |
| JDK | $jdk_version (\`$JAVA_HOME\`) |
| api-impl.jar | sha256 \`$jar_sha…\`, $class_count classes, major version $major |

| File here | atlas source | meson target |
| --- | --- | --- |
| api-impl.jar | \`src/api-impl/hax.jar\` | \`hax.jar\` — javac output, the framework classes |
| libtranslation_layer_main.so | same | \`libtranslation_layer_main\` — the framework natives (Skia, GLFW, libandroidfw) |
| libandroid.so.0, libandroid.so | same | \`libandroid.so.0\` — NDK API surface: \`AndroidBitmap_*\`, \`AAsset*\` |
| libskia.so | \`subprojects/skia/libskia.so\` | skia subproject — DT_NEEDED of the above, found via its \`\$ORIGIN/\` RUNPATH |
| libatl_webview_qt.so | same | optional Qt WebEngine WebView backend |
| android-translation-layer-hotspot | \`src/main-executable-hotspot/\` | the launcher: \`main.c\` + \`vm_hotspot.c\`, links \`libjvm.so\` |
| android-translation-layer-image | same sources | the launcher: \`main.c\` + \`vm_image.c\`, dlopens a native-image \`.so\` instead (x86_64 only) |
| framework-res.apk | \`res/framework-res/framework-res.apk\` | \`framework-res.apk\` — framework resource table, goes on the classpath |
| system/etc/fonts.xml | \`\$ATLAS_DIR/res/fonts.xml\` | \`install_data\` — see the note below |
| system/fonts/Roboto-*.ttf | \`\$ATLAS_DIR/res/fonts/\` | \`install_data\` — the sans-serif family, read by the framework |

atlas's own \`api-impl.jar\` is \`hax-stripped.jar\` after \`dx --dex\` and holds
nothing but a \`classes.dex\`; HotSpot cannot read it.

The port installs \`hax.jar\`, not \`hax-stripped.jar\`. The stripped jar exists for
ART: a class defined both there and in the app's dex makes ART reject the app's
oat file, so \`android/view/OnReceiveContentListener\`,
\`android/view/WindowInsetsAnimation\$Callback\` and
\`android/window/OnBackInvokedCallback\` are dropped before dexing. A JVM class
path has no duplicate-class check, and nothing in \`out/classpath/\` defines those
three — LaunchActivity needs \`OnBackInvokedCallback\` at load time.

## Fonts

\`system/fonts/\` is read by the framework. \`TypefaceCollection.cpp\` builds the
generic families — \`sans-serif\` and its weight aliases — from these twelve
Roboto faces, found at \`system/fonts\` beside \`libtranslation_layer_main.so\`
(\`ATL_FONT_DIR\` overrides the location). Without them the generic names fall
back to fontconfig, which on a desktop hands back Noto Sans and on the phone
hands back Ubuntu — different metrics from Android's in both cases.

\`system/etc/fonts.xml\` is not read on this path. It is where the face and weight
table in \`TypefaceCollection.cpp\` comes from, but nothing parses it at runtime:
the only consumer of \`/system/etc/fonts.xml\` is the path-override table in
atlas's own executable (\`src/main-executable/libc_bio_path_overrides.c\`), which
is part of the bionic shim the port does not use. It is copied for reference.
EOF

echo "atlas ready in $ATLAS_OUT (atlas $atlas_branch $atlas_rev$atlas_dirty," \
	"$class_count framework classes, api-impl.jar sha $jar_sha)"
