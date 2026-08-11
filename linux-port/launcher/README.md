# The jar-based launcher

**The launcher lives in atlas, not here**:
`$ATLAS_DIR/src/main-executable-hotspot/`, built by `build-atlas.sh` and
installed next to the framework libraries in `out/atlas/`. This directory holds
the decision and the port's smoke tests for it, nothing else.

It is two meson targets over one `main.c`, differing only in where the VM comes
from (`vm.h` is the interface, `vm_common.c` the shared option assembly):

| target | VM backend | built from |
| --- | --- | --- |
| `android-translation-layer-hotspot` | `libjvm.so`, linked | `vm_hotspot.c` |
| `android-translation-layer-image` | a GraalVM native-image `.so`, `dlopen`ed | `vm_image.c` |

The directory keeps its `-hotspot` name because `linux-port/CLAUDE.md`, this
file and `../README.md` point at it; renaming it buys nothing.

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
`--sdk-int`), `atl.apk.path`, `atl.framework.res.path`, `atl.data.dir`,
`atl.app.id`, `java.library.path`, and `user.language` / `user.country` taken
from the environment before `LC_ALL` is forced to `C.UTF-8` the way Android has
it. Both backends assemble exactly that set (`vm_common_properties`) and both
read every one of them back out of `java.lang.System` afterwards, printing
`vm property: <key>=<value> (from -D)` per property — so "the VM accepted the
option" and "Java can read it" never have to be assumed to be the same thing.
The read-back only reads. One of the launcher's own properties not arriving
exits 1; a `-X -D` of the caller's that the VM normalised (HotSpot rewrites
`sun.jnu.encoding`) is reported as `(the VM's own value, -D asked for …)` and
left alone.
`--add-opens=java.base/java.io=ALL-UNNAMED` (the compat shim needs it) is
HotSpot-only: an image accepts it at VM creation and does nothing with it, so
there it has to be a `native-image` *build* argument instead.

## The image backend

`android-translation-layer-image` takes the same argv and runs the same boot
sequence; what it does not do is assemble a class path. No
`-Djava.class.path`, no `-agentlib:*`, no `-XX:*`, no `-Xcheck:jni`, no
`--add-opens` — an image has none of them, and `-XX:` is the one namespace where
a bad option kills VM creation with no diagnostic at all. `--api-impl-jar`,
`--classpath`, `$JDWP_LISTEN` and `$ATL_CHECK_JNI` are warned about rather than
refused, so one command line drives both launchers.

The image is `dlopen`ed, never linked: it is built *from* atlas's own
`api-impl.jar` (`linux-port/build-image.sh`), it is rebuilt far more often than
the launcher, and the launcher has to be testable against a stub image before a
real one exists. `--vm-library PATH` (or `$ATL_IMAGE_LIB`) says which `.so`; the
resolved path is printed as `image: opened …`, which is the only honest record
of where the VM came from. `ldd` on the binary shows no `libjvm.so` and
`nm -D --undefined-only` no `JNI_CreateJavaVM`; `build-atlas.sh` asserts both.

`--vm-check CLASS` runs that class's `main(String[])` the moment the VM exists
and exits — before `FindClass("android/view/Display")`, the handle cache, the
window and the looper, i.e. before anything that needs api-impl. That is what
makes it a test of a VM backend rather than of the runtime the app needs, and
what `--run-class` cannot be.

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

`image-smoke-test.sh` is the same idea for the image launcher, and says up front
what a stub image cannot prove: atlas's own `--smoke-test` needs api-impl inside
the image, so it belongs to the real image build. What it does prove is the VM backend — the
`dlopen`, `JNI_CreateJavaVM`, every `-D` readable from Java, a static method
called inside the isolate, and no `libjvm.so` mapped in the process, read from
inside it. It runs the identical `--vm-check` on HotSpot first, so a failure
separates a wrong harness from a wrong image before any debugging starts.

```sh
linux-port/build-image.sh --stub         # ~30 s, one class
linux-port/launcher/image-smoke-test.sh  # both launchers, same class
```

`display.sh` holds the two things every run script here needs and nothing else:
`port_start_display` (an `Xvfb` when the session has no display) and
`port_screenshot`.

`libjvm.so` is not on the default loader path and the launcher's RUNPATH is
deliberately `$ORIGIN` only, so any HotSpot run needs
`LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ATLAS_OUT`. An image run gets the image's
directory instead of `lib/server`, on purpose: nothing in that process may be
able to find a `libjvm.so` even by accident.
