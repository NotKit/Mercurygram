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

```
atlas android-translation-layer-hotspot
        |  JNI_CreateJavaVM
        v
   libjvm.so  (OpenJDK 21 HotSpot)
        |
        |  classpath
        +--> out/atlas/api-impl.jar        atlas Android framework (javac, pre-dex)
        +--> out/shim/shim.jar             libcore/dalvik classes HotSpot lacks
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
| `env.sh` | shared environment (`ATLAS_DIR`, `ATLAS_SKIA_DIR`, `ATLAS_BUILDDIR`, `ATLAS_OUT`, `JAVA_HOME`, `PORT_OUT`); source it, don't run it |
| `atlas/` | the atlas (atl-touch) sources the port builds — a separate git repo on branch `mercurygram/openjdk-port`, gitignored here |
| `build-atlas.sh` | builds atlas from `atlas/` into `out/atlas-build/`, installs `out/atlas/` |
| `check-env.sh` | toolchain smoke test; exits 0 when the environment is usable |
| `native/` | glibc builds of the JNI deps (boringssl, ffmpeg, dav1d, libvpx) and of `libtmessages.so` |
| `gradle/` | Gradle glue applied only under `-PlinuxPort` (the `jarForLinuxPort` task) |
| `tools/` | small Java helpers used to verify the port's own artifacts |
| `build-classpath.sh` | builds the HotSpot classpath and the APK from the Android sources |
| `launcher/` | why the HotSpot launcher lives in atlas, the smoke test that boots it, and `display.sh` (the Xvfb/screenshot helper the run scripts share) |
| `run.sh` | runs Mercurygram on the launcher; `--seconds N` also checks the log and takes a screenshot |
| `check-native-loader.sh` | runs `NativeLoader` inside the launcher and proves it loads the glibc `libtmessages.so` |
| `build-shim.sh` | builds the compat shim into `out/shim.jar` + `out/libportshim.so` |
| `shim/` | sources of the libcore/dalvik classes HotSpot has no equivalent for, plus `audit-shim.sh` and the audit note in `shim/README.md` |
| `out/` | all build products and run logs — gitignored, safe to delete |

## Prerequisites

- OpenJDK 21 (Debian: `openjdk-21-jdk-headless`). `env.sh` uses
  `/usr/lib/jvm/java-21-openjdk-amd64` unless `JAVA_HOME`/`JAVA_21_HOME` says
  otherwise. Newer JDKs are deliberately not used: the toolchain is pinned so
  every build step sees the same runtime.
- Host toolchain: `cc`, `c++`, `cmake`, `make`, `ninja`, `pkg-config`, `unzip`.
- An atlas checkout at `linux-port/atlas` (see below) plus `meson`, `ninja`, and
  `gn` + `clang` for its skia subproject: the port builds atlas itself, it is not
  a prebuilt dependency. atlas's own dependencies (`art-standalone`, GTK4, GLFW,
  the AOSP support libraries in `/usr/local/lib/art`) must already be installed.
- A Wayland or X11 session for the run steps. `ATL_GLFW_PLATFORM` forces the
  GLFW backend; `ATL_NO_GPU=1` falls back to CPU raster.

## Usage

```sh
source linux-port/env.sh     # environment for any manual step
linux-port/check-env.sh      # verify the toolchain first
```

`linux-port/run.sh` launches the app (see *Running the app* below);
`build-all.sh`, the one-command build of everything, comes later.

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
[atl-touch](https://github.com/NotKit/atl-touch) on branch
`mercurygram/openjdk-port`, its own git repository, gitignored by this one. The
port builds it and may change it; framework fixes are commits on that branch,
written so they can go upstream to atl-touch.

On this machine it is a worktree of the existing clone, which is how to recreate
it:

```sh
git -C /home/nekit/UT/atlas worktree add \
    /home/nekit/UT/mercurygram-src/linux-port/atlas -b mercurygram/openjdk-port
ln -s /home/nekit/UT/atlas/subprojects/skia linux-port/atlas/subprojects/skia
```

On a machine without that clone, `git clone -b mercurygram/openjdk-port
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
git -C linux-port/atlas push origin mercurygram/openjdk-port
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
| `out/atlas/artifacts.env`, `ARTIFACTS.md` | generated paths and provenance |

The jar to put on a HotSpot classpath is **`hax-stripped.jar`**, atlas's javac
product minus three compile-only stubs (`meson.build:274`). atlas's own
`api-impl.jar` is that jar after `dx --dex` and contains only a `classes.dex`;
the script fails if it ever ends up installing it. `out/atlas/` doubles as the
natives dir (`java.library.path`): the installed
`libtranslation_layer_main.so` keeps its `$ORIGIN/` RUNPATH, so `libskia.so` and
`libandroid.so.0` resolve from the same flat directory, and the AOSP support
libraries (`libandroidfw`, `liblog`, `libbase`, …) from `/usr/local/lib/art`.

`fonts.xml` is not read on this path: atlas resolves fonts through Skia's
fontconfig `SkFontMgr`, and the only consumer of `/system/etc/fonts.xml` is the
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
linux-port/run.sh --fresh             # start from an empty data dir
linux-port/run.sh --gpu               # try Ganesh again (currently crashes, see below)
linux-port/run.sh -- --window-width 1280   # anything after -- goes to the launcher
```

The app data dir is `out/data/` (`--data-dir` to move it, `ANDROID_APP_DATA_DIR`
is honoured too), the log is `out/run.log` and timed runs write
`out/screenshots/run.png`. With no session, `launcher/display.sh` starts an Xvfb.

A timed run is also the story's check: it requires `boot: Application.onCreate
returned` and `boot: main activity started` in the log, no `hs_err`, and no
uncaught exception for the whole run. That now reaches the Telegram
intro screen ("Start Messaging") and idles cleanly for 70s.

Two things to know about the run:

- **CPU raster is the default.** atlas's Ganesh path segfaults inside skia's
  `GrGLExtensions::init` while assembling the GL interface — on llvmpipe and on
  hardware GL alike, so neither the JVM nor the headless setup is the cause.
  `run.sh` exports `ATL_NO_GPU=1`; `--gpu` reproduces it. See `BRINGUP_NOTES.md`.
- **`-Dtmessages.native.path`** points `NativeLoader` at
  `out/libtmessages.so`; without it the app would try to unpack an Android `.so`
  from the apk.
