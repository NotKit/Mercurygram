# Bring-up notes

Running log of workarounds, deviations from the Android build, and crash fixes.
One entry per problem: symptom → cause → where it is handled.

## Native dependencies

- **BoringSSL archives land at the top of the build tree**, not in
  `crypto/`+`ssl/` subdirs the way `TMessagesProj/jni/CMakeLists.txt` expects
  (`boringssl/build/${ANDROID_ABI}/crypto/libcrypto.a`). The submodule moved both
  `add_library` calls to its top-level `CMakeLists.txt`.
  `build_boringssl_linux.sh` locates the archives with `find` instead of
  hardcoding either layout.
- **`AES_ige_encrypt` is in `libssl.a`.** `patches/boringssl/0001-add-AES-IGE-mode.patch`
  appends `ssl/aes_ige.c` to `SSL_SOURCES`, so the MTProto cipher ships with
  libssl even though it is a crypto primitive. Link order in the libtmessages build must keep
  `ssl` before `crypto`.
- **`nm ... | grep -q` under `set -o pipefail` reports a false failure**: grep
  exits at the first match, nm dies of SIGPIPE, and the pipeline status becomes
  141. Port scripts read symbol lists into a variable and grep that.
- **ffmpeg/libvpx build out of tree.** The Android scripts configure inside the
  submodule and `make distclean`/`make clean` first, which leaves the submodule
  dirty. The linux scripts run `configure` from `out/native/<dep>/build/`
  instead; nothing under `TMessagesProj/jni/` is written.
- **ffmpeg's `--extra-cflags` loses `-fPIE -pie --static`.** Those three come
  from the Android script; on a glibc host the static/PIE mix makes configure's
  link tests fail. `-fPIC` is kept (the archives go into `libtmessages.so`).
- **ffmpeg keeps `--disable-asm`** because that is what the Android x86_64 case
  passes (`ADDITIONAL_CONFIGURE_FLAG`, last flag, overrides the earlier
  `--enable-x86asm`). Slower decode than a normal desktop ffmpeg; revisit only
  if it shows up as a real problem. libvpx and dav1d do assemble x86 asm, via
  host `yasm`/`nasm` instead of the NDK's.
- **The Android reproducibility hacks are dropped**: rewriting `ffbuild/version.sh`
  and `sed`-ing NDK paths out of `config.h`/`vpx_config.*`. Both edit the
  submodule source tree and only matter for byte-identical Android artifacts.
- **`patch_ffmpeg.sh`'s merged `jni/ffmpeg/include/` directory is not created.**
  It exists for `voip/CMakeLists.txt`, which this port excludes (FR-3). The
  private-header copies it patches (`isom.h`, `get_bits.h`, …) *are* installed,
  into `out/native/ffmpeg/include/`, because `gifvideo.cpp` needs them.
- **`--disable-neon-asm`/`--disable-neon-dotprod` dropped from libvpx**: arm-only
  options, no effect on an x86_64 target (configure still accepts them).
- **ffmpeg needs `--disable-bzlib --disable-lzma --disable-iconv`.** The NDK
  sysroot has none of the three, so the Android script never had to say so;
  on glibc configure finds them and `matroskadec.c` then pulls in `BZ2_*`,
  breaking the libtmessages link. Added to `build_ffmpeg_linux.sh` to keep the
  same feature set as the Android build. (Changing configure flags needs
  `--clean`; the script skips reconfiguring when `config.h` already exists.)

## libtmessages

- **The build is an overlay, not a wrapper.** `linux-port/native/CMakeLists.txt`
  mirrors `TMessagesProj/jni/CMakeLists.txt` rather than including it: that file
  branches on `ANDROID_ABI` throughout, `include()`s `voip/CMakeLists.txt`,
  `add_subdirectory(whisper)` and ends in `AndroidNdkModules`. Keep the two in
  sync when jni/CMakeLists.txt changes.
- **`-DANDROID` is kept, contrary to the original plan.** In this tree it is
  not a platform switch but the "build the JNI bridge" switch: `tgnet` hides
  `ConnectionsManager::useJavaVM`, `NativeByteBuffer::getJavaByteBuffer` and
  every `jobject` field behind `#ifdef ANDROID`. Dropping it would compile a
  tgnet with no Java integration at all. The real platform macro is
  `__ANDROID__`, which clang correctly does not define here.
- **Excluded from the build**: `voip/` (libtgvoip, tgcalls, webrtc, rnnoise,
  openh264, voipandroid) and breakpad per the PRD; `whisper_jni.cpp` and
  `tde2e/bridge.cpp` because `jni/whisper` and `jni/td` are not checked out;
  `cpufeatures`, an NDK module only used by the arm code. Consequence:
  `MgWhisperTranscriber` and the tde2e call-encryption natives will raise
  `UnsatisfiedLinkError` if reached — both are outside the boot-to-emoji path.
- **`jni.c` calls `tgvoipOnJNILoad` from `JNI_OnLoad`** and it lives in the
  excluded voip tree. `native/stubs/voip_stub.c` returns `JNI_TRUE`.
- **breakpad is shimmed at the header level.** `utilities.cpp` includes
  `breakpad/src/client/linux/handler/{exception_handler,minidump_descriptor}.h`;
  `native/include/breakpad/...` provides no-op classes with the same API, so
  `setupNativeCrashesListener` installs nothing. HotSpot writes its own hs_err.
- **libstdc++ is not libc++.** The NDK's libc++ pulls `<memory>`, `<cstring>`,
  `<algorithm>` and `<climits>` in transitively from `<string>`; libstdc++ does
  not, so tgnet and rlottie fail on `std::unique_ptr`, `std::memcpy`,
  `SHRT_MAX`. `native/include/port_compat.hpp` is force-included into every C++
  TU with those headers instead of patching ~40 upstream files.
- **`JavaVM::AttachCurrentThread` takes `JNIEnv**` on Android, `void**` on the
  JDK.** C++ rejects the conversion at a dozen call sites in tgnet and
  gifvideo. `port_compat.hpp` defines a function-like macro (after `<jni.h>`,
  so the declaration itself is untouched) that inserts the cast.
- **`-std=c11`/`-std=c++17` hide the POSIX declarations glibc gates behind
  `_DEFAULT_SOURCE`** (`strdup`, `strncasecmp`, `flockfile`), which bionic
  exposes unconditionally. Switched to `gnu11`/`gnu++17`.
- **libFLAC needs `HAVE_STDINT_H=1`.** `share/alloc.h` reaches `SIZE_MAX` only
  through `<stdint.h>` behind that flag, and falls back to bionic's
  `SIZE_T_MAX`, which glibc's `<limits.h>` does not define.
- **`gifvideo.cpp` mixes kernel UAPI headers with libc ones** (`<asm/fcntl.h>`,
  `<linux/stat.h>` next to `<fcntl.h>`). bionic tolerates it, glibc redefines
  `struct flock`/`f_owner_ex`. `native/include/{asm/fcntl.h,linux/stat.h}`
  shadow them and forward to `<fcntl.h>`/`<sys/stat.h>`.
- **`gifvideo.cpp` includes two webrtc H.264 parser headers it never uses.**
  They resolve relative to `jni/`, but their own includes need
  `jni/voip/webrtc` on the include path — added, header-only, nothing links.
- **Android system libraries**: `android/log.h` is our own header with the NDK
  enum/prototypes over `native/stubs/android_log.c` (stderr, threshold from
  `TMESSAGES_LOG_LEVEL`); `android/bitmap.h` and `android/asset_manager*.h` are
  declaration-only shims resolved by atlas's `libandroid.so.0`, which exports
  `AndroidBitmap_{getInfo,lockPixels,unlockPixels}` and the whole `AAsset*` API.
  `jnigraphics` therefore does not exist as a separate library here.
- **The OpenSL ES stub is currently dead weight.** With voip excluded nothing
  references it, but it is built (`native/stubs/opensles_stub.c`, ported from
  mercurygram-click-packaging) and installed as
  `out/libOpenSLES.so.1`. Voice record/playback over OpenSL stays a Non-Goal.
- **`-Wl,--no-undefined` is added** so a missing Android symbol fails the link
  instead of surfacing as an `UnsatisfiedLinkError` in the middle of bring-up.
- **RPATH is `$ORIGIN:$ORIGIN/atlas:$ATLAS_BUILDDIR`.** CMake would otherwise
  bake the build tree in. `$ORIGIN` finds the OpenSL ES stub next to the
  library; `libandroid.so.0` comes from `out/atlas/` once `build-atlas.sh` has run.
- **`libtmessages.49.so` cannot be `dlopen`ed with `RTLD_NOW` standalone.**
  atlas's `libandroid.so.0` leaves `android::Looper::prepare` &c. to
  `libtranslation_layer_main.so`, which itself leaves `apk_path` to the
  launcher executable. The build's `dlopen_check` uses `RTLD_LAZY`; the chain
  only closes under atlas's launcher.

## App classpath

- **The port needs a Gradle opt-in, not just a new task.** `-PlinuxPort` guards
  three things in `TMessagesProj/build.gradle` and `TMessagesProj_App/build.gradle`:
  `externalNativeBuild` (both the `path` and the `defaultConfig` arguments), the
  app's `jniLibs.srcDirs`, and the `merge*JniLibFolders` ordering against the
  per-ABI native tasks. Without it, assembling the APK runs the whole NDK build
  and `patch_*.sh`, which dirties `TMessagesProj/jni/`'s submodules — the one
  thing the port must not do.
- **Flavor: `afatFdX86_64Debug`** (resolves the open question about which flavor). `release`
  and `standalone` set `minifyEnabled true`, and R8 renames the classes the
  launcher, the shims and `NativeLoader` name explicitly. `debug` is the only
  non-minified build type the `variantFilter` allows for an `afatFd*` flavor.
- **AGP still downloads the NDK** even with `externalNativeBuild` gone, because
  `ndkVersion` and `ndk.debugSymbolLevel = 'FULL'` are set. It is only resolved,
  never invoked; not worth guarding.
- **`TMessagesProj` has no product flavors**, so the app's `afatFdX86_64Debug`
  variant consumes the library's plain `debug` variant. Do not construct library
  task names from the app variant name.
- **Dependency jars come from the `android-classes-jar` artifact view** of
  `afatFdX86_64DebugRuntimeClasspath`. AGP has already unpacked every AAR, so
  there is no AAR handling to write — but all 90 files are literally named
  `classes.jar`, hence the rename to `<group>-<module>-<version>.jar`.
- **`R` classes are not in any of those jars.** They live in
  `intermediates/compile_and_runtime_not_namespaced_r_class_jar/<variant>/**/R.jar`,
  copied as `mercurygram-res.jar`. With `android.nonTransitiveRClass=false` that
  one jar holds the real ids for every package, app and library alike, and
  nothing else on the classpath defines an `R` — no zeroed-stub shadowing risk.
- **`Copy.from {}` is not lazy enough for a just-built APK.** Gradle resolves it
  while building the task graph, so a clean run fails with "Could not determine
  the dependencies". Use a plain task with `inputs.files` on the `package<V>`
  task and copy in `doLast`.
- **Groovy `GString` keys never match `String` lookups.** The stale-jar pruning
  in `copyLinuxPortDeps` deleted jars it had just written until the collected
  names were declared `String`.
- **`gradle.projectsEvaluated`, not `afterEvaluate`.** The script is applied with
  the root project, so its `afterEvaluate` would run before AGP's and the variant
  configurations would not exist yet.
- **Two configure-time inputs the port has to supply**: `./API_KEYS` (read
  eagerly by `TMessagesProj/build.gradle`; dummied with a warning) and
  `MG_BUILD_TAG` (`gradle/mg-version.gradle` refuses to configure without it).
- **Expected still-missing classes.** `ApplicationLoader` and `LaunchActivity`
  cannot resolve yet — they extend `android.app.Application`/`Activity`.
  `PortClassCheck --needs-android` asserts the failure is *only* that, so the
  check stays meaningful until the atlas framework jar lands.
