# Mercurygram on desktop OpenJDK (linux-port)

Build glue for running Mercurygram on x86_64 desktop Linux on a stock OpenJDK 21
HotSpot JVM, using the [atlas](https://gitlab.com/android_translation_layer/android_translation_layer)
(atl-touch) Android framework as plain **jars** instead of dex under ART.

No ART, no dex2oat, no bionic_translation: the app's Java is AGP's javac output
jarred without d8, and the app's JNI libraries are rebuilt from the in-tree
sources against glibc.

Bring-up workarounds and crash notes: `BRINGUP_NOTES.md`.

## Boot architecture

`launcher/main.c` replaces atlas's `src/main-executable/main.c`: it links
`libjvm.so` from the JDK and boots HotSpot through the JNI invocation API
instead of ART. It sets the system properties atlas reads (SDK_INT, app id, data
dir, apk path), builds the classpath from atlas's pre-dex `api-impl.jar` plus the
compat `shim.jar` plus the app jars, then drives atlas's normal startup sequence
(`Context.createApplication` → `ContentProvider.createContentProviders` →
`Activity.createMainActivity`) and enters the GLib main loop. Resources and
assets still come from the built APK through atlas's libandroidfw path, so only
*code* loading changes.

```
linux-port/launcher/main.c
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
| `launcher/` | the HotSpot launcher that replaces atlas's ART `main.c` |
| `shim/` | javac-built jar with the libcore/dalvik classes HotSpot has no equivalent for |
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

Build and run entry points (`build-all.sh`, `run.sh`) are added by the later
stories and documented here as they land.

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
