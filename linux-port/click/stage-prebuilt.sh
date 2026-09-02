#!/bin/bash
# Copy the arm64 inputs the click build cannot produce itself into
# linux-port/out/click-prebuilt/. Runs on the host, before clickable:
# the build container only sees this repository, so anything from outside has to
# be inside the tree first.
#
# What is here and why it is not built from source:
#
#   art_standalone support libs   libtranslation_layer_main.so links libandroidfw
#                                 (AssetManager2, ResTable) and liblog. Building
#                                 art_standalone needs a native arm64 toolchain
#                                 (it has no cross build), which is what makes the
#                                 sibling ART packaging a multi-hour qemu build.
#   art_standalone boot jars      javac compiles api-impl against ART's libcore,
#                                 not the JDK's. Arch-independent.
#   bionic_translation stubs      only to satisfy atlas's configure-time
#                                 cc.find_library('c_bio'/'dl_bio'); the HotSpot
#                                 launcher brings its own bionic_* symbols.
#   GLFW 3.4                      atlas needs the libdecor init hint; noble ships 3.3.
#   libskia.so + skia headers     skia's gn build is not driven from atlas's meson
#                                 and does not cross-compile from it.
#
# Source: the sibling ART click packaging's arm64 build tree ($UT_ATL_PREBUILT),
# which builds all of the above natively. See README.md for how to (re)create it.
#
# Usage: linux-port/click/stage-prebuilt.sh [--force]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

# Two possible sources, in order:
#
#   1. the ATL SDK the atl-touch CI publishes per commit (atl-sdk-<arch>.tar.zst
#      on release sdk-<sha>). Self-contained and needs nothing outside this repo,
#      which is what lets the click build in CI.
#   2. the sibling ART packaging's arm64 build tree ($UT_ATL_PREBUILT), which
#      builds the same things natively. Machine-local.
#
# ATL_SDK_TAG: auto (default) derives sdk-<sha> from the atlas checkout and falls
# back to the local tree when that release has nothing for us; off|none forces
# the local tree; an explicit sdk-<sha> is an error if it cannot be used.
ATL_SDK_REPO="${ATL_SDK_REPO:-NotKit/atl-touch}"
ATL_SDK_TAG="${ATL_SDK_TAG-auto}"
ATL_PREBUILT="${UT_ATL_PREBUILT:-/home/nekit/UT/mercurygram-click-packaging/build/aarch64-linux-gnu/app}"

SDK_DIR=""
sdk_tag=""
if [ -n "$ATL_SDK_TAG" ] && [ "$ATL_SDK_TAG" != off ] && [ "$ATL_SDK_TAG" != none ]; then
	sdk_tag="$ATL_SDK_TAG"
	forced=1
	if [ "$ATL_SDK_TAG" = auto ]; then
		forced=""
		sha=$(git -C "$ATLAS_DIR" rev-parse --short=7 HEAD 2>/dev/null || true)
		sdk_tag="${sha:+sdk-$sha}"
	fi
	if [ -z "$sdk_tag" ]; then
		echo "no atlas checkout to derive an SDK tag from; using $ATL_PREBUILT"
	else
		dl="$PORT_OUT/downloads"; mkdir -p "$dl"
		archive="$dl/atl-sdk-$PORT_ARCH-$sdk_tag.tar.zst"
		url="https://github.com/$ATL_SDK_REPO/releases/download/$sdk_tag/atl-sdk-$PORT_ARCH.tar.zst"
		if [ ! -f "$archive" ] && ! curl -Lf --retry 3 -o "$archive.tmp" "$url"; then
			rm -f "$archive.tmp"
			[ -z "$forced" ] || { echo "SDK $sdk_tag not downloadable: $url" >&2; exit 1; }
			echo "SDK $sdk_tag not published; using $ATL_PREBUILT"
		else
			[ -f "$archive" ] || mv "$archive.tmp" "$archive"
			# The release carries a .sha256 beside the tarball; a missing one is
			# not fatal, a mismatching one is.
			if curl -Lf --retry 3 -so "$archive.sha256" "$url.sha256"; then
				want=$(awk '{print $1}' "$archive.sha256")
				have=$(sha256sum "$archive" | awk '{print $1}')
				[ "$want" = "$have" ] || { echo "SDK $sdk_tag checksum mismatch" >&2; exit 1; }
			fi
			SDK_DIR="$PORT_OUT/atl-sdk/$sdk_tag"
			rm -rf "$SDK_DIR"; mkdir -p "$SDK_DIR"
			zstd -dc "$archive" | tar -C "$SDK_DIR" -x
			# An SDK from before the headers were packaged cannot serve this
			# build; say so rather than failing later inside meson.
			if [ ! -d "$SDK_DIR/usr/include/androidfw" ] || [ ! -d "$SDK_DIR/usr/include/skia/include" ]; then
				[ -z "$forced" ] || {
					echo "SDK $sdk_tag has no include/ tree: it predates" >&2
					echo "atl-touch's 'ci: ship the headers a source consumer needs'" >&2
					exit 1
				}
				echo "SDK $sdk_tag has no include/ tree (predates the headers change); using $ATL_PREBUILT"
				SDK_DIR=""
			fi
		fi
	fi
fi

if [ -n "$SDK_DIR" ]; then
	SRC_DESC="ATL SDK $sdk_tag ($ATL_SDK_REPO)"
	SRC_STAGE="$SDK_DIR/usr"
	SRC_SKIA_LIB="$SDK_DIR/usr/lib/libskia.so"
	SRC_SKIA_INC="$SDK_DIR/usr/include/skia/include"
	SRC_SKIA_MODULES="$SDK_DIR/usr/include/skia/modules"
else
	SRC_DESC="$ATL_PREBUILT"
	SRC_STAGE="$ATL_PREBUILT/stage/usr"
	SRC_SKIA_LIB="$ATL_PREBUILT/atlas-build/subprojects/skia/libskia.so"
	SRC_SKIA_INC="${ATLAS_SKIA_DIR}/include"
	SRC_SKIA_MODULES="${ATLAS_SKIA_DIR}/modules"
fi

OUT="$PORT_OUT/click-prebuilt"
force=0
[ "${1:-}" = "--force" ] && force=1

if [ -f "$OUT/PROVENANCE.md" ] && [ "$force" = 0 ]; then
	echo "click-prebuilt is already staged in $OUT (--force to redo)"
	exit 0
fi

for f in "$SRC_STAGE/lib/art/libandroidfw.so" "$SRC_STAGE/lib/java/core-all_classes.jar" \
         "$SRC_STAGE/lib/libglfw.so.3" "$SRC_SKIA_LIB" "$SRC_SKIA_INC/core/SkCanvas.h"; do
	[ -e "$f" ] || {
		echo "missing prebuilt input: $f" >&2
		echo "set UT_ATL_PREBUILT to an arm64 ART packaging build tree (see README.md)" >&2
		exit 1
	}
done

# Everything under lib/art that libandroidfw needs at runtime, and nothing else:
# no libart.so (240 MB), which this port never loads — build.sh stubs the two
# names art-standalone.pc puts on the link line.
art_libs=(libandroidfw.so libbase.so libcutils.so liblog.so libutils.so libziparchive.so)

rm -rf "$OUT"
mkdir -p "$OUT/usr/lib/art" "$OUT/usr/lib/java" "$OUT/usr/include" "$OUT/skia"

for lib in "${art_libs[@]}"; do
	cp "$SRC_STAGE/lib/art/$lib" "$OUT/usr/lib/art/$lib"
done
cp "$SRC_STAGE"/lib/java/*.jar "$OUT/usr/lib/java/"
# atlas's meson resolves `dx` at configure time (it dexes api-impl.jar for ART).
# The port never runs those targets, but configure fails without the program —
# and dx is a shell wrapper around dx.jar, so it costs nothing to carry.
mkdir -p "$OUT/usr/bin"
cp "$SRC_STAGE/bin/dx" "$OUT/usr/bin/dx"
cp -a "$SRC_STAGE"/lib/lib{c,dl,pthread,stdc++}_bio.so* "$OUT/usr/lib/"
cp -a "$SRC_STAGE"/lib/libglfw.so* "$OUT/usr/lib/"
cp -a "$SRC_STAGE/include/androidfw" "$SRC_STAGE/include/GLFW" "$OUT/usr/include/"

cp "$SRC_SKIA_LIB" "$OUT/skia/libskia.so"
# include/ plus modules/: atlas only includes headers under include/, but those
# reach into modules/ themselves (SkColorSpace.h -> modules/skcms/skcms.h). The
# rest of the 8 GB checkout is sources and test data.
cp -a "$SRC_SKIA_INC" "$OUT/skia/include"
cp -a "$SRC_SKIA_MODULES" "$OUT/skia/modules"

if [ -n "$SDK_DIR" ]; then
	art_rev=$(sed -n 's/.*"art_standalone": *"\([^"]*\)".*/\1/p' "$SDK_DIR/meta/sdk-manifest.json" 2>/dev/null || echo unknown)
	skia_rev="shipped with the SDK"
else
	art_rev=$(git -C "$ATL_PREBUILT/../../../art_standalone" rev-parse --short HEAD 2>/dev/null || echo unknown)
	skia_rev=$(git -C "$ATLAS_SKIA_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
fi

cat >"$OUT/PROVENANCE.md" <<EOF
# arm64 prebuilt inputs for the Ubuntu Touch click

Staged by \`linux-port/click/stage-prebuilt.sh\`; do not edit, do not commit.

| | |
| --- | --- |
| source | \`$SRC_DESC\` |
| art_standalone | \`$art_rev\` |
| skia | \`$skia_rev\` |
| staged | $(date -u +%Y-%m-%dT%H:%M:%SZ) |

| Here | What needs it |
| --- | --- |
| usr/lib/art/*.so | libtranslation_layer_main.so's DT_NEEDED (libandroidfw, liblog) and their own |
| usr/lib/java/*.jar | javac's -bootclasspath for api-impl (ART's libcore, not the JDK's) |
| usr/lib/lib*_bio.so* | atlas's configure-time \`cc.find_library\` only |
| usr/lib/libglfw.so* | atlas's window/input backend |
| usr/include/{androidfw,GLFW} | headers for the above |
| skia/ | libskia.so for the target plus the headers atlas compiles against |

The one behavioural caveat: this libskia.so came from the ART packaging, built
with \`skia_use_system_libjpeg_turbo=true\`. The port builds skia with it false,
because libjpeg-turbo 3.x segfaults in
\`SkJpegCodec::onGetScaledDimensions\` — see BRINGUP_NOTES.md. Sampled JPEG
decodes (any thumbnail) are therefore expected to crash until skia is rebuilt
for arm64 with the port's own gn args.
EOF

echo "staged $(du -sh "$OUT" | cut -f1) of arm64 prebuilt inputs in $OUT"
