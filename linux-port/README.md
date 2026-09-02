# Mercurygram on desktop OpenJDK (linux-port)

Build glue for running Mercurygram on x86_64 desktop Linux on a stock OpenJDK 21
HotSpot JVM, using the [atlas](https://gitlab.com/android_translation_layer/android_translation_layer)
(atl-touch) Android framework as plain **jars** instead of dex under ART.

No ART, no dex2oat, no bionic_translation: the app's Java is AGP's javac output
jarred without d8, and the app's JNI libraries are rebuilt from the in-tree
sources against glibc.

Bring-up workarounds and crash notes: `BRINGUP_NOTES.md`.

## Boot architecture

`android-translation-layer-hotspot` replaces atlas's ART launcher
`android-translation-layer`: it links `libjvm.so` from the JDK and boots HotSpot
through the JNI invocation API instead of ART. It sets the system properties
atlas reads (SDK_INT, app id, data dir, apk path), builds the classpath from
atlas's pre-dex `api-impl.jar` plus the compat `shim.jar` plus the app jars, then
drives atlas's normal startup sequence (`Context.createApplication` →
`ContentProvider.createContentProviders` → `Activity.createMainActivity`) and
enters the GLib main loop. Resources and assets still come from the built APK
through atlas's libandroidfw path, so only *code* loading changes.

It is a meson target **inside atlas** (`src/main-executable-hotspot/`) rather
than a program in this repo, because `libtranslation_layer_main.so` imports
symbols from whatever executable loads it — see `launcher/README.md` for the
decision and the full ART-vs-HotSpot difference table.

The same sources also build `android-translation-layer-image`, which creates the
VM from a GraalVM native-image shared library (`--vm-library`, `run.sh --image`)
instead of `libjvm.so` and has no class path at all. `launcher/README.md` has
the backend table.

```
atlas android-translation-layer-hotspot
        |  JNI_CreateJavaVM
        v
   libjvm.so  (OpenJDK 21 HotSpot)
        |
        |  classpath
        +--> out/atlas/api-impl.jar        atlas Android framework (javac, pre-dex)
        +--> out/shim.jar                  libcore/dalvik classes HotSpot lacks
        +--> out/classpath/*.jar           Mercurygram + androidx/runtime deps
        |
        |  System.load from Java
        +--> libtranslation_layer_main.so  atlas natives: Skia, GLFW, libandroidfw
        +--> out/libtmessages.so           app JNI: tgnet, sqlite, image (glibc, no voip)
        |
        v
   GLib main loop  ->  ATLWindow (GLFW + Skia)
```

## Layout

| Path | Contents |
| --- | --- |
| `env.sh` | shared environment (`ATLAS_DIR`, `ATLAS_SKIA_DIR`, `ATLAS_BUILDDIR`, `ATLAS_OUT`, `JAVA_HOME`, `GRAALVM_HOME`, `PORT_OUT`); source it, don't run it |
| `build-all.sh` | every build step below, in dependency order — the one-command build |
| `click/` | the arm64 Ubuntu Touch click: cross build and packaging, on top of everything below (`click/README.md`) |
| `atlas/` | the atlas (atl-touch) sources the port builds — a separate git repo on `master`, gitignored here |
| `build-atlas.sh` | builds atlas from `atlas/` into `out/atlas-build/`, installs `out/atlas/` |
| `check-env.sh` | toolchain smoke test; exits 0 when the environment is usable |
| `check-graalvm.sh` | the same for `$GRAALVM_HOME`: `native-image`, the tracing agent, and that it has not shadowed `JAVA_HOME` |
| `native/` | glibc builds of the JNI deps (boringssl, ffmpeg, dav1d, libvpx) and of `libtmessages.so` |
| `gradle/` | Gradle glue applied only under `-PlinuxPort` (the `jarForLinuxPort` task) |
| `tools/` | small Java helpers used to verify the port's own artifacts |
| `build-classpath.sh` | builds the HotSpot classpath and the APK from the Android sources |
| `launcher/` | why the launcher lives in atlas, the smoke tests that boot it on either VM backend, and `display.sh` (the Xvfb/screenshot helper the run scripts share) |
| `build-image.sh` | no flag: the real native image over api-impl + shim + the classpath jars, ~4.5 min and ~9 GB (`out/image/build-stats.env`). `--stub`: the one-class image `launcher/image-smoke-test.sh` checks the image launcher against |
| `measure-startup.sh` | cold start to first frame and RSS at the chat list, HotSpot vs image, one definition (`measure-startup.py` is the harness it drives) |
| `run.sh` | runs Mercurygram on the launcher; `--seconds N` also checks the log and takes a screenshot |
| `check-native-loader.sh` | runs `NativeLoader` inside the launcher and proves it loads the glibc `libtmessages.so` |
| `check-extract-apk.sh` | proves `AssetManager.extractFromAPK` reads the apk, not the class path, and that a miss is cheap and throws nothing |
| `check-dump-hprof.sh` | proves the framework answers `Debug.dumpHprofData`, so `org/telegram/**` carries no workaround for it |
| `check-tlstore.sh` | instantiates every class in `TLClassStore`, the arms a driving run never takes (FR-4) |
| `check-mtproto.sh` | boots the app, drives the login screen with `xdotool` and checks the DC handshake and the `auth.sendCode` round trip in `out/run.log` |
| `check-messages.sh` | opens Saved Messages, sends a text and checks the server ack and an incoming message in `out/run.log` |
| `check-emoji.sh` | opens the emoji panel in Saved Messages, checks the glyphs it reads from `assets/emoji/`, taps one and sends it |
| `trace-metadata.sh` | runs the four driving checks plus `check-tlstore.sh` under GraalVM's tracing agent, merging one native-image config in `out/ni-config/` |
| `build-shim.sh` | builds the compat shim into `out/shim.jar` + `out/libportshim.so` |
| `shim/` | sources of the libcore/dalvik classes HotSpot has no equivalent for, plus `audit-shim.sh` and the audit note in `shim/README.md` |
| `out/` | all build products and run logs — gitignored, safe to delete |

## Prerequisites

- OpenJDK 21 (Debian: `openjdk-21-jdk-headless`). `env.sh` uses
  `/usr/lib/jvm/java-21-openjdk-amd64` unless `JAVA_HOME`/`JAVA_21_HOME` says
  otherwise. Newer JDKs are deliberately not used: the toolchain is pinned so
  every build step sees the same runtime.
- Host toolchain: `cc`, `c++`, `cmake`, `make`, `ninja`, `pkg-config`, `unzip`,
  plus `nasm` (dav1d) and `yasm` (libvpx) for the native dependencies.
- An atlas checkout at `linux-port/atlas` (`build-all.sh` clones it when it is
  missing; see *atlas source checkout*) plus `meson`, `ninja`, and `gn` +
  `clang` for its skia subproject: the port builds atlas itself, it is not a
  prebuilt dependency. atlas's own dependencies (`art-standalone`, GTK4, GLFW,
  the AOSP support libraries in `/usr/local/lib/art`) must already be installed.
- A Wayland or X11 session for the run steps. `ATL_GLFW_PLATFORM` forces the
  GLFW backend; `ATL_NO_GPU=1` falls back to CPU raster. Without a session the
  run scripts start an `Xvfb` themselves — that needs `Xvfb` and ImageMagick's
  `import` for the screenshots, and the driving checks need `xdotool`.
- `check-env.sh` verifies all of the above except the run-time extras.
- GraalVM CE 21 is needed only for the native image and its tracing agent, not
  for the HotSpot port. `env.sh` points `GRAALVM_HOME` at
  `/home/nekit/UT/graalvm-ce-21`; `check-graalvm.sh` verifies it.

## Usage

```sh
linux-port/build-all.sh      # build everything, ~1 min incremental
linux-port/run.sh            # start Mercurygram

linux-port/click/make-click.sh   # and, on top of that, the Ubuntu Touch click
```

That is the whole port: `build-all.sh` runs the steps of the following sections
in dependency order and `run.sh` boots the app. For a logged-in session, run
`transplant-session.sh` once in between (see *Chat list with an existing
session*).

```sh
source linux-port/env.sh          # environment for any manual step
linux-port/check-env.sh           # verify the toolchain on its own
linux-port/build-all.sh --list    # the steps, with the story each belongs to
linux-port/build-all.sh --clean   # rebuild everything from scratch (~7 min)
linux-port/build-all.sh --from atlas   # resume after a failed step
linux-port/build-all.sh --only shim    # just one step
```

`build-all.sh` starts from a bare checkout: it initializes the four native
submodules and clones `linux-port/atlas` when it is missing (`ATLAS_URL`,
`ATLAS_BRANCH` override the source). Every step is one of the scripts below and
all of them are idempotent, so re-running the whole thing is an incremental
pass, not a rebuild. Order matters in two places: libvpx before ffmpeg, and the
framework before the shim — the shim compiles against `api-impl.jar`, so
`build-atlas.sh` skips its app class-resolution checks on a first build and the
final `checks` step comes back to them once `out/shim.jar` exists.

### Native dependencies

```sh
git submodule update --init TMessagesProj/jni/{boringssl,ffmpeg,dav1d,libvpx}
linux-port/native/build_boringssl_linux.sh          # -> out/native/boringssl/
linux-port/native/build_libvpx_linux.sh             # -> out/native/libvpx/
linux-port/native/build_dav1d_linux.sh              # -> out/native/dav1d/
linux-port/native/build_ffmpeg_linux.sh             # -> out/native/ffmpeg/
```

libvpx must be built before ffmpeg (`--enable-libvpx`). Extra host tools for
these: `meson`, `ninja`, `nasm` (dav1d), `yasm` (libvpx).

Each `native/build_*_linux.sh` is idempotent: re-running it is an incremental
ninja/make pass. Pass `--clean` to throw the build tree away and start over.

Submodules deliberately left un-initialized: `TMessagesProj/jni/td` (tdlib) and
`TMessagesProj/jni/whisper`, plus everything under `TMessagesProj_PluginTor/`.
None are needed for the parity feature bar (login, chat list, text messages,
emoji panel), and tdlib is only reached through the tde2e build.

`build_boringssl_linux.sh` mirrors `TMessagesProj/jni/build_boringssl.sh` with
the NDK toolchain file dropped. It applies the same `patch_boringssl.sh`
(AES-IGE, which MTProto needs and stock BoringSSL lacks) and builds with
`-DCMAKE_POSITION_INDEPENDENT_CODE=ON`, since the archives get linked into
`libtmessages.so`. Note `AES_ige_encrypt` ends up in `libssl.a`, not
`libcrypto.a` — the patch adds `ssl/aes_ige.c` to `SSL_SOURCES`.

`build_{libvpx,dav1d,ffmpeg}_linux.sh` mirror the x86_64 case of the matching
Android script, with the NDK toolchain and `-DANDROID` dropped. All three build
out of tree under `out/native/<dep>/build/` so the submodules stay clean (the
Android scripts build in-tree and `make distclean`). The ffmpeg script also
installs and patches the private headers `jni/patch_ffmpeg.sh` handles, into
`out/native/ffmpeg/include/`. Every deviation is listed in `BRINGUP_NOTES.md`.

### libtmessages

```sh
linux-port/native/build_tmessages_linux.sh   # -> out/libtmessages.49.so
```

Builds the app's JNI library for x86_64-linux-gnu from
`linux-port/native/CMakeLists.txt`, an overlay that mirrors
`TMessagesProj/jni/CMakeLists.txt` (see the header comment in that file, and
`BRINGUP_NOTES.md` for every deviation). Products:

| File | What it is |
| --- | --- |
| `out/libtmessages.49.so` | the library, under the name `NativeLoader` asks for |
| `out/libtmessages.so` | symlink to the above, the name the PRD and launcher use |
| `out/libOpenSLES.so.1` | no-op OpenSL ES stub |

Not built: `voip/` (calls), breakpad, whisper transcription and the tde2e
bridge — the last two because their submodules are not checked out. Their JNI
methods raise `UnsatisfiedLinkError` if reached; none are on the parity path.

Android system libraries are replaced by `native/include/android/*.h` plus
`native/stubs/`: logging goes to stderr (`TMESSAGES_LOG_LEVEL` raises the
threshold), while `AndroidBitmap_*` and the `AAsset*` API come from atlas's
`libandroid.so.0`. The library therefore needs atlas on its search path; its
RPATH is `$ORIGIN:$ORIGIN/atlas:$ATLAS_BUILDDIR`.

The script verifies its own output: `ldd` for unresolved or Android-only
dependencies, `nm -D` for the `Java_org_telegram_*` entry points, and a
`dlopen` of the finished library. It is idempotent (a re-run is an incremental
ninja pass, <1s); `--clean` rebuilds from scratch in ~30s.

### App classpath

```sh
linux-port/build-classpath.sh            # -> out/classpath/, out/app.apk
linux-port/build-classpath.sh --clean    # gradle clean first (~3 min)
```

Wraps the Gradle task `jarForLinuxPort`, defined in
`linux-port/gradle/jar-for-linux-port.gradle` and applied from the root
`build.gradle` only when `-PlinuxPort` is set. The task jars AGP's javac output
instead of dexing it. Flavor: **`afatFdX86_64Debug`** — F-Droid per-ABI x86_64
matches the host, and `debug` is the only build type that does not run R8, whose
renaming would break the class names the launcher and shims have to reference.

`-PlinuxPort` also turns off `externalNativeBuild` in both modules, so no NDK
build runs and `TMessagesProj/jni/`'s submodules stay clean; the port supplies
its own `libtmessages.so`. Without it the Android build behaves exactly as
before.

| Product | What it is |
| --- | --- |
| `out/classpath/mercurygram-app.jar` | `TMessagesProj_App` javac output |
| `out/classpath/TMessagesProj.jar` | the library module, from AGP's own runtime jar |
| `out/classpath/mercurygram-res.jar` | the runtime `R` classes for every package |
| `out/classpath/<group>-<module>-<version>.jar` | 90 runtime dependencies, AAR `classes.jar` entries included |
| `out/classpath/deps.list` | what the dependency copy step wrote; stale jars are pruned against it |
| `out/app.apk` | the matching APK, the resource and asset source for libandroidfw |

`R` classes come from the app's non-namespaced runtime R jar
(`android.nonTransitiveRClass=false`), which is the only copy on the classpath —
nothing else contributes a stub with zeroed ids.

The script then smoke-tests the classpath with `tools/PortClassCheck.java`: it
resolves the classes the launcher and `NativeLoader` name, checks
`R.string.AppName` has a real id, and asserts that classes extending `android.*`
fail on nothing but a missing `android.*` class — which is exactly what the
atlas framework jar supplies.

`TMessagesProj/build.gradle` reads `./API_KEYS` at configure time, so the script
writes a dummy one when it is missing. Export `APP_ID`/`APP_HASH` and re-run
before attempting login. `MG_BUILD_TAG` defaults to `$APP_VERSION_NAME.1` from
`gradle.properties` and can be overridden in the environment.

### atlas source checkout

atlas is a **source** dependency: `linux-port/atlas/` is a checkout of
[atl-touch](https://github.com/NotKit/atl-touch) `master`, its own git
repository, gitignored by this one. The port builds it and may change it;
framework fixes are commits on master, pushed upstream to atl-touch.

On this machine it is a worktree of the existing clone, which is how to recreate
it. The worktree gets a branch of its own tracking `origin/master`, because the
main clone already has `master` checked out and git will not give one branch to
two worktrees:

```sh
git -C /home/nekit/UT/atlas worktree add --track -b mercurygram/master \
    /home/nekit/UT/mercurygram-src/linux-port/atlas origin/master
ln -s /home/nekit/UT/atlas/subprojects/skia linux-port/atlas/subprojects/skia
```

On a machine without that clone, `git clone -b master
git@github.com:NotKit/atl-touch.git linux-port/atlas` is equivalent; skia is then
downloaded by meson (`subprojects/skia`, ~8 GB — share an existing tree by
symlink whenever possible). `ATLAS_SKIA_DIR` points at the tree to share and
`build-atlas.sh` creates the symlink when `subprojects/skia` is missing. Because
a symlinked subproject does not match atlas's `/skia/` ignore rule, the symlink
is excluded through the atlas clone's `.git/info/exclude` so both trees stay
clean.

Framework work is committed in the atlas checkout, in atlas's own commit style,
and pushed to atl-touch:

```sh
git -C linux-port/atlas commit -am "graphics: ..."
git -C linux-port/atlas push origin HEAD:master
```

The commit this port needs is recorded at the end of this file. atlas's javac
also writes generated JNI headers back into its own source tree; those belong on
the atlas branch like any other change, so a build no longer has to be avoided
for that reason. `build-atlas.sh` fails if the build changes anything else in the
checkout.

### atlas framework build

```sh
linux-port/build-atlas.sh                # configure if needed, incremental ninja
linux-port/build-atlas.sh --reconfigure  # re-run meson setup from scratch
linux-port/build-atlas.sh --clean        # throw the builddir and out/atlas/ away
```

Builds `$ATLAS_DIR` (`linux-port/atlas`) in `out/atlas-build/` with the port's
JDK 21 — meson picks the JDK for its `jni` dependency and for javac at configure
time, and the framework must be compiled by the same runtime the port boots, so
the script stamps the builddir with the JDK it used and reconfigures when that
changes. Editing a framework source and re-running is the framework edit/build/run
loop; only `out/atlas/` is a copy, and it is refreshed on every run.

A full build takes ~95s (886 skia targets included), an incremental one ~4s. skia
is rebuilt whenever the builddir is configured anew — `--clean` and
`--reconfigure` — but its sources are never re-downloaded (see the symlink above).

| Product | atlas source |
| --- | --- |
| `out/atlas/api-impl.jar` | `hax-stripped.jar` — the **pre-dex** framework classes |
| `out/atlas/libtranslation_layer_main.so` | framework natives (Skia, GLFW, libandroidfw) |
| `out/atlas/libandroid.so.0`, `libandroid.so` | NDK API surface: `AndroidBitmap_*`, `AAsset*` |
| `out/atlas/libskia.so` | `subprojects/skia/` — `DT_NEEDED` of the above |
| `out/atlas/libatl_webview_qt.so` | optional Qt WebEngine WebView backend |
| `out/atlas/framework-res.apk` | framework resource table (goes on the classpath) |
| `out/atlas/system/etc/fonts.xml` | copied for reference only, see below |
| `out/atlas/system/fonts/Roboto-*.ttf` | the sans-serif family, read by the framework |
| `out/atlas/artifacts.env`, `ARTIFACTS.md` | generated paths and provenance |

The jar to put on a HotSpot classpath is **`hax-stripped.jar`**, atlas's javac
product minus three compile-only stubs (`meson.build:274`). atlas's own
`api-impl.jar` is that jar after `dx --dex` and contains only a `classes.dex`;
the script fails if it ever ends up installing it. `out/atlas/` doubles as the
natives dir (`java.library.path`): the installed
`libtranslation_layer_main.so` keeps its `$ORIGIN/` RUNPATH, so `libskia.so` and
`libandroid.so.0` resolve from the same flat directory, and the AOSP support
libraries (`libandroidfw`, `liblog`, `libbase`, …) from `/usr/local/lib/art`.

`system/fonts/` is read by the framework: `TypefaceCollection.cpp` builds
`sans-serif` and its weight aliases from those twelve Roboto faces, found beside
`libtranslation_layer_main.so` (`ATL_FONT_DIR` overrides the location). Without
them the generic names fall back to fontconfig, which answers Noto Sans here and
Ubuntu on the phone — neither has Android's metrics. `check-fonts.sh` is the
regression test.

`fonts.xml` itself is not read on this path. It is where that face-and-weight
table comes from, but the only consumer of `/system/etc/fonts.xml` is the
path-override table in atlas's own executable, which belongs to the bionic shim
the port does not use.

Verification: `unzip -l` for `android/view/View.class`, `android/os/Looper.class`
and the absence of `classes.dex`, `javap` for the class file version, `ldd` and
`nm -D` on the installed libraries, and — once `build-classpath.sh` has run — a
`PortClassCheck` that resolves `ApplicationLoader`/`LaunchActivity`, the classes
the app class path could not load without this jar.

### HotSpot launcher

```sh
linux-port/build-atlas.sh            # builds and installs the launcher too
linux-port/launcher/smoke-test.sh    # -> out/run.log, out/screenshots/
```

The launcher is atlas's `android-translation-layer-hotspot` target, installed to
`out/atlas/` alongside the framework libraries. `launcher/README.md` explains why
it lives in atlas, what it does differently from the ART launcher, and which
parts of that launcher are deliberately gone (bionic linker, path overrides, apk
native-library extraction).

```sh
LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ATLAS_OUT" \
out/atlas/android-translation-layer-hotspot \
    --api-impl-jar out/atlas/api-impl.jar \
    --framework-res out/atlas/framework-res.apk \
    --natives-dir out/atlas \
    --classpath "out/shim.jar:out/classpath/*" \
    --library-path out \
    out/app.apk
```

`--smoke-test N` boots the VM and the window but creates no application, which
is what `smoke-test.sh` uses: it asserts the JVM starts, the translation layer
loads into the class loader that owns the framework, one of its
`Java_android_*` entry points resolves, the window has a non-zero size, and the
process exits 0 — without depending on any Mercurygram code. It starts an `Xvfb`
when the session has no display.

`--run-class CLASS` runs one class's `main(String[])` in the app's runtime
instead of creating the application — the framework, the class path and the
native libraries are those of a real run, so a single piece of the app can be
tested without a UI. `check-native-loader.sh` (below) uses it.

`build-atlas.sh` checks the other half of the contract: every symbol
`libtranslation_layer_main.so` imports from its executable must be defined by
the installed launcher.

### Loading the glibc libtmessages.so

```sh
linux-port/check-native-loader.sh    # -> out/run.log
```

`NativeLoader.initNativeLibs` normally looks the library up with
`System.loadLibrary` and then unpacks an Android `.so` out of the apk. On the
desktop the library is a glibc build sitting in `out/`, so `NativeLoader` takes
`-Dtmessages.native.path=<path>`: it `System.load`s that file and returns,
skipping the extraction path entirely. That is the only change this port makes
to `org/telegram/**` for native loading.

`check-native-loader.sh` compiles `tools/NativeLoaderCheck.java` and runs it
with `--run-class`. Reaching the end proves the whole chain: the property took
effect, `JNI_OnLoad` returned a version (so `imageOnJNILoad`, `videoOnJNILoad`
and `registerNativeTgNetFunctions` all succeeded against the atlas framework),
tgnet's dynamically registered methods work
(`NativeByteBuffer.native_getFreeBuffer`), a statically named entry point
resolves by name (`NativeLoader.init`), and no library was extracted into the
app data dir.

### libcore/dalvik compat shim

```sh
linux-port/build-shim.sh            # jar + JNI back end + checks
linux-port/build-shim.sh --clean
linux-port/shim/audit-shim.sh       # what is still unresolved, and who needs it
```

Products: `out/shim.jar` (36 classes, `javac --release 21`) and
`out/libportshim.so`, the small JNI back end for the things that cannot be done
in Java — calling a registered free function for
`libcore.util.NativeAllocationRegistry`, and the file-descriptor syscalls behind
`android.system.Os`. Both go on the launcher's classpath and
`java.library.path`; `-Dport.shim.native.path=` overrides the library path.

`shim/README.md` is the audit note: every class, who demanded it, what is exact
and what is approximate, what was deferred, and what was fixed in atlas instead
of shimmed. `org.json` moved from deferred to implemented during the boot bring-up: it is on
the boot path, Android has it on the boot classpath and the JDK does not.

Two things the launcher has to carry because of the shim:

- `--add-opens java.base/java.io=ALL-UNNAMED`, so atlas's
  `android.atl.FileDescriptorUtils` can reach `FileDescriptor.fd` — libcore's
  `getInt$`/`setInt$` do not exist on a JDK.
- `out/shim.jar` **before** the app jars on the classpath, and `out/` on
  `java.library.path`.

Verification, all inside `build-shim.sh`: the jar and the `.so` must contain the
expected entries and symbols; `tools/JdkRefCheck.java` fails the build if
api-impl refers to any `java.*` member this JDK lacks (libcore adds several, and
no shim can supply them); `tools/ShimCheck.java` then runs api-impl code —
`Rect`, `TextUtils`, `SpannableStringBuilder`, `ArrayMap`, `AndroidBidi`,
`Process`, `Xml.newPullParser()`, `DateFormat`, `StatFs` — and checks the
answers, including that a `Cleaner` really calls the native free function.

### Running the app

```sh
linux-port/run.sh                     # until the window is closed
linux-port/run.sh --seconds 60        # timed run: checks run.log, takes a screenshot
linux-port/run.sh --seconds 600 --stop-file /tmp/done   # ... or until that file appears
linux-port/run.sh --fresh             # start from an empty data dir
linux-port/run.sh --gpu               # try Ganesh again (currently crashes, see below)
linux-port/run.sh --tl-dump           # put the MTProto request/response JSON back
linux-port/run.sh -- --window-width 1280   # anything after -- goes to the launcher
```

The app data dir is `out/data/` (`--data-dir` to move it, `ANDROID_APP_DATA_DIR`
is honoured too), the log is `out/run.log` and timed runs write
`out/screenshots/run.png`. With no session, `launcher/display.sh` starts an Xvfb.

A timed run is also the story's check: it requires `boot: Application.onCreate
returned` and `boot: main activity started` in the log, no `hs_err`, no uncaught
exception for the whole run, and no `FATAL/tmessages` in the app's own log —
this build is a `DEBUG_PRIVATE_VERSION`, so the app answers an uncaught exception
with `System.exit(2)`, which the launcher hangs in, leaving a window that looks
alive and is not. This now reaches the Telegram intro screen ("Start
Messaging") and idles cleanly; with a transplanted session it reaches the chat list.

`--stop-file PATH` makes `--seconds` an upper bound: the run ends as soon as
that file appears, so a driving script (`check-chatlist.sh`) can allow for a
slow first sync without paying for it every time.

A few things to know about the run:

- **CPU raster is the default.** atlas's Ganesh path segfaults inside skia's
  `GrGLExtensions::init` while assembling the GL interface — on llvmpipe and on
  hardware GL alike, so neither the JVM nor the headless setup is the cause.
  `run.sh` exports `ATL_NO_GPU=1`; `--gpu` reproduces it. See `BRINGUP_NOTES.md`.
- **`-Dtmessages.native.path`** points `NativeLoader` at
  `out/libtmessages.so`; without it the app would try to unpack an Android `.so`
  from the apk.
- **`-Dtmessages.tldump=0`** switches off `FileLog`'s TL debug dumper, which
  Gson-serializes every request and update. It was three quarters of
  `out/run.log` (6.1 MB down to 1.5 MB over the same 90 s boot) and 310 of the
  444 classes a native-image trace recorded. `--tl-dump` leaves it on
  for MTProto debugging; never combine it with a metadata trace.
- **`ANDROID_LOG_TAGS=*:V`** is exported, or liblog would drop everything below
  `INFO` and the app's own `FileLog.d` output would never reach `out/run.log`.

A timed run ends by killing the launcher, which does not stop on `SIGTERM` yet,
so `run.sh` follows up with `SIGKILL` and accepts exit 137 as a normal ending.

### MTProto connectivity

```sh
linux-port/check-mtproto.sh                       # -> out/run.log, out/screenshots/mtproto-*.png
linux-port/check-mtproto.sh --phone 15551234567   # number to type, country code first
linux-port/check-mtproto.sh --seconds 120         # how long the app runs in total
```

The MTProto check. It boots the app with `run.sh`, then drives the real UI with
`xdotool` (a prerequisite for this script only): **Start Messaging** → type the
number → next → confirm the number, which is what makes the app send
`auth.sendCode`. Afterwards it requires in `out/run.log`:

- tgnet's native init — `network thread started` and the account config written;
- a completed DC handshake within 30s of the login screen, and an answer to
  `help.getConfig`;
- no `UnsatisfiedLinkError`;
- a server answer to `auth.sendCode`, plus `run.sh`'s own "no uncaught
  exceptions" verdict for the whole run.

Clicks are per-mille positions inside the ATLWindow, so they follow the window
but not a layout change — if the login screen moves, the coordinates in the
script are what to update.

**API keys.** The port builds with the dummy `./API_KEYS` (`APP_ID=0`), so the
server answers every request that opens a connection with
`400 CONNECTION_API_ID_INVALID`. That is a complete round trip, all this check
asks for, but it is not a login: export `APP_ID`/`APP_HASH` and re-run
`build-classpath.sh` before transplanting a session.

### Chat list with an existing session

```sh
linux-port/transplant-session.sh                  # copy a logged-in ART/ATL data dir
linux-port/transplant-session.sh --from DIR --force
linux-port/check-chatlist.sh                      # -> out/screenshots/chatlist-*.png
```

The chat-list check. `transplant-session.sh` copies the data directory of a working
ART/ATL desktop login
(`~/.local/share/android_translation_layer/mercurygram-x64.apk_` by default)
into the port's own (`out/data/app.apk_` — the launcher appends
`<apk basename>_` to `ANDROID_APP_DATA_DIR`). Both runtimes are atlas, so the
layout matches and nothing is converted; `lib/`, `extracted_assets/` and the
SQLite `-shm` files are left out. The copy is stamped `.port-transplant`, which
is how a re-run knows there is a session there, so `run.sh --fresh` (which wipes
the data dir) is undone by simply running the script again.

`check-chatlist.sh` transplants if needed, boots the app with `run.sh`, and
requires:

- `loaded folderId 0 loadType 1 count N` with `N > 0` — dialogs straight out of
  `cache4.db` (`DIALOGS_LOAD_TYPE_CACHE`);
- no `UnsatisfiedLinkError` for the SQLite JNI and no `SQLiteException`;
- the chat list scrolls: three drags down and three back up, with the window's
  screenshot required to change (a frozen UI would pass otherwise);
- `run.sh`'s own verdict for the run.

**API keys.** A session is useless with the dummy `APP_ID=0` — the server
rejects every request that opens a connection. Export a real pair and rebuild
the classpath; `build-classpath.sh` rewrites `./API_KEYS` (gitignored) from the
environment:

```sh
APP_ID=... APP_HASH=... linux-port/build-classpath.sh
```

Do not run the ART build and the port at the same time: both would talk to
Telegram with the same auth key.

### Send and receive text messages

```sh
linux-port/check-messages.sh                      # -> out/screenshots/messages-*.png
linux-port/check-messages.sh --incoming-seconds 600
```

The messaging check, on top of the same transplanted session. It opens the overflow
menu, picks **Saved Messages**, types a `mg-port-msg-<timestamp>` line and
sends it. Saved Messages is the only chat it is allowed to write to, so it
refuses to type until the log says the chat that opened is the account's own
dialog — a click that missed and landed on the dialog list would otherwise send
a test message to a real correspondent.

It requires:

- the chat loaded its messages from the cache and the screen changed when it
  opened (an empty message list is what a missing framework class looks like,
  see `BRINGUP_NOTES.md`);
- `send message user_id = 0 chat_id = 0 channel_id = 0` — `inputPeerSelf`, the
  proof that the message went to Saved Messages;
- `TL_updateMessageID` in the server's answer and `process update
  TL_updateMessageID` in the app: the local message taking over the server's id,
  which is the single→double check the story asks for;
- an incoming `updateNewMessage`/`updateNewChannelMessage` processed while the
  app keeps running, with the dialog list redrawing because of it;
- `run.sh`'s own verdict for the run.

The incoming half depends on the account receiving something during the run —
a self-send does not come back through the update loop. `--incoming-seconds`
(default 300) is how long it waits.

### Emoji panel

```sh
linux-port/check-emoji.sh                         # -> out/screenshots/emoji-*.png
linux-port/check-emoji.sh --emoji-at 78,731       # where in the grid to tap
```

The emoji check, on the same transplanted session and with the same
Saved-Messages guard as `check-messages.sh`. It types a `mg-port-emoji-<timestamp>`
marker, opens the emoji panel with the emoji button, taps a glyph, closes the
panel and sends the line.

It requires:

- at least 20 distinct `assets/emoji/<page>_<index>.png` reads after the button
  was tapped — atlas logs every asset open, and those files are only read while
  a glyph is being painted, so this is what "the sprite sheets render" means
  here (a full screenful is ~110);
- a colourful grid area in the screenshot, not a blank sheet;
- the input field to change when a glyph is tapped;
- `send message user_id = 0 chat_id = 0 channel_id = 0` (`inputPeerSelf`),
  `TL_updateMessageID` back from the server and the app processing it;
- the marker followed by a non-ASCII character in the message the app stored in
  `cache4.db` — the proof that the tap inserted a real emoji, which a
  screenshot could not give;
- `run.sh`'s own verdict for the run.

The panel is as tall as a phone keyboard, so on a 960x540 window it covers the
chat; the check closes it again before sending. See `BRINGUP_NOTES.md` for the
framework bug this story found (`ImageView` dropped drawables with no intrinsic
size, which is every emoji cell).

## Known limitations

Parity with the ART/ATL desktop status is the bar: login, chat list, text
messages, emoji panel. What is knowingly missing:

- **No calls and no voice messages.** `jni/voip/` (tgcalls, webrtc, libtgvoip)
  is not built and OpenSL ES is a no-op stub, so recording and playback do
  nothing. Same for `whisper` transcription and the `tde2e` bridge, whose
  submodules are not checked out — their JNI methods raise
  `UnsatisfiedLinkError` if something reaches them.
- **CPU raster only.** `run.sh` exports `ATL_NO_GPU=1`: atlas's Ganesh path
  segfaults inside skia's `GrGLExtensions::init` on every GL driver on this
  machine, hardware and llvmpipe alike. `--gpu` reproduces it.
- **The Ubuntu Touch click is a first bring-up.** `linux-port/click/` cross-builds
  the port for arm64 and packages it (`click/README.md`); it boots on the device
  to the main activity with hardware GPU rendering and a live MTProto connection,
  but it ships a prebuilt `libskia.so` whose libjpeg-turbo choice is known to
  segfault on sampled JPEG decodes. The GraalVM native image (below) is still
  ahead of both.
- **Debug build.** `afatFdX86_64Debug` is the only usable variant, because R8
  renames the classes the launcher and the shims name. It is a
  `DEBUG_PRIVATE_VERSION`, so the app answers any uncaught exception with
  `System.exit(2)` instead of carrying on.
- **Screen-size assumptions.** The window is a phone-sized 960x540 by default;
  the emoji panel is as tall as a phone keyboard and covers the chat, and the
  intro page sits off-centre. Cosmetic atlas layout gaps, not port bugs.
- **One atlas gap left on purpose:** `AIEditorAlert$Tabs` does not verify,
  because atlas's `ScrollView` extends `ViewGroup` where the SDK's extends
  `FrameLayout`. `build-atlas.sh` reports it without failing — it is off the
  parity path (see `BRINGUP_NOTES.md`).
- Hardware video decode, notifications/UnifiedPush: atlas gaps, out of scope
  here. Camera1 exists in atlas now and the click enables it (see
  `click/run.sh`), but only the device has a HAL — the desktop build would get
  atlas's GStreamer `videotestsrc`.
- **Never run the ART build and this port at the same time** — both would use
  the same auth key against Telegram.

## GraalVM native-image tracing agent

The next phase after this port is a native image, which needs a reachability
profile of a real run. The launcher forwards `-X "OPTION"` straight to the JVM,
so the tracing agent attaches without any change to the port:

```sh
linux-port/check-graalvm.sh                       # native-image + agent usable?
linux-port/trace-metadata.sh                      # the real profile -> out/ni-config/
linux-port/trace-metadata.sh --only emoji --merge  # re-trace one path on top of it

# one boot by hand, without the checks. GRAALVM_HOME comes from env.sh, and
# run.sh sources env.sh in its own shell -- so source it here too, or the prefix
# assigns an empty JAVA_HOME and env.sh quietly hands the run the port's OpenJDK,
# where -agentlib:native-image-agent does not resolve.
source linux-port/env.sh
JAVA_HOME="$GRAALVM_HOME" linux-port/run.sh --seconds 120 -- \
    -X "-agentlib:native-image-agent=config-output-dir=linux-port/out/ni-config-boot" \
    -X "-Dorg.graalvm.nativeimage.imagecode=runtime"
```

The `imagecode` property is not optional in a hand trace either: atlas gates
`View.overridesOnDraw`'s `getDeclaredMethod` on it (atlas `cfa73805`), so a trace
without it records ~137 `onDraw` entries the image never asks for and disagrees
with `out/ni-config`. Such a boot-only config is also what `--baseline` compares
against; no script keeps one up to date, so record it by hand when you want one.

`trace-metadata.sh` is the supported way: it runs `check-tlstore.sh`,
`check-mtproto.sh`, `check-chatlist.sh`, `check-messages.sh` and
`check-emoji.sh` in that order (tlstore needs no session and takes seconds;
mtproto boots `--fresh` and wipes the data dir; the rest transplant the session
back), all with `config-merge-dir=out/ni-config`, and fails if any check does.
The driving checks do not forward `-- ARGS`, so it passes the agent in through
`$PORT_EXTRA_JVM_ARGS`, which `run.sh` splits into one `-X` per option;
`check-tlstore.sh` is a `--run-class` check and takes the same two options as
launcher arguments after `--`.

It **wipes `out/ni-config` first** unless `--merge` is given. The agent can only
add to a config dir, so merging a new trace into an old one keeps every entry
the dumper and registry work removed — and every reflect entry is an image root. One command
from a clean checkout has to produce the config the image is built from, so the
wipe is the default and `--merge` is the opt-in; `--only` needs `--merge` (or its
own `--config-dir`), because one check alone is not a usable profile. It says
`partial trace complete` in that case, and checks the config dir is complete
before it says anything is.

Things to know:

- The agent ships with GraalVM, not with the OpenJDK the port pins, so
  `JAVA_HOME` has to point at a **GraalVM 21** build for a traced run. `env.sh`
  pins the install as `GRAALVM_HOME` (default `/home/nekit/UT/graalvm-ce-21`,
  overridable) and deliberately never assigns it into `JAVA_HOME` — the caller
  opts in, one command at a time, as above. `env.sh` keeps any
  `JAVA_HOME` that reports 21.x, and GraalVM CE 21.0.2 does.
- **Run under GraalVM, never build under it.** Class files from the port's
  OpenJDK 21.0.11 load fine on GraalVM CE 21.0.2, so nothing needs rebuilding;
  `build-atlas.sh` stamps the builddir with the JDK it used and reconfigures when
  that changes, which means a skia rebuild (~2 min) each way.
- The agent records only what a run actually touches, and this stack is
  reflection-heavy in places a boot does not reach: atlas resolves every view's
  declared methods before drawing it, and the app looks up TL classes by name.
  Drive the checks under the agent and merge their configs rather than trusting
  one idle run — which is what `trace-metadata.sh` does.
- The agent writes its files when the VM shuts down, so a run that is killed
  contributes nothing. Every check has to be allowed to finish.
- `-X` is also how to pass anything else HotSpot-specific (`-Xmx`,
  `-XX:+UseSerialGC`); `JDWP_LISTEN=<port>` and `ATL_CHECK_JNI=1` are launcher
  environment variables for the debugger and for `-Xcheck:jni`.

## The native image: what it costs and what it buys

`build-image.sh` produces `out/image/libmercurygram.so` (247,476,056 B, ~4.7 min,
9.1 GB peak RSS), and `run.sh --image` — or `PORT_LAUNCHER=image` for any
`check-*.sh` — boots the app on it with no `libjvm.so` in the process. All three
acceptance checks pass on it.

**It is the preferred x86_64 desktop runtime**: faster to start, lighter in
memory, and bigger on disk. Measured on x86_64 on 2026-08-11 (the full
itemisation is in `BRINGUP_NOTES.md`):

| | jlink (shipping) | native image | delta |
| --- | --- | --- | --- |
| what changes on disk: jars + `jvm/` + api-impl + shim + launcher, vs the `.so` + launcher | 195,908,110 B | 247,611,312 B | **+51.7 MB (+26.4 %)** |
| whole install, same tree | ~324 MB | ~376 MB | **+15.9 %** |
| compressed (what a click downloads) | 103,436,782 B | 80,787,379 B | −22.6 MB |
| cold start to first frame, n=6 | 9.58 s | 7.27 s | **−24.1 %** |
| RSS at the chat list, t=75 s, n=6 | 589 MB | 503 MB | −14.6 % |

So the image is a better runtime and a worse install. The original rule was smaller
*and* faster; the 2026-08-11 decision was that the 24 % start-up win is worth
51.7 MB of disk, so the image is what a desktop run should use. HotSpot stays
the development runtime — it is the only one with `--run-class`, JDWP and
`hs_err` files, and the only one that can be traced (FR-2).

`click/` is unaffected, and not because of these numbers: `native-image` cannot
cross-compile, so there is no arm64 image to ship (FR-6). Re-measure with
`measure-startup.sh` (cold runs need passwordless `sudo` to drop the page cache):

```sh
linux-port/measure-startup.sh --rounds 4 --seconds 75
linux-port/measure-startup.py --summary linux-port/out/measure/startup-results.json
```

Two things worth knowing before reopening the size question. GraalVM CE 21.0.2
has no `-Os` and its serial GC is already what this builds with, so the usual
size lever needs a newer GraalVM, not a rebuild. And an arm64 image cannot be
cross-compiled: it would need an aarch64 host with 16 GB of RAM (peak RSS here is
9.1 GB) taking the architecture-neutral jars and `out/ni-config` as its only
inputs — an estimated 6-12 minutes a build, plus a device-side trace, because
this config was traced with `ATL_NO_GPU=1` and the phone runs Ganesh.

## The atlas commit this port needs

atlas is built from `linux-port/atlas/`, a checkout of atl-touch **`master`**, at
commit **`86480a1d`** ("keystore: give the AndroidKeyStore provider a named
class"). Every build records what it used in `out/atlas/ARTIFACTS.md` and
`out/atlas/artifacts.env`.

The port no longer carries an atlas branch of its own. Everything the bring-up
needed is in atl-touch master: the stock-JVM launcher and its `--run-class` mode,
the native-image VM backend, the api-impl build against the JDK's `java.*`,
minikin text shaping with the bundled Roboto families, the rest of the GLES 2.0
binding and SurfaceTexture. Upstream reworked some of it on the way in, so the
commits do not match the old branch one for one — master is the branch to build,
and the branch to fix framework bugs on.

A framework fix is a commit on master, pushed to atl-touch
(`git@github.com:NotKit/atl-touch.git`), which is also where `build-all.sh` clones
from on a machine with no atlas checkout:

```sh
git -C linux-port/atlas commit -am "api-impl: ..."
linux-port/build-atlas.sh && linux-port/run.sh --seconds 25
git -C linux-port/atlas push origin HEAD:master
```

The push is `HEAD:master` because the local branch here is `mercurygram/master`
(see "atlas source checkout" above). The old port branch is kept on the remote as
`mercurygram/openjdk-port` for history; nothing builds from it any more.