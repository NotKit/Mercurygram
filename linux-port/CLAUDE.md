# linux-port/ conventions

- Every script starts with `source "$(dirname "$0")/env.sh"` (or `../env.sh`) and
  uses `$PORT_OUT`, `$ATLAS_DIR`, `$JAVA_HOME` from there. Never hardcode paths
  or a JDK version in a build script — the toolchain is pinned in one place.
- All products go under `linux-port/out/` (gitignored). Nothing generated is
  committed; scripts must be idempotent and safe to re-run.
- `$ATLAS_DIR` is `linux-port/atlas/`: an atl-touch checkout on branch
  `mercurygram/openjdk-port`, its own git repo, gitignored by this one. It is a
  source dependency the port builds, not a place artifacts are copied from. Fix
  framework bugs there as commits that could be sent upstream to atl-touch; never
  patch atlas from this repo and never paper over a framework bug in the shim jar
  or the launcher.
- Run `check-env.sh` before debugging a build failure; it catches a wrong JDK
  (needs 21.x) and a missing atlas checkout, the two usual causes.
- `native/build_*_linux.sh` mirror the Android `TMessagesProj/jni/build_*.sh`:
  same source patches, same configure flags minus the NDK ones, plus
  `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` because every archive is linked into
  `libtmessages.so`. Read the Android script before writing a new one.
- Native deps install as a prefix: `out/native/<dep>/{lib,include}`. BoringSSL is
  the exception — its archives sit directly in `out/native/boringssl/` with
  `include/` beside them. Point the libtmessages build's imported targets at these, not at the
  `jni/<dep>/build/${ANDROID_ABI}/` paths in `jni/CMakeLists.txt`.
- Scripts use `set -euo pipefail`, so never pipe a long-running command into
  `grep -q` — grep exits first and the SIGPIPE fails the pipeline. Capture the
  output in a variable, then grep it.
- `native/CMakeLists.txt` mirrors `TMessagesProj/jni/CMakeLists.txt` target by
  target; it does not include it. Re-read the Android file before changing the
  overlay, and keep source lists and compile flags in step with it.
- Compiling jni/ sources against glibc + libstdc++ instead of bionic + libc++
  keeps turning up missing transitive includes and POSIX-vs-NDK signature
  differences. Fix them in `native/include/port_compat.hpp` (force-included
  into every C++ TU) or with a shim header under `native/include/`, never by
  editing `TMessagesProj/jni/**` — FR-7.
- Missing Android system libraries get a declaration-only header in
  `native/include/android/` plus either an implementation in `native/stubs/` or
  a link against atlas's `libandroid.so.0`. Check what atlas already exports
  (`nm -D $ATLAS_BUILDDIR/libandroid.so.0`) before writing a stub.
- Gradle glue for the port lives in `gradle/`, is applied from the root
  `build.gradle` only under `-PlinuxPort`, and hangs off `gradle.projectsEvaluated`
  (an `afterEvaluate` registered from the root project runs before AGP's, so
  variant configurations do not exist yet). The same flag guards
  `externalNativeBuild` in the two Android modules — never let a port build
  invoke the NDK, it dirties `TMessagesProj/jni/`.
- The port's chosen variant is `afatFdX86_64Debug`. Anything that names app
  classes (launcher, shims, `-D` properties) depends on `debug` being the
  build type, because `release`/`standalone` run R8 and rename them.
- Verification helpers written in Java go in `tools/`, built into
  `$PORT_OUT/tools` by the script that uses them — same idea as
  `native/tools/dlopen_check.c`.
- atlas is built by `build-atlas.sh` from `$ATLAS_DIR` into `$ATLAS_BUILDDIR`
  (`out/atlas-build/`) and installed
  into `$ATLAS_OUT` (`out/atlas/`), which is both the framework jar's home and the natives dir
  (`java.library.path`). Read `out/atlas/ARTIFACTS.md` for what each file is. The
  framework jar is atlas's `hax-stripped.jar` (pre-dex javac output) — never
  atlas's `api-impl.jar`, which is a `classes.dex`.
- atlas's javac writes generated JNI headers into its own source tree. That is
  now expected: commit them on the atlas branch like any other change, and keep
  the checkout otherwise clean so a real diff stays visible.
- Build atlas with the port's JDK 21 (`env.sh`), not the system default (25) —
  meson's `jni` dependency and javac must match the runtime. meson caches the java
  compiler in coredata, so a JDK change needs `meson setup --wipe` (what
  `build-atlas.sh --reconfigure` does), and that means rebuilding skia too;
  `build-atlas.sh` stamps the builddir with its JDK so it happens once.
- `linux-port/atlas/subprojects/skia` is a symlink to the shared ~8 GB skia tree.
  Never delete or re-download it; `--clean` means the builddir, not the sources.
- Record every deviation from the Android build in `BRINGUP_NOTES.md` as it is
  found; that file is the memory between sessions.
- The compat shim (`shim/`, built by `build-shim.sh`) may only contain classes
  ART's boot classpath has and the JDK lacks: `libcore.*`, `dalvik.*`,
  `android.system.*`, `android.icu.*`, `org.xmlpull.*`, `org.kxml2.*`. It compiles
  against the JDK alone — never against api-impl. A framework bug or an ART
  assumption inside atlas gets fixed in `$ATLAS_DIR` instead, and listed in
  `shim/README.md` under "Fixed in atlas".
- Nothing can be shimmed into `java.*`. If api-impl calls a method only libcore
  adds to a JDK class, the fix is in atlas's compilation, and
  `tools/JdkRefCheck.java` (run by `build-shim.sh`) catches it at build time.
- The launcher is an atlas meson target (`$ATLAS_DIR/src/main-executable-hotspot/`,
  `android-translation-layer-hotspot`), built and installed by `build-atlas.sh`;
  `launcher/` here holds only the decision note and `smoke-test.sh`. Edit the
  launcher in atlas and commit it there. Reason in `launcher/README.md`:
  `libtranslation_layer_main.so` *imports* `apk_path`, `atl_window`,
  `get_app_data_dir` and the `bionic_*` calls from its executable.
- Changing a Java signature that has a native peer in atlas needs two ninja
  passes: javac regenerates `src/api-impl-jni/generated_headers/*.h`, but the
  `.so` does not depend on them, so the first build compiles against the stale
  header. Re-run, then commit the header on the atlas branch.
- Anything running the launcher needs
  `LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ATLAS_OUT` — `libjvm.so` is
  deliberately not in its RUNPATH.
- `JNI_CreateJavaVM` is not the `java` command: it does not expand `dir/*` in
  `java.class.path`, and `System.load` called from JNI binds to the boot class
  loader. The launcher handles both; don't reintroduce either assumption.
- Before adding a shim class, run `shim/audit-shim.sh`: it lists what is
  unresolved and who references it. Implement what a reachable caller demands,
  record the rest under "Deferred" with its referrers.
- Shim classes carry approximations (ICU patterns, plural rules, likely
  subtags). Say so in the class javadoc *and* in `shim/README.md`, so nobody
  later mistakes them for the real ICU behaviour.
