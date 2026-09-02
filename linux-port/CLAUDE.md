# linux-port/ conventions

- Every script starts with `source "$(dirname "$0")/env.sh"` (or `../env.sh`) and
  uses `$PORT_OUT`, `$ATLAS_DIR`, `$JAVA_HOME` from there. Never hardcode paths
  or a JDK version in a build script — the toolchain is pinned in one place.
- All products go under `linux-port/out/` (gitignored). Nothing generated is
  committed; scripts must be idempotent and safe to re-run.
- `$ATLAS_DIR` is `linux-port/atlas/`: an atl-touch checkout of `master`, its own
  git repo, gitignored by this one. It is a source dependency the port builds,
  not a place artifacts are copied from. Fix framework bugs there as commits on
  master that go upstream to atl-touch; never patch atlas from this repo and
  never paper over a framework bug in the shim jar or the launcher.
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
- The launcher is atlas meson targets (`$ATLAS_DIR/src/main-executable-hotspot/`,
  `android-translation-layer-hotspot` and `-image`), built and installed by
  `build-atlas.sh`; `launcher/` here holds only the decision note and the two
  smoke tests. Edit the launcher in atlas and commit it there. Reason in
  `launcher/README.md`: `libtranslation_layer_main.so` *imports* `apk_path`,
  `atl_window`, `get_app_data_dir` and the `bionic_*` calls from its executable —
  which is also why `-rdynamic` on either target is load-bearing, and why a
  missing one is a startup crash rather than a link error.
- One `main.c`, two VM backends behind `vm.h`: `vm_hotspot.c` links `libjvm.so`
  and assembles a class path, `vm_image.c` `dlopen`s a native-image `.so` and
  assembles no `-Djava.class.path`, `-agentlib:`, `-XX:` or `--add-opens` at all.
  Both define `create_vm`, so the meson source lists are the only thing keeping
  them out of one binary. Anything that must reach both goes in `vm_common.c`.
  The launcher reads its `-D` properties back out of `java.lang.System` and
  reports what arrived; it never writes one back, because on HotSpot that would
  overwrite a value the JVM normalised.
- `PORT_LAUNCHER` (`hotspot`|`image`) picks the backend for a run and `env.sh`
  derives `$PORT_LAUNCHER_BIN` from it. A script that boots through `run.sh` must
  name the launcher that way, or its `[ -x ]` check and its `pkill` describe a
  different process than the one it started. A script that hands the launcher a
  class path (`--run-class`) stays HotSpot-only, and so does `trace-metadata.sh`:
  an image accepts `-agentlib` and ignores it, so a traced image run would write
  an empty config and say nothing.
- Changing a Java signature that has a native peer in atlas needs two ninja
  passes: javac regenerates `src/api-impl-jni/generated_headers/*.h`, but the
  `.so` does not depend on them, so the first build compiles against the stale
  header. Re-run, then commit the header on the atlas branch.
- Anything running the launcher needs
  `LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ATLAS_OUT` — `libjvm.so` is
  deliberately not in its RUNPATH — and `source launcher/display.sh` for
  `port_start_display`/`port_screenshot` instead of its own `Xvfb` block.
- To run app code without a full boot, use the launcher's `--run-class CLASS`
  with a helper in `tools/`. That is the cheapest way to test one piece of the
  app (or of the framework) while the boot path is still incomplete.
- Changes to `org/telegram/**` are a last resort (FR-7 allows the NativeLoader
  hook only): make them a guarded escape hatch driven by a `-D` property, so the
  Android build is bit-identical without it and the diff stays upstreamable.
- `JNI_CreateJavaVM` is not the `java` command: it does not expand `dir/*` in
  `java.class.path`, and `System.load` called from JNI binds to the boot class
  loader. The launcher handles both; don't reintroduce either assumption.
- Before adding a shim class, run `shim/audit-shim.sh`: it lists what is
  unresolved and who references it. Implement what a reachable caller demands,
  record the rest under "Deferred" with its referrers.
- Shim classes carry approximations (ICU patterns, plural rules, likely
  subtags). Say so in the class javadoc *and* in `shim/README.md`, so nobody
  later mistakes them for the real ICU behaviour.
- `run.sh` is the boot loop: `./build-atlas.sh && ./run.sh --seconds 25 --fresh`,
  then read the *first* exception in `out/run.log`. Later ones are usually the
  wreckage of the first (an aborted `onCreate` leaves the fragment host
  unattached, a null application object segfaults the launcher).
- A missing framework class is not always a missing feature. Most of what the
  boot path demanded is field types, catch clauses and API-29+ branches behind
  `SDK_INT` checks: the class has to exist because verification (or
  `View.overridesOnDraw`'s reflection) loads it, not because anything calls it.
  Add an honest stub in atlas, say in the javadoc what it does not do.
- Guarding a call to a class the runtime lacks does not stop the JVM loading it:
  verification resolves everything the verified method names. The fix is to move
  that code into its own class (`ATLZoneInfoDb`), not to add a check.
- A nested class that the SDK declares `static` must be `static` in api-impl too,
  or the app's `new Outer.Inner()` fails with `NoSuchMethodError`. Nested classes
  inside an *interface* are already static.
- The port installs atlas's `hax.jar`, not `hax-stripped.jar`: the stripping
  exists for ART's duplicate-class check on dex, and nothing on the app class
  path defines the three stubs it drops.
- `ATL_NO_GPU=1` is on by default in `run.sh`: atlas's Ganesh path crashes in
  skia's `GrGLExtensions::init` on any GL driver here. Don't chase it from the
  Java side.
- The UI can be driven: atlas feeds GLFW mouse and key events into
  `ViewRootImpl`, so `xdotool mousemove/click/type` against the (Xvfb) display
  works on the real app. `check-mtproto.sh` is the worked example — positions
  are per-mille of the ATLWindow, and the log, not a screenshot, is what tells
  the script whether a step took.
- Real `APP_ID`/`APP_HASH` are a build input: `APP_ID=... APP_HASH=...
  build-classpath.sh` rewrites the gitignored `./API_KEYS`. With the dummy
  `APP_ID=0`, Telegram answers every request that opens a connection with
  `400 CONNECTION_API_ID_INVALID` — enough to prove a round trip, never enough
  to use a session.
- Backgrounding a shell *function* that runs the launcher makes `$!` the
  subshell's pid, and killing that orphans the launcher. `exec` the binary
  inside the function (`run.sh`). The launcher also ignores SIGTERM, so a timed
  run ends in SIGKILL and exit 137.
- `pgrep -f android-translation-layer-hotspot` matches the shell you type it in
  too. Anchor the pattern (`^/…/android-translation-layer-hotspot `) before
  killing anything.
- The app's data dir is `$ANDROID_APP_DATA_DIR/<apk basename>_` (atlas appends
  it), so the port's is `out/data/app.apk_`. `transplant-session.sh` copies a
  logged-in ART/ATL session into it; `run.sh --fresh` wipes it and re-running
  the transplant puts it back.
- `run.sh` exports `ANDROID_LOG_TAGS=*:V`, without which liblog drops everything
  below `INFO` and the app's own `FileLog.d` lines never reach `out/run.log`.
  Check app behaviour there, not in `files/logs/*.txt`.
- atlas has no GLFW scroll callback: a list is scrolled with a drag
  (`mousedown` + stepped `mousemove` + `mouseup`), never `xdotool click 4/5`.
  See `check-chatlist.sh`.
- A gn option for skia lives in `$ATLAS_DIR/subprojects/packagefiles/skia/`, and
  meson only copies that into the (shared, long-extracted) skia checkout when it
  first extracts the wrap — `build-atlas.sh` re-copies it on every run so an
  atlas commit there actually takes effect.
- The port's build is a `DEBUG_PRIVATE_VERSION`, so `FileLog.fatal` answers any
  uncaught exception with `System.exit(2)` — and the launcher hangs in the exit,
  leaving a dead JVM with its window still up (0% CPU, no repaints, no input).
  "The UI froze" means "read `files/logs/*.txt` for `FATAL/tmessages`"; `run.sh`
  fails the run on it.
- The other freeze leaves no `FATAL` at all: a throw from a click handler is
  caught in `ViewRootImpl.dispatchTouchEvent`, and one from a `Handler` callback
  is cleared by the GLib dispatch in `android_os_MessageQueue.c`. The app keeps
  running with a half-built menu over it that eats every touch, `run.sh` still
  says "no uncaught exceptions", and the only evidence is a bare Java stack
  trace in `out/run.log`. Grep it for `Exception` before believing a green run.
- App code written for Android can depend on libcore *behaviour*, not just
  classes: `SvgHelper` switches on SAX's `localName`, which Xerces leaves empty
  unless the parser is namespace-aware. Such a fix goes in the shim as the class
  ART uses (`org.apache.harmony.xml.parsers.SAXParserFactoryImpl`), registered
  through `shim/resources/META-INF/services/`, never as an edit to
  `org/telegram/**`.
- `run.sh --stop-file PATH` turns `--seconds` into an upper bound, so a driving
  check can wait for a slow first sync without paying for it on every run.
- A view's *method signatures* must resolve, not just its code: atlas calls
  `getDeclaredMethod("onDraw", …)` on every view before drawing it, and that
  loads the parameter and return types of all its declared methods. One missing
  class (`ChatMessageCell.onProvideStructure(ViewStructure)`) makes the whole
  frame die with `NoClassDefFoundError` while the app looks merely empty.
  `tools/ViewSignatureCheck.java`, run by `build-atlas.sh`, fails the build on
  it; add the stub in `$ATLAS_DIR`.
- `pkill -f "$launcher "` is not enough to stop the app — the launcher ignores
  SIGTERM, and the orphan keeps talking to the account and holds the binary
  busy. Use `pkill -9`.
- Anything that drives the UI must prove *which* chat is open before it types:
  the account's own user id comes out of the log
  (`getSharedPreferences(ringtones_pref_<id>)`), and Saved Messages is the only
  dialog a check may write to.
- atlas's `ImageView` is not AOSP's: it had no handling for a drawable with no
  intrinsic size (AOSP stretches it over the whole view; atlas drew nothing —
  every emoji cell) and none for `setImageResource(0)` (AOSP clears the image;
  atlas threw `Resources$NotFoundException`). Before blaming app code for a view
  that stays empty, read the atlas widget it uses and compare it with AOSP's.
- A framework gap can be surfaced by a *network answer* rather than by a click,
  so a UI check that passes once is not proof. `check-emoji.sh` found
  `setImageResource(0)` only on the run where `getAllStickers` came back while
  the panel was open — re-run a driving check before believing it.
- `build-all.sh` is the port's build order, written down: every build script
  belongs to one of its steps, so a new one has to be added there too. It starts
  from a bare checkout (submodule init, atlas clone) and every step is
  idempotent, which is what makes a re-run cheap.
- The framework and the shim depend on each other: the shim compiles against
  `out/atlas/api-impl.jar`, while `build-atlas.sh`'s app class checks
  (`PortClassCheck`, `ViewSignatureCheck`) need `out/shim.jar` — the app's own
  classes name `org.json`. `build-atlas.sh` therefore skips those checks while
  the shim is missing, and `build-all.sh` re-runs it after `build-shim.sh`.
- The Ubuntu Touch click lives in `click/`, but its `clickable.yaml` is at the
  repository root: clickable mounts only the project root into the build
  container, and the build needs `TMessagesProj/jni/**` as well as `linux-port/`.
- `PORT_ARCH=arm64` retargets every script the port has (`env.sh` derives the
  triple, the tool prefix, `PORT_CROSS` and the target JDK from it). Add an arch
  case to the script that needs one; never fork a script per architecture, and
  keep the x86_64 path bit-identical.
- A cross build cannot run what it produces: `ldd`, `dlopen_check` and
  `ShimCheck` are skipped when `PORT_CROSS=1`, and `click/build.sh` replaces them
  with a static check — every staged object is aarch64, and every `DT_NEEDED` is
  either bundled or in `click/device-libs.txt`, the device's own `ldconfig -p`.
  Re-record that file when the device's release changes.
- The click's arm64 inputs that are not built here come from the ATL SDK release
  (`click/atl-sdk.tag` pins it) through `click/stage-prebuilt.sh`, which writes a
  `PROVENANCE.md` beside them. By default that includes atlas itself — the click
  does not compile the framework, so a framework change reaches it by way of an
  atl-touch commit, an SDK release and a new tag, not a local rebuild.
  `PORT_ATLAS_PREBUILT=0` builds it from source, and `ATL_SDK_TAG=off` falls back
  to the sibling ART packaging's tree. Nothing else may reach outside the
  repository: the container cannot see it.
- `click/device.sh` drives the installed click on a phone over ssh (`$PORT_DEVICE`,
  default oneplus11): `run`, `stop`, `log`, and `shot` for a screenshot through
  `mirscreencast`. It captures whatever is in the foreground, so it is useless
  while somebody is using the device, and an app started from ssh needs
  `GRID_UNIT_PX` copied out of Lomiri's environment or it runs at density 1.
  `lomiri-app-launch <pkg>_<app>_<version>` starts it the way Lomiri would.
- A defect that only shows on the phone is usually the phone's *density*, not its
  GPU: `GRID_UNIT_PX=21 ./run.sh` reproduces the oneplus11's 2.625 here, and the
  desktop loop is a hundred times faster than build-install-shoot. Try it before
  blaming the backend.
