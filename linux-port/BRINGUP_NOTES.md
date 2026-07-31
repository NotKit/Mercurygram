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
  `linux-port/atlas` on branch `mercurygram/openjdk-port`; builddir:
  `out/atlas-build`; install dir: `out/atlas`. The framework's javac writes
  generated JNI headers back into `src/api-impl-jni/generated_headers`, which is
  now expected — they get committed on the atlas branch. The script diffs
  `git status` of the checkout around the build and fails on any change outside
  that directory.
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
- **`fonts.xml` is dead weight here.** Only atlas's own executable looks at
  `/system/etc/fonts.xml`, through the bionic-shim path-override table in
  `src/main-executable/libc_bio_path_overrides.c`; the framework itself uses
  Skia's fontconfig `SkFontMgr` (`hwui/TypefaceCollection.cpp`). Copied for
  reference at `out/atlas/system/etc/fonts.xml`.
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
