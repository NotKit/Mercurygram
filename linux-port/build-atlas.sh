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
#   hax-stripped.jar        the above minus three compile-only stubs the app
#                           bundles itself (meson.build:274) -- THIS is the
#                           pre-dex jar the port puts on the HotSpot classpath
#   api-impl.jar            hax-stripped.jar run through `dx --dex`
#                           (meson.build:279) -- a classes.dex, useless here
#
# So out/atlas/api-impl.jar is a copy of hax-stripped.jar, not of atlas's
# identically named dexed jar. The verification below asserts that.
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
for tool in meson ninja gn clang; do
	command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done

# The skia subproject is the shared ~8 GB checkout; never download it again.
if [ ! -e "$ATLAS_DIR/subprojects/skia" ]; then
	[ -d "$ATLAS_SKIA_DIR" ] ||
		{ echo "no skia sources: set ATLAS_SKIA_DIR (tried $ATLAS_SKIA_DIR)" >&2; exit 1; }
	ln -s "$ATLAS_SKIA_DIR" "$ATLAS_DIR/subprojects/skia"
	echo "linked subprojects/skia -> $ATLAS_SKIA_DIR"
fi

# builddir-relative source | destination name | ninja target | required
artifacts=(
	"hax-stripped.jar|api-impl.jar|hax-stripped.jar|yes"
	"libtranslation_layer_main.so|libtranslation_layer_main.so|libtranslation_layer_main.so|yes"
	"libandroid.so.0|libandroid.so.0|libandroid.so.0|yes"
	"subprojects/skia/libskia.so|libskia.so|subprojects/skia/libskia.so|yes"
	"res/framework-res/framework-res.apk|framework-res.apk|res/framework-res/framework-res.apk|yes"
	"android-translation-layer-hotspot|android-translation-layer-hotspot|android-translation-layer-hotspot|yes"
	"libatl_webview_qt.so|libatl_webview_qt.so|libatl_webview_qt.so|no"
)

# --- configure --------------------------------------------------------------

# meson picks the JDK for its `jni` dependency and for javac from JAVA_HOME/PATH
# at setup time, so a builddir remembers the JDK it was configured with. The
# framework must be compiled by the same JDK the port runs on (21), and the
# system default here is 25 -- hence the stamp and the forced reconfigure.
jdk_stamp="$ATLAS_BUILDDIR/.port-jdk"
if [ -f "$ATLAS_BUILDDIR/build.ninja" ] &&
   [ "$(cat "$jdk_stamp" 2>/dev/null || true)" != "$JAVA_HOME" ]; then
	echo "builddir was configured with a different JDK than $JAVA_HOME, reconfiguring"
	reconfigure=1
fi

if [ ! -f "$ATLAS_BUILDDIR/build.ninja" ]; then
	meson setup "$ATLAS_BUILDDIR" "$ATLAS_DIR"
	echo "$JAVA_HOME" >"$jdk_stamp"
elif [ "$reconfigure" = 1 ]; then
	# --wipe, not --reconfigure: the java compiler is cached in coredata, so a JDK
	# change only takes effect on a from-scratch configure. It costs a full rebuild
	# including skia, so the stamp above exists to make this happen at most once.
	meson setup --wipe "$ATLAS_BUILDDIR" "$ATLAS_DIR"
	echo "$JAVA_HOME" >"$jdk_stamp"
fi

# --- build ------------------------------------------------------------------

# javac writes generated JNI headers back into the atlas source tree
# (src/api-impl/meson.build's -h flag). Those belong on the atlas branch, so the
# build is allowed to touch them -- but nothing else.
tree_before=$(git -C "$ATLAS_DIR" status --porcelain)

targets=()
for entry in "${artifacts[@]}"; do
	IFS='|' read -r _src _dst target required <<<"$entry"
	[ "$required" = yes ] && targets+=("$target")
done
ninja -C "$ATLAS_BUILDDIR" "${targets[@]}"

tree_after=$(git -C "$ATLAS_DIR" status --porcelain)
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

# DT_NEEDED of libtranslation_layer_main.so is the soname; the RUNPATH's leading
# $ORIGIN/ is why libskia.so and libandroid.so.0 work from this one flat dir.
ln -sfn libandroid.so.0 "$ATLAS_OUT/libandroid.so"

# fonts.xml lives in the atlas source tree, not the builddir (meson.build installs
# res/fonts.xml to <datadir>/atl/system/etc). Mirror that suffix so the same path
# tail works if the launcher ever needs to point at it.
mkdir -p "$ATLAS_OUT/system/etc"
cp "$ATLAS_DIR/res/fonts.xml" "$ATLAS_OUT/system/etc/fonts.xml"

atlas_branch=$(git -C "$ATLAS_DIR" branch --show-current)
atlas_rev=$(git -C "$ATLAS_DIR" rev-parse --short HEAD)
atlas_dirty=""
[ -n "$(git -C "$ATLAS_DIR" status --porcelain)" ] && atlas_dirty=" (working tree dirty)"
jdk_version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)

# --- verification -----------------------------------------------------------

jar_listing=$(unzip -l "$ATLAS_OUT/api-impl.jar")
for entry in android/view/View.class android/os/Looper.class android/content/Context.class; do
	grep -q " $entry\$" <<<"$jar_listing" || {
		echo "$ATLAS_OUT/api-impl.jar has no $entry" >&2; exit 1; }
done
if grep -q "classes.dex" <<<"$jar_listing"; then
	echo "$ATLAS_OUT/api-impl.jar is dexed: install hax-stripped.jar, not api-impl.jar" >&2
	exit 1
fi
class_count=$(grep -cE "\.class\$" <<<"$jar_listing")
[ "$class_count" -ge 1000 ] || { echo "only $class_count classes in the jar" >&2; exit 1; }

# Proves the JDK parses these class files. atlas compiles with -source/-target 1.8
# (major 52); anything above 65 would be unloadable on 21.
major=$("$JAVA_HOME/bin/javap" -verbose -cp "$ATLAS_OUT/api-impl.jar" android.os.Looper |
	sed -n 's/.*major version: *//p')
[ -n "$major" ] && [ "$major" -ge 45 ] && [ "$major" -le 65 ] || {
	echo "unexpected class file major version '$major'" >&2; exit 1; }

# ldd from the destination dir: an unresolved library here is a missing artifact.
tl_ldd=$(cd "$ATLAS_OUT" && ldd libtranslation_layer_main.so)
if grep -q "not found" <<<"$tl_ldd"; then
	echo "unresolved dependencies of the installed libtranslation_layer_main.so:" >&2
	grep "not found" <<<"$tl_ldd" >&2
	exit 1
fi

# The symbols the boot sequence and libtmessages call into.
tl_syms=$(nm -D --defined-only "$ATLAS_OUT/libtranslation_layer_main.so")
for sym in Java_android_os_MessageQueue_nativeInit Java_android_content_Context_native_1get_1apk_1path; do
	grep -q " T $sym\$" <<<"$tl_syms" || {
		echo "libtranslation_layer_main.so does not export $sym" >&2; exit 1; }
done
android_syms=$(nm -D --defined-only "$ATLAS_OUT/libandroid.so.0")
for sym in AndroidBitmap_lockPixels AAssetManager_open; do
	grep -q " T $sym\$" <<<"$android_syms" || {
		echo "libandroid.so.0 does not export $sym" >&2; exit 1; }
done

# The launcher is the other half of libtranslation_layer_main.so's link graph:
# the library imports these from whatever executable loads it, so a missing one
# is not a link error, it is a crash at startup.
launcher="$ATLAS_OUT/android-translation-layer-hotspot"
launcher_syms=$(nm -D --defined-only "$launcher")
tl_undef=$(nm -D --undefined-only "$ATLAS_OUT/libtranslation_layer_main.so" | awk '{print $2}')
for sym in apk_path atl_window get_app_data_dir bionic_dlopen bionic_dlsym \
	bionic_eglCreateWindowSurface bionic_eglDestroySurface bionic_eglGetDisplay \
	bionic_eglMakeCurrent bionic_eglSwapBuffers bionic_glBindFramebuffer
do
	grep -qx "$sym" <<<"$tl_undef" || continue
	grep -qE " [BTD] $sym\$" <<<"$launcher_syms" || {
		echo "libtranslation_layer_main.so imports $sym, but the launcher does not define it" >&2
		exit 1; }
done

# everything but libjvm.so, which the run scripts add to LD_LIBRARY_PATH
launcher_ldd=$(cd "$ATLAS_OUT" && ldd android-translation-layer-hotspot || true)
missing=$(grep "not found" <<<"$launcher_ldd" | grep -v libjvm || true)
[ -z "$missing" ] || { echo "unresolved launcher dependencies:" >&2; echo "$missing" >&2; exit 1; }

res_listing=$(unzip -l "$ATLAS_OUT/framework-res.apk")
grep -q "resources.arsc" <<<"$res_listing" || {
	echo "framework-res.apk has no resources.arsc" >&2; exit 1; }

[ -s "$ATLAS_OUT/system/etc/fonts.xml" ] || { echo "missing fonts.xml" >&2; exit 1; }

# What this jar is for: the app's android.* superclasses, the one thing the
# classpath check could not resolve. Needs build-classpath.sh to have run.
if [ -d "$PORT_OUT/classpath" ]; then
	mkdir -p "$PORT_OUT/tools"
	"$JAVA_HOME/bin/javac" -d "$PORT_OUT/tools" "$PORT_DIR/tools/PortClassCheck.java"
	"$JAVA_HOME/bin/java" -cp "$PORT_OUT/tools:$ATLAS_OUT/api-impl.jar:$PORT_OUT/classpath/*" \
		PortClassCheck \
		org.telegram.messenger.ApplicationLoader \
		org.telegram.ui.LaunchActivity \
		org.telegram.ui.IntroActivity
else
	echo "note: out/classpath/ is missing, skipping the app class-resolution check" \
		"(run build-classpath.sh)"
fi

# --- provenance -------------------------------------------------------------

jar_sha=$(sha256sum "$ATLAS_OUT/api-impl.jar" | cut -c1-16)

# Sourced by run.sh / build-all.sh so the paths live in one place.
cat >"$ATLAS_OUT/artifacts.env" <<EOF
# Generated by linux-port/build-atlas.sh
# atlas $atlas_branch $atlas_rev$atlas_dirty, built with $jdk_version
ATLAS_ARTIFACTS_DIR="$ATLAS_OUT"
ATLAS_API_IMPL_JAR="$ATLAS_OUT/api-impl.jar"
ATLAS_NATIVES_DIR="$ATLAS_OUT"
ATLAS_FRAMEWORK_RES="$ATLAS_OUT/framework-res.apk"
ATLAS_FONTS_XML="$ATLAS_OUT/system/etc/fonts.xml"
ATLAS_BRANCH="$atlas_branch"
ATLAS_REV="$atlas_rev"
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
| api-impl.jar | \`hax-stripped.jar\` | \`hax-stripped\` (meson.build:274) — pre-dex framework classes |
| libtranslation_layer_main.so | same | \`libtranslation_layer_main\` — the framework natives (Skia, GLFW, libandroidfw) |
| libandroid.so.0, libandroid.so | same | \`libandroid.so.0\` — NDK API surface: \`AndroidBitmap_*\`, \`AAsset*\` |
| libskia.so | \`subprojects/skia/libskia.so\` | skia subproject — DT_NEEDED of the above, found via its \`\$ORIGIN/\` RUNPATH |
| libatl_webview_qt.so | same | optional Qt WebEngine WebView backend |
| framework-res.apk | \`res/framework-res/framework-res.apk\` | \`framework-res.apk\` — framework resource table, goes on the classpath |
| system/etc/fonts.xml | \`\$ATLAS_DIR/res/fonts.xml\` | \`install_data\` — see the note below |

atlas's own \`api-impl.jar\` is \`hax-stripped.jar\` after \`dx --dex\` and holds
nothing but a \`classes.dex\`; HotSpot cannot read it.

\`hax-stripped.jar\` drops \`android/view/OnReceiveContentListener\`,
\`android/view/WindowInsetsAnimation\$Callback\` and
\`android/window/OnBackInvokedCallback\` from \`hax.jar\`; the app's bundled androidx
provides them from \`out/classpath/\`.

## fonts.xml

Nothing in the framework reads it on this path: atlas resolves fonts through
Skia's fontconfig \`SkFontMgr\` (\`src/api-impl-jni/hwui/TypefaceCollection.cpp\`),
and the only consumer of \`/system/etc/fonts.xml\` is the path-override table in
atlas's own executable (\`src/main-executable/libc_bio_path_overrides.c\`), which
is part of the bionic shim the port does not use. It is copied for reference and
in case a later minikin path needs it.
EOF

echo "atlas ready in $ATLAS_OUT (atlas $atlas_branch $atlas_rev$atlas_dirty," \
	"$class_count framework classes, api-impl.jar sha $jar_sha)"
