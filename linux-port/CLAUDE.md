# linux-port/ conventions

- Every script starts with `source "$(dirname "$0")/env.sh"` (or `../env.sh`) and
  uses `$PORT_OUT`, `$ATLAS_DIR`, `$JAVA_HOME` from there. Never hardcode paths
  or a JDK version in a build script — the toolchain is pinned in one place.
- All products go under `linux-port/out/` (gitignored). Nothing generated is
  committed; scripts must be idempotent and safe to re-run.
- `$ATLAS_DIR` is read-only: build it and copy artifacts out, never patch it.
  atlas bugs get fixed in the atlas repo, not worked around here.
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
- Record every deviation from the Android build in `BRINGUP_NOTES.md` as it is
  found; that file is the memory between sessions.
