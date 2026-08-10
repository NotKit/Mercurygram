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
| `api-impl.jar` | in the container by the host JDK's javac | `build-atlas.sh` |
| atlas natives, HotSpot launcher | in the container, arm64 | `build-atlas.sh` |
| `libtmessages.so` + boringssl/libvpx/dav1d/ffmpeg | in the container, arm64 | `native/build_*_linux.sh` |
| `shim.jar` + `libportshim.so` | in the container (the `.so` is arm64) | `build-shim.sh` |
| art support libs, ART boot jars, GLFW, `libskia.so` | outside, prebuilt | `stage-prebuilt.sh` |

The port's own scripts do all of it. `PORT_ARCH=arm64` (see `env.sh`) is the
whole switch: it picks the `aarch64-linux-gnu-*` toolchain, the arm64 JDK for
`jni.h`/`libjvm.so`, and it turns off the checks that can only run natively.

`build.sh` is a clickable `builder: custom` script and lives here; the
`clickable.yaml` that points at it is at the repository root, because the build
container only mounts the project root and the build needs
`TMessagesProj/jni/**` as well as `linux-port/**`.

## The prebuilt inputs

`stage-prebuilt.sh` copies five things out of the ART packaging's arm64 build
tree (`$UT_ATL_PREBUILT`) into `linux-port/out/click-prebuilt/`, because the
container cannot see outside this repository. `PROVENANCE.md` in that directory
records exactly what came from where. In short:

- **art support libs** (`libandroidfw`, `liblog`, and their four dependencies) —
  `libtranslation_layer_main.so` genuinely links them. `libart.so` itself is
  *not* copied: nothing in this port loads ART, so `build.sh` puts an empty
  `libart.so`/`libnativebridge.so` on the link line, which `--as-needed` drops.
- **ART's boot jars** — javac compiles api-impl against ART's libcore.
- **`dx`** — atlas's meson resolves the program at configure time even though
  the port never dexes anything.
- **`bionic_translation` stubs** — only to satisfy `cc.find_library('c_bio')`.
- **`libskia.so` + skia's `include/`** — atlas's meson drives skia's gn build,
  and that does not cross-compile from there. `-Dskia-prebuilt=DIR` (added on the
  port's atlas branch) links a ready-made one instead.

To (re)create that tree: `cd /home/nekit/UT/mercurygram-click-packaging &&
clickable build` — a multi-hour native arm64 build, which is precisely what this
package avoids repeating.

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

Dropped along the way, none of it reachable at runtime: 30 MB of CDS archives
(`classes*.jsa`, rebuilt per-JDK anyway), 11 MB of `ct.sym` (javac's historical
API data), and `include/`. jlink also writes a real `cacerts` (109 upstream CAs)
rather than Debian's symlink into `/etc/ssl/certs`, which is what
`--copy-unsafe-links` used to work around.

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
- **No calls** — `jni/voip/` is not built (as on the desktop). Voice messages do
  not need it: Telegram encodes those with its own opus code in
  `libtmessages.so`, and the click enables the microphone gate for them.
- **No round video messages.** `InstantCameraView` wants a MediaCodec *encoder*
  (`createEncoderByType`, `COLOR_FormatSurface`); atlas can only decode.
- **Camera1 is enabled but not device-verified.** `run.sh` sets
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
