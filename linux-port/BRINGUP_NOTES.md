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
- **Excluded from the build**: breakpad per the PRD; `whisper_jni.cpp` and
  `tde2e/bridge.cpp` because `jni/whisper` and `jni/td` are not checked out;
  `cpufeatures`, an NDK module only used by the arm code. Consequence:
  `MgWhisperTranscriber` and the tde2e call-encryption natives will raise
  `UnsatisfiedLinkError` if reached — both are outside the boot-to-emoji path.
- **`jni.c` calls `tgvoipOnJNILoad` from `JNI_OnLoad`**; with voip built that
  is the real one, which registers libtgvoip's natives and looks up the app's
  `AudioRecordJNI`/`AudioTrackJNI`. `native/stubs/voip_stub.c` is gone.
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
- **The OpenSL ES stub is linked but never selected.** webrtc and libtgvoip
  both build their OpenSL backends, and both pick the Java one instead: atlas
  reports no low-latency audio feature and AAudio is compiled out, so
  `audio_device_impl.cc` lands on `kAndroidJavaAudio`. `slCreateEngine`
  answering "unsupported" is what keeps that honest if anything ever asks.
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
  (Resolved once it did: with `out/atlas/api-impl.jar` on the classpath all three
  app entry classes load.)

## atlas framework build

- **The pre-dex jar is `hax-stripped.jar`, not `api-impl.jar`.** atlas builds
  `src/api-impl/hax.jar` with javac, strips three compile-only stubs from it
  (`meson.build:274`), and only then runs `dx --dex` into `api-impl.jar`
  (`meson.build:279`) — which holds a single `classes.dex`. The port installs
  `hax-stripped.jar` and *names* it `api-impl.jar` in `out/atlas/`, because that
  is the name the PRD and the launcher use; the copy is asserted dex-free.
- **The three stripped stubs stay stripped.** `OnReceiveContentListener`,
  `WindowInsetsAnimation$Callback` and `OnBackInvokedCallback` exist in atlas only
  so the framework compiles against SDK31+ types; the app's bundled androidx
  provides them from `out/classpath/`. The reason atlas strips them (ART's
  duplicate-class check rejecting the oat file) does not apply to HotSpot, but
  keeping the ART layout means one definition instead of two.
- **`out/atlas/` is a flat natives dir on purpose.** `libtranslation_layer_main.so`
  is linked with RUNPATH `$ORIGIN/:$ORIGIN/subprojects/skia:/usr/local/lib/art`,
  so installing `subprojects/skia/libskia.so` next to it is enough — no
  `LD_LIBRARY_PATH` needed for the atlas side. The AOSP support libraries
  (`libandroidfw`, `liblog`, `libbase`, `libcutils`, `libutils`, `libziparchive`)
  come from the absolute `/usr/local/lib/art` entry and are a host prerequisite,
  not artifacts to copy.
- **The port builds atlas itself** (`build-atlas.sh`, replacing the first pass's
  `get-atlas-artifacts.sh`, which copied out of an external builddir). Sources:
  `linux-port/atlas`, a checkout of atl-touch `master`; builddir:
  `out/atlas-build`; install dir: `out/atlas`. The framework's javac writes
  generated JNI headers back into `src/api-impl-jni/generated_headers`, which is
  now expected — they get committed on master like any other change. The script
  diffs `git status` of the checkout around the build and fails on any change
  outside that directory.
- **A JDK change needs `meson setup --wipe`, not `--reconfigure`.** meson caches
  the java compiler in the builddir's coredata, so re-running configuration keeps
  whichever `javac` was found first — here the system default 25 instead of the
  port's 21. `build-atlas.sh` writes the JDK it configured with to
  `$ATLAS_BUILDDIR/.port-jdk` and wipes when that no longer matches `$JAVA_HOME`,
  which also costs a skia rebuild, hence the stamp rather than an unconditional
  reconfigure.
- **`meson setup --wipe <builddir>` alone fails**: with a single argument meson
  reads it as the *source* directory ("Neither source directory … nor build
  directory None contain a build file meson.build"). Pass both dirs.
- **Source edits do reach the port** (the atlas build's acceptance check). Adding
  `public static final int PORT_BUILD_PROBE = 42;` to
  `linux-port/atlas/src/api-impl/android/os/Looper.java` and re-running
  `build-atlas.sh` moved `out/atlas/api-impl.jar` from sha `ffac56a0e25b00b2` to
  `306a73446d33cf2a`, and `javap -p -cp out/atlas/api-impl.jar android.os.Looper`
  listed the new field. Reverting the file and rebuilding removed it again.
- **That jar sha identifies a build, not the sources.** Reverting the probe gave a
  third sha (`f164e855863a1823`) for identical sources: jar entries carry
  timestamps. Compare `javap` output, not hashes, when checking whether a
  framework change landed.
- **The framework's javac emits 413 warnings** (deprecation-adjacent, unchecked)
  against JDK 21 and still produces a 1792-class jar. Not worth chasing; the
  warnings predate the port.
- **A full atlas build is ~95s here** (886 skia targets included, 12 cores), an
  incremental re-run ~4s. Building skia from scratch is far cheaper than the
  first pass's notes assumed, so `--clean` is not something to avoid.
- **The generated JNI headers are tracked by atlas** (97 files under
  `src/api-impl-jni/generated_headers`) and the build rewrites them with identical
  content, so the checkout stays clean. They only show up as a diff when a
  framework signature actually changes — which is exactly when they should be
  committed on the atlas branch.
- **`libtmessages.49.so` bakes `$ATLAS_BUILDDIR` into its RUNPATH**, so moving the
  builddir in tree left the libtmessages artifact pointing at the old external path.
  Re-run `native/build_tmessages_linux.sh` after any change to `$ATLAS_BUILDDIR`;
  the RUNPATH is now `$ORIGIN:$ORIGIN/atlas:<repo>/linux-port/out/atlas-build`.
- **`libtranslation_layer_main.so` has no `JNI_OnLoad`.** The launcher's acceptance
  wording expects one; the library exports statically named
  `Java_android_*` entry points instead, so loading it produces no log line of
  its own. Verify it by calling into it, not by watching for `JNI_OnLoad`.
- **`fonts.xml` is not parsed at runtime, but it is not dead weight either.**
  Only atlas's own executable looks at `/system/etc/fonts.xml`, through the
  bionic-shim path-override table in `src/main-executable/libc_bio_path_overrides.c`.
  The framework builds its collections in `hwui/TypefaceCollection.cpp`: the
  generic families from the Roboto faces atlas now ships (`res/fonts/`,
  installed to `system/fonts`), everything else from Skia's fontconfig
  `SkFontMgr`. The face-and-weight table in that file is `fonts.xml`'s
  sans-serif family transcribed, which is why the file is still copied to
  `out/atlas/system/etc/fonts.xml` — see "sans-serif was never Roboto" below.
- **`framework-res.apk` carries no code** (2480 entries, zero `.class`/`.dex`).
  atlas puts it on `java.class.path` purely so the resource table can be found;
  on HotSpot that is just an extra zip on the classpath.
- **atlas compiles its framework against ART's libcore**, not against a JDK:
  `-bootclasspath <libart libdir>/java/core-all_classes.jar` with
  `-source/-target 1.8` (`src/api-impl/meson.build:861`), which is why the
  classes are major version 52. On this machine that jar is
  `/usr/local/lib/java/core-all_classes.jar` — useful for the shim: `javap` against
  it shows what a framework class could legally have been compiled against, and
  the difference from HotSpot's `java.base` is exactly what the shim jar covers.

## Libcore/dalvik compat shim

- **libcore adds methods to `java.*`, and that is not shimmable.** api-impl was
  compiled with core-all as the *boot* classpath, so javac bound libcore-only
  overloads: `System.arraycopy(char[], int, char[], int, int)` (and byte/int/
  long/float/boolean siblings), `FileDescriptor.getInt$`/`setInt$`,
  `Socket.getFileDescriptor$`, `LinkedHashMap.eldest()`,
  `Thread.{get,set}UncaughtExceptionPreHandler`. Every one throws
  `NoSuchMethodError` on HotSpot — `ArrayMap.put` and `SpannableStringBuilder`
  died on the first call — and no classpath jar can fix it, because `java.*`
  belongs to the JDK. Fixed in atlas by compiling with `--release 8` and core-all
  on the *class* path (12 compile errors, 5 files); `build-shim.sh` now fails if
  such a reference reappears.
- **`--add-opens java.base/java.io=ALL-UNNAMED` is required from the launcher on.**
  atlas's replacement for `FileDescriptor.getInt$` reads the private `fd` field
  reflectively when the runtime has no libcore.
- **Framework "compiled against ART libcore" cuts both ways.** Constants that
  libcore fills in natively (`OsConstants.O_CLOEXEC`, `XmlPullParser.START_TAG`,
  ICU's `Bidi.LEVEL_DEFAULT_LTR`) are *not* inlined into api-impl when they are
  assigned in a static block, but they *are* inlined when they are compile-time
  constants. The shim has to reproduce the real values either way — check with
  `javap -constants` against `/usr/local/lib/java/core-all_classes.jar` before
  inventing one.
- **`android.util.Xml` needs a real pull parser**, not just the interfaces:
  `XmlBlock$Parser` (binary resources) only implements `XmlPullParser`, but
  `Xml.newPullParser()` instantiates `org.kxml2.io.KXmlParser` by name through
  `XmlPullParserFactory`. The shim's `KXmlParser` is a StAX bridge; the factory
  skips class names it cannot load, so the missing `KXmlSerializer` does not
  break parsing.
- **`ATLTimeZone` was an ART workaround.** It built an Android tzdata blob for
  `libcore.util.ZoneInfoDB` because ART returns GMT without one; on a JDK
  `TimeZone.getTimeZone(id)` already works. Fixed in atlas (ask the runtime
  first), which removed four libcore classes from the shim's list.
- **`org.json` is the largest remaining gap** (81 app classes, `ApplicationLoader`
  and `SharedConfig` among them). Android has it on the boot classpath; the JDK
  does not, and no dependency jar in `out/classpath/` carries it. Deferred
  deliberately — it is a JSON library, not a runtime shim.
- **What the JDK cannot approximate:** relative-time wording
  (`android.icu.text.RelativeDateTimeFormatter` is English-only here), CLDR
  skeleton patterns (`ICU.getBestDateTimePattern`), plural rules beyond
  one/other plus the Slavic family, and likely-subtags. All are localisation
  quality, not correctness — but they are visible in the UI.
- **`NativeAllocationRegistry` needs JNI**, not `java.lang.foreign`: the FFM API
  is still preview in JDK 21, so a 10-line `applyFreeFunction` in
  `libportshim.so` is the cheaper answer. `libcore.io.Posix` also uses JNI to
  read `FileDescriptor.fd`, because JNI ignores access control and needs no
  `--add-opens`.

## HotSpot launcher

- **The launcher had to move into atlas**, and the reason is a link-graph one,
  not a taste one: `libtranslation_layer_main.so` *imports* `apk_path`,
  `atl_window`, `get_app_data_dir` and seven `bionic_*` functions from whatever
  executable loads it. It is now atlas's `android-translation-layer-hotspot`
  meson target (`src/main-executable-hotspot/`, atlas commit *add a launcher for
  running apps on a stock JVM*); `linux-port/launcher/README.md` has the full
  decision and the ART-vs-HotSpot differences. `build-atlas.sh` fails the build
  if the launcher stops defining one of those imported symbols.
- **`JNI_CreateJavaVM` does not expand `dir/*` in `java.class.path`.** Only the
  `java` command does, before the VM starts. Passing the port's
  `out/classpath/*` straight through put a directory literally named `*` on the
  class path, and every one of the 90 dependency jars was missing —
  `ClassNotFoundException: androidx.core.content.FileProvider` with an
  `AppClassLoader` frame in the stack, which reads like a classpath typo rather
  than a wildcard problem. The launcher expands it itself now.
- **`System.load` from JNI loads into the wrong class loader.** It binds the
  library to its *calling class*'s loader, and JNI method lookup only searches
  the loader of the class declaring the native method. Called straight from the
  launcher there is no Java caller at all, so the library lands on the boot
  loader and no `Java_android_*` entry point resolves. ART's two-argument
  `Runtime.loadLibrary(String, ClassLoader)` has no JVM equivalent, so atlas
  gained `android.atl.ATLRuntime.loadNativeLibrary` and the launcher calls that.
- **First crash on the boot path: `TypedArray` used ART's pinned arrays.** It
  allocated `mData`/`mIndices` with `VMRuntime.newNonMovableArray` and passed
  `VMRuntime.addressOf()` of each into `applyStyle`/`retrieveAttributes`.
  Nothing outside ART can pin an array, so the shim's `addressOf` returns 0 and
  libandroidfw's `RetrieveAttributes` dereferenced it — SIGSEGV during
  `android.content.Context.<clinit>`, the manifest parse, before any app code
  ran. Fixed in atlas by passing the `int[]` and letting JNI hand out the
  pointers (commit *api-impl: hand the attribute buffers to JNI instead of raw
  addresses*). Watch for the same pattern elsewhere: `addressOf` is the tell.
- **Editing a Java signature that has a native peer needs two ninja passes.**
  javac writes `src/api-impl-jni/generated_headers/*.h`, but nothing in atlas's
  meson graph makes the `.so` depend on them, so the first build compiles the C
  against the stale header and fails with "conflicting types". Re-run; the
  regenerated header is a normal commit on the atlas branch.
- **`-rdynamic` and `$ORIGIN`, not the JDK, in the launcher's RUNPATH.**
  `-rdynamic` is what lets the library resolve the symbols above from the
  executable. `libjvm.so` is deliberately *not* in the RUNPATH (it would pin the
  binary to one JDK install); every run script exports
  `LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ATLAS_OUT` instead.
- **Where the full boot starts.** With the smoke test green, a full boot gets through
  the manifest parse, the content providers and the window, then dies on
  `NoClassDefFoundError: libcore/util/ZoneInfo` in `Context.createApplication`
  (the shim dropped `ZoneInfo` when `ATLTimeZone` stopped needing it
  — `Context` still does) and on
  `ClassNotFoundException: android.window.OnBackInvokedCallback`, one of the
  three stubs `hax-stripped.jar` drops on the assumption that the app's androidx
  brings its own. Both are full-boot work; the log is kept as `out/full-boot.log`.

## NativeLoader hook

- **The only change to `org/telegram/**` for native loading is a system
  property.** `NativeLoader.initNativeLibs` reads
  `-Dtmessages.native.path=<path>`, `System.load`s that file and returns before
  any of the Android logic — the `System.loadLibrary` attempt, the local copy in
  `files/lib/`, and the apk `lib/x86_64/` extraction, none of which can produce a
  glibc library. A failure there is deliberately *not* caught: with the property
  set, falling back to unpacking an Android `.so` would only turn a broken setup
  into a confusing one.
- **`initNativeLibs(null)` has to work.** The hook returns before the `Context`
  is used, which is what lets the check run without an Application. Keep it
  ahead of the `try` block for that reason.
- **`--run-class` in the launcher is how a single piece of app code gets
  tested.** It runs one class's `main()` in the app's runtime instead of
  `Context.createApplication`, so `NativeLoader` could be proven before the full boot
  makes a full boot work (atlas commit *hotspot launcher: add --run-class*).
- **`JNI_OnLoad` needs the framework, not just the class path.** It ends up in
  `imageOnJNILoad`, which requires `android.graphics.BitmapFactory$Options` and
  its `inJustDecodeBounds`/`outWidth`/`outHeight` fields, and in
  `registerNativeTgNetFunctions`, which looks up a few dozen `ConnectionsManager`
  callbacks. atlas's framework satisfied all of them first try; if one ever
  disappears, `System.load` fails with "JNI_OnLoad returned bad version" and the
  real cause is a `FindClass`/`GetFieldID` that returned 0.
- **Both JNI lookup paths are worth checking, they can fail separately.**
  Statically named `Java_org_telegram_*` symbols are resolved by the JVM on first
  call in the loader that did the `System.load`; tgnet's methods are registered
  by `RegisterNatives` from `JNI_OnLoad` instead. `NativeLoaderCheck` exercises
  one of each.

## Boot to the intro screen

Ten crashes between "the window appears" and the intro screen. Each one is
symptom → fix; atlas commits are on `mercurygram/openjdk-port`.

- **`NoClassDefFoundError: libcore/util/ZoneInfo` in `Context.createApplication`
  → atlas *atl: keep libcore out of ATLTimeZone until it is needed*.** The shim
  made `ATLTimeZone` ask the runtime first, which is not enough: the JVM loads
  every class named in the callees it verifies, so `ZoneInfo`,
  `MemoryMappedFile` and `ZoneInfoDB` came in through a fallback that never
  runs. Splitting them into `ATLZoneInfoDb` is the fix. **The general rule:
  guarding a call is not enough, the class it names has to move.**
- **`ClassNotFoundException: android.window.OnBackInvokedCallback` → the port
  installs `hax.jar`, not `hax-stripped.jar` (`build-atlas.sh`).** The stripped
  jar exists because ART rejects an app's oat file when a class is defined in
  both the framework and the app's dex. A JVM class path has no such check, and
  nothing in `out/classpath/` defines the three dropped stubs — checked, not
  assumed. `build-atlas.sh` now fails if the installed jar lacks them.
- **`NoSuchMethodError: OvershootInterpolator.<init>()`, and
  `StrictMode$VmPolicy$Builder.<init>(VmPolicy)` from `LaunchActivity.onCreate`
  → atlas *api-impl: add the constructors apps call*.** The second one aborted
  `onCreate` halfway, which is what produced the flood of
  "FragmentManager has not been attached to a host" afterwards. **Read the first
  exception, not the loudest.**
- **`NoSuchMethodError: ConnectivityManager$NetworkCallback.<init>()` and
  `NetworkRequest$Builder.<init>()` → atlas *api-impl: make the nested classes
  apps instantiate static*.** Inner classes where the SDK has static ones: the
  app's bytecode calls a no-arg constructor that does not exist. Worth grepping
  for more (`grep -n '^\tpublic class ' api-impl/**`) — most of the rest are in
  interfaces, where nested classes are implicitly static anyway.
- **`NoClassDefFoundError` for `AccessibilityRecord`, `AccessibilityEvent`,
  `AudioDeviceCallback`, `Notification$CallStyle`, `KeyPermanentlyInvalidated‐
  Exception`, `BackupHelper`, `RecordingCanvas`, `RenderNode`, `RenderEffect`,
  `RuntimeShader`, `SurfaceTexture` → four atlas commits adding them.** None of
  these run: they are field types, catch clauses and API-29+ paths behind
  `SDK_INT` checks. They still have to exist, because a class is loaded when a
  method mentioning it is verified — or, for `SurfaceTexture`, when
  `View.overridesOnDraw` reflects over the app's view classes.
- **`org.json` is in the shim, and it is on the boot path.** The shim audit deferred it;
  `LaunchActivity.getClientNotActivatedFragment` settles the question. It is
  ART boot-classpath, JDK-absent, so it belongs in the shim by the same rule as
  `libcore.*` — written out (six classes, `shim/src/org/json/`) rather than
  taking a jar, so the port keeps building offline. `ShimCheck` covers a parse →
  read → build → `toString` → re-parse round trip.
- **Ganesh (GPU) rendering crashes; the port runs on CPU raster.** The first
  draw calls `atl_gpu_context_create` → `GrGLMakeAssembledInterface` →
  `GrGLExtensions::init`, which segfaults on a bogus pointer (`-800`) coming
  back from a GL extension-string call, on llvmpipe under Xvfb *and* on hardware
  GL — so it is not the runtime and not the headless setup. `run.sh` exports
  `ATL_NO_GPU=1` (PRD Technical Considerations allow it for this milestone);
  `run.sh --gpu` reproduces the crash. This is atlas GPU-path work carried on
  the branch as WIP, not something HotSpot causes.
- **Known cosmetic gap at this milestone:** the intro page renders its title and
  text hard against the right edge and the animated Telegram logo does not
  appear. The screen is up and idles cleanly for 70s, which is what the boot asks
  for; layout/rlottie work belongs with the later UI stories.
- **The launcher exits on the first boot exception now** (atlas *hotspot
  launcher: stop the boot on the first exception*). It used to keep going and
  die in `jni_GetObjectClass` on a null application object, burying the real
  error. It also prints `boot: <step>` lines, which is what `run.sh` greps for.
- **Kill the launcher for real.** A timed run that only sends SIGTERM can leave
  the process alive, and the next `build-atlas.sh` then fails with "Text file
  busy" when it installs the launcher binary. `run.sh` follows up with SIGKILL.

## MTProto connectivity

- **MTProto needed no fixes.** tgnet's glibc build talks to Telegram exactly as
  the Android one does: `ConnectionsManager` starts its native network thread
  from `ApplicationLoader.onCreate`, the dc2 handshake completes ~6s after the
  login screen, `help.getConfig` comes back with the DC list, and the
  connections then sit on `ping_delay_disconnect`/`pong`. BoringSSL, epoll and
  the JNI callbacks all work as built by the BoringSSL and libtmessages builds.
- **`APP_ID=0` is the real limit, not the port.** The port builds with the dummy
  `./API_KEYS`, so every request carrying `initConnection` comes back
  `400 CONNECTION_API_ID_INVALID` — `help.getNearestDc`, `help.getCountriesList`
  and `auth.sendCode` alike. That is a full round trip (request serialised,
  encrypted, sent, error decoded and delivered to the Java callback in 40ms),
  which is what the MTProto check accepts, but no login is possible until real
  `APP_ID`/`APP_HASH` are exported and `build-classpath.sh` re-run. **The chat-list check
  cannot work without them**: a transplanted session would still fail on every
  request.
- **UI driving works with plain `xdotool`.** atlas maps GLFW mouse and key
  callbacks onto `ViewRootImpl.dispatchTouchEvent`/`dispatchKeyEvent`, so
  `xdotool mousemove/click/type` against the Xvfb display reaches the app.
  Typing `15551234567` into the phone screen filled the country code, picked
  "United States" from it and typed the rest into the number field, and the
  whole intro → phone → confirm dialog → sendCode path ran with zero uncaught
  exceptions. `check-mtproto.sh` is that sequence.
- **`run.sh` was orphaning a launcher on every timed run.** `run_launcher >log &`
  backgrounds a *subshell*, so `$!` was the subshell's pid: the SIGTERM and the
  SIGKILL after it both hit the wrapper while the launcher kept running, kept
  its X connection, and only died when something else killed the Xvfb — which is
  where the `X connection to :90 broken` and `double free or corruption` lines at
  the end of old logs came from. Fixed by `exec`ing the launcher in the
  function; a timed run now leaves nothing behind and the log ends clean.
- **The launcher does not stop on SIGTERM** (unresolved, and now visible because
  the signal reaches it). It survives ≥10s, so `run.sh` falls back to SIGKILL
  and accepts exit 137. `jstack` cannot attach to it (the JVM is created through
  the invocation API), so the hung shutdown path was not identified. Worth an
  atlas fix before the chat-list check, where a SIGKILL means the SQLite cache is never
  closed cleanly.

## Chat list with an existing session

- **The session transplant is a plain copy.** Both runtimes are atlas, so the
  data directory has the same shape on both sides and nothing had to be
  converted:

  | | path |
  |---|---|
  | source (ART/ATL desktop) | `~/.local/share/android_translation_layer/mercurygram-x64.apk_` |
  | destination (this port) | `linux-port/out/data/app.apk_` |

  The destination is `$ANDROID_APP_DATA_DIR/<apk basename>_`, which atlas's
  `make_app_data_dir()` appends — `out/data` alone is the base, not the data
  dir. `transplant-session.sh` copies with `rsync -a --delete
  --delete-excluded`, leaving out `lib/` (the ART build's Android `.so`s; the port
  loads the glibc one by path), `extracted_assets/` and the SQLite `-shm` files,
  which both sides rebuild. It stamps `.port-transplant` with the source and the
  date, because a plain first run creates the same files and there is otherwise
  no way to tell a session apart from an empty data dir.
- **Real API keys are a hard prerequisite, as the MTProto check warned.** They were
  recovered from the working ART build's APK rather than guessed:
  `dexdump -d classes.dex`, then read `BuildVars.<clinit>` — the `const v0`
  feeding `sput ... APP_ID:I` and the `const-string` feeding `APP_HASH`. The
  pair goes in `./API_KEYS` (gitignored); `build-classpath.sh` now rewrites that
  file when `APP_ID` is exported instead of keeping an existing dummy, and warns
  when it is building with `APP_ID=0`.
- **Sampled JPEG decoding segfaulted the JVM — a skia/libjpeg-turbo mismatch,
  fixed in atlas.** Every avatar in the chat list took the
  `ImageLoader$CacheOutTask` → `BitmapFactory.decodeStream` path with
  `inSampleSize = 2`, and the process died in
  `jpeg_calc_output_dimensions+0x33`:

  ```
  C  [libjpeg.so.62+0x45153]  jpeg_calc_output_dimensions+0x33
  J  android.graphics.BitmapFactory.nativeDecodeStream
  j  org.telegram.messenger.ImageLoader$CacheOutTask.run()V
  ```

  `SkJpegCodec::onGetScaledDimensions()` calls that function on a *zeroed*
  `jpeg_decompress_struct` to have libjpeg do the arithmetic. libjpeg-turbo 3.x
  (Debian's `libjpeg62-turbo` 3.1.3, `libjpeg.so.62.4.0`) starts it with
  `mov 0x220(%rbx),%rax; mov 0x14(%rax),%r12d` — `cinfo->master->lossless`,
  added for lossless JPEG — so it reads through a NULL `master`. Skia's own
  copy is the 2.x fork without that field, so the fix is one gn arg:
  `skia_use_system_libjpeg_turbo=false` (atlas `1f8ff0f6 skia: build against the
  bundled libjpeg-turbo`). This never showed on the device because Ubuntu Touch
  ships libjpeg-turbo 2.x.
- **A skia build option only reaches the build if the packagefiles are
  re-copied.** meson copies `subprojects/packagefiles/skia/` into the checkout
  once, when it extracts the wrap, and the port's `subprojects/skia` is the
  shared checkout that was extracted long ago — so an atlas commit to
  `packagefiles/skia/meson.build` changed nothing until `build-atlas.sh` started
  copying those files over on every run.
- **`liblog` was hiding the app's own log.** AOSP's liblog drops anything below
  `INFO` unless `ANDROID_LOG_TAGS` says otherwise, and `FileLog.d` is exactly
  where Telegram says what it is doing. `run.sh` now exports
  `ANDROID_LOG_TAGS=*:V`, so `out/run.log` is the whole picture instead of
  tgnet's native lines plus a separate `files/logs/*.txt` to correlate by hand.
  `loaded folderId 0 loadType 1 count 129` (`DIALOGS_LOAD_TYPE_CACHE`) is what
  `check-chatlist.sh` waits for.
- **The whole app died on the first SVG it parsed, and the corpse stayed on
  screen.** A freshly transplanted session froze a few seconds into its update
  catch-up: no repaints, no input, 0% CPU, `getDifference` never finishing. gdb
  showed why — a thread inside `JVM_Halt` → `vm_exit`, waiting for a safepoint
  that never comes, i.e. the JVM was *exiting*, not busy. The chain is:

  1. `SvgHelper.getDrawable(R.raw.topic_bubble)` returns a drawable with **zero
     commands**, so `ForumBubbleDrawable`'s `copyCommandFromPosition(0)` throws
     `IndexOutOfBoundsException` (a forum topic in the update stream is enough).
  2. `BuildVars`' default uncaught-exception handler calls `FileLog.fatal`,
     which on a `DEBUG_PRIVATE_VERSION` build — which the port's
     `afatFdX86_64Debug` is — calls `System.exit(2)`.
  3. atlas's hotspot launcher never returns from the GLib loop, so the exit
     hangs (the same "does not stop on SIGTERM" symptom the MTProto check saw) and the dead
     JVM keeps its window up.

  The empty drawable is the actual bug, and it is a JDK/libcore difference:
  `SvgHelper`'s handler switches on SAX's `localName`, and **Xerces leaves
  `localName` empty unless the factory is namespace-aware**, while libcore's
  Expat parser always fills it. Every SVG the app parses was silently becoming
  an empty drawable. Fixed in the shim with
  `org.apache.harmony.xml.parsers.SAXParserFactoryImpl` — the class ART installs
  as the JAXP default — registered through
  `META-INF/services/javax.xml.parsers.SAXParserFactory` in `shim.jar`, so
  `SAXParserFactory.newInstance()` picks it up exactly as it does on ART. With
  it, a cold transplanted session catches up in seconds and the chat list
  scrolls on the first try; without it the check ran for 10 minutes and never
  got a frame.
- **Scrolling is a drag, not a wheel.** atlas installs GLFW cursor and mouse
  button callbacks but no scroll callback, so `xdotool click 4/5` does nothing;
  `mousedown` + stepped `mousemove` + `mouseup` is a fling the way a finger
  makes one. The check requires the window's screenshot to change across the
  drags, since a frozen UI would otherwise pass silently.
- **Known, not fixed** (none of it blocks the acceptance path, Non-Goals):
  - `KeyGenParameterSpec cannot be cast to AlgorithmParameterSpec` —
    atlas's stub does not implement the JCA interface, so UnifiedPush
    registration fails on start. One-line atlas fix when notifications matter.
  - `ClassNotFoundException: android.widget.Editor` /
    `android.view.View$AttachInfo`, dozens of times: the app reflects into
    hidden framework internals (`EditTextBoldCursor.init`,
    `LinkSpanDrawable$LinksTextView.invalidate`) and catches the failure.
  - `getSystemService: case >batterymanager< is not implemented` (32×).

## Send and receive text messages

- **Opening a chat drew nothing, and one missing stub was why.** Saved Messages
  opened with its 50 messages loaded from `cache4.db` and its action bar in
  place, but the message list was empty wallpaper. Every frame died on:

  ```
  Exception in thread "main" java.lang.NoClassDefFoundError: android/view/ViewStructure
      at java.base/java.lang.Class.getDeclaredMethods0(Native Method)
      at android.view.View.overridesOnDraw(View.java:1283)
      at android.view.View.updateDisplayListIfDirty(View.java:1300)
      at org.telegram.ui.Cells.ChatMessageCell.draw(ChatMessageCell.java:20050)
  ```

  atlas asks each view whether it overrides `onDraw` before recording it, and
  `getDeclaredMethod` makes the runtime resolve the parameter and return types
  of *every* declared method of that class. `ChatMessageCell` declares
  `onProvideStructure(ViewStructure)` — for the assist API, which nothing on
  this platform ever calls — so a class that is never used broke the drawing of
  the class that is. Fixed in atlas (`a08f4ce0 api-impl: add the classes view
  signatures name`): `ViewStructure`, `DragEvent`, `TextClassifier` and
  `WebView.FindListener`, all stubs.
- **The same trap is now checked at build time.** `tools/ViewSignatureCheck.java`
  loads every class in `out/classpath/`, keeps the `android.view.View`
  subclasses (2757 of them) and calls `getDeclaredMethods()` on each — exactly
  what atlas does before a draw. `build-atlas.sh` runs it next to
  `PortClassCheck` and fails the build on a hit, so this class of bug cannot
  come back silently in the emoji check. It also reports, without failing, views that do
  not verify at all: `AIEditorAlert$Tabs` is one, because atlas's
  `android.widget.ScrollView` extends `ViewGroup` where the SDK's extends
  `FrameLayout`. Not on this story's path, so left alone (Non-Goals).
- **Saved Messages is the only chat the check may write to**, and it proves that
  before typing rather than after: `check-messages.sh` reads the account's own
  user id out of the log (`getSharedPreferences(ringtones_pref_<id>)`, which
  `MediaDataController` asks for at startup), requires the overflow menu to
  visibly open before clicking its third item, and then waits for
  `MessageLoaderLogger dialogId=<self>` before it types a character. A click
  that lands on the dialog list instead would open somebody's chat; the script
  goes back and retries, and gives up without sending anything.
- **What the round trip looks like in `run.log`:**

  ```
  send message user_id = 0 chat_id = 0 channel_id = 0    <- inputPeerSelf
  send request ...TL_messages_sendMessage with token = 50
  process update TL_updateMessageID
  ```

  `updateMessageID` is the ack the story asks for: it is what replaces the
  local negative id with the server's, i.e. the clock turning into a check
  mark. The text itself is never in the log, and neither is the server's
  numeric id: both only ever appeared in the TL dumper's JSON (`req ->` /
  `res -> TL_updates : {"updates":[{"..._":"...TL_updateMessageID","id":222004`),
  which the port turns off by default. `run.sh --tl-dump` brings that JSON back.
- **The incoming half rides on the account's own traffic.** A self-send does
  *not* come back through the update loop: the server answers the RPC with the
  updates and the app applies that `pts` itself, so a later push for the same
  message is dropped. A deterministic incoming message would need a second
  client on the account (the ART/ATL desktop build is one, but running both at
  once on one auth key is its own experiment). What the check requires instead
  is a real `updateNewMessage`/`updateNewChannelMessage` processed while the app
  keeps running, plus the dialog list visibly redrawing because of it. On this
  account that arrives within seconds; `--incoming-seconds` (default 300) is the
  bound.
- **A failed check used to leave the app running.** `pkill -f` sends SIGTERM,
  which this launcher ignores, so every aborted run left an instance
  talking to the account — and the next `build-atlas.sh` failed with `Text file
  busy` on the launcher binary. `check-messages.sh` kills with `-9`.

## Emoji panel

- **The panel opened and the grid was empty.** The emoji button worked, the
  sections drew ("Trending Emoji Packs", "Recently Used", "Emoji & People"),
  the rows had the right height — and not one glyph appeared. No exception
  anywhere in `run.log`, and only five `assets/emoji/*.png` reads in the whole
  run (the trending-pack previews, which go through `ImageReceiver`, not
  through this path).
- **The cause was in atlas's `ImageView.onDraw`**, which skipped any drawable
  whose intrinsic size is unset:

  ```java
  int contentWidth = contentWidth();   // max(0, drawable.getIntrinsicWidth())
  if (innerWidth <= 0 || innerHeight <= 0 || contentWidth <= 0 || contentHeight <= 0)
      return;
  ```

  `Drawable.getIntrinsicWidth()` is -1 unless a subclass overrides it, and
  `Emoji.SimpleEmojiDrawable` does not: it draws whatever `getBounds()` says.
  AOSP's `ImageView.configureBounds()` treats that case as "stretch over the
  whole view and ignore the scale type", so on Android the cell's own size is
  what the emoji is drawn at. atlas returned instead, which is why nothing was
  painted and why `SimpleEmojiDrawable.draw` never ran to ask for its sprite.
  Fixed in atlas (`api-impl: draw drawables that have no intrinsic size`).
  Every `ImageView` holding a bounds-driven drawable was affected, not only the
  emoji grid.
- **`setImageResource(0)` killed the app while the panel was open**, but only
  when the sticker requests came back during the run — `Resources$NotFoundException:
  Resource ID #0x0` out of `StickerCategoriesListView$CategoryButton.set`, which
  calls `setImageResource(0)` on purpose to clear the icon of a remote category
  before fetching it. AOSP treats id 0 as "no image" (`resolveUri()` returns
  early); atlas went straight to `BitmapFactory.decodeResource` and threw, and
  an uncaught exception in this build is `System.exit(2)`. Fixed in atlas
  (`api-impl: let setImageResource(0) clear the image`). Worth remembering that
  a network answer, not a click, is what surfaced it: the first run of the same
  check passed without ever touching that code.
- **The absence of asset reads was the useful clue.** `Emoji.loadEmoji` is
  called from `SimpleEmojiDrawable.draw` itself, so "the grid drew but the
  sprites are missing" and "the grid never drew" look identical on screen and
  differ completely in the log: atlas logs every `AssetManager_openAsset`, and
  `assets/emoji/<page>_<index>.png` reads only happen when a glyph is actually
  being painted. `check-emoji.sh` uses that as its evidence that the sprite
  sheets render (111 distinct glyphs on the first screenful).
- **The panel is as tall as a phone keyboard**, which on a 960x540 window means
  it covers the chat entirely: the message list is pushed off the top and only
  the input row stays visible. That is the layout being asked for, not a port
  bug — the popup height comes from the saved keyboard height. `check-emoji.sh`
  therefore closes the panel again (the emoji button is at the top of the window
  in that layout) before it looks at the input field or sends, and falls back to
  sending from the panel layout if the close does not take.
- **The sent text is read out of `cache4.db`, not off a screenshot** — a
  screenshot cannot tell an emoji from a placeholder circle. The check types
  `mg-us014-<timestamp>`, taps a glyph and then requires the marker to be
  followed by a non-ASCII character in the stored `TLRPC.Message` blob. The row
  is normally still in `cache4.db-wal` when the app exits, so both files have to
  be searched; and GNU grep in a UTF-8 locale will not find an ASCII pattern in
  a file with invalid UTF-8 around it, so this is done in Python on bytes.

## One-command build

- **`build-all.sh` is the build order written down**, from a bare checkout to a
  runnable app: submodule init and the atlas clone, the four native
  dependencies, `libtmessages.so`, the app class path, atlas (framework and
  launcher), the shim, then the checks. `--from`/`--only` resume a failed run,
  `--clean` rebuilds everything. Clean run 416s on 12 cores (Gradle 178s, atlas
  111s including skia), incremental re-run 57s.
- **The framework and the shim need each other**, which is the one ordering
  problem worth recording. `build-shim.sh` compiles against
  `out/atlas/api-impl.jar`, so atlas has to be built first; but
  `build-atlas.sh`'s app class checks (`PortClassCheck`, `ViewSignatureCheck`)
  load app classes whose signatures name `org.json`, which lives in the shim —
  without `out/shim.jar` the check reports ten views as broken. It is a
  bootstrap, not a cycle: `build-atlas.sh` now skips those two checks while the
  shim is missing and says so, and `build-all.sh`'s last step re-runs it (an
  incremental no-op for the build itself) once the shim exists. Proven by
  deleting `out/shim.jar` and running `build-all.sh --from atlas`.
- **`check-env.sh` no longer fails when `subprojects/skia` is missing.** Sharing
  the ~8 GB tree is an optimisation on this machine; a fresh clone has no tree
  to share and meson downloads the wrap, so the missing symlink is a note.
- The atlas branch `mercurygram/openjdk-port` is pushed to atl-touch
  (`git@github.com:NotKit/atl-touch.git`), 19 commits on top of the desktop
  work, ending at `8f8cb36e`. `linux-port/README.md` records that commit, and
  `build-all.sh` clones from there when `linux-port/atlas` is missing.
- **GraalVM tracing agent**: the launcher already forwards `-X "OPTION"` to the
  JVM (`--extra-jvm-option`), so `run.sh -- -X "-agentlib:native-image-agent=…"`
  is all the next phase needs — with `JAVA_HOME` pointing at a GraalVM 21, since
  the agent ships with GraalVM and `env.sh` accepts any 21.x. Switching JDKs
  re-stamps the atlas builddir and costs a skia rebuild.

## Visual bugs the running app showed

- **Every centred `TextView` drew its text flush right** — the labels under the
  main tab icons (Chats, Contacts, Settings, Profile) and the name and
  phone/username under the avatar in Settings, all of which are plain
  `TextView`s with `Gravity.CENTER` and `MATCH_PARENT` width. Nothing to do with
  RTL, which is what it looks like: `StaticLayout.getParagraphDirection(0)` is
  `+1` for those strings and the shim's `android.icu.text.Bidi` over
  `java.text.Bidi` reports the paragraph level correctly.
- **The gravity was applied twice.** atlas's `TextView.onDraw` translates the
  canvas by `getLayoutOffsetX()`, which offsets by the horizontal gravity
  against the *text's* measured width; the layout it then draws was built with
  `getLayoutAlignment()`, which derives `ALIGN_CENTER`/`ALIGN_RIGHT` from the
  same gravity. For "Chats" in a 300px layout the alignment already puts line 0
  at 107px, and the offset added another 107. Fixed in atlas (`api-impl: stop
  TextView applying its gravity twice`) by offsetting by the layout's width,
  which is 0 unless the layout is narrower than the view — the case the offset
  exists for, since the layout is built during measure and never rebuilt on
  resize.
- **It appeared with the desktop changes this port started from** (`fa0be5ad`),
  which made `View.getTextAlignment()` return `TEXT_ALIGNMENT_GRAVITY` instead
  of a constant 0. Until then every layout came out `ALIGN_NORMAL` and the
  offset in `onDraw` was the only thing placing text, so upstream ATL never drew
  it twice. Worth remembering when comparing this port against ATL: a bug that
  is "not in ATL" can still be atlas's, in code the port is the first to reach.
- **Black bands around the action bar and the message input bar.** In a chat
  the wallpaper stopped at the action bar and again above the input bar, and the
  gaps around both islands were pure black (19 black rows in a column through
  the window; none after the fix). The same drawables fade the profile header.
- **`ComposeShader` was an empty stub in atlas**, so its `native_instance`
  stayed 0, `Paint.getNativeInstance()` passed 0 to `nSetShader` and skia drew
  with the paint's own colour — an unset `Paint` is opaque black. Telegram's
  `blur3` fade (`BlurredBackgroundWithFadeDrawable`) composes the wallpaper's
  `BitmapShader` with a `LinearGradient` alpha mask through
  `ComposeShader(..., DST_IN)`, so every fade became a black rect. Fixed in
  atlas (`graphics: back ComposeShader with skia's blend shader`) with
  `SkShaders::Blend`, whose (mode, dst, src) argument order is exactly
  ComposeShader's A-is-dst/B-is-src contract.
- **A compose shader cannot be built once and cached.** Callers set the
  *children's* local matrices after composing them (the fade sets the gradient's
  matrix per draw to place the fade), so `ATLShader::effective()` rebuilds the
  blend from its children each time it is asked. `Paint` already re-reads
  `effective()` on every draw for exactly this reason.
- `ComposeShader` is used in six more places in the app (`ImageReceiver`,
  `MotionBackgroundDrawable`, `MotionBackgroundPaint` — which nests it three
  deep — and `LoadingStickerDrawable`), all with `DST_IN` gradient masks, so
  more than the fades were flat black before this.

## Ubuntu Touch click (arm64 cross build)

`linux-port/click/` packages the port for Ubuntu Touch 24.04 arm64. What the
cross build turned up, in the order it hit:

- **The port cross-compiles because it does not need ART.** The sibling ART
  packaging has to build natively under qemu (`art_standalone` has no cross
  build); this port only needs `libandroidfw` and `liblog` *prebuilt* out of that
  tree, so everything else is built by the host toolchain against the arm64
  sysroot in clickable's cross container. Minutes instead of hours.
- **`libart.so` is not shipped and not even linked.** `art-standalone.pc` puts
  `-lart -lnativebridge` on the link line, but nothing in this port calls into
  either — the framework's only ART-side `DT_NEEDED` are `libandroidfw` and
  `liblog`. An empty `.so` of each satisfies the linker, `--as-needed` drops it,
  and 240 MB of ART stays out of the click.
- **atlas's meson resolves `dx` at configure time** (the `api-impl.jar` and
  `test_runner.jar` custom targets dex with it) even when nothing asks for those
  targets. `dx` is a shell wrapper around `dx.jar`, so the click stages both
  rather than patching atlas; it looks for the jar in `../framework` relative to
  its own `bin/` first.
- **meson's cross-file binary key for the Java compiler is `java`, and it must
  point at `javac`.** A `javac = ...` key is silently ignored, and the build then
  fails with `ERROR: Unknown compiler: .../bin/java`.
- **meson ignores `CFLAGS`, `LDFLAGS` and `LIBRARY_PATH` for the host machine of
  a cross build.** A staged prefix has to reach `cc.find_library()` through the
  cross file's `[built-in options] c_args`/`c_link_args` instead — that is what
  `PORT_CROSS_LIB_DIRS` in `native/write-meson-cross.sh` exists for.
- **`[properties] java_home` is how the `jni` dependency is pointed at the target
  JDK.** Without it meson takes the JDK that owns the `javac` in `PATH`, i.e. the
  host's, and the launcher would try to link an x86-64 `libjvm.so`.
- **skia's public headers reach into `modules/`** (`SkColorSpace.h` includes
  `modules/skcms/skcms.h`), so a prebuilt-skia build needs `include/` *and*
  `modules/`, not just `include/`.
- **git is unavailable inside the build container.** `linux-port/atlas` is a
  worktree whose `.git` file points outside the mounted repository, so
  `build-atlas.sh` now degrades to "no working-tree check, revision unknown"
  instead of failing.
- **What Ubuntu Touch 24.04 does not ship, from the device's own `ldconfig -p`:**
  GLFW, `libportal.so.1`, `libswscale.so.7` (though `libavcodec.so.60` is
  there), `libmaliit-glib.so.*` and `libcontent-hub-glib.so.1`. All are
  `DT_NEEDED` of `libtranslation_layer_main.so`, so the click carries them and
  `build.sh` fails the build if a needed library is neither on the device (per
  the recorded `click/device-libs.txt`) nor in the container. `libGL.so.1` *is*
  on the device, which the framework also needs.
- **The prebuilt `libskia.so` is the one known behavioural compromise.** It comes
  from the ART packaging's build of atlas master, i.e. with
  `skia_use_system_libjpeg_turbo=true`; the port's atlas branch sets it to false
  because libjpeg-turbo 3.x segfaults on any sampled JPEG decode (see "Native
  dependencies" above). Cross-building skia with the port's own gn args is the
  fix; until then thumbnails are expected to crash on the device.

### First run on the device (OnePlus 11, Ubuntu Touch 24.04.4)

- **`"policy_version": 20.04` is rejected on 24.04.** `aa-clickhook` skips the
  profile with `ERROR: Invalid policy version`, no profile is generated, and
  `lomiri-app-launch` then dies in `aa-exec: ERROR: profile '<appid>' does not
  exist` before the app runs at all. `2404.1` is the version this release
  accepts (`/usr/share/apparmor/easyprof/policygroups/ubuntu/`). The sibling ART
  packaging still says 20.04 and has the same bug — its profile on this device is
  a leftover from an older release.
- **Lomiri starts a click app with `XDG_RUNTIME_DIR=$HOME/.cache` and
  `WAYLAND_DISPLAY=wayland-0`,** and the compositor's socket is in neither: it is
  `/run/user/<uid>/wayland-0`. GLFW resolves the display relative to
  `XDG_RUNTIME_DIR` and aborts the launch with "Wayland: Failed to connect to
  display". `click/run.sh` points `WAYLAND_DISPLAY` at the absolute socket path
  (libwayland accepts one) instead of moving `XDG_RUNTIME_DIR`, which the app
  uses for its own storage.
- **Debian's JDK is a tree of symlinks into `/etc/java-21-openjdk`**
  (`conf/*.properties`, `conf/security/`, `lib/jvm.cfg`, cacerts). Copied as
  symlinks into a click they all dangle, and the JVM dies the first time
  anything touches a security provider — which `java.util.jar`'s signature
  verifier does while atlas parses the apk:
  `InternalError: Error loading java.security file`. `rsync --copy-unsafe-links`
  is what makes the bundled runtime self-contained.
- **`libportshim.so` has to be built for the target too.** With only the host's
  copy in the tree the app logs "port-shim: libportshim.so is not loaded …
  native peers will leak" and runs on regardless, which is exactly the kind of
  failure that would have been missed without reading the log.
- **The GPU path works on the device**, unlike on the desktop: atlas reports
  `GPU rendering (Ganesh) on Adreno (TM) 740, OpenGL ES 3.2`. GLFW still logs
  `EGL: Failed to find support for OpenGL` first — it probes desktop GL before
  falling back to GLES — which is noise, not an error.
- The two exceptions the device log shows (`ClassNotFoundException:
  android.view.View$AttachInfo` from `WindowInsetsCompat`, and
  `KeyGenParameterSpec cannot be cast to AlgorithmParameterSpec`) both appear in
  the x86_64 run log too: pre-existing framework gaps, not arm64 regressions.
- **GCC acts on UB the NDK's clang let pass, and it killed the app five seconds
  into every launch.** `ConnectionsManager::failNotRunningRequest`'s
  `scheduleTask` lambda ended its match branch with `return true;`, so its return
  type deduced to `bool` and falling off the loop became UB. GCC 13.3 concluded
  the loop can only leave through the match, dropped the
  `iter != requestsQueue.end()` test, and walked into the list sentinel —
  `SIGSEGV` at `si_addr 0x16` in `checkPendingTasks`. `FileLoadOperation:818`
  cancels tokens of *running* requests, which are never in `requestsQueue`, so
  the first avatar load always hit it. Fixed as `return;` in
  `TMessagesProj/jni/tgnet/ConnectionsManager.cpp` — an upstream bug, not a
  compat gap, so it is the rare jni/ edit FR-7 does not cover; it belongs
  upstream rather than in `port_compat.hpp`. Worth assuming there are more:
  nothing in the port's flags warns about it, and only `-O2` GCC exposes it.

## Attaching files through content-hub

A confined UT app cannot read `$HOME` and has no media store to enumerate, so
Telegram's gallery grid and file browser are both empty on the device. The
attach sheet now lists the apps content-hub says can supply the content and
takes what they hand back, the way Lomiri's own picker does.

- **The whole feature is behind `-Dtmessages.contenthub=1`**, set only by
  `click/run.sh`. Without it `ContentHub.isEnabled()` is false, no reflection
  happens, and the Android build takes its usual paths — the same escape-hatch
  shape as `tmessages.native.path`.
- **The app talks to `android.atl.ATLContentHub` by reflection.** It is a
  framework class the Android SDK does not have, so naming it directly would not
  compile; `org/telegram/messenger/ContentHub.java` resolves it once and caches
  the three methods.
- **The natives are device-only, and that is a runtime fact, not a build one.**
  atlas compiles `android_atl_ATLContentHub.c` only where content-hub-glib
  exists, so on the desktop the class loads but its methods do not bind. The
  first `UnsatisfiedLinkError` turns `isEnabled()` off for good and the sheet
  falls back to the photo and document layouts, which is what makes running the
  desktop port with the property set harmless.
- **Imported media joins `cameraPhotos`, not an album.** The files are in no
  media store, and `cameraPhotos` is the list the photo grid already keeps for
  photos the app itself produced — so selection, captions, quality and sending
  all work unchanged. `clearSelectedPhotos()` deletes those files, so
  `onShow` must skip it when the previous layout was the content-hub one.
- **`MediaController.loadGalleryPhotosAlbums` returns early with the property
  set.** Otherwise every attach-sheet open would query the media store, and
  atlas's `ATLMediaContentProvider` answers such a query by popping its own
  source picker — two pickers for one tap.
- **`showLayout` no-ops on the layout that is already current.** One layout
  serves both the Gallery and the File tab, so switching tabs has to reload it
  and move the type-button highlight itself.
- **The count button reads `currentAttachLayout`, which the animated switch only
  assigns when the spring lands.** Handing over imported files therefore uses
  the un-animated `showLayout`, or the send button stays at zero.
- **`androidx.exifinterface` names `android.media.MediaDataSource`**, which
  atlas did not have: `AndroidUtilities.getImageOrientation` died with
  `NoClassDefFoundError` the first time an imported photo went through it. Fixed
  as a declaration-only stub in atlas. A pre-existing gap — the external-camera
  path would have hit it too, if the port could reach one.
- **`copyLinuxPortRJar` declared no inputs**, so Gradle called it up-to-date
  forever and a new string never reached `mercurygram-res.jar`: the app compiled
  and then died with `NoSuchFieldError` on `R$string`. It now takes the
  resource-processing output as an input.
- **Voice recording needs the microphone gate, not just the camera one.** atlas
  answers `checkPermission(RECORD_AUDIO)` with `DENIED` unless
  `ATL_UGLY_ENABLE_MICROPHONE` is set, so the app asked for a permission that
  nothing could grant. Both gates now live in `click/run.sh`.
- **Two atlas gaps sat behind that prompt, and the first one froze the app.**
  `MediaController.setBluetoothScoOn` called
  `AudioManager.isBluetoothScoAvailableOffCall()`, which did not exist:
  `NoSuchMethodError` → `FileLog.fatal` → `System.exit(2)`, i.e. the documented
  "UI froze" (dead JVM, window still up). The next frame would have died the
  same way on `AudioRecord.read(ByteBuffer, int)` — atlas had only the `short[]`
  overload. Both added in atlas; `adjustStreamVolume` went in beside them,
  because `getStreamVolume` always answers 0 and that is the branch
  `checkVolumeBarUI` then takes, outside any `catch (Exception)`.
- **Round video messages need a MediaCodec *encoder*, which atlas does not
  have.** `InstantCameraView` calls `MediaCodec.createEncoderByType` and feeds
  it `COLOR_FormatSurface`; atlas has `createByCodecName` and an ffmpeg
  *decode* backend only. Voice messages avoid this entirely — Telegram encodes
  those with its own opus code in `libtmessages.so`.
- **Every bottom sheet blacked out the window behind it.** With the attach sheet
  open the chat was not dimmed but gone: pure `(0,0,0)` everywhere outside the
  sheet card (`out/screenshots/grid-sheet.png`), rather than the 20% shade
  `dimBehindAlpha` asks for.
- **A panel is not a window in atlas.** `ViewRootImpl.performDraw` drew panels
  (Dialog, PopupWindow, `WindowManager.addView`) onto the same canvas as the
  activity decor, so a non-SrcOver paint inside a panel reached the pixels
  below. Telegram's `BottomSheet.SheetBackDrawable` is black in
  `PorterDuff.Mode.SRC`, which is right on AOSP — the dialog has its own
  transparent surface and the compositor blends it over the window — and wrote
  premultiplied `(0,0,0,51)` straight over the chat here. The present path
  blits without blending (`ATLCanvas.cpp` `kSrc`, `ATLWindow.c`'s textured
  quad), so the alpha was dropped and RGB 0 reached the screen. Fixed in atlas
  (`5755b11f`) with a `saveLayer` around each panel draw.
- `BottomSheet.makeAttached` switches that paint to `SRC_OVER` because an
  attached sheet draws inside the activity window. Under atlas *every* sheet is
  in that situation, which is the shape of this class of bug: an app path that
  is only correct because Android gave it a surface of its own.

## GraalVM native image

- **`GRAALVM_HOME` is a second JDK, never the port's.** `env.sh` exports it
  (default `/home/nekit/UT/graalvm-ce-21`, overridable) and never assigns it
  into `JAVA_HOME`, nor puts its `bin/` on `PATH`: meson caches the java
  compiler in coredata, so building atlas under GraalVM forces a
  `--reconfigure` and a skia rebuild. A traced run opts in per command with
  `JAVA_HOME=$GRAALVM_HOME`.
- The existing `JAVA_HOME` block keeps any 21.x it is given, and GraalVM CE
  21.0.2 reports `version "21.0.2"`, so that opt-in survives `env.sh`. Verified:
  `JAVA_HOME=$GRAALVM_HOME` in, `openjdk version "21.0.2" … GraalVM CE 21.0.2`
  out; with no `JAVA_HOME`, `env.sh` still picks the OpenJDK 21.0.11.
- `check-graalvm.sh` is the GraalVM twin of `check-env.sh`. Beyond the criteria
  it also checks `cc`/`ld`/`objcopy` and `zlib.h`, because `native-image` links
  the image with the system toolchain and a missing zlib only surfaces at the
  end of a long build.
- **It is not in `build-all.sh`.** Every *build* script is a step there, but
  GraalVM is not needed to build or run the HotSpot port, and a bare checkout
  without it must still build. The image scripts call it themselves.
- `native-image` and `native-image-configure` are in `$GRAALVM_HOME/bin`; the
  tracing agent is `$GRAALVM_HOME/lib/libnative-image-agent.so`, resolved by
  `-agentlib:native-image-agent` only when the running java *is* GraalVM's.

## GLUtils.getEGLErrorString

- **atlas's `GLUtils` had `texImage2D` and nothing else.** Every EGL error path
  in the app formats its message with `GLUtils.getEGLErrorString(...)`, so the
  *error handler* threw `NoSuchMethodError` — `FileLog.fatal` → `System.exit(2)`,
  the documented "UI froze". Added in atlas (`0f27bebd`) with AOSP's strings for
  the EGL10/EGL11 codes and AOSP's `"0x" + Integer.toHexString(error)` fallback.
- The symptom only shows without a session: `IntroActivity$EGLThread.initGL`
  runs on the intro screen, and `transplant-session.sh` had been hiding it
  because a logged-in boot never draws that screen. Same call sits all over
  `CameraView` and `InstantCameraView`.
- **atlas's `eglGetDisplay` answers `EGL_NO_DISPLAY` and leaves the error at
  `EGL_SUCCESS`**, so the intro now logs `eglGetDisplay failed EGL_SUCCESS` and
  gives up on its GL animation. The screen itself is fine — `finish()` there is
  `EGLThread`'s own teardown method, not `Activity.finish()` — so the intro
  draws, minus the animated logo (`out/screenshots/run.png`).
- Verified: `run.sh --fresh --seconds 120 --data-dir out/data-fresh` → "run ok",
  0 `NoSuchMethodError` in `out/run.log`, intro screen with "Start Messaging" in
  the screenshot; `check-mtproto.sh` → `TL_auth_sendCode` answered
  (420 FLOOD_WAIT_, a real server reply).
- Use a separate `--data-dir` for fresh runs. Plain `--fresh` wipes `out/data`,
  which is where the transplanted session lives.

## Complete metadata trace

- **`trace-metadata.sh` runs the four driving checks under the agent**, in the
  order `check-mtproto.sh`, `check-chatlist.sh`, `check-messages.sh`,
  `check-emoji.sh`, all merging into `out/ni-config` with
  `config-merge-dir`. mtproto goes first because it boots `run.sh --fresh` and
  wipes the data dir; the other three transplant the session back first.
- **`$PORT_EXTRA_JVM_ARGS` is how the agent gets in.** The checks call `run.sh`
  and do not forward its `-- ARGS`, so `run.sh` now splits that variable on
  whitespace and appends one `-X OPTION` per word (the launcher's
  `--extra-jvm-option` takes exactly one option per flag,
  `main-executable-hotspot/main.c:515`). Unset means zero extra words, so every
  existing caller is unaffected.
- **`JAVA_HOME=$GRAALVM_HOME` is exported by the script, once**, and survives the
  `env.sh` each check sources because that block keeps any 21.x it is given.
  Nothing is rebuilt under GraalVM.
- **The agent's write survives the way `run.sh` ends a timed run.** It only
  writes at VM shutdown, and `run.sh` ends with a signal, so this was worth
  proving: `PORT_EXTRA_JVM_ARGS="-agentlib:native-image-agent=config-output-dir=DIR
  -Dport.trace.probe=1" run.sh --seconds 90` → "run ok", both options in
  `out/run.log` as separate `jvm option:` lines, and a full six-file config in
  `DIR`. A check that is killed before it finishes still contributes nothing.
- Run to completion on 2026-08-10, all four green: mtproto 164 s, chatlist 54 s,
  messages 53 s, emoji 56 s (~5.5 min). Only mtproto pays its full `--seconds`
  (150) — it has no `--stop-file`, while the other three end as soon as they are
  done, which is why their bounds can be generous.

### Counts, boot-only baseline vs merged

The 2026-08-10 boot-only config is kept at `out/ni-config-baseline-boot/`;
`config-merge-dir` writes `out/ni-config` in place, so re-tracing from scratch
means restoring that copy first.

| | baseline (boot) | merged (4 checks) |
|---|---|---|
| `reflect-config.json` | 444 classes, 42022 B | **613 classes**, 62587 B |
| — `org.telegram.*` | 357 | 510 |
| — `allPublicFields` (all `tgnet`) | 304 | 366 |
| — everything else | 87 | 103 |
| `jni-config.json` | 61 classes, 13303 B | 62 classes, 13465 B |
| `resource-config.json` | 12 entries | 12 entries (byte-identical) |
| `proxy-config.json` | empty | empty |
| `serialization-config.json` | empty | empty |

Per check: 444 → 485 (mtproto) → 487 (chatlist) → 561 (messages) → 613 (emoji).
Nothing was ever removed (+169, −0).

- **The classes that prove the coverage** — none of these are in the boot-only
  baseline: login `LoginActivity$PhoneView`,
  `LoginActivity$PhoneNumberConfirmView`, `TLRPC$TL_auth_sendCode`,
  `TLRPC$TL_codeSettings`, `IntroActivity$IntroAdapter$1`; message send
  `ChatActivity$ChatActivityFragmentView`, `ChatActivityEnterView$SendButton`,
  `Cells.ChatMessageCell`, `TLRPC$TL_messages_sendMessage`; emoji
  `EmojiView$EmojiGridView`, `EmojiTabsStrip$EmojiTabButton`,
  `StickerCategoriesListView`, `TLRPC$TL_messages_getAllStickers`.
- **`resource-config.json` did not move at all.** Four driven paths, including
  the emoji panel reading hundreds of `assets/emoji/*.png`, and still the same 12
  entries: assets really do go through native libandroidfw by file path, not
  through the class loader. The apk change removes one call site, not a long list.
- **`proxy-config.json` and `serialization-config.json` are still empty** over a
  login, a chat list, a send/receive and the emoji panel — the PRD's boot-only
  claim holds for a whole session.
- `jni-config` grew by one class, `android.graphics.SurfaceTexture`, plus more
  members on `android.view.KeyEvent` (the checks type with `xdotool`). The JNI
  surface is essentially a boot-time constant.
- **The `TLRPC$*` `allPublicFields` bulge grows with coverage**: 304 → 366, i.e.
  60% of the merged config. It scales with how many TL types a session touches,
  which is the argument for removing the dumper rather than trimming
  metadata by hand.

### Two bugs this turned up

- **`transplant-session.sh` refused to run whenever *any* atlas app was alive.**
  Its guard was a bare `pgrep -f 'android-translation-layer'`, which matched an
  unrelated `atlas-camera2` test that had been up for five days, so all three
  session-based checks died on "stop it first". Narrowed to the two processes
  that can actually be writing either side of the copy — the port's own launcher
  and whatever atlas run owns the source apk — and each candidate is confirmed
  through `/proc/<pid>/exe`, because a shell whose command line merely names the
  launcher matches the pattern just as well (the trap CLAUDE.md warns about; the
  first fix walked straight into it and its own test shell matched).
- **`cmd | tee log || true` loses the exit status.** `||` runs another command,
  and `PIPESTATUS` then describes *that* command, so `trace-metadata.sh` read 0
  for three checks that had failed instantly and printed "trace complete". Use
  `set +e` around the pipeline and read `PIPESTATUS` before anything else runs.
  Verified after the fix: `ATLAS_OUT=/nonexistent trace-metadata.sh --only
  mtproto` → "trace incomplete: 1 check(s) failed", exit 1.

## Turning off the TL debug dumper

`FileLog.dumpResponseAndRequest` / `dumpUnparsedMessage` Gson-serialize every
MTProto request, response and unparsed update into the log. Gson reflects over
the public fields of whatever it is handed, so the dumper alone accounts for
almost the whole reflection surface an ahead-of-time image would have to
declare. The port switches it off with a `-D` property; nothing else changes.

- **The escape hatch is `-Dtmessages.tldump`** (`FileLog.java`, the same shape as
  `tmessages.native.path` and `tmessages.contenthub`): `0` or `false` disables,
  anything else — including *unset* — keeps dumping, so the Android build is
  unchanged without the flag. It is read once into a `static final boolean` and
  tested **first** in both guards, ahead of `BuildVars.DEBUG_PRIVATE_VERSION`, so
  `checkGson()` never runs and the `GsonBuilder`, the `TLObjectDeserializer` and
  the exclusion sets are never constructed. `run.sh` and `click/run.sh` pass
  `-X "-Dtmessages.tldump=0"`; `run.sh --tl-dump` opts back in.
- **The property must be read from the JVM, not guessed.** The value is decided
  in `FileLog`'s `<clinit>`, which runs long before `Application.onCreate`;
  `JNI_CreateJavaVM` installs `-D` options before any class loads, so it is
  correct here, but the only honest check is `grep -c '/MTProto' out/run.log`,
  never inspection. Measured over the same 90 s boot: **867 `MTProto` lines and
  6,150,122 B of `run.log` with the dumper on, 0 lines and 1,526,359 B with it
  off** — three quarters of the log was the dump.
- **What the trace lost.** Re-running the PRD's 2026-08-10 baseline command (a
  120 s chat-list boot on the transplanted session, GraalVM agent,
  `config-output-dir` into a *fresh* directory) against
  `out/ni-config-baseline-boot`:

  | file | baseline (dumper on) | after (dumper off) |
  | --- | --- | --- |
  | `reflect-config.json` | 444 classes, 42022 B | **134 classes, 13861 B** |
  | ... of which `allPublicFields` | 304 | **0** |
  | ... of which `org.telegram.*` | 357 | 55 |
  | `jni-config.json` | 61 classes | 60 classes |
  | `resource-config.json` | 12 entries | 10 entries |
  | `proxy-config` / `serialization-config` | empty | empty |

  310 classes removed, **none added**. 301 of the 310 are TL types; the other
  nine are Gson's own reflective plumbing (`java.lang.Class`,
  `java.lang.reflect.RecordComponent`, `java.util.ArrayList`, `java.sql.Date`,
  `org.telegram.tgnet.Vector`, `[Lorg.telegram.ui.Components.URLSpanNoUnderline;`,
  `android.graphics.Path`, `Path$Direction`, `Region`). The PRD's "~140" estimate
  was right. `META-INF/services/java.nio.charset.spi.CharsetProvider` also went,
  which is the JSON writer's charset lookup; the one `res/` entry
  (`drawable-mdpi-v4/notification.webp`) and `android.graphics.Paint$FontMetrics`
  are run-to-run variance, not attributable to this change. That "after" trace is
  kept beside the baseline at `out/ni-config-boot-us004/` (gitignored); both are
  boot-only, so compare them with each other and not with the four-check merge in
  `out/ni-config/`, which is still the one traced before the dumper came out.

### Deviation: the checks read the send back out of the dump

The third acceptance criterion says "no behaviour change in `check-chatlist.sh` /
`check-messages.sh`". `check-chatlist.sh` is genuinely untouched, but
`check-messages.sh` proved the send *out of the Gson JSON itself*, so switching
the dumper off necessarily changed it. Three call sites had to move to
dump-free signals:

- `check-messages.sh` and `check-emoji.sh` waited for the literal
  `"TL_updateMessageID"` — quoted, i.e. JSON only — and then for
  `process update TL_updateMessageID` right after. The first wait is deleted and
  the second gets its 60 s budget, so the total is unchanged. It is the stronger
  assertion anyway: it says the update *arrived and was applied*, not just that
  it was in a response body.
- `check-messages.sh` also extracted the server-assigned id
  (`grep -oE '"TL_updateMessageID"[^}]*"id":[0-9]+'`) and hard-failed on an empty
  one. **That number exists nowhere else in the log** —
  `MessagesStorage.updateMessageStateAndId` logs nothing,
  `SendMessagesHelper` never prints it, and `MessagesController` logs only
  `process update ` + the class simple name. The check now asserts the update was
  processed and its summary line no longer quotes an id. Getting the number back
  would need a second `org/telegram/**` edit, which FR-7 does not justify for a
  summary line.
- `check-mtproto.sh`'s success fallback was `grep -q 'TL_auth_sentCode'`, which
  only ever matched `res -> TL_auth_sentCode : {…}`. It is unreachable in
  practice — a test number always comes back as an error, so the error branch
  above it wins — but it was a landmine. Repointed at tgnet's own native line,
  `got response for request … TL_auth_sendCode`, the same shape the script
  already uses for `help.getConfig`.

All four checks pass with the dumper off: `check-chatlist.sh` (129 dialogs),
`check-messages.sh` (sent and echoed, incoming seen), `check-emoji.sh` (109
glyphs, emoji sent), `check-mtproto.sh` (`got error 420 FLOOD_WAIT_`), and
`run.sh --seconds 90` still reports "run ok".

`files/logs/<date>_mtproto.txt` is now header-only — `FileLog.init()` still
creates it, nothing writes to it. `run.sh` already excluded that file from its
`FATAL/tmessages` scan, so nothing broke; anyone debugging MTProto from it wants
`--tl-dump`.

**Still reflective, for the image build:** `it.belloworld.mercurygram.ui`
`MessageDetailsActivity` builds its own Gson over `TLObject` in `<clinit>`
(`RuntimeClassNameTypeAdapterFactory`, same as `FileLog`'s). It never shows up in
a trace — the screen is only reachable from a message context menu and no check
opens it — but static analysis will see it. If the image's reflective closure
blows up through that class, that is why; handle it at the image level, not with
another `FileLog` change.

## The manifest-component registry is not worth building

The registry idea asked atlas to generate a `name → constructor` table from the apk's
`AndroidManifest.xml` at build time and consult it before `Class.forName`, so
manifest components stop being runtime class names. It was not built. Both of
its measurable criteria rest on facts that do not hold, and the reflection site
that actually dominates the config is somewhere else in the same file.

### AC-1 is not implementable in atlas: there is no apk at build time

- The manifest is read **at runtime**, once, in
  `atlas/src/api-impl/android/content/Context.java:122-135`:
  `assets.openXmlResourceParser("AndroidManifest.xml")` →
  `new PackageParser(native_get_apk_path())`. `native_get_apk_path()` resolves
  the `apk_path` symbol the *launcher* exports.
- `atlas/meson.build` takes no apk input of any kind — its only `apk`
  occurrence is a comment at `:346` about `res/framework-res` — and
  `atlas/meson.options` declares exactly two options, `hotspot-launcher` and
  `skia-prebuilt`. The Java side is one `jar('hax', srcs)` over api-impl
  sources.
- That is by design: atlas is one framework for any apk, chosen at launch time
  by argv. A generator would have to live in `linux-port/`, over
  `TMessagesProj_App/build/intermediates/packaged_manifests/afatFdX86_64Debug/processAfatFdX86_64DebugManifestForPackage/AndroidManifest.xml`,
  which makes it a cross-repo codegen contract, not an atlas feature.

### AC-4's "54 `<init>` entries" is wrong, and the real yield is ~8 of 134

Counted over `out/ni-config-boot-us004/reflect-config.json`, the post-dumper
boot trace (134 classes):

| group | entries |
|---|---|
| `onDraw`-only, from `View.overridesOnDraw` | 40 (+1 `TextView` that also has fields) |
| `<init>` entries of any kind | 37 |
| — atlas-instantiated manifest components | 7 |
| — app-side `NotificationBadge$*Badger` | 12 |
| — JDK/security/androidx-startup plumbing | 18 |
| everything else | 56 |

The 7, plus one bare class entry, are what a registry could remove:
`ApplicationLoaderImpl` (Context:175),
`LaunchActivity` (Activity:76) and the five `<provider>` classes
(`ContentProvider.java:31`: `androidx.core.content.FileProvider`,
`androidx.startup.InitializationProvider`, `NotificationImageProvider`,
`voip.CallNotificationSoundProvider`, `ru.noties.jlatexmath.JLatexMathInitProvider`),
plus the bare `NotificationsService` class entry. The 12 `NotificationBadge`
ones come from the app's own `b.newInstance()` loop
(`TMessagesProj/src/main/java/org/telegram/messenger/NotificationBadge.java:543`
and `:565`) and no atlas change can touch them.

`grep -rn "Class\.forName" --include=*.java atlas/src/api-impl` finds **14**
sites, not 13 (three more are in `src/test-runner/`, which is
`build_by_default: false` and never built here). Three of the 14 are not
manifest-driven and are dead or swallowed: the `com.whatsapp.util.Log` hack
(`Context.java:186`), NewPipe's PoToken probe (`CookieManager.java:14`), and
`LayoutInflater.java:90`, which never fires because Telegram builds its UI in
code. Two of the manifest-driven ones want a `Class`, not an instance
(`Context.java:679`, `:769`), so a constructor table would not replace them.

### A complete registry would make the image bigger, not smaller

The merged manifest declares 69 components — 14 activity, 7 activity-alias, 22
service, 21 receiver, 5 provider — plus the application class. A generated
`switch (name) { … return new X(); }` makes every one of them an image root and
drags in its transitive closure: `voip.VoIPService`,
`voip.TelegramConnectionService`, `VoIPPermissionActivity`,
`VoIPFeedbackActivity`, `voip.VoIPMediaButtonReceiver`,
`voip.VoIPActionsReceiver` — the calls stack the PRD's Non-Goals exclude — and
`androidx.car.app.CarAppPermissionActivity`,
`androidx.car.app.CarAppMetadataHolderService`,
`androidx.car.app.notification.CarAppNotificationBroadcastReceiver`,
`androidx.sharetarget.ChooserTargetServiceCompat`,
`androidx.profileinstaller.ProfileInstallReceiver`, none of which run here. The
same objection kills the "declare all 69 as metadata" variant: a class
registered for reflection is a root too. Registering what a trace actually
exercised is the cheaper and the safer policy, and it is what FR-4 already
prescribes.

### What was done instead: `View.overridesOnDraw` is off on the image path

atlas commit `cfa73805` — *view: do not reflect for onDraw inside a native
image*, on `mercurygram/openjdk-port`.

`View.updateDisplayListIfDirty` (`android/view/View.java:1300`) skips recording
a display list for a view with no background that does not override `onDraw`,
and it decides that with `c.getDeclaredMethod("onDraw", Canvas.class)` walking
up the superclass chain (`:1273-1292`). That single site is **41 of the 134**
entries in the post-dumper boot config, and **139 of the 613** in the
four-check merge — it grows with every screen a trace covers and can never be
complete. Under a closed-world image an unregistered class answers that query
either with `NoSuchMethodException` (absent metadata reads as "no such member")
or with a missing-registration error; the first makes the view silently blank,
the second crashes. Both outcomes are removed by not asking. Which of the two
GraalVM 21.0.2 actually produces is not measured yet — the image run will show it.

This site has already cost this port one full-UI failure on HotSpot
(`NoClassDefFoundError: android/view/ViewStructure` at `View.overridesOnDraw`,
every frame of the message list dead — see the note further up), so it is not a
theoretical risk.

The gate is

```java
private static final boolean IN_NATIVE_IMAGE =
        System.getProperty("org.graalvm.nativeimage.imagecode") != null;
```

tested first in the `if`, so `overridesOnDraw()` is not even called. Two details
matter:

- The key is GraalVM's own `ImageInfo.PROPERTY_IMAGE_CODE_KEY`, read with plain
  `System.getProperty` so nothing depends on the GraalVM SDK.
- It tests for **any** value, not for `"runtime"`. The property reads
  `"buildtime"` during the image build and `"runtime"` after it, and a
  `static final` initialised while `View`'s class initialiser runs at build
  time would otherwise be baked to `false` — the exact opposite of what is
  wanted. On ART and on a stock JVM the property is unset, so both keep the
  reflective fast path and the ART decision is unchanged.

The cost on the image is empty display lists recorded for views that draw
nothing: more `RenderNode` allocations, a slower first frame. If the start-up
numbers say it matters, the port can generate a
`"queryAllDeclaredMethods": true` fragment for every `View` subclass on
`out/classpath/` and drop the gate.

### Measured

- **FR-2, HotSpot unchanged:** `build-atlas.sh` clean (2761 views enumerate
  their methods), `run.sh --seconds 90` → "run ok: booted to the main activity,
  no uncaught exceptions", `check-chatlist.sh` → "chat list check passed: 129
  dialogs loaded from cache4.db … the list scrolled".
- **The fallback draw path is correct, not just slower:**
  `PORT_EXTRA_JVM_ARGS="-Dorg.graalvm.nativeimage.imagecode=runtime" check-chatlist.sh`
  → same pass, 129 dialogs, list scrolled; `out/run.log` line 13 confirms
  `jvm option: -Dorg.graalvm.nativeimage.imagecode=runtime` reached the VM, and
  `out/screenshots/chatlist-loaded.png` is the same rendering as the ungated run
  (avatars, badges, bottom bar, FAB; the pixels differ only where new messages
  arrived between the two runs on a live account).
- **The metadata it removes**, 120 s chat-list boot under the GraalVM agent with
  the property set, into a fresh dir, against `out/ni-config-boot-us004`:

  | | post-dumper boot | + this change |
  | --- | --- | --- |
  | `reflect-config.json` | 134 classes, 13861 B | **94 classes, 8259 B** |
  | — entries mentioning `onDraw` | 41 | **0** |
  | `resource-config` / `proxy` / `serialization` | — | byte-identical |

  40 class entries removed, `android.widget.TextView` trimmed to its two fields,
  **0 added**. `jni-config.json` gained `android.graphics.Paint$FontMetrics`,
  which is the run-to-run variance already noted for the dumper removal, not this change.
  The kept trace is `out/ni-config-boot-us005/` (gitignored), beside the other
  two boot traces.

  Success Metric 4 ("`reflect-config.json` under ~150 classes after the dumper
  removal and the registry decision") is met at 94, without a registry.

### If someone still wants the registry

The only shape that can work, written down so nobody re-derives it: atlas gains
`android/atl/ComponentRegistry` with a settable `ComponentFactory` and a
`newInstance(name, type)` that falls back to today's `Class.forName`, added to
the `srcs` list in `src/api-impl/meson.build`; the generator lives in the port
as `linux-port/gen-registry.sh`, reads the merged manifest, javacs one class
into `$PORT_OUT/classpath/port-registry.jar` (`main.c` globs that directory),
and is a `build-all.sh` step after both `build-atlas.sh` and
`build-classpath.sh`; the generated class self-registers from its static
initialiser, triggered on HotSpot by one `Class.forName` behind a `-D` property
and in the image by `--initialize-at-build-time`. Emit arms only for
`org.telegram` classes outside `…voip`, or the closure problem above lands in
the image build's lap.

## The apk is out of the classloader's reach

Two places in `AssetManager` read apk content through the system class loader.
Both are gone; each is its own atlas commit on `mercurygram/openjdk-port`.

### `extractFromAPK` read from the class path, not from the apk

atlas commit `6d5bd6f5` — *api-impl: extract apk files through the apk, not the
class path*.

The old `extractFromAPK(apk_path, path, target)` enumerated `apk_path` with a
`JarFile` in its directory branch, but every byte it copied came from
`ClassLoader.getSystemClassLoader().getResourceAsStream(path)`. So the listing
and the data came from different archives: the data was whatever jar answered
first on `-Djava.class.path`, which here is api-impl.jar, ~200 app jars,
app.apk, framework-res.apk, in that order. That is a shadowing bug on HotSpot
before it is anything else; in an image there is no class path at all, so it
would simply stop working.

Now one `JarFile` serves both branches. Three invariants had to survive, each
with a caller that depends on it:

- **a missing entry is a silent no-op.** `SoundPool.java:57/:63` and
  `MediaPlayer.java:65` pass `getResourceEntryName(resId)` — a bare name like
  `sound_in`, which is not an apk entry and never was. The classloader returned
  null there; `getJarEntry` returns null and the method returns. Telegram
  swallows a throw here (`NotificationsController` catches `Exception`), so
  breaking this would show up as a silently missing sound, not as a failure.
- **the mtime guard stays**, and the target stays `$app_data_dir/<target>`.
- **the descriptor is unchanged.** `handle_cache.c:97` looks
  `extractFromAPK` up as `(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V`
  at startup; a mismatch is an abort.

`new JarFile(apk_path, false)` — verification off — is deliberate. `out/app.apk`
is v1-signed: `META-INF/MANIFEST.MF` is 997 KB of per-entry `SHA-256-Digest`,
with `CERT.SF` and `CERT.RSA` beside it. A verifying `JarFile` only verifies
lazily, when a stream is read, so the old directory branch never paid for it —
but the new code *does* read streams, and would parse ~2 MB, check an RSA
signature and hash every extracted byte on each notification, plus drag the JCA
signature stack into the image's reachable set. This path only copies data out;
`PackageParser.collectCertificates` still verifies for real, once, at
`Context.<clinit>`.

### The constructor discovered its apks by scanning the class path

atlas commit `eaa62f9e` — *api-impl: find the apks from properties, not from the
class path*.

This is the site the PRD's background section misses, and it is the more
important of the two. `AssetManager()` called
`getSystemClassLoader().getResources("AndroidManifest.xml")`, turned every
`jar:file:…!/AndroidManifest.xml` URL back into an archive path, put
framework-res.apk first and handed the list to `native_setApkAssets`. That scan
is where the whole resource system gets its apk paths, it is what produced the
`AndroidManifest.xml` entry in `resource-config.json`, and it is the *only*
consumer of `--framework-res`, which reaches Java solely as a
`-Djava.class.path` element (`main-executable-hotspot/main.c:203`). Under an
image it would return an empty enumeration, leaving `asset_paths` holding only
the external-storage dir — every resource lookup dead. The image run could not have
booted with it in place.

The hotspot launcher already passed `-Datl.apk.path` (added with `atl.data.dir`
and `atl.app.id` for exactly this, and until now read by nothing); it now also
passes `-Datl.framework.res.path` when `--framework-res` is given. `AssetManager`
takes both when `atl.apk.path` is set — framework-res first, so app resources
still override framework ones — and otherwise falls back to the class path scan
verbatim. The dex/ART launcher sets neither property, so it is unaffected. No
script changed: `run.sh` and `click/run.sh` already pass `--framework-res`.

Knowing the apk list also repairs the one regression the first commit would have
left. `extractFromAPK` now tries the caller's apk and then the other registered
ones, so `setSmallIcon(android.R.drawable.stat_sys_upload)` — reachable from
`ImportingService`, `VideoEncodingService`, `StoryUploadingService` — still finds
its icon in framework-res.apk. Without the fallback it would have degraded to
`g_mapped_file_new` returning NULL and GLib criticals from
`android_app_NotificationManager.c:126`; no crash, just a missing icon.

### `check-emoji.sh` does not exercise any of this

Worth writing down, because the PRD claims it does. Its assertion counts
`AssetManager_openAsset(…, assets/emoji/N_M.png)` lines, which come from the
native libandroidfw reader behind `AssetManager.open()`; the fonts it also needs
go through `extractAsset()`, which copies via `open()` too. Neither touches
`extractFromAPK` or a class loader. It is a regression guard for the second
commit (the asset paths it reads *are* what changed), not evidence for the
first.

The direct evidence is `check-extract-apk.sh` + `tools/ExtractFromApkCheck.java`,
a `--run-class` helper modelled on `check-native-loader.sh`. It runs against a
fresh `ANDROID_APP_DATA_DIR` — mandatory, see the trap below — and asserts the
four behaviours: `res/drawable-mdpi-v4/notification.webp` comes out byte-identical
to the apk entry, `sound_in` throws nothing and creates nothing, the directory
branch extracts all 1049 entries under `res/drawable-mdpi-v4/`, and
`res/drawable-mdpi-v4/stat_sys_upload_anim0.png` (absent from app.apk) comes out
of framework-res.apk. It is a `build-all.sh` `checks` step beside
`check-native-loader.sh`.

### The trap: the mtime guard makes a naive re-trace vacuous

`extractFromAPK` copies only when the target is missing or older than the apk,
and `out/data/app.apk_/res/drawable-mdpi-v4/notification.webp` is always newer
than `out/app.apk`. So a re-trace over an existing data dir produces no `res/`
entry *whether or not the fix landed*, and the PRD's criterion 2 proves nothing
unless the target is deleted first. Worse, nothing in a boot deterministically
posts a notification — Telegram does not notify for your own Saved Messages
message — so the path may not run at all. Both traces below were taken after
`rm -f` on the target, and both are known to have actually extracted it.

### Measured

- `build-atlas.sh` after each commit: exit 0, 1849 framework classes, 2761 views
  enumerate their methods.
- `check-extract-apk.sh`: exit 0, all four assertions —
  `single file: res/drawable-mdpi-v4/notification.webp extracted, 208 bytes
  identical to the apk entry` / `missing entry: 'sound_in' threw nothing and
  created nothing` / `directory: 1049 files under res/drawable-mdpi-v4/ for 1049
  apk entries` / `framework resource: res/drawable-mdpi-v4/stat_sys_upload_anim0.png
  extracted from framework-res.apk, 527 bytes`.
- `jvm option: -Datl.framework.res.path=…/out/atlas/framework-res.apk` in
  `out/run.log` line 5: the new property reaches the VM.
- **FR-2:** `run.sh --seconds 90` → "run ok: booted to the main activity, no
  uncaught exceptions in 90s".
- **Criterion 3:** `check-emoji.sh` → passed, 109 glyphs in the panel, 113 read
  in all, `mg-us014-1786362750😚` round-tripped through cache4.db.
- **Criterion 2**, `resource-config.json`, 12 entries → 9. Baseline is
  `out/ni-config-baseline-boot`; the new traces are `out/ni-verify-boot`
  (120 s chat-list boot under the GraalVM agent, after deleting the extracted
  icon — and the run re-created it, so the extraction really ran during the
  trace) and `out/ni-verify-extract` (the same agent over `check-extract-apk.sh`).

  | entry | baseline | boot re-trace | `check-extract-apk.sh` trace |
  | --- | --- | --- | --- |
  | `AndroidManifest.xml` | yes | **gone** | **gone** |
  | `res/drawable-mdpi-v4/notification.webp` | yes | **gone** | **gone** |
  | `META-INF/services/javax.xml.parsers.SAXParserFactory` | yes | yes | — |
  | 5 × `META-INF/services/java*` (negative lookups) | yes | 4 | 2 |
  | 4 × `java.base:…/icudt72b/*` | yes | yes | 1 |

  The `res/` count is 0 in both (`grep -c '"\\Qres/'`). Only the
  `SAXParserFactory` line resolves to a real file — `shim/resources/META-INF/
  services/…`, the namespace-aware-SAX fix — and it must stay an embedded
  resource in the image. The other five `META-INF/services` patterns are JDK
  `ServiceLoader` scans that find nothing anywhere on the class path, and which
  of them a run records is variance, not signal. The four ICU files are inside
  `java.base` and have nothing to do with the apk.

  So the image needs exactly one embedded classpath resource, and no apk
  content at all.

## GraalVM phases 1-2: the combined state, re-measured

Phases 1 and 2 are in. This section is the one place to look for what the
metadata actually is now; the per-story sections above keep their own
before/after tables and their deviations. Everything here was re-measured on
2026-08-10 from a wiped `out/ni-config`, not carried over from a story report.

### `trace-metadata.sh` now traces under image conditions

The script exported only the agent option, so every trace it produced recorded
atlas's `View.overridesOnDraw` lookups — the very lookups the registry work removed from
the image path (atlas `cfa73805`, gated on
`org.graalvm.nativeimage.imagecode`). It now also passes
`-Dorg.graalvm.nativeimage.imagecode=runtime`, so the trace sees the code path
the image will run. Measured cost of getting this wrong: **242 classes vs 105**
for the same four checks, i.e. 137 of 242 entries were metadata the image never
asks for. Both runs are kept: `out/ni-config-phase2-hotspot/` (agent only) and
`out/ni-config/` (agent + the property). The diff between them is `+0 -137`,
and `jni-config.json`, `resource-config.json`, `proxy-config.json` and
`serialization-config.json` are byte-identical in the two.

All four checks pass with the property set (mtproto 163 s, chatlist 42 s,
messages 54 s, emoji 54 s, `trace complete`, exit 0), which extends the registry work's
chatlist-only evidence that the non-reflective draw path is correct to the whole
check suite.

### The numbers

Boot-only traces on the left, the four-check merge on the right. They are not
comparable with each other — the merge covers login, the chat list, a send and
the emoji panel — so both columns carry their own before and after.

| | boot, 2026-08-10 baseline | boot, after phases 1-2 | merged 4 checks, before | merged 4 checks, after |
|---|---|---|---|---|
| dir | `out/ni-config-baseline-boot` | `out/ni-config-boot-us005` | `out/ni-config-stale-us003` | `out/ni-config` |
| `reflect-config.json` | 444 classes, 42022 B | 94, 8259 B | 613 classes, 62587 B | **105 classes, 9098 B** |
| — `org.telegram.*` | 357 | — | 510 | **19** |
| — `allPublicFields` | 304 | 0 | 366 | **0** |
| — entries asking `onDraw` | 41 | 0 | 139 | **0** |
| — `<init>`-only entries | 34 | — | 34 | 35 |
| — name-only entries | 47 | — | 54 | 53 |
| `resource-config.json` | 12 entries, 1 × `res/` | — | 12, 1 × `res/` | **10 entries, 0 × `res/`** |
| `jni-config.json` | 61 classes, 13303 B | — | 62, 13465 B | 62 classes, 13465 B |
| `proxy-config.json` | empty | empty | empty | empty |
| `serialization-config.json` | empty | empty | empty | empty |
| `predefined-classes-config.json` | empty | empty | empty | empty |

Per check, merged in order: 0 → 81 (mtproto) → 96 (chatlist) → 104 (messages)
→ 105 (emoji). Against the boot-only 94, four driven checks add **11** classes:
eight span arrays (`URLSpan*`, `QuoteSpan$*`, `TypefaceSpan`,
`CodeHighlighting$Span`) plus `StateListDrawable`, `PopupWindow` and
`ScrollView`.

`AndroidManifest.xml` and `res/drawable-mdpi-v4/notification.webp` are gone from
`resource-config.json`; the surviving 10 are six `META-INF/services`
patterns — only `javax.xml.parsers.SAXParserFactory` resolves to a real file,
`shim/resources/` — and four ICU data files inside `java.base`.

### Success Metric 4

> `reflect-config.json` is under ~150 classes after the dumper and registry work, and every
> entry traces to a call site someone can point at.

**Met, at 105 classes over all four checks** (94 on a boot alone). It is met
only with the image-code property set: without it the same trace is 242, which
is over the bar. Two corrections to the PRD's background numbers while they are
being quoted:

- "304 `allPublicFields` on `org.telegram.tgnet.TLRPC$*`" is 304
  `allPublicFields` of which **239** are `TLRPC$*` and 65 are other
  `org.telegram.tgnet.*` types.
- "the remaining 54 `org.telegram` entries ask for `<init>` only" is **34**
  `<init>`-only entries in the baseline, and only 16 of those are
  `org.telegram`.

The 105 by origin, all pointable:

- 13 `NotificationBadge$*Badger` + 4 manifest components
  (`ApplicationLoaderImpl`, `LaunchActivity`, `NotificationImageProvider`,
  `voip.CallNotificationSoundProvider`) + the bare `NotificationsService` name.
- 2 `TLRPC$TL_updates` / `TL_updateShort`, from `TLClassStore.java:58`
  `objClass.newInstance()`.
- 53 name-only entries, 36 of them array classes from `Spannable.getSpans`.
- The rest is JDK plumbing: `sun.security.*` providers, `androidx.startup`
  initializers, `KXmlParser`/`KXmlSerializer`.

**The converse does not hold, and the image build should know it:** a traced call site is
only registered for the arms the trace happened to take. `TLClassStore`'s map
has **20** distinct classes and the trace registered **2**. The other 18
(`TL_updateShortMessage`, `TL_updatesCombined`, `TL_updatesTooLong`, `TL_error`,
`TL_null`, the secret-chat types …) will fail `newInstance()` in the image and
land in `FileLog.e` with a null return — a silently dropped update, not a crash.
FR-4 says the fix is a check that exercises them, not a hand-edit.

### FR-2, the HotSpot path

Re-verified after the whole phase, on the port's own JDK 21.0.11 and with no
agent: `check-env.sh` → "environment OK"; `check-graalvm.sh` → "GraalVM OK";
`run.sh --seconds 90` → "run ok: booted to the main activity, no uncaught
exceptions in 90s", exit 0, `out/run.log` 760,990 B with `-Dtmessages.tldump=0`
in the option list and 0 `/MTProto` lines; all four driving checks green twice
over in the two traces above. Both repos clean apart from the notes and the
`FileLog.java` `catch (Throwable)` hunk that has been in the tree since before
the dumper work.

## Phase 1-2 review: five script defects, fixed

A code review after the apk change found nine defects the checks themselves could not
see. These five are the `linux-port/` scripts; none changed a measured number, and
`out/ni-config` is byte-identical before and after (`md5sum -c`, all six files
OK).

### `trace-metadata.sh` merged into a stale config (HIGH)

The script did `mkdir -p "$config_dir"` and handed the agent `config-merge-dir`.
The agent can only ever *add*, so re-running on a tree whose `out/ni-config` still
held the pre-dumper trace merged today's 105 classes on top of yesterday's 613,
printed `trace complete` and exited 0 — with the 304 `allPublicFields` entries
the dumper removal took out still in it, each one an image root the image build
would have to honour.
The 105-class config only exists because a human `rm -rf`'d by hand; no script did.

**It now wipes the config dir first**, and `--merge` is the opt-in. The reasoning
for that default: the config is a build input, one command from a clean checkout
has to reproduce it, and a merge cannot subtract. The wipe refuses to touch a
directory holding anything but `*-config.json` /
`agent-extracted-predefined-classes`, so an `rm -rf` never runs on a path the
caller merely mistyped. `--only` is a partial profile, so it now needs `--merge`
or its own `--config-dir` and reports `partial trace complete`, never
`trace complete`.

Measured on a stale directory seeded with 613 entries (`PORT_OUT` pointed at a
scratch dir): "wiping …/ni-config", the four checks then ran, and the directory
ended up empty because the launcher was missing — exit 1, `trace incomplete`.

**`trace complete` is now impossible without a complete config.** The agent writes
at VM shutdown; an option that never reached the VM leaves the directory as it was
while every check still exits 0. The script therefore checks the six
`*-config.json` files exist and are non-empty and that `reflect-config.json` parses
to a non-empty list. With four stub checks that pass and write nothing: "the agent
left … incomplete, missing: reflect-config.json …", exit 1. It also writes
`<config-dir>.trace-stamp` (checks, date, JAVA_HOME, agent options, class count)
so the image build can tell a full profile from a partial one.

**The baseline is validated before anything runs.** `out/ni-config-baseline-boot`
is a *kept* boot-only trace — it is the 2026-08-10, dumper-on, 444-class one, and
no script produces it (nor could: with the dumper off, the same command now gives 93).
`if [ -d ]` used to skip the comparison in silence. An explicit `--baseline` that
does not exist is now an error before the first check; a missing default prints a
note at the start *and* `=== no baseline comparison: … ===` where the diff would
have been. README.md carries the one-run command that records one.

**`$GRAALVM_HOME` is checked for 21.x there.** `env.sh` keeps an externally-set
`JAVA_HOME` only while it reports 21.x and silently substitutes the port's OpenJDK
otherwise — which has no agent. A JDK 17 in `GRAALVM_HOME` now fails with
"$GRAALVM_HOME is not a JDK 21, so env.sh would drop it: openjdk version "17.0.9"".

### `run.sh` truncated `$PORT_EXTRA_JVM_ARGS` at the first newline (MEDIUM)

`read -ra arr <<<"$V"` reads one line, and the variable is documented as
whitespace-separated. `W=$'-Done\n-Dtwo'; read -ra y <<<"$W"` → `${#y[@]}` is **1**.
`trace-metadata.sh` survived only because its two options are joined by a
backslash continuation inside one pair of quotes; had the `-agentlib` option been
the dropped one, every trace would have traced nothing at exit 0 throughout.

`read -ra … -d ''` reads to NUL instead, so all whitespace separates and nothing
globs. Proven on a real run: `PORT_EXTRA_JVM_ARGS=$'-Dport.probe.one=1\n-Dport.probe.two=2'
run.sh --seconds 45` → "run ok", and both `jvm option: -Dport.probe.*` lines in
`out/run.log`.

Two loud failures replace the silent drops: a word that does not start with `-`
(the visible half of an option split on its own space) is refused before the
launcher starts — `PORT_EXTRA_JVM_ARGS='-Dfoo=a b'` → "'b' is not a JVM option",
exit 1 — and a timed run greps the launcher's own `jvm option:` echo for every
requested option, failing if one never reached the VM. The agent path was
re-verified through it end to end: `PORT_EXTRA_JVM_ARGS="-agentlib:native-image-agent=config-merge-dir=DIR
-Dorg.graalvm.nativeimage.imagecode=runtime"` under `JAVA_HOME=$GRAALVM_HOME`,
60 s → "run ok" and 93 reflect classes in `DIR`.

### `check-graalvm.sh` hid the diagnostic it exists to print (LOW)

`ni_version="$("$ni" --version 2>&1 | head -1)"` captures stderr into the variable,
and under `pipefail` a non-zero exit kills the script before any `ok:` line — the
error text dies unprinted. A `native-image` stub that prints "Error: image builder
is broken" and exits 1 produced *no output at all* from the old code (exit 1). Both
that and the `java -version` line now run the tool first and print everything it
said on failure: "…/native-image --version exited 1: Error: image builder is
broken". The converse case, a tool that prints an error and exits 0, used to be
reported as `ok: native-image: <error text>`; the first line must now contain a
21.x version, so it fails with "native-image did not report a 21.x version".

### `transplant-session.sh`'s busy-app guard was too narrow (LOW)

It matched `^$ATLAS_OUT/android-translation-layer-hotspot ` or a command line
naming the source apk. `cd out/atlas && ./android-translation-layer-hotspot …`, a
symlink, or the click's `$PKG_ROOT/lib/…` against the same `ANDROID_APP_DATA_DIR`
matched neither, so it would rsync over a live SQLite WAL — the corruption the
guard exists to prevent. A `readlink /proc/$pid/exe` that failed also dropped the
candidate in silence.

It now matches on **what holds the two session trees**, not on how the launch was
spelled: one `find /proc/[0-9]*/fd /proc/[0-9]*/cwd -lname` pass (one process, not
a `readlink` per descriptor — the whole scan is 0.27 s) plus, for a launcher that
has not opened anything yet, `ANDROID_APP_DATA_DIR` out of `/proc/$pid/environ`
restricted to an `android-translation-layer*` exe. A candidate whose `/proc` entry
cannot be read is reported as `<exited>`, never dropped.

Verified against a fake session: a `bash -c 'exec 3< …/cache4.db; sleep 60'` that
names no launcher at all is caught ("pid … (holds …/cache4.db)"), so is a copy of
the binary at an unrelated path with `ANDROID_APP_DATA_DIR` pointing at the
destination, so is a process holding a file in the *source* tree. The narrowing
the metadata trace asked for still holds: the six `atlas-camera2` `android-translation-layer`
processes were running throughout, and a transplant with no real holder exits 0.

The source side deliberately gets no environment check — its data dir is
`~/.local/share/android_translation_layer`, which every atlas app on the machine
shares, so matching it would block on the camera tests again.

### README.md's hand-trace recipe could not work (LOW)

`JAVA_HOME=$GRAALVM_HOME linux-port/run.sh …` — `GRAALVM_HOME` is exported by
`env.sh`, which `run.sh` sources in its *own* shell, so in the reader's shell the
prefix assigns an empty `JAVA_HOME` and `env.sh` substitutes the port's OpenJDK,
where `-agentlib:native-image-agent` does not resolve. The recipe now sources
`env.sh` first and passes `-Dorg.graalvm.nativeimage.imagecode=runtime` alongside
the agent, without which a hand trace records the ~137 `View.overridesOnDraw`
entries the registry work removed and contradicts `out/ni-config`. Run as written:
"run ok", 93 reflect classes — the boot-only number, one apart from that stage's 94.

## Phase 1-2 review: the three atlas-side defects, fixed

The other half of the same review. All three are framework work, so all three are
commits in `atlas/` (FR-1a) — `api-impl: add Debug.dumpHprofData` and
`api-impl: keep an extractFromAPK miss cheap and quiet`. No measured number moved:
`out/ni-config` is untouched, and `run.sh --seconds 90` still exits 0.

### The app-source workaround was a missing framework method (FR-1a)

The tree carried an uncommitted edit to `FileLog.dumpMemory()` widening
`catch (Exception)` to `catch (Throwable)`, so that the `NoSuchMethodError` from
`Debug.dumpHprofData` — a method atlas's `android/os/Debug.java` simply did not
have — could not reach `FileLog.fatal()` and `System.exit(2)`. It was in every jar
the branch's measurements were taken from, while a clean checkout did not have it:
the verified artefact and the committed state differed.

atlas now has the method. It writes no dump (there is no ART heap to walk, and
nothing here reads hprof) and throws `IOException`, which is what AOSP declares and
what the app's own `catch (Exception)` already handles. The app edit is reverted,
so `org/telegram/**` is back to the two `-D`-guarded hooks — the dumper's
`tmessages.tldump` and FR-7's `tmessages.native.path`.

`check-dump-hprof.sh` + `tools/DumpHprofCheck.java` hold the line, and
`build-all.sh` runs it. It checks both ends: `javap -c` on the built
`TMessagesProj.jar` must show `dumpMemory` calling
`android/os/Debug.dumpHprofData:(Ljava/lang/String;)V` inside a
`Class java/lang/Exception` handler and **not** a `Throwable` one (the workaround
coming back fails the check), and the framework half runs in the launcher via
`--run-class`:

```
signature: public static void android.os.Debug.dumpHprofData(java.lang.String) throws java.io.IOException
caught by catch (Exception): java.io.IOException: android.os.Debug.dumpHprofData is not implemented: /tmp/atl_check_heap.hprof
dump-hprof check: passed
```

### A miss in `extractFromAPK` cost two central-directory parses (LOW)

The fallback loop calls `extract(other, path, target)` for every other apk,
and `extract(String, …)` opened `new JarFile(apk_path, false)` each time. That is
the *normal* path for `SoundPool.load` and `MediaPlayer.create`, which pass bare
resource entry names (`sound_in`) that are never apk entries — on the click, once
per notification sound on device storage.

Measured with the old jar, inside the launcher: **200 misses = 1134 ms**, ~5.7 ms
each. A cold `JarFile` open of `out/app.apk` (64 MB, 9450 entries) is 0.9 ms, and a
miss paid one per apk. The opened `JarFile`s are now kept in a static map for the
life of the process; the same 200 misses are **0 ms** (`check-extract-apk.sh` step
6, budget 50 ms).

Note when measuring this: the JDK shares a parsed `ZipFile.Source` between open
handles on the same file, so an `open+close` loop timed *while* something holds the
apk open reads 35x too fast (2.9 ms vs 182 ms for 200 opens here). The check
therefore asserts an absolute budget instead of comparing against a live baseline.

A name with no `/` is *not* a safe short circuit for the same problem:
`AndroidManifest.xml`, `classes.dex` and `resources.arsc` are top-level apk
entries.

### A `JarFile` exception could reach a native frame with no `ExceptionCheck` (LOW)

`new JarFile()` throws on a missing or truncated apk, where its predecessor —
`getSystemClassLoader().getResourceAsStream(path)` — returned null in silence. The
only native caller, `util.c:extract_from_apk`, invokes this with
`CallStaticVoidMethod` and no `ExceptionCheck`, so the pending exception would be
delivered at some later, unrelated JNI transition. It is reachable: `click/run.sh`
passes `--framework-res "${PKG_ROOT}/atlas/framework-res.apk"` and the launcher
turns it into `-Datl.framework.res.path` without checking the file is there.

Confirmed against the old jar — `check-extract-apk.sh` step 5 with
`/nonexistent/no-such.apk` as the caller's apk:

```
Exception in thread "main" java.nio.file.NoSuchFileException: /nonexistent/no-such.apk
	at android.content.res.AssetManager.extract(AssetManager.java:688)
	at android.content.res.AssetManager.extractFromAPK(AssetManager.java:676)
```

An apk that cannot be opened is now a miss like any other (logged once, cached as
"cannot be opened" so it is not retried), and only a failed *copy* still throws.
`extract_from_apk` describes and clears a pending exception anyway, the same way
`ATLWindow.c` does around its per-frame calls.

The native half is verified by inspection, not end to end: on the port the only
native caller left is `nativeShowNotification`, which needs a real delivered
notification to reach (the boot extraction at `main.c:418` belongs to the dex
launcher). What is verified is that the Java side no longer throws for either
reason a native caller can hit.

## Phase 1-2 review: the app-side and image-correctness defects, fixed

The last three of the review's nine. Two of them decide what
`build-image.sh` has to do, so they are fixed before anything tries to build an
image.

### `check-mtproto.sh`'s success arm could never match (MEDIUM)

`grep -qE 'got response for request .*TL_auth_sendCode'` was unreachable, for the
reason the review gave: that line is tgnet's own
`ConnectionsManager.cpp:1312`, whose `%s` is `typeid(*request->rawRequest).name()`,
and `TgNetWrapper.cpp:111` wraps **every** request coming from Java in a
`TL_api_request`. Measured in a real run's `out/run.log`: the `got response`
lines carry `14TL_api_request` for all nine Java requests, and a mangled C++ name
only for tgnet's own objects (`17TL_help_getConfig`, `23TL_auth_bindTempAuthKey`)
— which is why the same shape *does* work for `help.getConfig` two arms above.

The review was wrong about the two `wait_for_log 'TL_auth_sendCode'` calls, and
that is worth writing down: they match
`ConnectionsManager.sendRequestInternal`'s own
`FileLog.d("send request " + object + " with token = ")`
(`ConnectionsManager.java:388`), where `object` is `TLObject`'s default
`toString`. Exactly two lines in the whole log carry the literal:

```
3913:D/tmessages: send request org.telegram.tgnet.TLRPC$TL_auth_sendCode@283eac7f with token = 9
4031:E/tmessages: org.telegram.tgnet.TLRPC$TL_auth_sendCode@283eac7f got error 420 FLOOD_WAIT_45810
```

Both waits are now spelled `send request .*TL_auth_sendCode`, so they say what
they mean. The success arm is `java received .*TL_auth_sentCode`
(`ConnectionsManager.java:445`): `auth.sendCode` deserialises its response with
`TL_auth_sentCode.TLdeserialize` (`TLRPC.java:51020`), whose three results are
`TL_auth_sentCode`, `TL_auth_sentCodeSuccess` and
`TL_auth_sentCodePaymentRequired` — the prefix covers all three. Only
`auth.resendCode` shares that response type and the check never sends one.

**The success arm is correct by construction, not tested.** With the dummy
`APP_ID=0` the server answers this number with `420 FLOOD_WAIT_*` every time, so
only the error arm runs here; nothing in this environment can execute the other
one. Whoever first runs the check with real `API_KEYS` should confirm it.

The error arm's own pattern grew a digit class (`[A-Z_0-9]+`), so the summary now
reads `got error 420 FLOOD_WAIT_45810` instead of stopping at `FLOOD_WAIT_`.

### `FileLog`'s TL-dump flag would have baked into the image (MEDIUM)

`private static final boolean tlDumpEnabled = tlDumpEnabled();` read the property
in `<clinit>`. Nothing passes `-Dtmessages.tldump=0` to `native-image`, so a
build-time-initialised `FileLog` would have frozen the flag at **true** and
shipped an image with the dumper on — the exact Gson reflection over `TLRPC$*`
that the dumper removal took out, back on the first MTProto response.

Fixed in the app (still one `-D`-guarded escape hatch, FR-7): the value is read
on first use and cached in a *mutable* `private static Boolean tlDump`. A
build-time snapshot of that field is `null`, which is not an answer, so the first
call at image runtime reads the real property. No `--initialize-at-run-time` and
no build-time `-D` needed — **the image build has to remember nothing**, which is why this
shape was chosen over the two the review offered.

Verified in the built jar (`javap -p -c` on `out/classpath/TMessagesProj.jar`):

```
static {};
   0: iconst_0   putstatic  databaseIsMalformed:Z
   4: aconst_null putstatic Instance:Lorg/telegram/messenger/FileLog;
```

— no property read left in `<clinit>`, and `tlDump` is `private static
java.lang.Boolean`. Both runtime arms still work on HotSpot: `run.sh --seconds 90`
(property `0`) leaves **0** `req -> ` lines in `out/run.log` while 33 requests go
out, and `run.sh --seconds 40 --tl-dump` (property unset, i.e. the Android
default) dumps `req -> TL_langpack_getLanguages`.

atlas's `View.IN_NATIVE_IMAGE` keeps the `static final` shape on purpose: its
property is `org.graalvm.nativeimage.imagecode`, which `native-image` sets during
the build, so folding it to "in an image" is the answer the image wants. Don't
copy that pattern for a property only the *launcher* sets.

### `TLClassStore` was registered for 2 arms of 19 (FR-4 gap)

`TLClassStore.TLdeserialize` does `objClass.newInstance()` over a `SparseArray`
the constructor fills with **20 entries covering 19 distinct classes** (the review
said 20 distinct; `TL_decryptedMessage_layer17` maps to `TL_decryptedMessage`,
which is already there). The four-check trace registered **two**: `TL_updates` and
`TL_updateShort`, the arms the server happened to send. The other 17 would fail
`newInstance()` in the image, be swallowed by that method's
`catch (Throwable) -> FileLog.e` and return null — a dropped update, no crash.

Fixed the way FR-4 asks: a check that exercises the arms, not a hand-edited
config. `check-tlstore.sh` + `tools/TLClassStoreCheck.java`, in the port's
two-ended style:

- the jar half reads the class list out of the built
  `TMessagesProj.jar`'s own bytecode. javac folds `TLRPC.TL_x.constructor` into an
  `ldc <int>`, so the constructor is a run of `ldc int; ldc class; SparseArray.put`
  and the class literals *are* the list. It asserts one literal per `put`, so an
  arm added upstream is covered without editing the check;
- the launcher half runs `Class.forName(name).newInstance()` on each inside
  `--run-class`, which is what the agent needs to see. Deliberately not
  `getDeclaredField("classStore")`: reading the private field would put
  `TLClassStore.classStore` into `reflect-config.json` for the check's benefit
  alone.

`trace-metadata.sh` runs it first (seconds, no session, its own data dir) and
`build-all.sh`'s `checks` step runs it too. Traced on its own into a scratch dir:
**35 reflect classes, of which the 19 TL ones are all `<init>`, 17 of them not in
`out/ni-config`** — every missing arm, and nothing else new (the other 16 entries
are JDK security classes already in the config, and it adds no resource entry).

One wrinkle worth knowing for any future `--run-class` check under the agent: the
launcher reaches `main()` through `FindClass`, so the agent records the *harness*
as a JNI root (`{"name": "TLClassStoreCheck", "methods": [{"name": "main", …}]}`).
That class is not in the image and `native-image` warns about config it cannot
resolve, so `trace-metadata.sh` drops that one entry by name after the run
(`drop_harness`) — part of generating the config, not a hand edit of it.

### Green after this stage

`check-tlstore.sh` exit 0 ("all 19 classes in the store instantiate"),
`check-mtproto.sh` exit 0 (`got error 420 FLOOD_WAIT_45810`, DC connected 6 s
after the login screen), `run.sh --seconds 90` exit 0 "run ok",
`trace-metadata.sh --only tlstore --config-dir <scratch>` exit 0. `out/ni-config`
is untouched: still the phase-2 artefact, and now **two app-jar rebuilds old** —
`FileLog`'s change is on no boot path, but stage 4's re-trace is what makes the
config current. `check-mtproto.sh --fresh` wiped `out/data` again, as it always
does; `transplant-session.sh` puts the session back.

## Pre-phase-3 fixes: the whole review, verified independently

The three sections above are what the fix stages reported. This one is the
check on them, run on 2026-08-10 before phase 3 starts: every number here was
produced by re-running the thing, not carried over from a stage report. It is
also the section to read first when starting on the image launcher.

### The HIGH finding is dead, with no flag to remember

The test the fix needs to pass is not "the wipe works when you ask for it", it is
"a session that knows nothing about the bug gets a correct config anyway". So
`out/ni-config` was seeded with the real pre-dumper artefact
(`cp -a out/ni-config-stale-us003 out/ni-config` — 613 classes, 62587 B, 366
`allPublicFields`, 139 `onDraw`, `AndroidManifest.xml` and
`res/drawable-mdpi-v4/notification.webp` in `resource-config.json`) and the trace
was run the way the image build would run it:

```
$ linux-port/trace-metadata.sh          # no arguments at all
wiping …/out/ni-config (--merge to keep what is in it)
before: reflect 0 classes (0 B), jni 0 classes (0 B), resource 0 entries, …
…
trace complete: tlstore mtproto chatlist messages emoji all passed,
122 reflect classes in …/out/ni-config          # exit 0
```

The result is **122 classes / 11094 B, not 613 + anything**: no
`allPublicFields` entry, no `onDraw` entry, no `res/` entry, i.e. nothing the
stale directory carried survived. The wipe is the default and needs no flag, so
the fix does not depend on an operator remembering one.

### The trace, end to end

One run, five checks, all exit 0 (`out/trace-<name>.log` each):

| check | exit | time | reflect after |
|---|---|---|---|
| tlstore | 0 | 8 s | 35 (3406 B) |
| mtproto | 0 | 163 s | 100 (9121 B) |
| chatlist | 0 | 42 s | 114 (10469 B) |
| messages | 0 | 48 s | 121 (10965 B) |
| emoji | 0 | 54 s | 122 (11094 B) |

Whole run 18:48:50 → 18:54:16 (5 min 26 s), `TRACE_EXIT=0`, and
`out/ni-config.trace-stamp` records the five checks, `merged onto an existing
config: no`, the GraalVM path and the two agent options.

### The numbers, phase 2 vs now

| | phase 2 (`ni-config`, 105) | now (122) |
|---|---|---|
| `reflect-config.json` | 105 classes, 9098 B | **122 classes, 11094 B** |
| — `org.telegram.*` (non-array) | 19 | 36 |
| — `TLRPC$*` | 2 | 19 |
| — `allPublicFields` | 0 | **0** |
| — entries asking `onDraw` | 0 | **0** |
| — `<init>`-only entries | 35 | 52 |
| — name-only entries | 53 (36 of them arrays) | 53 (36 arrays) |
| `resource-config.json` | 10 entries, 0 × `res/` | **10 entries, 0 × `res/`** (byte-identical) |
| `jni-config.json` | 62 classes, 13465 B | 63 classes, 13498 B |
| `proxy-config.json` | empty | empty (byte-identical) |
| `serialization-config.json` | empty | empty (byte-identical) |
| `predefined-classes-config.json` | empty `agent-extracted` | empty (byte-identical) |

`resource-`, `proxy-`, `serialization-` and `predefined-classes-config.json` are
byte-identical to the phase-2 artefact (`md5sum`), so the whole change is in
`reflect-config.json` and one JNI entry.

### The increase is exactly the TLClassStore gap being closed

`reflect-config.json` is **+17, −0** against phase 2, and all 17 are
`TLClassStore`'s missing arms, each `<init>`-only:

`TL_error`, `TL_null`, `TL_updateShortMessage`, `TL_updateShortChatMessage`,
`TL_updateShortSentMessage`, `TL_updatesCombined`, `TL_updatesTooLong`,
`TL_messageEncryptedAction`, `TL_message_secret`, `TL_message_secret_layer72`,
`TL_message_secret_old`, `TL_decryptedMessage`, `TL_decryptedMessageLayer`,
`TL_decryptedMessage_layer8`, `TL_decryptedMessage_layer45`,
`TL_decryptedMessageService`, `TL_decryptedMessageService_layer8`.

That set was predicted from the source before the trace ran (the 20 `put` calls
in `TLClassStore.java` minus `TL_decryptedMessage_layer17`'s duplicate, minus the
two arms the old trace already had) and the trace produced it exactly — nothing
else, and nothing dropped. All 19 TLRPC entries in the config are
`{"name": …, "methods": [{"name": "<init>", …}]}`.

`jni-config.json`'s one new entry is `java.lang.String`, name-only, from the
`--run-class` harness path; the harness class itself is not there
(`drop_harness` did its job).

### Success Metric 4 still holds

> `reflect-config.json` is under ~150 classes after the dumper and registry work, and every
> entry traces to a call site someone can point at.

**122 of ~150.** By origin, adding up to 122 exactly:

- 36 array classes (`Spannable.getSpans`),
- 36 `org.telegram.*`: 19 `TLRPC$*` (`TLClassStore.java:58` `newInstance()`),
  12 `NotificationBadge$*Badger`, 4 manifest components, `NotificationsService`,
- 21 `java.*`/`sun.*`/`jdk.*`/`javax.*` (security providers, XML),
- 14 `android.*`, 8 `androidx.*` (`androidx.startup` initializers),
- 7 others: `com.android.internal.R$styleable`,
  `com.sun.xml.internal.stream.XMLInputFactoryImpl`, `com.whatsapp.util.Log`,
  `kotlin.reflect.jvm.internal.ReflectionFactoryImpl`, `KXmlParser`,
  `KXmlSerializer`, `ru.noties.jlatexmath.JLatexMathInitProvider`.

Correction to the phase-2 breakdown above: the badgers are **12**, not 13
(`NotificationBadge$…` counted in the config), which is why that list added up to
20 for a 19-entry set.

The caveat phase 2 recorded — "a traced call site is only registered for the arms
the trace took" — is now closed for `TLClassStore` specifically, and stays true
in general.

### FR-2: the HotSpot path, all re-run today with no agent

One serial suite, the port's own OpenJDK 21 (no `JAVA_HOME`, no
`PORT_EXTRA_JVM_ARGS`), each check's log kept:

| check | exit | time | said |
|---|---|---|---|
| `check-env.sh` | 0 | 0 s | environment OK |
| `check-graalvm.sh` | 0 | 0 s | GraalVM OK |
| `check-extract-apk.sh` | 0 | 7 s | apk content came from the apk, not the class path |
| `check-dump-hprof.sh` | 0 | 8 s | the framework answers `Debug.dumpHprofData`, app-side `catch (Exception)` is enough |
| `check-tlstore.sh` | 0 | 8 s | all 19 classes in the store instantiate |
| `check-mtproto.sh` | 0 | 103 s | DC handshake + `help.getConfig`; `TL_auth_sendCode` → `420 FLOOD_WAIT_44271` |
| `check-chatlist.sh` | 0 | 40 s | 129 dialogs from cache4.db, no SQLite errors, the list scrolled |
| `check-messages.sh` | 0 | 51 s | send came back as `updateMessageID`, an incoming message redrew the list |
| `check-emoji.sh` | 0 | 53 s | 108 glyphs drawn, a tapped emoji went out as `mg-us014-…😚` |
| `run.sh --seconds 90` | 0 | 102 s | run ok: booted to the main activity, no uncaught exceptions in 90s |

`check-dump-hprof.sh` and `check-tlstore.sh` are not FR-2 checks; they are here
because they are the regression guards for two of the fixes.

Two guards were exercised directly rather than inferred, both exiting before any
app run: `--only emoji` without `--merge` → "would replace … with a partial
config", exit 1; a config dir holding `notes.txt` → "refusing to wipe …: it holds
files no trace wrote", exit 1, and the file was still there afterwards.

### Both repos clean, and the jars match the committed source

`git status --short` is empty in `mercurygram-src` (`ralph/graalvm-native-image`)
and in `linux-port/atlas` (`mercurygram/openjdk-port` at `21ae0094`). The
`FileLog.java` `catch (Throwable)` hunk that sat uncommitted across four stories
is **gone, not committed**: `dumpMemory` reads `catch (Exception e2)` again, and
the only `org/telegram/**` change in `FileLog.java` against `Mercurygram` is the
`-Dtmessages.tldump` escape hatch. The framework answers the call now
(atlas `82fe6c38`).

`build-classpath.sh` re-run from the clean tree: "64 actionable tasks: 64
up-to-date", 11/11 class checks ok, and the jar was not rewritten — the sha256
over the 12764 `org/telegram/**` class files in
`out/classpath/TMessagesProj.jar` is `c320ee9c…` before and after. So the
classpath the trace and the checks used is the committed source.

### Per-finding disposition, all nine

| # | finding | disposition |
|---|---|---|
| 1 | `trace-metadata.sh` merged into a stale config (HIGH) | fixed; re-proved here from a seeded 613-class directory, no flag needed |
| 2 | `run.sh` truncated `$PORT_EXTRA_JVM_ARGS` at the first newline | fixed (`read -ra -d ''` + an "option never reached the VM" check) |
| 3 | `check-graalvm.sh` swallowed the tool's diagnostic | fixed; `check-graalvm.sh` → "GraalVM OK" today |
| 4 | `transplant-session.sh`'s busy-app guard was too narrow | fixed; the three session checks transplanted cleanly in both suites today |
| 5 | README's hand-trace recipe assigned an empty `JAVA_HOME` | fixed |
| 6 | `FileLog`'s `catch (Throwable)` workaround (FR-1a/FR-7) | fixed in atlas (`Debug.dumpHprofData`, atlas 82fe6c38); the app hunk is gone from the tree |
| 7 | `AssetManager.extract` let a `JarFile` exception reach a native frame | fixed in atlas 21ae0094 + `util.c` `ExceptionDescribe`/`Clear` |
| 8 | an `extractFromAPK` miss re-parsed both central directories | fixed in atlas 21ae0094 (`openApk()` cache) |
| 9 | `check-mtproto.sh`'s success grep could never match | fixed; and the second half of that finding (the `wait_for_log`) was **not a defect** |
| + | `FileLog`'s TL-dump flag would have baked into the image | fixed (mutable `Boolean`, read on first use) |
| + | `TLClassStore` registered for 2 arms of 19 | fixed by `check-tlstore.sh`, and the +17 above is the proof |

### What is still open going into phase 3

Not defects found here, but things a later session should know:

- `out/ni-config-baseline-boot`, the default `--baseline`, is the 2026-08-10
  TL-dumper-on, 444-class trace and cannot be regenerated. The diff it prints is
  dominated by the dumper's removals. `out/ni-config-boot-us005` (94 classes) is the
  honest boot baseline; pass `--baseline out/ni-config-boot-us005` when the
  comparison matters.
- `trace-metadata.sh:80` still kills leftovers with `pkill -9 -f "^$launcher "`,
  one spelling of the path. Correct today because every check launches through
  `run.sh` with that absolute path.
- `run.sh --seconds 0` (interactive) runs none of the verification block, so the
  "an option never reached the VM" check does not apply to a manual run.
- `android_app_NotificationManager.c:127` NULL-derefs when a notification icon is
  not an apk entry (`g_mapped_file_new` unchecked). Pre-existing, unrelated to
  the image, and the reason the new `util.c` `ExceptionCheck` could not be
  exercised end to end.
- `check-mtproto.sh`'s success arm is still unexecuted: with `APP_ID=0` the
  server always answers `420 FLOOD_WAIT_*`, so only the error arm runs.

### A second review of the fixes themselves, and what it left open

The adversarial pass ran after the verification above, so none of it is in the
tables. It found one regression and eight live defects. Only the regression is
fixed; the rest are recorded here because a later session will meet them.

Fixed (commit `readlink -m`): `transplant-session.sh:62` canonicalised the
destination with `readlink -f` *before* the `mkdir -p` below it. `-f` prints
nothing and exits 1 on a missing component, so under `set -e` the script died
silently on every first transplant -- the flow `build-all.sh` itself points at.
Reproduced (`--data-dir` at a fresh path: exit 1, no output), fixed with
`readlink -m`, re-verified both ways plus the busy-app guard still firing.

Open, in the order they would bite:

- `trace-metadata.sh` relates `--config-dir` to nothing. `--baseline
  $PORT_OUT/ni-config` -- a natural way to ask what a trace adds to the config
  you have -- passes the existence check, is then wiped as the default
  `config_dir`, refilled, and diffed against itself: `+0, -0` and "trace
  complete". The foreign-file guard cannot help; a baseline dir holds exactly
  the `*-config.json` the wipe considers its own.
- `--only X --config-dir <the default dir>` is what the `--only` error message
  tells the user to type, and it replaces the full five-check config with a
  one-check partial.
- The tlstore arm passes the agent straight to the launcher (`-- -X ...`),
  bypassing `run.sh` and therefore the "the JVM never got '$opt'" check that
  same fix stage added for exactly this. If the agent ever fails to attach,
  `check-tlstore.sh` still says all 19 classes instantiate and the 17 arms go
  unregistered with everything green. The harness does use the app's own
  `newInstance()` call, so the registrations it makes are the right ones -- what
  is missing is any assertion that they landed.
- `util.c` now `ExceptionClear`s what `extractFromAPK` throws, and the only
  remaining thrower is a failed `Files.copy`, which leaves a partial file whose
  mtime is *newer* than the apk. `AssetManager`'s mtime guard then never
  re-extracts it. ENOSPC part-way through an extract corrupts that asset for the
  life of the data dir, silently.
- The transplant guard now blocks on any fd or cwd under either tree, with the
  exe filter only on the environ arm: running it from inside `out/data/app.apk_`,
  or with a `tail -f` on the app's logs (which CLAUDE.md recommends), is refused
  as "an app is using this session". It also dropped the command-line signal that
  caught the *source* app during its startup window, before SQLite opens
  anything.
- `FileLog`'s move off `static final` rests on a premise nobody established:
  Native Image initialises application classes at run time by default, in which
  case the old shape already read the property at image runtime and the change
  was a no-op. Where the premise does hold, the old shape gave the analysis a
  constant `false` that dead-code-eliminates the whole Gson body -- which the new
  shape makes impossible in every configuration. Correctness now rests entirely
  on `-Dtmessages.tldump=0` reaching the image process, so the image build must prove it
  does.
- `README.md`'s hand-trace recipe writes `out/ni-config-boot`, but the default
  `--baseline` reads `out/ni-config-baseline-boot`. Following the "no baseline
  (see README)" note produces a directory the default never looks at.
- `AssetManager` caches a `null` for an apk that failed to open and never
  retries, and holds every opened `JarFile` in a static field for the life of the
  process. If `build-image.sh` ever puts it on `--initialize-at-build-time`, a
  live `ZipFile` in the image heap fails the build.

## The image-backed launcher, measured

Both trees dirty at the time of writing; nothing here is inferred from an
earlier session's log, every number was re-run from the current sources.

### What was built

atlas gained a second executable over the *same* `main.c`. The VM backend is a
per-target source file behind `src/main-executable-hotspot/vm.h`, the way atlas
already expresses "same launcher, different runtime" with `bionic_compat.c` vs
`glibc_compat.c`:

| target | backend file | VM |
| --- | --- | --- |
| `android-translation-layer-hotspot` | `vm_hotspot.c` | `libjvm.so`, linked, class path assembled |
| `android-translation-layer-image` | `vm_image.c` | a native-image `.so`, `dlopen`ed, no class path at all |

`vm_common.c` holds what must reach both: the `-D` set, the `jvm option:` echo
`run.sh` greps, and `vm_verify_properties()`, which reads every `-Dkey=value`
back out of `java.lang.System` and prints the value that arrived. It only reads:
see "the read-back does not repair" below. Both backends define `create_vm`, so
the two meson source lists are the only thing keeping them out of one binary.

The `image-launcher` meson option is `value: 'auto'` on purpose: `build-atlas.sh`
stamps the builddir with `"$JAVA_HOME $PORT_TRIPLE ${setup_args[*]}"`, so adding
`-Dimage-launcher=enabled` to `setup_args` would change the stamp and force
`meson setup --wipe` — which rebuilds skia. Nothing is passed to `meson setup`;
ninja's own regen picked the new target up.

### The acceptance criteria, and the one that is not reachable

`ldd` on the image launcher: no `libjvm.so` anywhere, and nothing `not found`
(the HotSpot binary legitimately shows `libjvm.so => not found`). `nm -D
--undefined-only` has no `JNI_CreateJavaVM` at all, where the HotSpot one has
`JNI_CreateJavaVM@SUNWprivate_1.1` — the `dlopen` design, asserted rather than
described. `build-atlas.sh` now checks all three on every build.

FR-5 holds on the new target. `libtranslation_layer_main.so` imports **sixteen**
launcher-shaped symbols, not eleven: `apk_path`, `atl_window`,
`get_app_data_dir` and thirteen `bionic_*`. Eleven of them are defined by each
launcher with identical `B`/`T` bindings; the other five
(`bionic_eglChooseConfig`, `bionic_eglCreatePbufferSurface`,
`bionic_eglGetCurrentSurface`, `bionic_eglPresentationTimeANDROID`,
`bionic_eglQuerySurface`) are defined by `libandroid.so.0`, which is a
`DT_NEEDED` of the library itself — so they resolve, from the other provider,
and always did. `-rdynamic` is therefore not cosmetic on the new target, and
`build-atlas.sh`'s symbol loop now runs over both binaries with the import list
read out of the library rather than hardcoded, so a dropped `-rdynamic` fails
the build instead of crashing at startup.

**The third criterion as literally worded is not reachable with a stub, and is
not claimed.** atlas's own `--smoke-test` fires only after `FindClass`
`android/view/Display`, `android/atl/ATLRuntime` + `System.load` of
`libtranslation_layer_main.so`, `set_up_handle_cache`, `atl_window_new` and
`prepare_main_looper`, and then calls `android.os.SystemClock.uptimeMillis()`,
whose peer is in `libtranslation_layer_main.so`. Every one of those needs
api-impl inside the image. It moves to the real image build.

What replaces it is `--vm-check CLASS`, ~15 lines in `main.c` that run a class's
`main(String[])` the moment the VM exists and exit — before any framework setup,
so it works against a VM containing nothing but that class. `--run-class` cannot
serve: it fires after the handle cache, the window and the looper.

### The stub, and the numbers

`build-image.sh --stub` -> `out/image-stub/libatl-vm-stub.so`, 14,775,808 B, in
32 s wall (native-image's own line: 29.5 s), peak RSS 0.82 GB, for one class.
Deliberately not named `libmercurygram.so`, so a stub can never be mistaken for
the real image or picked up by `$PORT_IMAGE_LIB`. Its `jni-config.json` is a
heredoc fixture, not metadata: FR-4 governs `out/ni-config`, which no script
here touches.

`launcher/image-smoke-test.sh` runs the identical `--vm-check VmCheck` command
on both launchers, HotSpot first, so a failure separates a wrong harness from a
wrong image. Both pass; two logs, `out/image-smoke-hotspot.log` and
`out/image-smoke.log`.

### The PRD's first open question, answered: `-D` works, all of it

> does `JNI_CreateJavaVM` in an image accept the launcher's options, or must the
> launcher filter down to nothing?

**10 options passed, 10 accepted, all 10 readable back from Java with the value
they were given.** `launcher/image-smoke-test.sh` asserts that count rather than
printing it: `jvm option: -D…` lines in, `vm property: … (from -D)` lines out,
and the run fails if they differ. Every one is readable *inside the image*
(`VmCheck` prints them from the other side of JNI):

```
image: VM created with 10 options
JVM launched successfully
vm property: Build.VERSION.SDK_INT=28 (from -D)
vm property: atl.apk.path=.../out/app.apk (from -D)
vm property: atl.framework.res.path=.../out/atlas/framework-res.apk (from -D)
vm property: atl.data.dir=.../out/image-smoke-data/app.apk_/ (from -D)
vm property: atl.app.id=com.example.demo_application (from -D)
vm property: java.library.path=... (from -D)
vm property: tmessages.native.path=.../out/libtmessages.so (from -D)
vm property: tmessages.tldump=0 (from -D)
vm check: alive on Substrate VM 21.0.2+13
vm check: libjvm.so mapped: no
vm check: mapped: .../out/image-stub/libatl-vm-stub.so
vm check: all 5 required properties reached Java
```

So the launcher keeps the whole `-D` block verbatim on the image path. What it
drops is only what an image has no notion of: `-Djava.class.path`,
`-agentlib:*`, `-XX:*`, `-Xcheck:jni`, `--add-opens`. `--api-impl-jar`,
`--classpath`, `$JDWP_LISTEN` and `$ATL_CHECK_JNI` are warned about, not
refused, so one argv drives both launchers.

`vm_verify_properties()` runs on the HotSpot path too, and tracing it there is
the only way `java.lang.System` gets into `jni-config.json` (it is not there
today, while `android.view.Display`, `android.atl.ATLRuntime`,
`android.content.Context`, `android.app.Activity` and
`android.content.ContentProvider` are).

**The read-back does not repair.** An earlier shape of this function called
`System.setProperty` whenever the value read back differed, which on HotSpot is
a write, not a check: `java -Dsun.jnu.encoding=XYZ` reports `UTF-8`, because the
JVM refuses the value, and the launcher was putting `XYZ` back. It now reports
what arrived and changes nothing. A miss is fatal only for the properties the
launcher assembles itself (the framework cannot boot without them); a caller's
`-X -Dkey=value` that the VM normalised is printed as
`vm property: sun.jnu.encoding=UTF-8 (the VM's own value, -D asked for XYZ)` and
the run carries on.

### `ignoreUnrecognized = JNI_TRUE` on the image path, and why

The HotSpot backend keeps `JNI_FALSE`, bit-identically. The image backend uses
`JNI_TRUE`, and both halves are measured. On an image the flag governs the
`-XX:` namespace and nothing else: every other string is accepted regardless,
and an unknown or unparsable `-XX:` name is otherwise fatal — *fatal and
silent*, `JNI_CreateJavaVM` returning `JNI_ERR` having named neither the option
nor a reason. There is no recovery: a second `JNI_CreateJavaVM` in the same
process after a failed one hangs (GraalVM CE 21.0.2), so the two-stage
"retry with no options" ladder the plan proposed is not available.

Verified with a deliberate `-X -XX:NoSuchOptionAtAll=1` through `run.sh`'s own
escape hatch: `image: VM created with 9 options`, `vm check: alive on Substrate
VM 21.0.2+13`, exit 0. Nothing is lost, because the image path assembles no
`-XX:` itself and a `-D` cannot be in that namespace. The launcher does *not*
claim "none rejected" — with `JNI_TRUE` a bad `-XX:` is dropped silently and the
image reports neither, so the honest evidence is the per-property read-back, not
the option count.

### Two `main.c` fixes the split turned up

- `load_translation_layer`'s failure hint named `--api-impl-jar`, an option the
  image ignores. It now names neither backend's cause as if it were the only one.
- `FindClass("android/view/Display")` had no exception check, so a VM without the
  framework reported the *next* miss (`android.atl.ATLRuntime`) and read as a
  broken `--api-impl-jar`. Checked now, which is what makes a stub run through
  `run.sh --image` say what is actually wrong. Cannot fire on a working HotSpot
  boot; re-verified below.

### FR-2: the HotSpot path, re-run from these sources

`run.sh --seconds 25`: exit 0, "run ok: booted to the main activity, no uncaught
exceptions in 25s", `JVM launched successfully` at line 14, `boot: application
created`, `boot: content providers created`, `boot: Application.onCreate
returned`, `boot: main activity started`, and 0 lines matching
`^(error: exception during|Exception in thread|uncaught exception)`.
`launcher/smoke-test.sh`: "smoke test passed: JVM booted, translation layer
loaded, 960px window, clean exit". `build-atlas.sh`'s own class checks
(`PortClassCheck`, 2761 `ViewSignatureCheck` views) all pass.

The visible change on the HotSpot path is eleven new
`vm property: <key>=<value> (from -D)` lines in `out/run.log`, all eleven saying
`(from -D)` on a real boot. It is not purely additive: a launcher-assembled
property that does not arrive now exits 1 inside `create_vm` — deliberately, it
is the assertion the image path needs — and a caller `-X -D` the VM normalises
prints a line saying so. Option *order* moved slightly — `--add-opens` now sits
after the locale pair instead of before it — which no consumer depends on.

### What the real image must not get wrong

Both measured on a probe image, not assumed:

- `--add-opens=java.base/java.io=ALL-UNNAMED` must be a `native-image` **build**
  argument. Passed at VM creation an image accepts it and does nothing:
  `FileDescriptor.class.getDeclaredField("fd").setAccessible(true)` throws
  `InaccessibleObjectException`, so `FileDescriptorUtils.FD_FIELD` would be null
  and `AssetManager.openFd`, `Parcel` and `ParcelFileDescriptor` would all throw.
  Rebuilding the probe *with* the build-time flag made the identical code print
  `fd field accessible, value=1`, at a cost of ~2 s and 4 kB. `build-image.sh
  --stub` already passes it; the full build must too.
- `org.telegram.messenger.FileLog` must never go on
  `--initialize-at-build-time`. Measured both ways on a class shaped exactly like
  it: with run-time initialisation (the default) `-Dtmessages.tldump=0` arrives
  and the dumper stays off; with the class initialised at build time the same
  `-D` reads back `null` and the dumper turns back **on**, which reflects over
  all of `TLRPC$*` and voids the dumper removal's whole reduction. Same hazard class for
  `android.os.Build$VERSION` / `android.os.SystemProperties` (they would bake the
  build host's `SDK_INT`) and for `android.content.res.AssetManager` (a live
  `ZipFile` in the image heap fails the build outright).

Also, from the same probe: `-agentlib:native-image-agent` is accepted and
silently ignored by an image, so tracing stays a HotSpot-only operation — `--image`
and `trace-metadata.sh` do not compose. `-Djava.class.path` is accepted and the
property is set, but it does not affect class loading (closed world), and it
reads as the empty string when unset. `JNI_GetDefaultJavaVMInitArgs` reports
`JNI_VERSION_1_8` and the `version` field is not validated at all, so
`main.c`'s `JNI_VERSION_1_8` needs no change.

### Left open by the launcher work

- `run.sh --image` is wired end to end (launcher selection, no
  `$JAVA_HOME/lib/server` on `LD_LIBRARY_PATH`, `--vm-library`, the
  `/proc/<pid>/maps` read while the process is alive) but cannot boot until a
  real image exists. Against the stub it now stops at the first honest error,
  `error: exception during looking up android.view.Display`, which is the real image's problem.
- `PORT_LAUNCHER=image` selects the image in `run.sh`, and in the four checks
  that boot through `run.sh` (they take `$PORT_LAUNCHER_BIN` from `env.sh`, so
  their `[ -x ]` precondition and their `pkill` follow whatever ran). The four
  `--run-class` checks still name the HotSpot binary on purpose: they hand the
  launcher a class path, which an image has no notion of. Making those work is
  a parity-check job.
- `transplant-session.sh` was **not** hotspot-only, contrary to an earlier note
  here: its exe filter is `android-translation-layer*` (line 102) and its other
  two arms scan fds and cwds, so an image launcher is caught. `trace-metadata.sh`
  does kill by the hotspot path (line 162), which is correct now that it refuses
  to run with `PORT_LAUNCHER=image` — an image ignores `-agentlib` silently, so
  a traced image run would produce an empty config and say nothing.
- `jni-config.json` has no `java.lang.System` and no `android.os.SystemClock`
  entry, both of which the launcher itself looks up by name. The fix is a trace
  that exercises them (FR-4), not a hand edit: `vm_verify_properties` now runs on
  the HotSpot path so the first is traceable, and adding `launcher/smoke-test.sh`
  to `trace-metadata.sh`'s check list would cover the second.

## Launcher review: what the two reviews changed, and the state it landed in

Two reviews ran over the section above — an acceptance check and an adversarial
regression pass. Thirteen findings between them; this is the disposition and the
re-run evidence, all of it from the sources as committed (atlas
`mercurygram/openjdk-port`, this repo `ralph/graalvm-native-image`), on
2026-08-11.

### The one that was a real regression on the HotSpot path

`vm_verify_properties()` did not only read the properties back. When a value
read back differently it called `System.setProperty` and wrote the command-line
value into the running VM. On HotSpot that is a mutation of a path FR-2 says
must not change: `java -Dsun.jnu.encoding=XYZ -XshowSettings:properties` prints
`sun.jnu.encoding = UTF-8`, because the JVM refuses the value, and the launcher
was putting `XYZ` back.

It reads and reports now, never writes. The keys the launcher assembles itself
are recorded from `vm_common_properties()`'s own output (so a property added
there cannot be left out of the check), and only those are fatal when they do
not arrive — the framework cannot boot without them. Anything the caller passed
with `-X -D` is the caller's, and a VM that normalised it says so:

```
jvm option: -Dsun.jnu.encoding=XYZ
vm property: sun.jnu.encoding=UTF-8 (the VM's own value, -D asked for XYZ)
vm check: alive on OpenJDK 64-Bit Server VM 21.0.11+10-1-deb13u2-Debian
```

exit 0, where the same command previously reported `sun.jnu.encoding=XYZ (set
through System.setProperty)`. The stub image's `jni-config.json` fixture lost
its `setProperty` entry with it.

### The rest, in the order they would bite

- **`meson.build` could not disable the image target.** The block was guarded by
  `get_option('image-launcher').allowed()`, true for the default `'auto'`, and
  the `dependency('jni')` inside it had no `required:`, so it was mandatory: a
  host without JNI headers failed configure instead of degrading, and
  `-Dhotspot-launcher=disabled` still built a launcher. It is
  `dependency('jni', required: get_option('image-launcher'))` now, with the
  target guarded on `.found()`, which is what the hotspot block does one screen
  above.
- **`build-atlas.sh`'s FR-5 check tested a hardcoded eleven names.** The library
  imports sixteen. The list now comes out of
  `nm -D --undefined-only libtranslation_layer_main.so`, and a symbol counts as
  provided if either the launcher or `libandroid.so.0` defines it — which is how
  the five `bionic_egl*` the launchers do not define have always resolved.
  Measured after the change: `16` launcher-shaped imports, `11 from the
  launcher, 5 from libandroid.so.0`, identical for both binaries.
- **`run.sh`'s "no libjvm.so in the process" assertion could silently not run.**
  `/proc/<pid>/maps` was read once, after the wait loop, and that loop also ends
  when the launcher has already exited — an early exit left the variable empty
  and the whole check was skipped behind `[ -n "$launcher_maps" ]` while the run
  still printed `run ok`. The snapshot is now taken during the run, kept, and a
  missing one is `exit 1`. Demonstrated both ways against a `sleep` that ends
  before the loop does: old shape `0 bytes of maps after the process ended`, new
  shape `2330 bytes`.
- **`launcher/image-smoke-test.sh` printed the property counts instead of
  asserting them.** "10 by -D, 0 by System.setProperty" was an `echo`; nothing
  failed if a `-D` stopped arriving. It now requires one
  `vm property: … (from -D)` line per `jvm option: -D…` line, and prints
  `properties: 10 passed as -D, all 10 readable from Java as themselves`.
- **`main.c` looked up `java.lang.String` without a check**, in both
  `--run-class` and `--vm-check`, and handed a possibly-NULL class to
  `NewObjectArray`. On an image whose `jni-config` omits `java.lang.String` that
  reports the miss as a failure of whatever ran next — the exact confusion the
  `android.view.Display` check in this same story exists to prevent. One
  `empty_string_array()` helper with the check in it, used by both.
- **`build-all.sh`'s image step guarded on `native-image` being present, not on
  `PORT_CROSS`.** `native-image` exists on a cross host too, so
  `PORT_ARCH=arm64 ./build-all.sh` walked into `build-image.sh`'s own FR-6
  guard. It has the `PORT_CROSS` check now, like every other step that builds
  something native.
- **`PORT_LAUNCHER=image` reached `run.sh` and nothing else.** The four checks
  that boot through `run.sh` (`check-chatlist.sh`, `check-messages.sh`,
  `check-mtproto.sh`, `check-emoji.sh`) verified one binary, ran another, and
  their `pkill -f "^$launcher "` could not match what they started. They take
  `$PORT_LAUNCHER_BIN` from `env.sh` now. The four `--run-class` checks keep
  naming the HotSpot binary, with a comment saying why: they pass a class path,
  which an image has no notion of. `trace-metadata.sh` refuses
  `PORT_LAUNCHER=image` outright — an image accepts `-agentlib` and ignores it,
  so a traced image run would write an empty config and say nothing. An
  unknown `PORT_LAUNCHER` no longer falls back to hotspot: `env.sh` warns and
  the name goes into the path, so `run.sh` says `no launcher at
  …/android-translation-layer-bogus` and exits 1.

Two findings were rejected as facts, not as concerns. `transplant-session.sh` is
not hotspot-only (its exe filter is `android-translation-layer*`, line 102, plus
two name-agnostic arms), and the five `bionic_egl*` symbols neither launcher
defines are not a hole: `libandroid.so.0`, a `DT_NEEDED` of
`libtranslation_layer_main.so`, defines all five.

### The numbers, re-measured after the fixes

| | |
|---|---|
| `android-translation-layer-hotspot` | 136,568 B |
| `android-translation-layer-image` | 135,256 B |
| stub image `out/image-stub/libatl-vm-stub.so` | 14,775,808 B, one class |
| stub build | 69 s wall on a loaded host (`Finished generating 'libatl-vm-stub' in 1m 7s`), peak RSS **0.88 GB**, 171 GCs |
| `build-all.sh --only image` (build + smoke test) | 54 s |
| atlas rebuild for both launchers | 12 ninja targets, no `meson setup --wipe`, no skia |

The stub is one class. Whatever the real image costs, the real build measures from
scratch; nothing here scales to it.

### What the image VM takes and what it drops

Accepted and delivered, all ten, every time: `-Djava.library.path`,
`-DBuild.VERSION.SDK_INT`, `-Datl.apk.path`, `-Datl.framework.res.path`,
`-Datl.data.dir`, `-Datl.app.id`, `-Duser.language`, `-Duser.country`, and the
two `run.sh` adds through `-X`, `-Dtmessages.native.path` and
`-Dtmessages.tldump`. That answers the PRD's first open question — *does the
Invocation API accept the option set the launcher passes, or does the launcher
have to filter down to nothing?* — with **it accepts all of it**; the launcher
filters nothing and only omits what an image has no notion of.

Not assembled on the image path, each for a measured reason:
`-Djava.class.path` (accepted, and the property is set, but class loading is
closed-world so it does nothing and reads back as the empty string),
`-agentlib:*` (accepted, silently ignored — so `--image` and
`trace-metadata.sh` do not compose), `-XX:*` (an unknown name is fatal *and*
silent, which is why the image backend uses `ignoreUnrecognized = JNI_TRUE`),
`-Xcheck:jni` (HotSpot), `--add-opens` (accepted, does nothing; on an image it
has to be a `native-image` build argument).

**`-Dtmessages.tldump=0` reaches the image process.** That was left open by the
second review of phase 1-2 — `FileLog`'s move off `static final` made the TL
dumper's correctness depend on the property arriving — and it is now measured
end to end on the stub: `jvm option: -Dtmessages.tldump=0` →
`vm property: tmessages.tldump=0 (from -D)` (read back through
`java.lang.System` from the launcher) → `vm check: tmessages.tldump=0` (printed
by `VmCheck` from inside the isolate). The caveat that survives is the other
half of the same finding: this holds because the class reads the property at run
time. `org.telegram.messenger.FileLog` on `--initialize-at-build-time` would
read it during the build, get `null`, and turn the dumper back on.

### What the stub smoke test proves, and what it does not

Proves: the launcher `dlopen`s the image and finds `JNI_CreateJavaVM` in it
(`image: opened …`, and the resolved path, not the requested one);
`JNI_CreateJavaVM` accepts the option set; every `-D` crosses into Java with the
value it was given; `FindClass` + `GetStaticMethodID` + `CallStaticVoidMethod`
work against the isolate (`vm check: VmCheck.main() returned`); and no
`libjvm.so` is mapped, read from `/proc/self/maps` inside the process. The
identical `--vm-check VmCheck` command runs on the HotSpot launcher first, so a
failure separates a wrong harness from a wrong image.

Does not prove: anything about the framework. The launcher's third acceptance
criterion as written asks for atlas's own `--smoke-test`, which fires only after
`android/view/Display`, `android/atl/ATLRuntime` + `System.load`,
`set_up_handle_cache`, `atl_window_new` and `prepare_main_looper`, and then
calls `android.os.SystemClock.uptimeMillis()`. Against the stub it stops at the
first of those: `error: exception during looking up android.view.Display`,
`java.lang.NoClassDefFoundError`, exit 1. That is the real image's starting line. The
PRD records the criterion as unmet.

The negative controls, so a green run is not a no-op: `--vm-library
/nonexistent/nope.so` → `error: cannot open the image library …`, exit 1;
`--vm-check NoSuchClassHere` → `error: exception during looking up the
--vm-check class`, `NoClassDefFoundError` raised inside
`com.oracle.svm.core.jni.functions.JNIFunctions.FindClass`, exit 1;
`--vm-library` on the HotSpot launcher → `error: --vm-library belongs to
android-translation-layer-image; this launcher links libjvm`, exit 1.

### FR-2, re-run after every fix

`run.sh --seconds 25`: exit 0, "run ok: booted to the main activity, no uncaught
exceptions in 25s", `JVM launched successfully` at line 14, `boot: application
created`, `boot: Application.onCreate returned`, `boot: main activity started`,
0 lines matching `^(error: exception during|Exception in thread|uncaught
exception)`, and 11 `vm property:` lines of which 11 say `(from -D)`.
`launcher/smoke-test.sh`: "smoke test passed: JVM booted, translation layer
loaded, 960px window, clean exit". `check-chatlist.sh` (the check whose launcher
line changed): exit 0, 129 dialogs, the list scrolled.
`check-extract-apk.sh` and `check-native-loader.sh`: exit 0.
`build-atlas.sh`: `all 3 checks passed`, `ok 2761 views can enumerate their
methods`.

### Open going into the real image build

- **The real image is unbuilt.** `build-image.sh` with no flag prints its inputs
  and exits 2. `run.sh --image` is wired end to end and stops at
  `android.view.Display` against the stub.
- **`--add-opens=java.base/java.io=ALL-UNNAMED` must be a build argument**, and
  `java.io.FileDescriptor` appears in no file under `out/ni-config`, so nothing
  will warn about it. Without it `FileDescriptorUtils.FD_FIELD` is null and
  `AssetManager.openFd`, `Parcel` and `ParcelFileDescriptor` throw.
- **`FileLog` must stay off `--initialize-at-build-time`**, as must
  `android.os.Build$VERSION` / `android.os.SystemProperties` (they would bake
  the build host's `SDK_INT`) and `android.content.res.AssetManager` (a live
  `ZipFile` in the image heap fails the build outright).
- **`jni-config.json` still has no `java.lang.System` and no
  `android.os.SystemClock`**, both looked up by name by the launcher itself. The
  fix is a trace that exercises them (FR-4), not a hand edit:
  `vm_verify_properties` now runs on the HotSpot path, so the first is
  traceable, and adding `launcher/smoke-test.sh` to `trace-metadata.sh`'s check
  list would cover the second.
- **The `--run-class` checks are still HotSpot-only** (`check-native-loader.sh`,
  `check-dump-hprof.sh`, `check-extract-apk.sh`, `check-tlstore.sh`): they hand
  the launcher a class path. The parity checks decide what their image equivalent is.
- **A second `JNI_CreateJavaVM` in the same process after a failed one hangs**
  (GraalVM CE 21.0.2). There is no retry ladder available; a failed image VM
  creation is the end of the run.

## The first full image, measured

`linux-port/build-image.sh` (no flag) built `out/image/libmercurygram.so` over
api-impl + shim + the 93 classpath jars on 2026-08-11, atlas
`mercurygram/openjdk-port` e0ee8e39, GraalVM CE 21.0.2+13.1. Three builds: two
attempts with one fix between them, then a third re-run after the review's
script fixes so the shipped `.so` comes from the committed `build-image.sh`. No
metadata was hand-edited and nothing under `out/ni-config` was touched.

The numbers below are the third build's — `out/image/build-stats.env`,
`build.log`, `build-argv.txt` and `reports/*_094316.csv` all describe it.

| | |
|---|---|
| `out/image/libmercurygram.so` | 247,463,768 B |
| wall clock | 261 s (`Finished generating 'libmercurygram' in 4m 18s`) |
| peak RSS, whole process tree | 8,821 MB (native-image's own line: `Peak RSS: 8.57GB`) |
| builder cap that held | `-J-Xmx12g`, `--parallelism=8` |
| analysis | 106.7 s @ 3.49 GB; 40,459 reachable types, 189,235 reachable methods |
| image content | 120.4 MB code (111,689 compilation units), 88.5 MB heap (678,898 objects, 60 resources) |
| where the code came from | 94.3 MB `TMessagesProj.jar`, 11.7 MB `java.base`, 3.1 MB `api-impl.jar` |

The build repeats: the second build of the same inputs took 262 s and peaked at
9,050 MB, and its `.so` was 247,467,864 B — 4,096 bytes and ~2.5 % of the peak
apart. Treat the size and the RSS as ±1 page and ±0.3 GB, not as exact
constants.

`-J-Xmx12g` was never approached: the builder reported 10.67 GB available and
peaked at 8.6-9.0 GB, so **12 GB is the working number, not a ceiling that had to
be found**. This host's swap was already 100 % used before any of these builds
(20,478 MB, from earlier sessions) and was exactly as full afterwards — the
builder forced no new paging; free memory bottomed out around 1-2 GB with
~10 GB still reclaimable from cache, and the machine stayed usable. 8 threads
gave a CPU load of 5.4-5.6, so the build is not thread-bound and lowering
parallelism further would cost time without saving much memory.

Not a fallback image, three ways: `--no-fallback` was passed, the build log has
zero occurrences of `fallback`, and `objdump -p` shows exactly two `DT_NEEDED`
entries, `libz.so.1` and `libc.so.6` — no `libjvm.so` and no undefined JVM
symbol. `nm -D` exports `JNI_CreateJavaVM`, `JNI_GetCreatedJavaVMs` and
`JNI_GetDefaultJavaVMInitArgs`.

### The one fix, and the error that justifies it

`--initialize-at-run-time=org.telegram.messenger.FileLog`. Attempt 1 built the
`.so` but failed `check_class_initialization` on an observed report line:

```
org.telegram.messenger.FileLog, BUILD_TIME, class proven as side-effect free before analysis
```

Honest caveat, because the gate's own message overstates it: `FileLog`'s
`<clinit>` is property-free as the code stands. The dumper fix moved the
`tmessages.tldump` read into `tlDumpEnabled()`, which caches into the *mutable*
`Boolean tlDump` on first use, so a build-time `<clinit>` would not in fact have
baked the dumper back on. The flag is therefore a guarantee rather than a repair
of a live bug — it keeps that class's statics answering for the running process
whatever a later edit does — and it is in the script as a justified default, not
in `$PORT_IMAGE_INIT_AT_RUNTIME`, so a plain `build-image.sh` is correct.
`android.os.Build$VERSION` and `android.os.SystemProperties` were `RUN_TIME` on
their own in every build; the gate is a regression check on them, as designed.

The flag moves *that class*, and nothing else: `FileLog`'s 16 nested classes and
lambdas (`FileLog$ANRDetector`, `FileLog$TLObjectDeserializer`, nine
`FileLog$$Lambda…`) are still `BUILD_TIME` in the shipped image. Harmless as the
code stands — `FileLog.java:108` is the file's only `System.getProperty` and it
is on the outer class — but the guarantee is narrower than "FileLog is a
run-time class", so the gate now prints that count on every build.

No other `--initialize-at-run-time`, no `--trace-class-initialization` and no
substitution was needed. The predicted image-heap violations (a live `JarFile`
from `AssetManager`, `Thread`, `FileDescriptor`) did not happen:
`android.content.res.AssetManager` is `BUILD_TIME` by native-image's
"proven side-effect free" heuristic, and its static state was empty at build
time, so nothing illegal reached the heap. The shipped image's tally is 33,904
`BUILD_TIME`, 6,841 `RUN_TIME`, 411 `SIMULATED` and 88 `RERUN` of 41,244 rows;
that is the 21.0.2 default (`StrictImageHeap` is off) and it held.

`AssetManager` staying build-time is accepted, not fixed. Pinning it would be a
flag with no observed error behind it, which the image build forbids; what makes it safe
today is that its `<clinit>` only sets constants, `sSync = new Object()`,
`apk_paths = null` and an empty `open_apks` map (`AssetManager.java:99,698`). Any
future `<clinit>` there that reads `atl.apk.path` or opens an apk would bake the
build host's answer into the image, and the build would not say so — the gate
reports its kind on every build for exactly that reason.

### What the build warned about and what it means

Eleven `Warning:` lines before stage 1, all from
`-H:+WarnAboutMissingReflectionOrJNIMetadataElements`, all of them a config
entry naming something the image classpath does not have. They are the image run's
list, not build failures:

- `org.telegram.ui.LaunchActivity.onBackPressed()` could not be registered:
  `NoClassDefFoundError: android/app/PictureInPictureParams`. This one is worth
  reading twice — `LaunchActivity` is one of the three roots that make the app
  reachable at all.
- `android.view.View$AttachInfo`, `android.widget.Editor`,
  `org.kxml2.io.KXmlSerializer`, `kotlin.reflect.jvm.internal.ReflectionFactoryImpl`,
  `com.whatsapp.util.Log`: classes in the traced config that api-impl, the shim
  and the jars do not define.
- Fields `View.mScrollY`, `PopupWindow.mOnScrollChangedListener`,
  `ScrollView.mEdgeGlowTop`, `TextView.mCursorDrawableRes`: AOSP-internal
  fields the app reflects on and atlas's widgets do not have.
- `sun.security.provider.NativePRNG.<init>(SecureRandomParameters)`.

### The PRD's two open questions, as far as a build can answer them

**"How long, and how much RAM, does analysis over 112 MB of jars take?"**
Answered, and it is not the blocker it was written up as: **106.7 s at 3.49 GB**
for the analysis stage, 261 s and 8.8 GB peak for the whole build, on 8 threads
of a 12-core host with a 12 GB builder cap that was never reached. Per-stage:
init 9.1 s, analysis 106.7 s, universe 19.3 s, parsing 10.7 s, inlining 5.4 s,
compiling 61.1 s, layout 26.1 s, image write 16.3 s — 35.2 s of the total in
220 GCs. A rebuild is therefore a 4.5-minute loop, not an overnight one, which
is what makes the fix-and-rebuild cycle affordable.

**"Does the image's name-based binding cover the `Java_org_telegram_*`
symbols with only `jni-config` entries?"** Partly answered, and the question's
premise is wrong in a useful way. `jni-config` is about *native → Java* lookups;
a Java → native call needs no entry at all, only for the declaring method to be
reachable. Of the 13 classes that own an exported symbol, 12 are absent from
`jni-config` and only `ConnectionsManager` is there — and that is for the
opposite reason, because native code calls back into it. Measured on
`out/libtmessages.so`: 129 exported `Java_*` symbols, 96 of them
`Java_org_telegram_*` across those 13 classes (26 `Utilities`, 13 `Intro`, 23
`org.telegram.SQLite.*`, 16 `RLottieNative`/`AnimatedFileNative`, …), plus 76
more methods bound
by `RegisterNatives` tables (44 in `TgNetWrapper.cpp`, 32 in
`voip/tg_voip_jni.cpp`) which export no symbol at all. The PRD's "161" is a
count of neither set; use these numbers.

The image gives no build-time list of what it will bind. `strings` on
`libmercurygram.so` finds 196 mangled `Java_*` names, all of them `java.base`
natives that Substrate links statically, and **zero** `Java_org_telegram_*`:
the app's natives go through `JNINativeLinkage`, which stores the declaring
class, method name and signature separately and mangles at first call (the
class and method strings are in the image: `org/telegram/messenger/Utilities`,
`aesIgeEncryption`, `columnLongValue`). So coverage is a run-time fact by
construction, and the honest answer stays "running it will tell us" — the first
image run already got far enough to prove that much of it works (below).

### Review fixes to `build-image.sh` after the first green build

Six defects, all in the script or the write-up, none in the image:

- `--clean` did `rm -rf "$(dirname "$PORT_IMAGE_LIB")"` before any input check.
  `$PORT_IMAGE_LIB` is an environment override, so that dirname can be
  `$PORT_OUT` — one `PORT_IMAGE_LIB=out/libmercurygram.so build-image.sh
  --clean` would have deleted `out/ni-config`, the classpath jars and the apks,
  i.e. the FR-4 metadata the script exists to consume. It now deletes this
  build's own products by name and never a directory (reproduced in a scratch
  tree before and after: the seeded `ni-config` survives).
- A failed post-build gate left a fresh 247 MB `.so` on disk with nothing
  marking it rejected, and `run.sh --image` gates only on the file existing —
  attempt 1 left the tree in exactly that state. A rejected image is now
  deleted, and `build-stats.env` is removed before the build rather than after
  a success.
- The gate matched `grep -F "$class, "` anywhere on a line and took `head -1`.
  The report's Reason column contains class names too, so an unrelated row could
  have been read as a hazard's verdict. It is an exact first-column match now
  (`awk -F', ' '$1 == c'`), verified against attempt 1's report: still exits 1
  on `FileLog, BUILD_TIME`.
- Nothing recorded the builder's argv, and `--add-opens=java.base/java.io` in
  particular leaves no trace in the `.so` or in native-image's output — the one
  build argument whose absence would only show up as a null `FD_FIELD` at run
  time. Every build now writes `out/image/build-argv.txt` (16 lines, the `-cp`
  being one of them). Kept beside the log, not in it, so `grep fallback
  build.log` still describes the build and not the argv.
- A second attempt overwrote the first's `build.log`, which is why attempt 1's
  size and wall clock are no longer checkable (its two `reports/*.csv` survived
  and do corroborate the failure). The previous log is kept as `build.log.prev`.
- The write-up said "33,905 of ~40,700 classes" and "ten warnings"; the shipped
  build has 33,904 of 41,244 and eleven. Corrected above.

Not changed, deliberately: a hazard class that is *absent* from the report does
not fail the gate. Absent means never initialised in this image, which is the
one outcome that cannot bake a property in.

### The first image run, unscheduled, for the handoff

`PORT_IMAGE_LIB=… run.sh --image --seconds 25` was run once against the shipped
image, to hand the image run a starting point rather than a prediction. **The launcher's
prediction was wrong and the news is good**: nothing died in
`vm_verify_properties()`. The launcher opened the `.so`, created the VM with 10
options, read all ten `-D` properties back out of `java.lang.System`
(`tmessages.tldump=0` among them), `maps:` reported no `libjvm.so`, and the app
reached `onResume`, `onWindowFocusChanged`, `boot: main activity started` and
live tgnet requests — 8,576 lines of run log. So `java.lang.System` and
`android.os.SystemClock` resolve through JNI on an image without being in
`out/ni-config`; whatever registers them, it is not the traced config.

The run still exits 1, on one uncaught exception, and it is the warning the
build already named:

```
java.lang.NoSuchMethodError: org.telegram.ui.LaunchActivity.onBackPressed()V
	at com.oracle.svm.core.jni.functions.JNIFunctions.GetMethodID(JNIFunctions.java:431)
```

`reflect-config` asks for `LaunchActivity.onBackPressed()`, registering it fails
at build time with `NoClassDefFoundError: android/app/PictureInPictureParams`
(api-impl has no such class), and atlas then looks the method up by JNI at run
time and gets nothing. It is not fatal — the app keeps running past it — but it
is the image run's first fix and it belongs in atlas.

### Still open going into the image run

- **A green build proves the build, nothing else.** With `--shared` there is no
  main class, so the analysis roots are exactly the 63 `jni-config` + 122
  `reflect-config` entries. `run.sh --image` is the verdict, and the one run
  above is a smoke test, not that verdict.
- `LaunchActivity.onBackPressed()` — the missing `android.app.PictureInPictureParams`
  in api-impl (atlas fix, FR-1a), then a rebuild.
- The other ten build warnings: `android.view.View$AttachInfo`,
  `android.widget.Editor`, `org.kxml2.io.KXmlSerializer`,
  `kotlin.reflect.jvm.internal.ReflectionFactoryImpl`, `com.whatsapp.util.Log`,
  the four AOSP-internal fields and `NativePRNG.<init>`. Each is a traced entry
  the image classpath cannot satisfy; none stopped the build.
- **`android.content.res.AssetManager` is build-time initialised** by
  native-image's heuristic. Safe only because its statics are empty today.
- Native binding is unproven beyond what the one run exercised: 96 exported
  `Java_org_telegram_*` symbols and 76 `RegisterNatives` entries, none of them
  listed anywhere at build time.
- `--strict-image-heap` is recommended by 21.0.2 and would move ~34,000 classes
  off build-time init. Not adopted here: it is a different build, and this one
  wanted the first one.

## The image boots to the chat list

One atlas fix, one rebuild, one run. `run.sh --image --seconds 30` exits 0 with
`run ok: booted to the main activity, no uncaught exceptions in 30s`, and
`out/screenshots/us009-image-chatlist.png` is the chat list with live messages
timestamped during the run.

### The one framework stub the image run needed, and the error behind it

`android.app.PictureInPictureParams` — atlas `1bb39aeb`, a stub class with the
nested `Builder` the app calls (`setAspectRatio`, `setExpandedAspectRatio`,
`setSourceRectHint`, `setActions`, `setAutoEnterEnabled`, `build`) plus a no-op
`Activity.setPictureInPictureParams`, because `LaunchActivity`'s override calls
super on it. api-impl had no such class, so the build could not register
`LaunchActivity.onBackPressed()`:

```
Warning: Could not register method org.telegram.ui.LaunchActivity.onBackPressed()
for reflection. Reason: java.lang.NoClassDefFoundError:
android/app/PictureInPictureParams.
```

(Reflecting over LaunchActivity's declared methods loads the parameter type of
its `setPictureInPictureParams`.) atlas then looked the method up by JNI at run
time and got nothing:

```
java.lang.NoSuchMethodError: org.telegram.ui.LaunchActivity.onBackPressed()V
	at com.oracle.svm.core.jni.functions.JNIFunctions.GetMethodID(JNIFunctions.java:431)
```

That is the whole list — one stub, one error. The Builder stores what the app
sets and hands it back; nothing reads it and `Activity.setPictureInPictureParams`
drops it. `Builder.setActions` takes `List<?>` because api-impl has no
`RemoteAction` and the erased descriptor an app call site uses is the same either
way. Nothing under `org/telegram/**` was touched.

The build's warning list is 10 lines instead of 11 — the `onBackPressed` one is
gone and nothing new appeared. The shipped image is built from committed atlas
`1bb39aeb`: 247,476,056 B, 282 s, peak RSS 9,072 MB, two `DT_NEEDED`
(`libz.so.1`, `libc.so.6`), no `libjvm.so` in `/proc/<pid>/maps` during the run,
`ATLAS_REV="1bb39aeb"` in `build-stats.env`.

### Criterion 2 in full: what is left in `out/run.log`, and why

The criterion asks for no `ClassNotFoundException`, `NoSuchMethodError` or
missing-metadata error. After the fix a 30 s image run has **0
`NoSuchMethodError`, 0 `NoClassDefFoundError`, 0 `UnsatisfiedLinkError`** — the
handover exception from the image build is gone — but the log is not literally clean, and the
two things left are named rather than glossed:

- **15 `ClassNotFoundException`**: 1 `android.view.View$AttachInfo`, 14
  `android.widget.Editor`. A HotSpot control run has exactly the same two
  classes at exactly the same counts, so this is pre-existing port behaviour
  (below).
- **1 `com.oracle.svm.core.jdk.UnsupportedFeatureError: Trying to verify a
  provider that was not registered at build time: AndroidKeyStore version 1.0`**,
  in UnifiedPush's web-push key generation. This one *is* image-only and it *is*
  a build-time-registration error, i.e. a missing-metadata error in the
  criterion's sense. It is swallowed by the caller, HotSpot fails the same method
  five lines later for a different reason, and no working feature is lost — the
  mechanism is under the parity checks below, and it is recorded, not fixed.

So criterion 2 holds for everything the image itself introduced, with those two
exceptions written up. It is not ticked as a clean pass.

### The two remaining ClassNotFoundExceptions are the port's, not the image's

`out/run.log` still has `ClassNotFoundException: android.view.View$AttachInfo`
(once, from `androidx.core.view.WindowInsetsCompat$Impl20.loadReflectionField`)
and `android.widget.Editor` (14 times, from `EditTextBoldCursor.init`). A HotSpot
control run the same afternoon has **exactly the same two classes at exactly the
same counts, 1 and 14**, so this is pre-existing port behaviour and not an image
regression. Both are app/androidx reflection probes inside a `catch (Throwable)`
that log and carry on.

Deliberately not "fixed": an empty `AttachInfo` or `Editor` in atlas would let
the probe get one step further and then fail on the field it really wants
(`View.mAttachInfo`, `TextView.mEditor`), which changes app behaviour on both
backends to swap one logged exception for another. The error tags of the two
runs are otherwise the same set (`E/ContextImpl`, `E/tgnet`,
`E/ShortcutInfoCompatSaver`, `E/WindowInsetsCompat`, …) with no image-only line.

One image-specific detail, in case someone does stub them later. The image's
message is not HotSpot's:

```
java.lang.ClassNotFoundException: android.widget.Editor. This exception was
synthesized during native image building from a call to
java.lang.Class.forName(String) with constant arguments.
```

16 lines per run carry that suffix. The miss is baked into the binary, not
thrown by a lookup, so an atlas stub added later would fix HotSpot the moment
atlas is rebuilt and the image only after a `build-image.sh` as well. Same
counts, same app behaviour today; different mechanism.

## The parity checks on the image, and the one difference they found

Twelve runs on 2026-08-11 against that image (`out/image/libmercurygram.so`,
247,476,056 B, atlas `mercurygram/openjdk-port` with the `PictureInPictureParams`
stub, since committed as `1bb39aeb` and rebuilt to the same byte count): the four
`run.sh`-driven checks on the image, the
same four on HotSpot as the control, then the four on the image again, because a
driving check that passes once is not proof. **All twelve exited 0**, unmodified
apart from `PORT_LAUNCHER=image`.

| check | image #1 | HotSpot control | image #2 |
|---|---|---|---|
| `check-mtproto.sh` | 0 — `420 FLOOD_WAIT_79327` | 0 — `400 PHONE_NUMBER_INVALID` | 0 — `420 FLOOD_WAIT_78800` |
| `check-chatlist.sh` | 0 — 129 dialogs from cache4.db, list scrolled | 0 — 129 dialogs, scrolled | 0 — 129 dialogs, scrolled |
| `check-messages.sh` | 0 — 15 cached, sent + `updateMessageID` + incoming | 0 — same | 0 — same |
| `check-emoji.sh` | 0 — 110 glyphs, 18435 colours, `…😚` | 0 — 109 glyphs, same colours | 0 — 108 glyphs, same colours |

Each image run carries its own no-JVM evidence: `run.sh` read
`/proc/<pid>/maps` during the run and printed `maps: …/libmercurygram.so mapped,
no libjvm.so` in all eight, and every run ended in `run ok: booted to the main
activity, no uncaught exceptions`. Boot-to-checks-done wall clock is within 3 s
of HotSpot's on every check (chat list 26-27 s vs 28 s, messages 32-35 s vs 35 s,
emoji 37 s vs 40 s) — a like-for-like start-up number comes later, not from this.

The mtproto answer differs between runs, and the numbers say it is the server's
clock and not the backend: the two image runs got `FLOOD_WAIT_79327` and
`FLOOD_WAIT_78800`, a 527 s drop over the 517 s between them — one pre-existing
~22 h flood window counting down, which the HotSpot control in the middle
answered with `PHONE_NUMBER_INVALID` instead. All three are the error arm, which
is the only arm this environment can execute: with `APP_ID=0` the server never
sends a code, as recorded under the MTProto check above.

### The two logged `ClassNotFoundException`s are identical, per check, to HotSpot's

`android.view.View$AttachInfo` (androidx `WindowInsetsCompat`) and
`android.widget.Editor` (`EditTextBoldCursor.init`) appear in every run on both
backends, and the counts match **exactly**, per check and across both image
rounds:

| | mtproto | chatlist | messages | emoji |
|---|---|---|---|---|
| `View$AttachInfo` | 1 / 1 / 1 | 1 / 1 / 1 | 1 / 1 / 1 | 1 / 1 / 1 |
| `widget.Editor` | 31 / 31 / 31 | 14 / 14 / 14 | 18 / 18 / 18 | 21 / 21 / 21 |

(image #1 / HotSpot / image #2.) The count varies by check because it is one per
`EditText` the run creates, and it is reproducible to the unit — so these are the
port's pre-existing probes, unchanged by the image. The image run's reasoning for
leaving them alone still holds.

### The one real image-only difference: JCE provider verification

`org.unifiedpush.android.connector`'s web-push key generation fails on **both**
backends, once per run, in the same method — but for different reasons, and the
image's is a Native Image restriction:

```
image:   com.oracle.svm.core.jdk.UnsupportedFeatureError: Trying to verify a provider
         that was not registered at build time: AndroidKeyStore version 1.0
             at javax.crypto.JceSecurity.getVerificationResult(JceSecurity.java:333)
             at javax.crypto.KeyGenerator.getInstance(KeyGenerator.java:286)
             at …keys.WebPushKeysEntries23.getSecretKey(WebPushKeysEntries23.kt:115)
HotSpot: java.lang.ClassCastException: class android.security.keystore.KeyGenParameterSpec
         cannot be cast to class java.security.spec.AlgorithmParameterSpec
             at …keys.WebPushKeysEntries23.getSecretKey(WebPushKeysEntries23.kt:120)
```

Substrate verifies JCE providers at build time, and atlas builds its
`AndroidKeyStore` provider in Java at run time — an anonymous `new
Provider("AndroidKeyStore", 1.0, …)` handed to `Security.addProvider` in
`Context.java:141-145`, which is exactly the "version 1.0" the error names. A
provider that did not exist during analysis cannot be verified, so
`KeyGenerator.getInstance` rejects it five lines before the point where HotSpot
fails on atlas's `KeyGenParameterSpec` not implementing `AlgorithmParameterSpec`. Both
are swallowed by UnifiedPush and logged; both leave the app with no web-push
keys, which is the port's existing state (push is out of scope, and there is no
distributor on the desktop). So the image loses no working feature here, but it
does move the failure earlier, and **fixing atlas's `KeyGenParameterSpec` would
not be enough on the image** — a provider assembled at run time can never pass
build-time verification, so that path would also need the provider to exist
during analysis (registered from a build-time-initialised class, or declared to
the builder's security config). Recorded, not fixed: no check asks for it and
The parity checks forbid a build flag with no observed need behind it.

Counts: 1 per image run in all four checks (both rounds), 1 per HotSpot run in
all four.

### One non-reproducible log line, and why it is not the image's

`chatlist` image #1 logged twice:

```
org.telegram.tgnet.TLParseException: can't parse magic cd78e586 in
org.telegram.tgnet.TLRPC$upload_File. Source: NETWORK
    at org.telegram.tgnet.TLRPC$TL_upload_getFile.deserializeResponse(TLRPC.java:52903)
```

Not an image finding, for three reasons. `upload_File.TLdeserialize` is a
`switch` over magics in generated code, not reflection, so no metadata can be
missing. The app knows this particular magic: `TLParseException.java:18-19`
hard-codes `constructorId != 0xcd78e586` twice, so it is logged and deliberately
not reported as a scheme error. And it did not recur — not in image #2, not in
any HotSpot run — because which file the session downloads is server-side.

### What cannot run on the image, and the mechanism

The four `--run-class` checks — `check-tlstore.sh`, `check-dump-hprof.sh`,
`check-extract-apk.sh`, `check-native-loader.sh` — are HotSpot-only **by
construction**, not by regression. Each names
`$ATLAS_OUT/android-translation-layer-hotspot` directly (not `$PORT_LAUNCHER_BIN`)
and hands it `--classpath …:$PORT_OUT/tools`, a helper compiled per run. The
image has no class path and `out/tools` is not among the 95 `-cp` entries in
`out/image/build-argv.txt`, so the helper class does not exist inside the image.
Run anyway, that is exactly what happens:

```
$ android-translation-layer-image --vm-library …/libmercurygram.so \
      --classpath "…/shim.jar:…/classpath/*:…/out/tools" --run-class TLClassStoreCheck …
image: ignoring --classpath; the image has no class path
run-class: running TLClassStoreCheck.main() instead of creating the application
error: exception during looking up the --run-class class:
java.lang.NoClassDefFoundError: TLClassStoreCheck
exit 1
```

Making them image-capable would mean compiling each helper *into* the image,
i.e. a different image per check — which is why the PRD's Technical
Considerations already list "no `--run-class` on the image" as a debuggability
cost, not a gap to close. `check-tlstore.sh` was re-run on HotSpot for FR-2 and
passes: *all 19 classes in the store instantiate*.

`check-env.sh` and `check-graalvm.sh` boot nothing and are launcher-independent.

### Nothing was changed for the parity checks

No atlas commit, no metadata change: the three acceptance checks plus
`check-emoji.sh` passed against the image as they stand, twice, with
`PORT_LAUNCHER=image` as the only difference. `out/ni-config` was not touched.
(The `wait_for_log` anchor in the four checks was relaxed afterwards — see the
review section below — and every check was re-run on both backends after it.)

### Re-run after the atlas commit, on the rebuilt image

The image the twelve runs used was built from a dirty atlas checkout. After
committing the stub (`1bb39aeb`) and rebuilding, everything above was re-run
against the rebuilt `.so` — same size to the byte, same ten build warnings:

| run | result |
|---|---|
| `run.sh --image --seconds 30` | 0 — booted, chat list screenshot, `maps: … no libjvm.so` |
| `PORT_LAUNCHER=image check-chatlist.sh` | 0 — 129 dialogs, list scrolled |
| `PORT_LAUNCHER=image check-messages.sh` | 0 — 15 cached, sent + `updateMessageID` + incoming |
| `PORT_LAUNCHER=image check-mtproto.sh` | 0 — `420 FLOOD_WAIT_74918` (second attempt; see the flake below) |
| `PORT_LAUNCHER=image check-emoji.sh` | 0 — 109 glyphs, 18435 colours, tapped emoji sent |
| `run.sh --seconds 25` (HotSpot, FR-2) | 0 |
| `check-chatlist.sh` (HotSpot, FR-2) | 0 — 129 dialogs, scrolled |

`FLOOD_WAIT_74918` continues the same countdown the twelve runs recorded (79327,
78800, 76311), which is the server's clock and not a backend difference.

## The numbers, and the answer about jlink

Measured on 2026-08-11, x86_64, against the image built from atlas `1bb39aeb`
(`out/image/libmercurygram.so`, 247,476,056 B). **Success Metric 3 is not met as
written: the image starts faster and uses less memory, but the install is
51.7 MB bigger**, and the metric asked for both.

**That was overridden the same day.** The owner's decision is that a 24 % faster
cold start is the win that matters and the 51.7 MB is an acceptable price, so
the image is the preferred x86_64 desktop runtime. The measurements below are
unchanged by that — they are why the decision could be made — and the metric
stays recorded as not met, because the bytes are the bytes.

The click still ships jlink, but for a different reason than the numbers:
`native-image` cannot cross-compile and no arm64 image exists (FR-2, FR-6).

### Size: what actually changes, x86_64, apparent bytes of regular files

Only these files differ between the two runtimes. Everything else in a package —
`app.apk` (64,045,594 B), the native libraries, `framework-res.apk`, fonts — is
byte-identical either way and is left out of the swap on purpose.

| goes away with jlink | bytes |
|---|---|
| `out/classpath/*.jar` (93 jars, 83,995,583 of it `TMessagesProj.jar`) | 116,180,987 |
| `jvm/` — the click's own jlink of 14 modules, re-run on the x86_64 JDK | 76,593,423 |
| `out/atlas/api-impl.jar` | 2,935,758 |
| `out/atlas/android-translation-layer-hotspot` | 136,568 |
| `out/shim.jar` | 61,374 |
| **total** | **195,908,110** |

| comes in with the image | bytes |
|---|---|
| `out/image/libmercurygram.so` | 247,476,056 |
| `out/atlas/android-translation-layer-image` | 135,256 |
| **total** | **247,611,312** |

**Delta: +51,703,202 B (+26.4 % of the part that changes).** The image ships
none of the jars, api-impl or the shim: `vm_image.c` prints `image: ignoring
--api-impl-jar` and `image: ignoring --classpath`. The apks still ship — they
reach Java as `-D` file paths, not as class path entries.

Against a whole install, the arm64 click that ships today measures 324,352,711 B
of regular files, of which 196,623,677 B is its own jlink column (`jvm/`
77,315,670 + `classpath/` 116,241,858 + `api-impl.jar` 2,931,781 + the HotSpot
launcher 134,368) — within 0.4 % of the x86_64 column above, which is the only
cross-architecture claim made here. So an image build of the same tree would be
about **376 MB installed against 324 MB**, +15.9 %.

The jlink runtime itself was **not** taken from the PRD's 74 MB arm64 figure. The
click's own jlink invocation (same 14 `PORT_JVM_MODULES`, `--no-header-files
--no-man-pages --compress=zip-6`) was re-run on the x86_64 JDK 21.0.11:
76,593,423 B, against the arm64 `jvm/` at 77,315,670 B — same 19 modules in
`release`, 77 files each, within 1 %. The architectures are not the problem.

Two things the table hides, both measured:

- **Compressed, the image wins.** `gzip -6`: the `.so` is 80,735,126 B, while
  `jvm/` + the 93 jars + shim + api-impl + launcher come to 103,436,782 B —
  the image is ~22.6 MB smaller to download, because the jars are already
  deflated and re-compress by about a tenth while the `.so` compresses 3.1x.
  A click is shipped compressed, but the criterion says on-disk, and on disk
  the image is bigger.
- **Stripping buys nothing.** The `.so` is "with debug_info, not stripped", and
  `strip --strip-unneeded` takes it from 247,476,056 to 247,302,632 B: 173 KB,
  0.07 %. native-image's own breakdown is 120.41 MB code, 88.50 MB image heap,
  27.11 MB other — there is no debug bulk to remove.

### Start-up: cold, same definition on both, `measure-startup.sh`

`linux-port/measure-startup.sh` is the harness, committed with these numbers so the
number can be re-checked rather than believed. Per run it drops the page cache
(`sync; echo 3 > /proc/sys/vm/drop_caches`), waits 2 s, execs the launcher with
the argv `run.sh` builds, timestamps every launcher/liblog line, and samples the
X root window with `xwd` every ~100 ms. Runs alternate hotspot/image so drift
hits both columns. Two pixel events are kept apart, because conflating them
would flatter the image by ~3 s:

- `window_mapped` — the screen stops being black. That is GLFW's empty white
  window; the `.xwd` is written out and it is a blank rectangle.
- `first_frame` — the next sample whose pixels differ from that blank window.
  The `.xwd` is Telegram's chat-list skeleton with the "Connecting" title. This
  is the headline number. Resolution ±0.12 s.

Cold, n = 6 per backend (four runs on the pre-commit image, two on the rebuilt
one; they agree), seconds from exec:

| marker | HotSpot | image | delta |
|---|---|---|---|
| VM created | 0.82 [0.74..0.93] | 0.84 [0.77..0.98] | +0.02 |
| application created | 6.78 [6.68..6.84] | 6.21 [6.12..6.35] | −0.57 |
| window mapped | 6.82 [6.73..6.92] | 6.28 [6.18..6.41] | −0.54 |
| `Application.onCreate` returned | 7.70 [7.58..7.78] | 6.52 [6.40..6.63] | −1.18 |
| dialogs out of cache4.db | 8.95 [8.80..9.14] | 7.10 [6.95..7.25] | −1.85 |
| main activity started | 9.42 [9.30..9.59] | 7.11 [6.96..7.26] | −2.30 |
| **first frame** | **9.58 [9.45..9.81]** | **7.27 [7.08..7.39]** | **−2.31 (−24.1 %)** |

Warm (same harness, `--warm`, n = 2 each): first frame 8.26 vs 6.12 s, −25.9 %.
The win is the same hot or cold, so it is not I/O.

Creating the VM is a wash: 0.82 vs 0.84 s cold. Substrate's isolate is not
measurably cheaper than `JNI_CreateJavaVM` here, and the whole win is in what
runs after — class loading and first execution of app code.

Where the rest of the time goes, since it bounds how much any runtime change can
buy: **5.96 s (HotSpot) / 5.37 s (image) pass between "VM created" and
"application created" with no log line on either backend.** That is atlas's
native `Context.createApplication` parsing `app.apk` and `framework-res.apk`
through libandroidfw. It is 74 % of the image's 7.27 s. It is *not* a fixed
floor, though — the image is 0.59 s faster through it too, so about a quarter of
the total win happens inside that silent stretch and the rest after it.

### RSS at the chat list

Read from `/proc/<pid>/status` and `/proc/<pid>/smaps` at a fixed 75 s after
exec, with the pixel sampler stopped so nothing is poking the app. Proof it is
really at the chat list and not at a skeleton: an `.xwd` is captured at that
instant on both backends, and both show the populated 129-dialog list with
avatars and live timestamps.

| | HotSpot | image | delta |
|---|---|---|---|
| RSS | 589,007 KB [566,552..618,560] | 503,205 KB [492,316..520,580] | −85,801 KB (−14.6 %) |
| PSS | 546,572 KB [523,651..576,554] | 460,604 KB [449,061..478,258] | −85,968 KB (−15.7 %) |

The ranges do not overlap, but the spread is wide (±5 %) and RSS climbs the
whole run on both — HotSpot 519 → 570 MB, image 465 → 505 MB over the same
minute — so the number only means anything with the 75 s attached. Two sessions'
worth of runs put the gap between 57 MB and 100 MB; −86 MB is the pooled mean.
The image wins despite mapping a 247 MB `.so`: only touched pages are resident,
and there is no metaspace, no code cache and no JIT'd code.

### Verdict: the image does not replace jlink

Scored against the PRD's own rule — "a native image has to beat it on size *and*
start faster":

- **installed size: loses.** +51.7 MB, +15.9 % on a whole install. Not marginal,
  not a rounding artefact.
- **cold start: wins.** −2.31 s to first frame, −24.1 %, six runs each.
- **RSS at the chat list: wins.** −86 MB, −14.6 %. Not asked for; recorded.
- **download size: wins.** −22.6 MB compressed. Also not the criterion.

So: **no**, under the rule as written, and the rule should stay `AND`. The
narrower and more useful reading is that the image is a better *runtime* and a
worse *install*. `linux-port/click/` is unchanged and keeps shipping jlink
(FR-2); the image stays an opt-in second backend on x86_64, which
`PORT_LAUNCHER=image` already gives at no cost to the HotSpot path.

**The obvious lever does not exist on this toolchain, and that was checked, not
assumed.** A first draft of this write-up recommended rebuilding with `-Os` and
`--gc=serial` as "the cheapest experiment on the board". Both are wrong here:

```
$ native-image -Os -cp . H
Error: Invalid value 's' provided for option Optimize (expected 'b' or numeric value >= 0)
$ native-image --gc=G1 -cp . H
Error: In user 'G1' is not a valid value for the option --gc. Supported values are 'epsilon', 'serial'.
```

GraalVM CE 21.0.2 has no `-Os` (`-H:Optimize` takes `b`, 0..3), and serial GC is
already what this image uses — `out/image/build.log:21` says `Garbage collector:
Serial GC`, the version banner says `serial gc`, and the only alternative,
`epsilon`, never collects. So reopening Success Metric 3 that way means
upgrading the pinned GraalVM at `env.sh:29` first, not a 4.5-minute rebuild.
Nobody has measured what a newer native-image would save.

### arm64, if the verdict ever changes

It has not, so this is a contingency answer. `native-image` cannot
cross-compile — 21.0.2 offers no target option and GraalVM does not support it —
so an arm64 image needs an aarch64 native-image on an aarch64 host.

The good news, and the part most likely to be got wrong: **the arm64 build host
does not need the port's native build.** Every input to `build-image.sh` is
architecture-neutral — `api-impl.jar` and `shim.jar` (javac output, not dex), the
93 jars in `out/classpath`, and the JSON in `out/ni-config`. atlas, skia,
`libtmessages.so` and the launcher are not image inputs and stay in the existing
x86_64 clickable cross container. So it is "add one aarch64 step that eats
~120 MB of jars and emits a ~250 MB `.so`", not "port the build to arm64".

What such a host needs, from this build's own numbers (`build-stats.env`,
`build.log`): **9,072 MB peak RSS** for the whole process tree, against
`-J-Xmx12g --parallelism=8`, with native-image's own builder figure `Peak RSS:
8.95GB`; **282 s** wall on 12 x86_64 cores (`Finished generating … in 4m 39s`),
of which analysis is 111.7 s at 5.17 GB; about a GB of scratch plus the output;
GraalVM CE 21 for linux-aarch64 and a JDK 21 to stage the jars. So: 16 GB of
RAM, not 12.

Three options, and only the first is sane. Times are **estimates**, scaled from
the measurement above; none was run.

1. An aarch64 Linux server (8 vCPU, 16 GB): estimated 6-12 minutes a build. It
   is new infrastructure — `click/build.sh` is one command in one container
   today, and this splits it across two hosts with an artefact hand-off.
2. qemu-user on this x86_64 box: estimated 25-90 minutes, and the emulated
   builder still wants ~9 GB of guest RAM. This is what the PRD's Non-Goals call
   the opposite of what the click packaging exists to avoid.
3. On the phone: not viable. Peak RSS is 9.1 GB.

Two arm64 risks that are not about the build host:

- The metadata was traced on x86_64 with `ATL_NO_GPU=1`, because skia's Ganesh
  path crashes on this desktop's GL driver. The device runs the GPU path
  (`GPU rendering (Ganesh) on Adreno (TM) 740`). Classes reachable only there are
  not in `out/ni-config`, and under a closed world that is a
  `NoClassDefFoundError` on the device rather than a slow path. FR-4 says the fix
  is a check that exercises it, and no such check exists.
- The size verdict does not improve on arm64, and may get slightly worse: the
  shared column is fixed and the arm64 `jvm/` is within 1 % of the x86_64 one.

## Final review: every finding and what happened to it

Two reviews ran over phase 3 — one re-running the boot and parity claims, one
re-deriving the numbers. Fifteen findings; what follows is all of them, because a
dropped `LOW` is how a wrong number survives.

Fixed:

- **`-Os` / `--gc=serial` do not exist as a lever** (HIGH). The verdict's one
  actionable recommendation was unrunnable on the pinned toolchain. Re-checked
  by running both, quoted above; the recommendation is now "upgrade GraalVM
  first, and measure".
- **atlas was dirty** (MEDIUM, FR-1a in form). The `PictureInPictureParams` stub
  existed only as working-tree state. Committed as `1bb39aeb`.
- **`build-stats.env` claimed a revision that cannot build the artefact**
  (MEDIUM). It stamped `ATLAS_REV="e0ee8e39"` for a `.so` that demonstrably
  contains `android.app.PictureInPictureParams$Builder`. Two fixes: the stub is
  committed and the image rebuilt (`ATLAS_REV="1bb39aeb"`, same 247,476,056 B,
  same ten build warnings), and `build-atlas.sh` now appends `-dirty` to
  `ATLAS_REV` itself when the checkout is dirty, so the next such build says so
  in the file rather than only in a comment.
- **The numbers were recorded nowhere** (MEDIUM). It is the section above, plus both
  READMEs and the PRD.
- **The image-run write-up discussed only the two `ClassNotFoundException`s**
  (MEDIUM) and called the run otherwise clean, leaving out the image-only
  `UnsupportedFeatureError` that also violates criterion 2. The criterion is now
  stated in full, with both exceptions.
- **The image's `ClassNotFoundException`s are synthesized at build time** (LOW).
  Recorded under the image run: same counts as HotSpot, different mechanism, and a
  later atlas stub would need a rebuild to reach the image.
- **The "within 73 KB" sanity check was two ~1 MB errors cancelling** (LOW). The
  reconstruction substituted x86_64 files for arm64 ones (+1,071,437 B) and
  omitted ~996,869 B of libraries `click/build.sh` bundles. Withdrawn: the size
  section above compares the two runtimes inside one architecture and decomposes
  the real arm64 tree separately, instead of reconstructing it.
- **The measurement harness documented a different marker than it used** (LOW).
  The scratch script's docstring called `window_mapped` the first frame, which is
  2.8-3.4 s earlier than the number that was reported. Superseded by committed
  `measure-startup.sh` / `measure-startup.py`, whose docstring describes the
  two-event split it implements.
- **The arm64 section quoted numbers from the wrong build** (LOW): analysis
  "106.7 s @ 3.49 GB" was the first full image build, whose log had since been overwritten,
  and "peak RSS 8.62-8.87 GB" mixed native-image's builder GiB figure with the
  process-tree decimal GB. The section above quotes this build's `build.log` and
  `build-stats.env` only, and names which is which.
- **The 5.3 s silent stretch was called untouchable** (LOW) while the same
  table showed the image 0.60 s faster through it. Corrected: 5.96 s vs 5.37 s,
  and about a quarter of the win happens inside it.

Found while re-running, not by the reviews:

- **`check-*.sh` could fail a good boot.** `check-mtproto.sh` failed once with
  "the app never reached the main activity" on a run that had reached it: liblog
  writes a message and its newline in separate calls, and the launcher's line
  landed inside one —
  `D/tmessages(602676): cache path = /tmp/atl_cache/…betaboot: main activity started`
  — so `wait_for_log '^boot: main activity started'` never matched. The four
  driving checks now grep unanchored, like `run.sh`'s own check has always done.
  The launcher is the only writer of that string. Re-run after the change:
  `check-chatlist.sh` passes on both backends, and `check-mtproto.sh` passes on
  the image.

Left open, deliberately:

- The two `ClassNotFoundException`s (`View$AttachInfo`, `widget.Editor`) stay
  unstubbed: identical on HotSpot, and a stub moves the failure one field later.
- The `AndroidKeyStore` JCE provider cannot be verified in an image. Fixing it
  needs a build-config change with no failing check behind it.
- `android.content.res.AssetManager` is still build-time initialised by
  native-image's heuristic; safe only because its statics are empty today, and
  the build gate prints its kind every build for that reason.

## The soft keyboard: what Maliit's own Qt plugin does that this did not

Maliit's `input-context/minputcontext.cpp` (maliit/framework) is the reference
implementation of this protocol, and reading it explained every symptom the
keyboard had on the device. The findings, which are not specific to this port —
they apply to anything driving maliit through `libmaliit-glib` — are written up
in `~/UT/MALIIT-GLIB-NOTES.md`. The four that mattered here:

- **The server keeps a copy of the editor and predicts how it evolves.**
  `MInputContextConnection::sendCommitString` inserts what it commits into its
  own `surroundingText`, `sendKeyEvent` deletes from it on Backspace, and the
  keyboard's word engine reads that copy back. This port never sent
  `surroundingText` or `cursorPosition` at all, and never sent anything after
  the first `show`. So the server's copy was whatever it had guessed since the
  app started: clearing the field (or sending a message) left the keyboard
  completing a word that no longer existed, and it committed it back. Every
  edit, every caret move and every programmatic `setText` now pushes
  `updateWidgetInformation`.
- **A preedit is not part of the widget's text.** Qt keeps it outside the
  content and the server assumes the same. atlas's `EditText` splices the
  composing region into its buffer, so `getImeSurroundingText()` has to subtract
  it and report the cursor at its start — otherwise the keyboard sees its own
  uncommitted word as context and types it twice.
- **`reset()` is racy and MInputContext tracks it.** When a preedit is dropped,
  the keyboard may already have a commit for it in flight;
  `DBusServerConnection` keeps the pending reset call and both `commitString`
  and `updatePreedit` start with `if (imServer->pendingResets()) return;`. That
  guard is the difference between "the word is gone" and "the word comes back
  half a second later". The `_sync` calls this used before gave no such
  ordering — the stale commit is dispatched by GLib once the sync call returns,
  with no flag left to recognise it by. Every server call is async now.
- **`handle-*` on a gdbus-codegen skeleton must complete the invocation.** The
  signals use `g_signal_accumulator_true_handled`, so returning `TRUE` stops
  emission — the server then waits 25 s for a reply that never comes, and, for
  `update-input-method-area`, `libmaliit-glib`'s own `_after` completer never
  runs either. This handled 5 of the 15 context methods and completed none of
  them. All 15 are handled and completed first thing now, including the two
  the server calls synchronously (`selection`, `preeditRectangle`).

Also from the same file: releasing the context on window-focus-loss and on
`atl_window_hide` (an unmapped wayland surface gets no keyboard-leave), the
100 ms deferred hide so focus moving between two fields does not flap the panel,
the deferred *show* for a `showSoftInput` that arrives before focus, dropping
the editor's focus on `imInitiatedHide`, and the replacement ranges on
`commitString`/`updatePreedit` that autocorrect needs.

- **A keyboard-less desktop can still check all of this.** The debug backend
  (`ATL_IM_MODULE=debug ATL_IM_DEBUG_INSET=1`) traces the state the app pushes
  under `ATL_DEBUG_IME=1`, which is exactly what a real backend forwards over
  D-Bus. `check-input-method.sh` drives Saved Messages with xdotool and asserts
  on that trace: focus activates the context, each keystroke pushes the text
  with the cursor at its end, the send resets and pushes an empty
  `surroundingText`, leaving releases the context. The failure mode here is
  always "the state stopped being sent", which is invisible in a screenshot and
  obvious as one line per keystroke.

Left open, deliberately:

- **No reconnect if `maliit-server` restarts.** The Qt plugin retries the
  address lookup every 6 s and re-registers on reconnect; `libmaliit-glib`
  caches the bus and both proxies in file statics, so doing the same means
  `maliit_set_bus(NULL)` and rebuilding every signal connection. There is no way
  to test it from here (no maliit server on the desktop) and it was equally
  absent before, so it is documented rather than guessed at. The graceful half —
  `activationLostEvent` — is handled.
- `setRedirectKeys` is recorded and not acted on: ATL loads no hardware-keyboard
  plugin, so nothing would consume the redirected events.

## Two menus that never opened: the long press and the window blur

Both were framework gaps, and neither showed up as a crash: one silently did
nothing, the other left the app looking frozen with a `FATAL`-free log.

- **`setOnLongClickListener` was dead framework-wide.** A long tap on the
  profile tab of the main tabs is what opens the account switcher
  (`MainTabsActivity.openAccountSelector`); on the port it just selected the
  Profile tab. atlas's `View.onTouchEvent` took the press on `ACTION_DOWN` and
  fired `performClick` on `ACTION_UP`, and nothing anywhere called
  `performLongClick` — there was no long-press timer at all. App code that runs
  its own (`RecyclerListView`'s `CheckForLongPress`, `ClickHelper` in
  `MainTabsLayout`) worked throughout, which is why selecting a message and the
  tab-slide gesture always did and why this looked like an app bug. Fixed in
  atlas: `ACTION_DOWN` posts the long press at
  `ViewConfiguration.getLongPressTimeout()`, a `ACTION_MOVE` outside the view
  (plus touch slop) cancels it together with the pressed state, `ACTION_UP` and
  `ACTION_CANCEL` drop it, and a long click the listener handled suppresses the
  click on release — AOSP's order, including that an unhandled long click still
  clicks. `View.cancelLongPress()`, an empty stub until now, is what drops the
  pending one.
- **The whole-window blur crashed on `WindowManagerGlobal`.** Tapping the
  forward (or reply) panel above the input opened the blurred layer over the
  chat and stopped there: no preview, no menu, and the layer swallowed every
  touch and the back key, which is what "the app froze" was. The phone-number
  menu (`ScrimOptions`) and every `ItemOptions.setBlur(true)` — the account
  switcher included — failed the same way. `AndroidUtilities.allGlobalViews()`
  enumerates the process's windows to draw them into the blur bitmap, and below
  API 29 it does that by reflection on
  `android.view.WindowManagerGlobal.getViewRootNames()`/`getRootView(String)`.
  atlas's class had neither, the `NoSuchMethodException` was caught and became a
  `null` list, and the bitmap callback then ran with a null bitmap:

```
E/tmessages: allGlobalViews()
E/tmessages: java.lang.NoSuchMethodException: android.view.WindowManagerGlobal.getViewRootNames()
java.lang.NullPointerException: Cannot invoke "android.graphics.Bitmap.getWidth()" because "bitmap" is null
	at org.telegram.messenger.AndroidUtilities.applyColorMatrix(AndroidUtilities.java:6926)
	at org.telegram.ui.Components.ScrimOptions.makeGlobalBlurBitmaps(ScrimOptions.java:352)
	at org.telegram.ui.ChatActivity.checkShowBlur(ChatActivity.java:11719)
	at org.telegram.ui.ChatActivity.openForwardingPreview(ChatActivity.java:11028)
```

  Fixed in atlas by implementing both methods, and
  `android.view.WindowInspector.getGlobalWindowViews()` for the API 29 path,
  over the active view root's main view followed by its panels: AOSP has one
  `ViewRootImpl` per window and lists those, while atlas composites dialogs and
  popups as panels of the single native window, so the panels take the place of
  AOSP's extra roots. The list is bottom-most first, because the app draws it in
  order. The names are the view's class and identity hash rather than AOSP's
  title-plus-`ViewRootImpl`, which a panel here does not have; nothing but
  `getRootView` consumes them.
- **A UI-thread exception does not fail the run, and writes no `FATAL`.** Both
  crashes above were logged and swallowed: `ViewRootImpl.dispatchTouchEvent`
  catches `Throwable` around the app's handler so a throw does not escape into
  the native boundary, and an exception from a `Handler` callback is printed and
  cleared by `ExceptionDescribe`/`ExceptionClear` in the GLib dispatch in
  `android_os_MessageQueue.c`. So `FileLog.fatal` never runs, `files/logs/*.txt`
  has nothing, `run.sh` says "no uncaught exceptions" — and the half-built menu
  stays on screen eating input. For this kind of freeze the evidence is a raw
  Java stack trace in `out/run.log`, nothing else.

## Three things the same session turned up

- **A notification with an emoji in it lost its text.** `check-input-method.sh`
  ends on two `g_variant_new_string(): requires valid UTF-8` criticals, from the
  notification the account's own message comes back as, not from the input
  method the check is about. `GNotification` keeps what it is handed in a
  GVariant, and `GetStringUTFChars` returns modified UTF-8, whose surrogate pair
  for a non-BMP character GLib rejects — the same hazard `jstring_to_utf8`
  exists for, one file over. Fixed in atlas for the notification's title, body
  and button label, an intent's string extras and its action/component/data, and
  the share dialog's mail body: everything there is text the user typed or a
  chat is named after. Anything else still on `GetStringUTFChars` is fine only
  as long as it stays away from GLib.
- **A `Dialog`'s theme is dropped, so a full-screen one paints over the app.**
  atlas's `Dialog(Context, themeResId)` ignores `themeResId`, so
  `Window.setContentView`'s `windowBackground` lookup resolves against the
  *activity's* theme. `ScrimOptions` asks for `R.style.TransparentDialog`
  (`windowBackground` = transparent) and gets the activity's opaque white
  instead, which is why the phone-number menu shows a flat white page where the
  blurred chat should be: the blur bitmap is captured after the window is added,
  so the window's own background is what gets blurred. Not fixed — wrapping the
  context in a `ContextThemeWrapper` like AOSP does changes what every dialog in
  every app resolves, and that wants its own pass over the app's dialogs.
- **The back key never reaches the activity.** `ViewRootImpl.dispatchKeyEvent`
  gives `KEYCODE_BACK` to the topmost panel (`onPanelBack`, which is how a
  dialog or popup closes) and otherwise hands it to the main view; nothing
  routes an unconsumed one to `Window.Callback`, and `Activity.dispatchKeyEvent`
  is a `return false` stub, so `onBackPressed` only ever runs when the app calls
  it itself. Escape in a chat does nothing, and the forwarding preview — a child
  view of the chat, not a panel — can only be left through its own menu. Not
  fixed: back would start closing fragments and finishing activities across the
  whole app, up to quitting it from the chat list, and that needs deciding and
  retesting on its own.

## The caret was the framework's, not the app's

Typing anywhere — the composer, the chat-list search field — put a grey hairline
where Android draws a 2 px Telegram-blue bar. Fixed in atlas (`api-impl: let an
app draw its own text caret`); `check-caret.sh` drives the search field and
measures what is drawn.

- **The app's own cursor was never drawn, and `SDK_INT=28` is why.**
  `EditTextBoldCursor` has two ways to know when to draw it, and the port had
  neither. Above API 29 it installs its own `cursorDrawable` through
  `setTextCursorDrawable` and draws when that drawable's `draw()` was called;
  below, it reads `android.widget.Editor.mShowCursor` by reflection. The launcher
  reports 28 (`vm_common.c`, `-DBuild.VERSION.SDK_INT`), so `init()` takes the
  reflection path, `Class.forName("android.widget.Editor")` throws — those are
  the 14–31 `ClassNotFoundException: android.widget.Editor` per run — and
  `editor` stays null. `onDraw` then falls back to `showCursor = cursorDrawn`,
  and `cursorDrawn` is only ever set by the marker `ShapeDrawable` that
  `getTextCursorDrawable()` returns, which nothing on atlas called. So the flag
  was false in every frame, and `setCursorColor`, `setCursorWidth` and
  `setCursorSize` reached nothing.
- **What was on screen was atlas's own caret.** `android.widget.EditText.onDraw`
  ended in `canvas.drawLine(...)` with `cursorPaint` fixed at `0xFF000000` and
  the default stroke width 0, so it was a hairline that landed on a half-pixel
  and antialiased into two half-covered columns.
- **The API-29 contract works at 28 too, which is what makes this fixable in
  atlas alone.** `TextView` now holds a `setTextCursorDrawable` /
  `getTextCursorDrawable` pair and `EditText.onDraw` draws that drawable at the
  caret rect, keeping `drawLine` for a field that has none.
  `EditTextBoldCursor` overrides the getter *unconditionally* and, on the `< 29`
  path, returns a fresh transparent `ShapeDrawable` whose `draw()` sets
  `cursorDrawn` — AOSP's own mechanism. The getter must therefore be called every
  frame: caching what a setter stored, as AOSP's `Editor` does, gets nothing
  here, because at SDK 28 the app never calls the setter.
- **Placing it needed the vertical padding to stop being zero.** The app puts its
  cursor at `getExtendedPaddingTop() + (getTotalPaddingTop() -
  getExtendedPaddingTop())`, both of which atlas returned 0 from, so the caret
  would have sat at the top of the field instead of beside the text. They are
  now the compound padding and the compound padding plus what gravity adds
  (`getLayoutOffsetY()`). `TextView.onDraw` had to start from the *extended*
  padding for that to work: `EditTextBoldCursor.onDraw` pre-translates by it and
  sets `ignoreTopCount = 1` so the framework's next read returns 0 and it is not
  applied twice — a trick that only pays off if the framework reads it at all.
  `getExtendedPaddingBottom()` was missing outright, and the app's override calls
  `super`.
- **The caret is steady, not blinking**, because atlas has no blink timer.
- **`TextView.setHint` is a no-op and `getHint()` returns the string `"HINT"`.**
  `EditText` overrides both and keeps the real hint, but nothing draws it, which
  is why no search field or dialog input on the port shows its placeholder. Any
  app reading `TextView.getHint()` gets `"HINT"`. Still unfixed.

## A hairline seam across the search pill, and across every alert card

The reported "thin line in the middle of the search bar" is atlas's nine-patch
drawing ignoring the paint's alpha. Fixed in atlas (`api-impl: fade a
nine-patch's colour cells with its paint`), with `check-ninepatch.sh` as the
regression test.

- **It is not device-only, and not the GPU.** The first diagnosis blamed
  Ganesh's generic path fill, because the seam only ever showed up on the phone.
  It is neither: on the device it is pixel-identical with `MERCURYGRAM_NO_GPU=1`
  (CPU raster), and it reproduces on the desktop port at `GRID_UNIT_PX=21`. The
  variable was the **density**, 2.625, which is the phone's and which no desktop
  run had used. Reproducing it there turned a 20-minute build-install-shoot loop
  into an 18-second one.
- **`Path.addRoundRect` was innocent.** `Theme.createRoundRectDrawable` really is
  a `ShapeDrawable(RoundRectShape)` ending in `Canvas.drawPath`, but that fill is
  watertight at every size the pill takes; a `--run-class` harness drawing it
  into a bitmap never leaked a row. What settled it was painting an **opaque red
  rect over the whole path bounds** immediately before the fill: the seam rows
  stayed the page's colour, so something was painting *over* the pill, not
  failing to paint it.
- **The over-drawer is a nine-patch at alpha 0.** `FragmentSearchField`'s
  `dispatchDraw` draws `bg` and then a `BlurredBackgroundDrawable`, which for a
  colour source ends in `NinePatchDrawable.draw` on a rounded-rect nine-patch the
  app generates at runtime (blur3's `NinePatchBuilder`). With the blur hidden that
  drawable is at **alpha 0** — and atlas painted it anyway: `nDrawNinePatch`'s
  shortcut for a cell the chunk declares a solid colour did
  `SkPaint::setColor(cell_color)`, which replaces the paint's alpha as well as its
  colour. The centre cell of a capsule is the two-pixel band where the corner arcs
  meet, hence one seam at the pill's midpoint; on a taller card the same cell
  covers the whole middle, and the seams are its top and bottom edges.
- **Finding it was a bisect, and the hooks are worth reusing.** Temporary
  property-gated tracing in `BaseCanvas`/`Canvas` (log every wide draw with its
  bounds, clip and matrix), a `atl.debug.skipchild=<class>` early return in
  `ViewGroup.drawChild`, and `atl.debug.nopatch` to drop nine-patches altogether.
  Skipping the nine-patch made the seam disappear, which named the file. None of
  it is committed; re-add what a similar hunt needs.
- **`ATL_NO_DAMAGE=1` rules out the other explanation.** atlas repaints only
  `ViewRootImpl.mDirty` (`ATLWindow.c`), so a band that is never re-damaged keeps
  a stale colour, which looks exactly like this. It is not that: the seam is
  unchanged with damage tracking off.
- **`GRID_UNIT_PX` sets the port's density, which is how a phone's scale is
  reproduced on the desktop.** atlas derives `DisplayMetrics.DENSITY_DEVICE` from
  it (8 px per grid unit = 1x), so `GRID_UNIT_PX=21 ./run.sh` runs at the
  oneplus11's 2.625 and `run.log` prints `density = 2.625` on start. Take the
  value from the device's own session (`/proc/$(pgrep -x lomiri)/environ`), not
  from `/etc/ubuntu-touch-session.d/`, which holds one file per device.
- **The device can be driven from here after all.** `click/device.sh` runs, stops,
  logs and screenshots the click over ssh: `mirscreencast -n 2 --stdout` against
  `/run/user/<uid>/mir_socket` gives a raw RGBA frame, which `convert` turns into
  a PNG. Two caveats: it captures whatever is in the foreground, so it is useless
  while somebody is using the phone, and an app started from ssh gets no
  `GRID_UNIT_PX` unless the script copies it out of Lomiri's environment —
  without it the app runs at density 1 and looks nothing like the phone.
  `lomiri-app-launch <pkg>_<app>_<version>` starts it as Lomiri would.
- **Driving the UI after a theme switch is unreliable, and it is not a hang.** A
  click can take several seconds to have an effect (the ANR detector dumps every
  30 s throughout, with an empty `main` stack), a tap can be consumed as a list
  scroll, and after a theme change the main-tab bar stopped switching tabs
  entirely. Opening the Settings overflow menu left a half-drawn "Log Out" popup
  that ate every click and Escape, with no exception in `out/run.log` — the
  input-eating freeze from the section above, but without a throw behind it.

## sans-serif was never Roboto, and the metrics showed it

Text on the port did not match Android at the same `textSize`, and the font was
the reason: `TypefaceCollection.cpp` asked fontconfig for `sans-serif`, which on
this desktop is Noto Sans and on Ubuntu Touch is Ubuntu. Neither is Roboto.
atlas now ships `res/fonts/` — the twelve faces `res/fonts.xml` names for
sans-serif — and builds the generic families from them. `check-fonts.sh`
(`tools/FontMetricsCheck.java`) is the regression test; it needs no boot.

- **The line box was 16% too tall.** Skia reports `hhea` ascent/descent, and Noto
  Sans's is 1.069/-0.293 em against Roboto's 0.928/-0.244 — 1.362 em of line
  against 1.172. Every line in the app was laid out too tall, which is the part
  that reads as "the font size is different" even though the x-heights are within
  1% of each other (0.536 against 0.528 em).
- **Only the regular weight was wrong, which made it worse.** Telegram bundles
  its own Roboto for medium, extra-bold, italic, mono and condensed
  (`assets/fonts/rmedium.ttf` and friends) and only falls back to the system
  font for regular text, so the port was drawing Roboto Medium headings above
  Noto Sans body text. On the intro screen the title measured pixel-identical
  before and after the fix and the two body lines shrank 2-3%.
- **fontconfig answered every `sans-serif-*` alias with the same file.** The
  `light`/`regular`/`medium` widths were byte-identical (8372 px for the test
  pangram at 400 px) because `matchFamilyStyle` substitutes freely and
  `make_family` only ever asked for the four canonical styles. The bundled table
  states each face's weight explicitly — `Roboto-Thin`'s own OS/2 says 250 where
  fonts.xml declares 100 — and `make_typeface` carries the alias's weight as the
  base weight, so `Typeface.create("sans-serif-medium", …)` is a real 500.
- **Black has to precede Bold in the table.** `FontFamily::getClosestMatch` keeps
  the first of two equally distant faces, and a bolded 500 asks for 800, which is
  100 from either. fonts.xml orders the faces that way for exactly this reason;
  the transcription keeps the order.
- **The port is smaller than Waydroid because Lomiri says 420 dpi and Waydroid
  says 480 — and both are laying out correctly.** Side by side on the oneplus11
  at 1080x2349, the chat row pitch is 185 px on the port and 211 px under
  Waydroid. `DialogCell` in `DialogsActivity` measures
  `dp(heightDefault) + (useSeparator ? 1 : 0)` with `heightDefault = 70` and
  `dp()` a `ceil`, so the prediction is `ceil(70 x 2.625) + 1 = 185` at Lomiri's
  420 and `ceil(70 x 3.0) + 1 = 211` at Waydroid's 480. Both land exactly, and
  the dialog avatar agrees independently (130 px / 2.625 = 49.5 dp against
  145 px / 3.0 = 48.3 dp). Nothing in atlas's dp arithmetic is wrong; the gap is
  the two platforms' own scale.
- **Compare against another runtime's scale with `ATL_DENSITY_DPI`.** It
  overrides `GRID_UNIT_PX` outright in `DisplayMetrics.getDeviceDensity`, which
  matters because the grid unit can only say multiples of 20 dpi (density is
  `20 x GRID_UNIT_PX`). `click/device.sh run --dpi 480` puts the port at
  Waydroid's scale on the phone. A ratio between two screenshots is not enough to
  conclude anything here — check the measurement against the app's own dp
  constant, or a swapped pair of images will read as a density bug that is not
  there.
- **For 480 specifically, prefer `GRID_UNIT_PX=24`.** It is the same density by
  the normal path and it renders cleanly. `ATL_DENSITY_DPI=480` against Lomiri's
  own `GRID_UNIT_PX=21` gets the scale right (row pitch 211, Waydroid's exactly)
  but leaves the app drawn into a bottom-right 860x1768 of the 1080x2412 surface,
  the rest never painted. It is a repaint artifact, not layout:
  `ATL_NO_DAMAGE=1` fills the screen at the same dpi, and atlas logs the same
  `sized to the primary monitor's work area, 1080x2412` either way. atlas
  repaints only `ViewRootImpl.mDirty`, so the area exposed while the window
  settles is never damaged.
- **A stop that does not stop costs the session.** `click/device.sh stop` used to
  `pkill` and return without checking. One silent failure left an instance
  running, the next `run` was a second client on the same auth key, and Telegram
  answered `406 AUTH_KEY_DUPLICATED` — which the app surfaces as a modal
  "Authorization error … Log out". Do **not** take that button: the session is
  not revoked, `tgnet.dat` and `userconfing.xml` are untouched, and a clean
  relaunch clears it. `dev_stop` now SIGKILLs up to three times and fails loudly
  if anything survives.
- **The faces are found beside the framework's library**, at `system/fonts`
  relative to `libtranslation_layer_main.so` (`dladdr`), which is the desktop's
  one flat `out/atlas/`. The click splits natives (`lib/`) from atlas data
  (`atlas/`), so `click/run.sh` sets `ATL_FONT_DIR` instead. Without either the
  framework falls back to fontconfig and logs it.
- **Hinting is not a deviation.** AOSP's `Paint(int)` has the density-dependent
  `setHinting` commented out behind a TODO, and atlas carries the same commented
  block, so both leave Skia's default (`kNormal`). It does cost width: at 12-24 px
  the pangram measures 2.3-2.9% wider than the font's own advances, and Skia
  rounds each advance to a whole pixel whatever `setSubpixelText`/`setLinearText`
  say. That is Android's behaviour too — don't "fix" it without a device to
  compare against.
- **`ANTI_ALIAS_FLAG` was not reaching the glyphs.** `apply_flags` set
  `SkPaint::setAntiAlias`, but text is rasterised from `SkFont::getEdging`, whose
  default is `kAntiAlias` — so a paint with the flag *off* still drew antialiased
  text. AOSP's `applyLegacyFlagsToFont` sets edging, embedded bitmaps and forced
  auto-hinting from the same flags; atlas now mirrors it, and `AndroidPaint()`
  starts at `kAlias` the way AOSP's `Paint()` does. No visual change in the app
  (every app paint sets the flag) — the intro screen is pixel-identical — but the
  check now counts 94 grey levels with the flag and exactly 2 without.

## The window that stayed 960x540 while the app laid out for the screen

A screenshot from the phone showed the app painted into the top-left 960x540 of
the 1280x2775 screen, with "Start Messaging" running off the right edge and
unpressable. The window size and the layout size had come apart: atlas opens at
the launcher's default and Lomiri resizes it afterwards, and the frame in
between is laid out for one size and drawn into a buffer of the other.

- **The screenshot's own geometry names both sizes.** The painted area is
  exactly 960x540 — `main-executable-hotspot/main.c`'s hardcoded default, which
  `click/run.sh` never overrode with `-w/-h`. The button is 320dp wide
  (`IntroActivity` caps it there) and centred in its parent; at the phone's
  density 3.375 that is 1080px, and it starts 100px from the left, so the parent
  was **1280px** — the full screen. Both numbers come out of one PNG, which is
  quicker than any amount of reading.
- **Density is the constant that makes the arithmetic work.** `GRID_UNIT_PX=27`
  on this phone, so `DENSITY_DEVICE` is 540 and density is 3.375; the 48dp
  button measures 162px in the image. Getting this first turns "some layout is
  wrong" into an equation with one unknown.
- **atlas takes the layout size, the canvas size and the GL viewport all from
  `glfwGetFramebufferSize`** (`ATLWindow.c`), and relayouts only when that value
  *changes*. So a frame drawn while the reported size has moved on but the
  surface has not is not corrected later — the window stays wrong for the rest
  of the run, which is why this looked like a fixed misconfiguration rather than
  a startup race.
- **A clean launch is fine, which is what made it a race.** Launched through
  `lomiri-app-launch` with `ATL_DEBUG_DAMAGE=1`, the first frame is
  `damage 0,0-1280,2775 (full) of 1280x2775`: Lomiri does hand the app the whole
  screen, and atlas lays out correctly when the configure lands before the first
  draw.
- **Fixed by never resizing.** `ATL_FORCE_FULLSCREEN` was documented in atlas's
  `doc/Envs.md` but implemented nowhere; it now opens the window on the primary
  monitor (`atl_window_new`), and `click/run.sh` sets it. The launchers also stop
  publishing the *requested* size to `Display` and publish what the window
  actually got, since `Display` backs `getMetrics()`/`getSize()`.
- **Size the window from the monitor's work area, never from its video mode.**
  The first attempt used `glfwGetVideoMode`, and the app came up **2856x1280**:
  a phone panel's mode is the unrotated one, and the compositor is what turns it
  portrait. `glfwGetMonitorWorkarea` is the rotation-aware number. `atl_screen_size()`
  still reads the video mode, so anything else that grows a use for it inherits
  the same trap.
- **`Configuration.screenWidthDp` was pixels, not dp.**
  `android_content_Context.c` filled `screenWidthDp`/`screenHeightDp` from
  `atl_screen_size()` — the monitor, in pixels. Telegram recomputes its whole
  `displaySize` from those fields (`AndroidUtilities.checkDisplaySize`), so at
  density 3.375 it was laying out for 4320px. Invisible on the desktop port,
  where density is 1 and px == dp; wrong on any device that sets `GRID_UNIT_PX`.
  Now the app window, converted to dp.
- **`click/device.sh` does not work on this phone.** `mirscreencast` fails with
  "No appropriate client platform module found" on pixel9, so `device.sh shot`
  is unavailable (it works on the oneplus11). Starting the click over ssh also
  segfaults in `glfwInit` -> `wl_proxy_get_version`, so `device.sh run` is out
  too; `lomiri-app-launch <pkg>_<app>_<version>` is the way in, and app-unit
  environment can be injected with `systemctl --user set-environment` (the unit
  inherits it — this is how `ATL_DEBUG_DAMAGE` got in).

## The freeze with no FATAL is the intro screen's GL thread

"No button can be touched" was not an input bug. The app was deadlocked, and a
deadlocked app never reaches `glfwPollEvents()`, so touch is never *read* --
which from the outside is indistinguishable from touch not being delivered. The
last frame stays on screen because the compositor still holds its buffer.

- **The tell is the main thread's `wchan`.** `futex_wait_queue` where a healthy
  idle GLib loop sits in `do_sys_poll`, with 11s of CPU over 1h39m. `/proc/<pid>/
  task/<tid>/wchan` answers this in one command; SIGQUIT does not, because the
  VM cannot reach a safepoint to print the dump -- that silence is itself the
  signature of a native deadlock, and is why this freeze "leaves no FATAL".
- **The chain.** atlas's `EGLImpl.eglCreateWindowSurface` handles Surface,
  SurfaceView and SurfaceHolder, and throws `UnsupportedOperationException` for
  a `SurfaceTexture` (the branch is commented out with a FIXME, untouched since
  2026-02). `IntroActivity$EGLThread.run()` is `initied = initGL(); super.run();`
  so the throw skips `super.run()`, and `DispatchQueue` counts its `syncLatch`
  down *inside* `run()`. Every later `postRunnable`/`getHandler` calls
  `syncLatch.await()`, so the first one from the UI thread blocks it for good.
- **Only reachable logged out.** The `TextureView` that feeds `EGLThread` is the
  intro screen's animated logo. Every earlier device session started from a
  transplanted session and went straight to the chat list, which is why a
  six-month-old gap surfaced now and looked like a recent regression.
- **Degrade, do not throw.** `EGLImpl` now returns `EGL_NO_SURFACE` for a
  SurfaceTexture instead of throwing: Telegram already checks for it
  (`createWindowSurface failed`), `initGL` returns false, `super.run()` runs and
  the latch opens. The app stays alive and responsive; the animated logo stays
  blank until atlas can render into a SurfaceTexture. That is now implemented --
  see below.

## Rendering GL into a SurfaceTexture: a pbuffer read back into the mailbox

`eglCreateWindowSurface(SurfaceTexture)` works now
(`api-impl-jni/egl/surface_texture_target.c`), and with it the intro logo. Nine
call sites in the app hand a SurfaceTexture straight to EGL -- the intro, the
camera preview and the round-video recorder, the photo editor, the paint view,
the premium icon, and the spoiler and delete effects -- so this is the path
almost every GL view here takes.

- **A window surface was never an option.** `ANativeWindow_fromSurface()` returns
  NULL in this windowing stack, so Surface and SurfaceView get no EGL window
  either; the wl_subsurface bring-up would be a much bigger job. It would also
  not help: the consumer is Skia in the window's own GL context on another
  thread, sharing no buffers with the app's, so the frame has to come back
  through the CPU whatever the producer is. `check-surface-texture-gl.sh` is the
  check; the readback costs 4.3 ms for a full-screen frame on llvmpipe, and is
  skipped entirely whenever the view has not taken the previous frame.
- **The surface must keep the app's EGLConfig.** A single-sample pbuffer under a
  4x-MSAA context is `EGL_BAD_MATCH` at `eglMakeCurrent` -- multisampling is part
  of config compatibility, so the fallback config search matches the app's colour,
  depth *and* sample counts. Both phones' EGL and Mesa give the intro's own
  config (`EGL_SURFACE_TYPE` defaults to `EGL_WINDOW_BIT`) a pbuffer bit anyway.
- **A pbuffer cannot be resized**, and apps do not recreate the surface when the
  TextureView changes size -- they just move the viewport. It is made at the
  size the SurfaceTexture has when the app asks, so `TextureView` had to stop
  announcing the texture from a `post()` in `onAttachedToWindow` (size 0x0 before
  the first layout) and announce it from `onSizeChanged` instead. A view that
  later grows is read back clipped, once with a warning.

## Two GL gaps behind it, either of which is an invisible app

With the surface working the logo was still blank: the app drew, no GL error,
nothing appeared. Both causes are the kind that only a pixel check finds.

- **`GLUtils.texImage2D` uploaded a NULL pixel pointer.** It read `Bitmap.bytes`,
  a field nothing has filled in since the SkBitmap rewrite;
  `AndroidBitmap_lockPixels` is what returns the pixels. `glTexImage2D` with NULL
  data is not an error -- it makes a *complete* texture full of zeroes, so every
  textured draw is a fully transparent quad and the frame is just the clear
  colour. All 24 intro textures were empty.
- **`libandroid/bitmap.h` had invented its own `ANDROID_BITMAP_FORMAT_*`
  numbering** (a plain 0-based sequence) while `Bitmap.Config` stores the NDK's
  (RGBA_8888 = 1, RGB_565 = 4, RGBA_4444 = 7, A_8 = 8). An ARGB_8888 bitmap read
  back as RGBA_4444, so the upload type was `GL_UNSIGNED_SHORT_4_4_4_4`. The
  header is also what NDK apps compile against, so the NDK's numbers are the ones
  that had to stay.
- **`get_nio_buffer` read libcore's `_elementSizeShift`**, which the JDK's
  `java.nio.Buffer` does not have, so *every* GL call taking an NIO buffer threw
  `NoSuchFieldError` -- `glVertexAttribPointer` included, i.e. anything drawing
  from Java rather than from its own JNI. The element width now comes from the
  buffer's type.

## The app's EGL display is not the window's on X11

`bionic_eglGetDisplay(NULL)` handed apps `glfwGetEGLDisplay()`, which is
`EGL_NO_DISPLAY` unless GLFW created its contexts through EGL -- and on X11 it
uses GLX. Telegram's `initGL` stopped at the first line with "eglGetDisplay
failed", on the desktop only; the phone's Wayland path always had a display. It
falls back to `eglGetDisplay(EGL_DEFAULT_DISPLAY)` now. Nothing passes buffers
between the app's GL and the window's, so they do not have to share a display.

- **A GL check has to run off the main thread.** `eglMakeCurrent` from the main
  thread fails with `EGL_BAD_ACCESS` while GLFW's own context is current there.
  Every GL view in the app already has its own thread; `SurfaceTextureGLCheck`
  had to grow one.

## Asking Lomiri for fullscreen crashes Lomiri

`ATL_FORCE_FULLSCREEN=1` in `click/run.sh` made `atl_window_new` pass a monitor
to `glfwCreateWindow`, i.e. a real fullscreen toplevel. On the pixel9 that took
the whole shell down three times in four minutes, always with the same abort:

```
lomiri[5229]: ASSERT: "extraInfo->previousState != Mir::MinimizedState" in file
              ./src/platforms/mirserver/wrappedwindowmanagementpolicy.cpp, line 661
lomiri-full-greeter.service: Main process exited, code=dumped, status=6/ABRT
```

- **The app is the victim, not the culprit.** Its own `status=6/ABRT` five
  seconds later is just `Wayland display got fatal error 104: Connection reset
  by peer / The display is now unusable, aborting.` -- the compositor it was
  talking to had died. Read the *shell's* journal before the app's; the app's
  looks like a crash of its own.
- **qtmir keeps a shadow window state beside Mir's**, and only half of it is
  maintained. `requestState()` (the shell's own path) sets `previousState`;
  `advise_state_change()` -- where a *client*-driven change arrives -- updates
  `state` and leaves `previousState` stale. `activate()` restores a minimised
  window to `previousState` and asserts it is not itself Minimized.
- **So a client that drives its own state is what breaks it.** Nothing else the
  app does matters; it only has to ask once.
- **Not subsurfaces.** The `TODO: wl_subsurface.visiblity not implemented`
  warnings on this phone are real but unrelated: zero of them fall inside the
  crash windows, and they appear in hours when the app was not running.
- **Fixed on both sides.** atlas sizes the window to
  `glfwGetMonitorWorkarea` and passes no monitor, so no state is ever requested
  -- Lomiri hands an app the whole screen unasked, so the request bought
  nothing. qtmir maintains `previousState` in `advise_state_change` too, and
  `activate()` falls back to `RestoredState` instead of aborting.
- **The journal could not isolate the variable.** The app only ever ran in one
  boot, always with the flag set, so there is no before/after in the log; the
  mechanism came from reading qtmir 0.7.2's source, whose line numbers match the
  installed build.

## Four ways the port's text differed from Android, and the two left

Comparing the same chat side by side against Waydroid on the oneplus11 (both at
density 3.0, 16sp message text = 48 px) turned up four distinct causes. Measure
them from screenshots: line pitch by autocorrelating the row ink profile of a
wrapped block, stroke weight as summed alpha coverage plus stem width at half
maximum, advance behaviour as the ink span of a known string.

- **Lines ran 14% tall: `Paint`'s SkFont was fontconfig's face, not the
  collection's.** A fresh `Paint` reported `ascent=-51.312 descent=14.064` (Noto
  Sans hhea, 1069/-293 per 1000 upem) while `measureText` and drawing went
  through minikin's Roboto. Naming *any* typeface fixed it, which is what hid it
  from `FontMetricsCheck` -- every case there set one. `atl_default_typeface()`
  is deleted; `paint_set_typeface()` now sets `AndroidPaint::typeface` and the
  SkFont together from `typeface_init_default()`. Pitch 64.99 px -> 57.00 px
  against Waydroid's 56.99.
- **Do not derive a line box from arithmetic alone.** 65 px also equals
  `floor(fTop)+ceil(fBottom)` for Roboto's glyph bbox (2163/-555), and equals
  the OS/2 typo box, and equals Noto Sans's hhea. Three candidates fit the same
  number; only a probe printing `getFontMetricsInt()` inside the port told them
  apart. Skia reads `face->ascender`/`descender` (hhea) unless
  `fsSelection` bit 7 is set, and Roboto does not set it.
- **Emphasis text was double-bolded.** `AndroidUtilities.getTypeface` relabels
  `fonts/rmedium.ttf` (a 500 face) as weight 700 through `Typeface.Builder`,
  which on Android overrides the file's OS/2 value so the request matches
  exactly. The port collapsed the exact weight onto a legacy `BOLD`, so minikin's
  `computeFakery` saw 700 wanted against 500 actual and `MinikinSkia` emboldened
  it. `Typeface.Builder` now carries weight/italic to
  `typeface_family_from_file`, which declares them via
  `minikin::Font::Builder::setWeight`/`setSlant` -- the same override
  `BUNDLED_SANS` uses. "Colbys" ink 3296 -> 2555 against Waydroid's 2506.
  Honest `getStyle()`/`getWeight()` also stop `StyleSpan(BOLD)` over an already
  bold app font from synthesising a second time.
- **`TextUtils.concat` dropped every span**, so `TranslateButton`'s one-character
  `"x"` placeholder under an `ImageSpan` drew as a literal x instead of the
  translate icon. It is AOSP's `copySpansFrom` implementation now. ~100 Telegram
  call sites use it, so this was degrading more than the one icon.

Two deviations remain, both measured and both deliberately left:

- **Text gamma.** AOSP builds Skia with `SK_GAMMA_APPLY_TO_A8`,
  `SK_GAMMA_EXPONENT=1.4`, `SK_GAMMA_CONTRAST=0.0`; stock defaults are sRGB and
  contrast 0.5, so partial-coverage pixels come out far more opaque
  (alpha_port ~= alpha_android^0.6, edge quartile 0.60 vs 0.26, stems 4.7 vs 3.7
  px). Text reads slightly bolder and harder-edged, and is +2-4% ink. Invisible
  at 1:1, obvious at 6x. The fix is `skia_use_fixed_gamma_text=true` in
  `subprojects/packagefiles/skia/meson.build`, but it forces a full Skia
  rebuild -- carry it in whenever Skia is next rebuilt for another reason.
- **Advance rounding.** `measureText` of a sample line is 759 px against the
  linear 754; Android keeps advances fractional, the port rounds each to a whole
  pixel, so lines run 0-0.8% wide and drift up to ~6.5 px over 26 glyphs. AOSP's
  `Paint` defaults and `packPaintFlags` match the port's exactly, so this is a
  build difference, not an API one -- try `skia_use_system_freetype2=false`
  before forcing linear metrics in `AndroidPaint`.

Also seen and not chased: colour emoji render monochrome (minikin prefers a mono
symbols font over CBDT `Noto Color Emoji`), `Paint.getTextBounds` bypasses
minikin so every character the primary face lacks reports identical `.notdef`
bounds, and the grey pill where a contact-name emoji belongs is Telegram's own
sprite path (`Emoji.java:382` draws it when `emojiBmp` is still null), not font
fallback.

## Adding a second account, and the loop the fix for it uncovered

The add-account screen hung on the oneplus11: the number was accepted, the
confirmation dialog appeared, and nothing was ever sent. Two framework gaps, one
behind the other, and fixing the first one made the second one visible.

- **The hang was `PhoneNumberUtils.compare`.** `LoginActivity.onNextPressed`
  (line 3059) checks the typed number against every activated account before it
  requests a code. api-impl's `PhoneNumberUtils` had `isNonSeparator`,
  `isGlobalPhoneNumber` and `stripSeparators` and nothing else, so the call threw
  `NoSuchMethodError` on the first loop iteration and `auth.sendCode` was never
  reached. The whole 19k-line journal has no `sendCode` in it. Implemented in
  atlas as AOSP's loose comparison: the last 7 dialable characters must agree and
  what precedes them may only be an international or trunk prefix.
- **`WindowManager.LayoutParams.preferredRefreshRate` was missing too**, and
  `AndroidUtilities.setPreferredMaxRefreshRate` writes it from
  `LaunchActivity.onConfigurationChanged`. The `NoSuchFieldError` fired on every
  configuration change -- about 80 times in that session -- and aborted the rest
  of the handler each time.
- **Adding the field was what started the spin.** The throw had been an
  accidental circuit breaker: it aborted `onConfigurationChanged` *before*
  `setPreferredMaxRefreshRate` reached `wm.updateViewLayout`. With the field
  present the call went through, and `updateViewLayout` -> `setLayoutParams` ->
  `requestLayout` -> `nativeRequestLayout` zeroed `layout_width/height`, which
  `atl_window_render_inner` reads as "the window was resized" and answers with
  `dispatchConfigurationChanged`. 5838 `onConfigurationChanged` and 5838
  `updateViewLayout`, strictly alternating, at 67% CPU. The confirmation dialog
  was not being dismissed -- the window was being relaid out faster than it could
  be drawn.
- **A layout request is not a configuration change.** That is the actual defect,
  and it predates the field: any app calling `requestLayout()` from
  `onConfigurationChanged` would have spun. AOSP's `ViewRootImpl.requestLayout`
  only raises `mLayoutRequested`; it never touches the window size. And AOSP's
  `updateConfiguration` calls `requestLayout()` *immediately after* dispatching,
  which is safe there precisely because the two are never conflated. atlas now
  keeps them apart with a `needs_layout` flag, and `ViewRootImpl` diffs against
  the last dispatched Configuration the way AOSP diffs
  `mLastConfigurationFromResources`.
- **The IME inset moved to the same flag.** It used the same zeroing trick to
  force a relayout. `Configuration.keyboardHidden` says whether a keyboard is
  *available*, not whether the IME is up, so AOSP routes inset changes through
  `dispatchApplyInsets` and never a configuration change.
- **A green run hides this.** Both `run.sh` runs printed "no uncaught exceptions"
  -- the loop is not an exception. Measure it: `GRID_UNIT_PX=21 ./run.sh
  --seconds 25 --fresh` then `grep -c onConfigurationChanged out/run.log`. 2512
  without the fix, 1 with it; on the pixel9 click, 1 across three samples.

## The app is never told it went to the background

Chasing what looked like residual CPU on the pixel9. It was not residual -- idle
is 4-6% -- but the search turned up a real gap.

- **Idle is fine; interaction is what costs.** An 11-minute sample showed ~67%
  CPU for the first 8 minutes and 5-8% after. That looked like a startup task
  completing, but the log had 10 touch events in it: somebody was using the
  phone. Sampling again with touches counted per window alongside CPU separates
  the two cleanly: thirteen windows of 4-7% at zero touches, then 53% at 76
  touches and 97% at 152, then back down. Always count interaction in the same
  window as CPU on a device that is somebody's daily phone, or the curve means
  nothing. (That 97% while scrolling is a separate question, unmeasured here.)
- **`onPause` and `onStop` are never delivered for a compositor focus change.**
  In a 14-minute run: one `app paused = false`, two `onResume`, zero `onPause`,
  zero `onStop`, zero `hasFocus: false`. Telegram's `mainInterfacePaused` stays
  false for the life of the process, so it keeps behaving as the foreground app.
- **The plumbing exists but is wired to the wrong thing.**
  `activity_unfocus` in `app/android_app_Activity.c` does the right sequence
  (`performPause`, `performStop`, `onWindowFocusChanged(false)`), and it is called
  from exactly two places: `activity_update_current` and `activity_start` -- both
  transitions *within* atlas's own activity stack. Nothing connects it to the
  window losing focus.
- **The compositor's signal does arrive**, and stops one layer short.
  `glfwSetWindowFocusCallback` -> `on_window_focus` -> `atl_window_notify_focus`
  -> `ViewRootImpl.dispatchWindowFocusChanged`. That is view-level focus only; it
  never reaches the activity lifecycle.
- **Not yet measured under backgrounding.** The app held focus for the whole
  sample, so what is proven is the code path and the absent callbacks, not the
  cost. The test is to switch away and watch whether CPU and the chat-list
  updates continue.

## voip: building the calls stack

- **`jni/voip/CMakeLists.txt` is read and rewritten, not copied.** It is 2000
  lines of source lists, and unlike `jni/CMakeLists.txt` it has no NDK
  dependency beyond branching on `ANDROID_ABI`. `native/voip.cmake` reads it,
  rewrites the `jni/`-relative paths to absolute ones and `include()`s the
  result, so the targets, flags and definitions are exactly the Android ones and
  cannot drift. Each deviation is one `string(REPLACE …)` with a comment.
- **A regex over a whole file eats the newline the next match needs.** A bare
  `voip` line and the line after it both start with `\n[ \t]+`, so consecutive
  matches lose every second one. The rewrite doubles the newlines first and
  halves them afterwards.
- **`__ANDROID__` cannot be public.** `tgcalls_tp` defines it `PUBLIC` on
  Android, where the toolchain defines it anyway; here it would push every
  dependent target's glibc code down bionic branches. libtgvoip is the one
  consumer that needs it — it selects `AudioInputAndroid`/`AudioOutputAndroid`,
  the JNI classes the app ships, which is exactly the path this port wants — so
  it gets it `PRIVATE`, with `include/sys/system_properties.h` answering the
  property reads that come with it.
- **`__ANDROID_API__` is a toolchain define, and code reads it.**
  `rtc_base/event.cc` picks the bionic-only `pthread_cond_timedwait_monotonic_np`
  below API 21. Set to 28, the level the port reports as `Build.VERSION.SDK_INT`.
- **clang 21 rejects `[[clang::lifetimebound]]` on a void function's parameter**,
  which `api/candidate.h` has 61 times. absl defines the macro unconditionally,
  so `port_compat.hpp` includes `absl/base/attributes.h` and empties it — it is
  a lint annotation, nothing generated changes.
- **The cross build is gcc, the desktop build is clang, and the OpenSL ES
  headers are clang-only.** `SL_API_DEPRECATED` expands to an
  `__attribute__((availability(android,…)))` gcc does not know. Defining it away
  has to be a compile *option*: CMake silently drops a function-style
  `target_compile_definitions`.
- **webrtc spells two codec headers the Android way** — `<libvpx/vp8cx.h>` and
  `"ffmpeg/include/libavcodec/avcodec.h"`, the second being the merged directory
  `patch_ffmpeg.sh` creates on Android and this port does not (see above).
  `voip.cmake` builds a small include tree of symlinks pointing at the port's
  installed prefixes rather than moving headers around.
- **webrtc's bundled libevent has an Android `config.h` with no `fd_mask`**, so
  `select.c` typedefs one that glibc already has. `_EVENT_HAVE_FD_MASK=1`.
- **glibc's `<ucontext.h>` does not drag in `<signal.h>`; bionic's does**, and
  `sdk/android/native_api/stacktrace/stacktrace.cc` relies on it. Added to
  `port_compat.hpp`.
- **tde2e is a stub, so conference calls cannot work.** `Instance.cpp` calls
  `tde2e_api::call_encrypt`/`call_decrypt` for a conference call's frame
  encryptor; `jni/td` is not checked out, so `native/stubs/tde2e_stub.cpp`
  answers both with an error. One-to-one and group calls do not go through it.
- **The audio layer webrtc picks is the Java one.** `audio_device_impl.cc`
  chooses between AAudio, OpenSL and Java from what `AudioManager` reports;
  atlas has no low-latency audio feature and AAudio is compiled out, so it lands
  on `kAndroidJavaAudio` — the app's own `org.webrtc.voiceengine` classes over
  atlas's `AudioRecord`/`AudioTrack`, i.e. ALSA `default`. On Ubuntu Touch that
  is the PulseAudio plugin in front of the droid card, verified on the
  oneplus11: `arecord -D default` and `aplay -D default` both work and show up
  as PulseAudio streams.
- **What atlas needed for `VoIPService` to start at all**: `startForegroundService`
  was a `return null` stub (the app targets SDK 26+ and starts the call service
  that way), `Notification.Builder.setFullScreenIntent` was dropped on the floor
  (it is how an incoming call takes the screen), and `startActivity` only reused
  a running activity when `FLAG_ACTIVITY_CLEAR_TOP` was set, ignoring
  `launchMode` — `LaunchActivity` is `singleTask`, so every call would have
  built a second one. All three are atlas commits on master.
- **`android.telecom.Connection` does not exist in atlas**, so
  `VoIPService$CallConnection` cannot link. It is only reached when
  `USE_CONNECTION_SERVICE` is true, and that is a device whitelist the port does
  not match, so the class is never loaded. Left alone deliberately.

### A missing framework method hides until the line runs

Pressing the call button did nothing. `VoIPService.onCreate` had died on
`NoSuchMethodError: AudioManager.registerMediaButtonEventReceiver`, two lines
before the end of its setup block — and because a `NoSuchMethodError` is an
`Error`, the `catch (Exception x)` wrapped around that whole block did not
catch it. atlas's GLib dispatch then cleared the exception out of the `Handler`
callback, so the app kept running with a half-built call service and no visible
failure at all. `BluetoothAdapter.getProfileProxy` had failed the same way a few
lines earlier, inside a `catch (Throwable)` that did swallow it.

The existing checks could not have caught either. `PortClassCheck` and
`ViewSignatureCheck` load classes, and a missing *class* does fail at load; a
missing *method* resolves lazily, at the instant the call executes.

`check-framework-api.sh` reads the constant pool of the app's own class files
and resolves every `android.*`/`dalvik.*`/`libcore.*` method and field against
atlas plus the shim. On the call stack it found 57 gaps at once — 43 reachable
— which would otherwise have been 43 rounds of build, install, press the
button, read the log. Fourteen are deliberately left: `android.telecom.*` is
behind `VoIPService.USE_CONNECTION_SERVICE`, a device whitelist this port does
not match, and the rest is screen capture and Wi-Fi Direct.

Worth knowing for the next subsystem: point the script at another package
(`check-framework-api.sh org/telegram/messenger/camera`) before bringing it up,
not after.

### The click takes atlas prebuilt, so a framework fix does not reach the phone

The first calls click was built the default way, with atlas from the pinned ATL
SDK. None of the framework fixes were in it — which is why the crash on the
device was in code that had already been fixed here. `PORT_ATLAS_PREBUILT=0`
builds the framework from source instead, and it still wants the SDK for what
the container cannot produce, so pin the tag rather than letting `auto` derive
one from the local HEAD:

```sh
PORT_ATLAS_PREBUILT=0 ATL_SDK_TAG=$(cat linux-port/click/atl-sdk.tag) \
    linux-port/click/stage-prebuilt.sh
PORT_ATLAS_PREBUILT=0 ATL_SDK_TAG=$(cat linux-port/click/atl-sdk.tag) \
    clickable build --arch arm64 --skip-review
```

Letting it fall back to the sibling ART packaging tree instead works, but that
tree's `libskia.so` is the one with the sampled-JPEG-decode segfault.
