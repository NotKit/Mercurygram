# Ubuntu Touch click of the OpenJDK port

Packages what `linux-port/` builds — Mercurygram on OpenJDK 21 with atlas's
framework classes as jars — as an arm64 click for `ubuntu-touch-24.04-1.x`.

This is the sibling of `/home/nekit/UT/mercurygram-click-packaging`, which
packages the same app the other way round (ART + `bionic_translation` + dex).
The difference that matters for the build: **no `art_standalone` to compile**, so
this one cross-compiles on the host instead of building natively under qemu.
Minutes, not hours.

    linux-port/build-all.sh            # the x86_64 half, first (see ../README.md)
    linux-port/click/make-click.sh     # -> linux-port/out/click/**/*.click

`make-click.sh` stages the prebuilt inputs and then runs
`clickable build --arch arm64`. To iterate on packaging alone,
`clickable build --arch arm64 --skip-review` from the repository root does the
same thing without re-staging.

## What is built where, and why

The port has an arch-independent half and an arm64 half, and only the second one
has to be cross-compiled:

| Piece | Built | By |
| --- | --- | --- |
| app jars, `app.apk` | host, x86_64 | `build-classpath.sh` |
| `api-impl.jar`, atlas natives, HotSpot launcher | not built: taken from the ATL SDK | `stage-prebuilt.sh` |
| `libtmessages.so` + boringssl/libvpx/dav1d/ffmpeg | in the container, arm64 | `native/build_*_linux.sh` |
| `shim.jar` + `libportshim.so` | in the container (the `.so` is arm64) | `build-shim.sh` |
| art support libs, GLFW | outside, prebuilt | `stage-prebuilt.sh` |

The port's own scripts do all of it. `PORT_ARCH=arm64` (see `env.sh`) is the
whole switch: it picks the `aarch64-linux-gnu-*` toolchain, the arm64 JDK for
`jni.h`/`libjvm.so`, and it turns off the checks that can only run natively.

`build.sh` is a clickable `builder: custom` script and lives here; the
`clickable.yaml` that points at it is at the repository root, because the build
container only mounts the project root and the build needs
`TMessagesProj/jni/**` as well as `linux-port/**`.

## The prebuilt inputs

`stage-prebuilt.sh` fills `linux-port/out/click-prebuilt/` with what the
container cannot produce, because it cannot see outside this repository.
`PROVENANCE.md` in that directory records exactly what came from where.

The source is the **ATL SDK** the atl-touch CI publishes per commit
(`atl-sdk-arm64.tar.zst` on release `sdk-<sha>`); `atl-sdk.tag` pins the one CI
uses. `ATL_SDK_TAG=off` falls back to the sibling ART packaging's arm64 build
tree (`$UT_ATL_PREBUILT`), which builds the same things natively — a multi-hour
build, which is precisely what the SDK avoids repeating.

By default **atlas is not built at all**: the framework, its natives, the
HotSpot launcher and `libskia.so` come straight from the SDK, laid out exactly
as `build-atlas.sh` would install them so `build.sh` cannot tell the difference.
Only two things are staged alongside:

- **art support libs** (`libandroidfw`, `liblog`, and their four dependencies) —
  `libtranslation_layer_main.so` genuinely links them. `libart.so` itself is
  *not* copied: nothing in this port loads ART, so `build.sh` puts an empty
  `libart.so`/`libnativebridge.so` on the link line, which `--as-needed` drops.
- **GLFW 3.4** — atlas needs the libdecor init hint; noble ships 3.3.

`PORT_ATLAS_PREBUILT=0` builds atlas from source instead, and then the framework
build's own inputs are staged too: ART's boot jars (javac compiles api-impl
against ART's libcore), `dx` (atlas's meson resolves the program at configure
time even though the port never dexes anything), the `bionic_translation` stubs
(only to satisfy `cc.find_library('c_bio')`), and skia's headers next to
`libskia.so` — atlas's meson drives skia's gn build and that does not
cross-compile from there, so `-Dskia-prebuilt=DIR` links a ready-made one.

One difference worth knowing: a from-source atlas links Lomiri's content-hub
fork, while the SDK's links the original `libcontent-hub-glib.so.1`. Neither is
on the device, so `clickable.yaml` carries both and `build.sh` bundles whichever
one is named.

## Layout of the click

    lib/        every native object, flat: the launcher, atlas's natives,
                libskia, libtmessages, the art support libs, and each library
                Ubuntu Touch does not ship (GLFW, libportal, libswscale,
                maliit-glib, content-hub-glib). One directory, so the natives'
                $ORIGIN/ RUNPATH resolves all of it on the device.
    atlas/      api-impl.jar, framework-res.apk, system/etc/fonts.xml
    classpath/  shim.jar and the app jars
    jvm/        a jlink image of the arm64 OpenJDK 21, not a copy of the JDK
    app.apk     resources, assets and the manifest
    run.sh      the device launcher, mirroring linux-port/run.sh

`device-libs.txt` is the device's own `ldconfig -p`. `build.sh` bundles every
`DT_NEEDED` that is not in it, transitively, and fails the build if something is
neither on the device nor in the container — that is what stops "it linked on
the host" from turning into a silent load failure on the phone.

## The bundled JVM

`build.sh` jlinks `jvm/` from the arm64 `jmods` instead of copying the JDK:
**207 MB to 75 MB**. jlink is architecture-neutral, so the host's jlink builds
the arm64 image — the cross build stays a cross build. This needs
`openjdk-21-jdk-headless:arm64` in the container; the jre package has no `jmods`
and the build stops with that message.

The module set is `PORT_JVM_MODULES` in `build.sh`. `jdeps` finds most of it, and
the comment there has the command to re-derive it when a dependency is added; the
rest (locales, charsets, EC for TLS, the JDWP agent) is what static analysis
cannot see. A missing module is not a build error — it is a `NoClassDefFoundError`
on whatever path first needs it, so keep the set generous.

### Why it is still jlink and not a GraalVM native image

Not because the image lost. On x86_64 it is the runtime the port now prefers:
cold start to first frame 24 % faster (7.27 s vs 9.58 s), RSS at the chat list
15 % lower (503 vs 589 MB), and 22.6 MB smaller compressed — at the cost of
**+51.7 MB installed**, because dropping `jvm/`, `classpath/`'s 93 jars,
`api-impl.jar` and `shim.jar` (195,908,110 B) to add a 247,476,056 B
`libmercurygram.so` takes an install from ~324 MB to ~376 MB. The 2026-08-11
decision was that the start-up win is worth that. Itemised tables are in
`../BRINGUP_NOTES.md` under the start-up and size numbers.

**The click keeps jlink because there is no arm64 image to ship**, which is a
build-host problem and not a verdict on the numbers. Nothing in `click/` changed:
`run.sh` here still launches `android-translation-layer-hotspot` against `jvm/`.
Note the +51.7 MB would also weigh more on a phone than on a desktop, so the
trade-off is worth re-deciding rather than inheriting if an arm64 image appears.

`native-image` cannot cross-compile, so the click would need a second, aarch64
build host with
16 GB of RAM (peak RSS is 9.1 GB on x86_64) and 6-12 minutes a build — feeding it
only the architecture-neutral jars and `out/ni-config`, since none of the native
build is an image input. The x86_64 metadata would not do: it was traced with
`ATL_NO_GPU=1` and the device runs Ganesh, and under a closed world a class that
only the GPU path reaches is a `NoClassDefFoundError` on the phone.

Dropped along the way, none of it reachable at runtime: 11 MB of `ct.sym`
(javac's historical API data) and `include/`. The JDK's own `classes*.jsa` go
too, but a base CDS archive is dumped back for the target arch afterwards (see
"AppCDS" below). jlink also writes a real `cacerts` (109 upstream CAs)
rather than Debian's symlink into `/etc/ssl/certs`, which is what
`--copy-unsafe-links` used to work around.

### AppCDS

The click ships a **base** CDS archive and creates the **app** archive on the
device, the same split the sibling fenix click uses.

`build.sh` dumps the base one after jlink (`-Xshare:dump` writes
`jvm/lib/server/classes.jsa`, exactly where the runtime looks when no
`-XX:SharedArchiveFile` is given). A CDS archive is architecture-specific, so
that has to run the click's own arm64 `java`: native on an arm64 builder,
otherwise `qemu-user-static` (hence its entry in `dependencies_host`). It is not
fatal if it fails — the click just starts slower — but it is load-bearing for the
app archive: a dynamic archive layers on a base one, and without a base HotSpot
refuses the flag and says so only in its cds log.

`run.sh` asks for the app archive with `-XX:+AutoCreateSharedArchive
-XX:SharedArchiveFile=$XDG_CACHE_HOME/mercurygram-jvm.nekit/app.jsa`, which the
VM writes at exit — so it lives in the cache directory, not in the read-only
package. Two traps, both already paid for in fenix:

* HotSpot records each class-path entry's **size and mtime**; a mismatch is a
  warning to the cds log and a silent fallback. `run.sh` fingerprints
  `classpath/*.jar` plus `atlas/api-impl.jar` the same way and forces a rewrite
  when it differs — which is what makes a reinstall pick up a fresh archive.
* the archive is written mode 444, so a stale one has to be **removed**, not
  overwritten, or every later run falls back for ever.

`MERCURYGRAM_CDS=off` disables both. `$XDG_CACHE_HOME/mercurygram-jvm.nekit/cds.log`
holds the warnings, and is the place to look when start-up is slow.


## Status

Device-verified on a OnePlus 11 running Ubuntu Touch 24.04.4: the app launches
from the Lomiri launcher, boots to the main activity with hardware GPU
rendering, and connects to Telegram (MTProto handshake and pings against dc2).
It has not been driven any further than that — no login, no chat list, no
send/receive on the device yet.

## Known limitations

Beyond everything in `../README.md` under "Known limitations":

- **Sampled JPEG decodes are expected to crash.** The prebuilt `libskia.so` was
  built with `skia_use_system_libjpeg_turbo=true`, while the port's atlas branch
  sets it to false precisely because libjpeg-turbo 3.x segfaults in
  `SkJpegCodec::onGetScaledDimensions` (`BRINGUP_NOTES.md`). Any thumbnail is a
  sampled decode. Fixing it means cross-building skia for arm64 with the port's
  own gn args.
- **Unconfined AppArmor**, like the ART packaging: a JVM needs far more than the
  click templates allow.
- **310 MB installed (a 175 MB click)**, now mostly the app: `classpath/` is
  112 MB (81 MB of it `TMessagesProj.jar`) and `app.apk` another 62 MB. The
  runtime is no longer the big half — see "The bundled JVM" below. Shrinking the
  jars means R8, which the port cannot use: it needs `debug`'s unrenamed class
  names.
- **The GPU path is the default here** and it works on the device (`GPU rendering
  (Ganesh) on Adreno (TM) 740, OpenGL ES 3.2`), unlike on the desktop, where the
  same code crashes in skia and `run.sh` forces CPU raster.
  `MERCURYGRAM_NO_GPU=1` switches back if a device disagrees.
- **Voice and video calls work on the device.** Placed from the click on the
  oneplus11 and answered on Telegram Desktop: audio both ways, camera both
  ways. Audio goes through atlas's ALSA
  `default`, which here is the PulseAudio plugin in front of the droid card.
  Conference calls cannot work, because the tde2e bridge is a stub, and a video
  call has no picture: the camera opens but delivers no frames (below).
- **A framework fix does not reach this click by default.** It takes atlas
  prebuilt from the pinned SDK, so building one from source needs
  `PORT_ATLAS_PREBUILT=0` *and* an explicit `ATL_SDK_TAG` — see BRINGUP_NOTES.md.
- **No round video messages.** `InstantCameraView` wants a MediaCodec *encoder*
  (`createEncoderByType`, `COLOR_FormatSurface`); atlas can only decode.
- **Camera1 is device-verified now**, through a video call: ~45 fps from the
  hybris backend. It needed two atlas fixes (the HAL had never been given a
  preview target, and external textures were being rewritten to 2D) — see
  BRINGUP_NOTES.md.
- **Camera1 is enabled and gated.** `run.sh` sets
  `ATL_UGLY_ENABLE_CAMERA=1` and pins `ATL_CAMERA_BACKEND=hybris`, so a device
  without libhybris' `libcamera.so.1` fails loudly rather than serving
  `videotestsrc`. Retest checklist: atlas `doc/CameraDevice.md`; camera2 stays a
  zero-camera stub, so anything insisting on it still sees no camera.

## click-review

`make-click.sh` passes `--skip-review`, because the package fails two checks by
design and both are shared with the ART packaging:

- `security:template_valid: 'unconfined' not allowed` — a JVM needs far more than
  the click templates grant. This is a NEEDS REVIEW finding: it blocks OpenStore
  submission, not a local install.
- `lint:hardcoded_paths: '/opt/click.ubuntu.com/' in run.sh` — deliberate. The
  launcher prefers the version-independent `current` symlink and only falls back
  to its own directory.

`clickable review --arch arm64` reproduces both.

## Checks worth running on the device

    # nothing unresolved, from the click's own directory
    cd /opt/click.ubuntu.com/mercurygram-jvm.nekit/current/lib
    for f in *.so* android-translation-layer-hotspot; do ldd "$f" | grep -H 'not found' && echo "  ^ $f"; done

    # the app's own log, which is where a fatal exception ends up
    journalctl --user -f | grep -i mercurygram
    tail -f ~/.local/share/mercurygram-jvm.nekit/app.apk_/files/logs/*.txt
