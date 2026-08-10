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
