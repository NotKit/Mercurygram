# The HotSpot launcher

**The launcher lives in atlas, not here**:
`$ATLAS_DIR/src/main-executable-hotspot/`, built by `build-atlas.sh` as the
meson target `android-translation-layer-hotspot` and installed next to the
framework libraries in `out/atlas/`. This directory holds the decision and the
port's smoke test for it, nothing else.

## Why it is in atlas

The PRD allowed either home and preferred atlas if the launcher turned out to
need atlas internals rather than atlas's public boot sequence. It does, in a way
that is not negotiable: `libtranslation_layer_main.so` **imports** symbols from
whatever executable loads it.

```
$ nm -D --undefined-only out/atlas/libtranslation_layer_main.so | grep -vF @
apk_path            atl_window          get_app_data_dir
bionic_dlopen       bionic_dlsym        bionic_glBindFramebuffer
bionic_eglGetDisplay  bionic_eglCreateWindowSurface  bionic_eglDestroySurface
bionic_eglMakeCurrent bionic_eglSwapBuffers
```

The launcher is one half of that link graph, not a consumer of it. On top of
that it calls `set_up_handle_cache`, `prepare_main_looper`, `activity_start`,
`activity_window_ready` and the `ATLWindow` API, and includes
`api-impl-jni/{defines,util,handle_cache,ATLWindow}.h` and
`api-impl-jni/app/android_app_Activity.h`. Keeping it here would mean keeping a
second copy of that ABI in this repo, silently drifting whenever atlas changes.

`build-atlas.sh` asserts the contract from the other side: every one of those
imported symbols must be defined by the installed launcher, or the build fails.

## What the launcher does differently from `android-translation-layer`

| | ART launcher | HotSpot launcher |
| --- | --- | --- |
| VM | `libart` via the dex install dir found with `dladdr` | `libjvm`, class path passed in |
| framework | dexed `api-impl.jar` | `--api-impl-jar`, the pre-dex jar |
| app code | apk's `classes.dex` | `--classpath`, jars (`dir/*` expanded by the launcher, `JNI_CreateJavaVM` does not) |
| library registration | `Runtime.loadLibrary(String, ClassLoader)` (ART-only) | `android.atl.ATLRuntime.loadNativeLibrary` |
| app `.so`s | extracted from the apk, bionic-linked | glibc builds already on `--library-path` |
| `bionic_*` | the bionic translation layer | the plain host calls (`glibc_compat.c`) |
| debugging | `-XjdwpOptions` | `-agentlib:jdwp` (`JDWP_LISTEN` either way) |

Dropped on purpose: `init__r_debug` and `dl_parse_library_path` (bionic linker),
`libc_bio_path_overrides` (fonts resolve through Skia's fontconfig now),
`pregrow_stack` (ART's guard page), apk native-library extraction, and
`--install`/`--instrument`.

Properties the launcher sets: `Build.VERSION.SDK_INT` (28 by default,
`--sdk-int`), `atl.apk.path`, `atl.data.dir`, `atl.app.id`,
`--add-opens=java.base/java.io=ALL-UNNAMED`, and `user.language` /
`user.country` taken from the environment before `LC_ALL` is forced to
`C.UTF-8` the way Android has it.

## Running it

`smoke-test.sh` is the HotSpot check: `--smoke-test N` boots the VM and the
window but creates no application, so it proves the runtime without depending on
anything Mercurygram does. It writes `out/run.log`, screenshots the window into
`out/screenshots/`, and starts an `Xvfb` if the session has no display.

```sh
linux-port/build-atlas.sh          # builds and installs the launcher
linux-port/launcher/smoke-test.sh  # exits 0 when the runtime is up
```

`--run-class CLASS` is the other test entry point: it runs that class's
`main(String[])` in the app's runtime — same framework, class path and native
libraries as a real run — instead of creating the application, then exits with
its status. `linux-port/check-native-loader.sh` runs on it.

`display.sh` holds the two things every run script here needs and nothing else:
`port_start_display` (an `Xvfb` when the session has no display) and
`port_screenshot`.

`libjvm.so` is not on the default loader path and the launcher's RUNPATH is
deliberately `$ORIGIN` only, so any run needs
`LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ATLAS_OUT`.
