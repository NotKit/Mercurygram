#!/bin/bash
# Custom clickable builder for the Ubuntu Touch click of the OpenJDK port.
#
# Runs inside a CROSS clickable container (amd64 host toolchain, aarch64 target
# sysroot), which is what keeps a rebuild in minutes: nothing is compiled by an
# emulated arm64 toolchain. The split is
#
#   arch-independent, built on the host first (linux-port/build-all.sh):
#       out/classpath/*.jar   the app and its dependencies
#       out/app.apk           resources, assets and the manifest
#   arm64, built here:
#       atlas                 framework natives + the HotSpot launcher
#                             (api-impl.jar comes out of the same build; javac is
#                             a host tool, so it is the same bytecode either way)
#       libtmessages.so       and the four static deps it links
#       shim.jar + libportshim.so  the libcore/dalvik compat shim
#   prebuilt, staged by stage-prebuilt.sh:
#       art support libs, ART's boot jars, GLFW, libskia.so — see PROVENANCE.md
#
# Every step is stamped in $BUILD_DIR/stamps, so a re-run only redoes what
# changed. The port's own build scripts do the work; this file only retargets
# them (PORT_ARCH=arm64) and assembles the click.
set -euo pipefail

ROOT="${ROOT:?not run through clickable}"
BUILD_DIR="${BUILD_DIR:?}"
INSTALL_DIR="${INSTALL_DIR:?}"
ARCH="${ARCH:-arm64}"
JOBS="${NUM_PROCS:-$(nproc)}"

PKG="mercurygram-jvm.nekit"
HOOK="mercurygram-jvm"

[ "$ARCH" = "arm64" ] ||
	{ echo "this package is arm64 only (ARCH=$ARCH)" >&2; exit 1; }

CLICK_DIR="$ROOT/linux-port/click"
HOST_OUT="$ROOT/linux-port/out"          # products of the x86_64 host build
PREBUILT="$HOST_OUT/click-prebuilt"      # staged by stage-prebuilt.sh
STAGE="$BUILD_DIR/stage"
PREFIX="$STAGE/usr"                      # build-time sysroot for atlas
STAMPS="$BUILD_DIR/stamps"

log()        { echo -e "\033[1;34m[click]\033[0m $*"; }
stamp()      { [ -f "$STAMPS/$1.done" ]; }
done_stamp() { mkdir -p "$STAMPS"; touch "$STAMPS/$1.done"; }

# --- 0. the port's environment, retargeted at arm64 -------------------------

export PORT_ARCH="arm64"
# arm64 products stay out of the host build's out/ — same scripts, own tree.
export PORT_OUT="$BUILD_DIR/port"
# javac, jar and every other Java tool: host. The JDK the app will run on: arm64.
export JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
export PORT_TARGET_JAVA_HOME="/usr/lib/jvm/java-21-openjdk-arm64"
export PORT_SKIA_PREBUILT="$PREBUILT/skia"

source "$ROOT/linux-port/env.sh"

[ "$PORT_CROSS" = 1 ] ||
	{ echo "expected a cross build, got PORT_TRIPLE=$PORT_TRIPLE" >&2; exit 1; }

# atlas resolves art-standalone and glfw3 through pkg-config, links against the
# staged .so files and includes their headers; the cross gcc reads LIBRARY_PATH.
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/art${LIBRARY_PATH:+:$LIBRARY_PATH}"
# meson ignores LIBRARY_PATH for the host machine of a cross build; these end up
# in the cross file's [built-in options] instead (write-meson-cross.sh).
export PORT_CROSS_LIB_DIRS="$PREFIX/lib $PREFIX/lib/art"
export PORT_CROSS_INCLUDE_DIRS="$PREFIX/include"

log "target $PORT_TRIPLE, $JOBS jobs"
log "host JDK $JAVA_HOME, target JDK $PORT_TARGET_JAVA_HOME"

# --- 1. inputs from the host build ------------------------------------------

for f in "$HOST_OUT/app.apk" "$HOST_OUT/classpath"; do
	[ -e "$f" ] || {
		echo "missing $f — run linux-port/build-all.sh on the host first" >&2
		exit 1
	}
done
jar_count=$(find "$HOST_OUT/classpath" -name '*.jar' | wc -l)
[ "$jar_count" -gt 50 ] ||
	{ echo "only $jar_count jars in $HOST_OUT/classpath; re-run build-classpath.sh" >&2; exit 1; }

[ -f "$PREBUILT/PROVENANCE.md" ] || {
	echo "no arm64 prebuilt inputs at $PREBUILT" >&2
	echo "run linux-port/click/stage-prebuilt.sh on the host first" >&2
	exit 1
}

[ -f "$PORT_TARGET_JAVA_HOME/lib/server/libjvm.so" ] || {
	echo "no arm64 JVM at $PORT_TARGET_JAVA_HOME (openjdk-21-jdk-headless:arm64)" >&2
	exit 1
}

# --- 2. build-time sysroot --------------------------------------------------

if ! stamp "prefix-$(sha256sum "$PREBUILT/PROVENANCE.md" | cut -c1-12)"; then
	log "staging the build-time sysroot in $PREFIX"
	mkdir -p "$PREFIX"
	rsync -a --delete-after "$PREBUILT/usr/" "$PREFIX/"

	# art-standalone.pc puts -lart -lnativebridge on every link line that uses
	# it. Nothing in this port calls into either (the framework's DT_NEEDED are
	# libandroidfw and liblog), so an empty .so of each satisfies the linker and
	# --as-needed drops it again — instead of copying 240 MB of ART that the
	# click would never load.
	for stub in art nativebridge; do
		"$PORT_CC" -shared -o "$PREFIX/lib/art/lib$stub.so" -x c /dev/null
	done

	# dx looks for dx.jar in ../framework relative to its own bin/ before it
	# starts guessing from the linker's search path.
	mkdir -p "$PREFIX/framework"
	cp "$PREFIX/lib/java/dx.jar" "$PREFIX/framework/dx.jar"

	mkdir -p "$PREFIX/lib/pkgconfig"
	cat >"$PREFIX/lib/pkgconfig/art-standalone.pc" <<EOF
# Generated by linux-port/click/build.sh for the arm64 cross build.
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: art-standalone
Description: Android ART runtime (boot jars and libandroidfw only, see PROVENANCE.md)
Version: 0.0.0
Libs: -L\${libdir}/art -lart -lnativebridge -landroidfw
Cflags: -I\${includedir} -I\${includedir}/androidfw
EOF
	cat >"$PREFIX/lib/pkgconfig/glfw3.pc" <<EOF
# Generated by linux-port/click/build.sh for the arm64 cross build.
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: GLFW
Description: GLFW 3.4 (prebuilt, see PROVENANCE.md)
Version: 3.4
Libs: -L\${libdir} -lglfw
Cflags: -I\${includedir}
EOF
	done_stamp "prefix-$(sha256sum "$PREBUILT/PROVENANCE.md" | cut -c1-12)"
fi

# --- 3. atlas: framework natives, api-impl.jar and the HotSpot launcher -----

# Before libtmessages: its CMake finds atlas's libandroid.so.0 at link time.
log "atlas (arm64, prebuilt skia)"
"$ROOT/linux-port/build-atlas.sh"

# --- 3b. the compat shim ----------------------------------------------------

# shim.jar is bytecode, but libportshim.so is not: without an arm64 build of it
# every libcore.util.NativeAllocationRegistry falls back to leaking its native
# peer ("port-shim: libportshim.so is not loaded" in the log).
log "libcore/dalvik compat shim"
"$ROOT/linux-port/build-shim.sh"

# --- 4. the static native dependencies and libtmessages.so ------------------

log "boringssl, libvpx, dav1d, ffmpeg, libtmessages ($PORT_TRIPLE)"
"$ROOT/linux-port/native/build_boringssl_linux.sh"
"$ROOT/linux-port/native/build_libvpx_linux.sh"
"$ROOT/linux-port/native/build_dav1d_linux.sh"
"$ROOT/linux-port/native/build_ffmpeg_linux.sh"
"$ROOT/linux-port/native/build_tmessages_linux.sh"

# --- 5. assemble the click tree ---------------------------------------------

log "assembling $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/atlas" "$INSTALL_DIR/classpath"

# One flat directory for every native object, launcher included: atlas's natives
# find each other through their $ORIGIN/ RUNPATH, and the absolute paths the
# build baked into it (this build tree) do not exist on the device.
cp "$ATLAS_OUT/android-translation-layer-hotspot" "$INSTALL_DIR/lib/"
cp "$ATLAS_OUT/libtranslation_layer_main.so" "$ATLAS_OUT/libandroid.so.0" \
   "$ATLAS_OUT/libskia.so" "$INSTALL_DIR/lib/"
ln -sfn libandroid.so.0 "$INSTALL_DIR/lib/libandroid.so"
cp -a "$PORT_OUT"/libtmessages.49.so "$PORT_OUT"/libtmessages.so \
      "$PORT_OUT"/libOpenSLES.so.1 "$PORT_OUT"/libportshim.so "$INSTALL_DIR/lib/"

# What libtranslation_layer_main.so needs and Ubuntu Touch does not ship:
# art's libandroidfw and its own dependencies, and GLFW 3.4.
cp "$PREFIX"/lib/art/*.so "$INSTALL_DIR/lib/"
rm -f "$INSTALL_DIR/lib/libart.so" "$INSTALL_DIR/lib/libnativebridge.so"  # the stubs
cp -a "$PREFIX"/lib/libglfw.so* "$INSTALL_DIR/lib/"


cp "$ATLAS_OUT/api-impl.jar" "$ATLAS_OUT/framework-res.apk" "$INSTALL_DIR/atlas/"
mkdir -p "$INSTALL_DIR/atlas/system/etc"
cp "$ATLAS_OUT/system/etc/fonts.xml" "$INSTALL_DIR/atlas/system/etc/"

# The bundled Roboto faces the framework lays text out against. On the desktop
# it finds them beside its own library; here the natives are in lib/ and the
# atlas data in atlas/, so run.sh points ATL_FONT_DIR at this.
mkdir -p "$INSTALL_DIR/atlas/system/fonts"
cp "$ATLAS_OUT/system/fonts"/*.ttf "$ATLAS_OUT/system/fonts/NOTICE" \
   "$INSTALL_DIR/atlas/system/fonts/"

cp "$PORT_OUT/shim.jar" "$INSTALL_DIR/classpath/"
cp "$HOST_OUT"/classpath/*.jar "$INSTALL_DIR/classpath/"
cp "$HOST_OUT/app.apk" "$INSTALL_DIR/app.apk"

# The JVM: a jlink image of the modules the app reaches, not a copy of the whole
# JDK (207 MB -> 75 MB). jlink is arch-neutral, so the host one builds the arm64
# image out of the arm64 jmods; nothing here has to run under qemu.
#
# The module set is $PORT_JVM_MODULES below. jdeps over classpath/ + api-impl
# finds java.{base,compiler,desktop,instrument,management,sql} and jdk.unsupported
# (java.xml and java.datatransfer follow transitively); the rest is what static
# analysis cannot see — locales, EC for TLS, the JDWP agent the launcher's
# JDWP_LISTEN needs. Re-run this when a dependency is added:
#
#   jdeps --ignore-missing-deps --print-module-deps --multi-release 21 \
#         -cp 'classpath/*:atlas/api-impl.jar' classpath/*.jar atlas/api-impl.jar
#
# A jlink image also fixes what --copy-unsafe-links used to paper over: Debian's
# JDK is a tree of symlinks into /etc/java-21-openjdk and /etc/ssl/certs, none of
# which exists on the device. jlink writes real files, including a populated
# cacerts (109 CAs, upstream's set rather than the build host's).
#
# Java debug attributes are kept on purpose: --strip-java-debug-attributes saves
# another 6 MB and costs line numbers in every JDK frame of every stack trace.
PORT_JVM_MODULES="java.base,java.compiler,java.desktop,java.instrument,java.logging"
PORT_JVM_MODULES="$PORT_JVM_MODULES,java.management,java.naming,java.sql"
PORT_JVM_MODULES="$PORT_JVM_MODULES,jdk.charsets,jdk.crypto.ec,jdk.jdwp.agent"
PORT_JVM_MODULES="$PORT_JVM_MODULES,jdk.localedata,jdk.unsupported,jdk.zipfs"

[ -d "$PORT_TARGET_JAVA_HOME/jmods" ] || {
	echo "no jmods at $PORT_TARGET_JAVA_HOME (openjdk-21-jdk-headless:arm64)" >&2
	echo "jlink needs them; the jre package alone is not enough" >&2
	exit 1
}
# jlink refuses jmods from another JDK build. Both packages come from the same
# Debian release in the container, so this only fires if one was pinned.
host_build=$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$JAVA_HOME/release")
target_build=$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$PORT_TARGET_JAVA_HOME/release")
[ "$host_build" = "$target_build" ] || {
	echo "JDK mismatch: host jlink is $host_build, arm64 jmods are $target_build" >&2
	exit 1
}

log "jlinking the arm64 JVM ($PORT_JVM_MODULES)"
rm -rf "$INSTALL_DIR/jvm"
"$JAVA_HOME/bin/jlink" \
	--module-path "$PORT_TARGET_JAVA_HOME/jmods" \
	--add-modules "$PORT_JVM_MODULES" \
	--no-header-files --no-man-pages --compress=zip-6 \
	--output "$INSTALL_DIR/jvm"

# libjvm.so is the launcher's DT_NEEDED and the JVM derives java.home from where
# it was loaded from, so this one file decides whether the image is usable.
[ -f "$INSTALL_DIR/jvm/lib/server/libjvm.so" ] ||
	{ echo "jlink produced no lib/server/libjvm.so" >&2; exit 1; }
log "  JVM image: $(du -sh "$INSTALL_DIR/jvm" | cut -f1)"

install -m 0755 "$CLICK_DIR/run.sh" "$INSTALL_DIR/run.sh"
cp "$CLICK_DIR/$HOOK.desktop" "$CLICK_DIR/$HOOK.apparmor" "$CLICK_DIR/$HOOK.svg" "$INSTALL_DIR/"

# clickable fills in @CLICK_ARCH@ and @CLICK_FRAMEWORK@; the version is the app's
# own, from gradle.properties, so a click is identifiable as that build.
app_version=$(sed -n 's/^APP_VERSION_NAME=//p' "$ROOT/gradle.properties" | tr -d ' \r')
sed "s|@CLICK_VERSION@|${app_version:-0.0.0}|" "$CLICK_DIR/manifest.json" \
	>"$INSTALL_DIR/manifest.json"

# --- 6. bundle what the device does not have --------------------------------

# device-libs.txt is the device's own `ldconfig -p`. Anything the click needs
# that is not there has to travel with it: Ubuntu Touch has no GLFW, no
# libportal, no libswscale, no maliit or content-hub glib bindings. Closure,
# because a bundled library brings its own DT_NEEDED (libswscale -> libavutil).
device_libs="$CLICK_DIR/device-libs.txt"
[ -f "$device_libs" ] || { echo "missing $device_libs" >&2; exit 1; }

search_dirs=("/usr/lib/$PORT_TRIPLE" "/lib/$PORT_TRIPLE" "$PREFIX/lib" "$PREFIX/lib/art")
unavailable=""
while :; do
	needed=$(for f in "$INSTALL_DIR"/lib/*; do
			readelf -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
		done | sort -u)
	# The JVM's own libraries count as present: libjvm.so and friends live in
	# jvm/lib/, which run.sh puts on LD_LIBRARY_PATH.
	have=$( { ls "$INSTALL_DIR/lib"
		  find "$INSTALL_DIR/jvm" -name '*.so' -printf '%f\n' 2>/dev/null
		  echo "$unavailable"
		  grep -v '^#' "$device_libs"; } | sort -u)
	missing=$(comm -23 <(echo "$needed") <(echo "$have"))
	[ -n "$missing" ] || break
	for lib in $missing; do
		found=""
		for d in "${search_dirs[@]}"; do
			[ -e "$d/$lib" ] && { cp -L "$d/$lib" "$INSTALL_DIR/lib/$lib"; found=1; break; }
		done
		if [ -n "$found" ]; then
			log "  bundling $lib (not on the device)"
		else
			echo "  WARNING: $lib is neither on the device nor in this container" >&2
			unavailable="$unavailable$lib"$'\n'
		fi
	done
done
[ -z "$unavailable" ] || {
	echo "unresolvable libraries — the app would fail to start:" >&2
	echo "$unavailable" >&2
	exit 1
}

# --- 7. verify what is about to be packaged ---------------------------------

log "verifying the staged tree"
bad=0
while read -r f; do
	case "$(file -b "$f")" in
	*"ARM aarch64"*) ;;
	*) echo "  NOT aarch64: $f  ($(file -b "$f" | cut -c1-60))" >&2; bad=1 ;;
	esac
done < <(find "$INSTALL_DIR/lib" "$INSTALL_DIR/jvm/lib" "$INSTALL_DIR/jvm/bin" -type f \
	\( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null | grep -v '\.jar$')
[ "$bad" = 0 ] || { echo "the click holds objects for the wrong architecture" >&2; exit 1; }

log "click tree staged: $(du -sh "$INSTALL_DIR" | cut -f1)"
