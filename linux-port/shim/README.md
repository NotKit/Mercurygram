# libcore/dalvik compat shim

HotSpot has no libcore, so the classes ART's boot classpath provides and the JDK
does not are reimplemented here. `../build-shim.sh` compiles `src/` with
`javac --release 21` into `out/shim.jar` and `native/port_shim.c` into
`out/libportshim.so`, then runs `../tools/ShimCheck.java`, which exercises
api-impl code paths that reach into the shim.

The shim compiles against the JDK only — never against api-impl. If a shim class
ever needs a framework type, that is a sign the code belongs in atlas instead.

`resources/` is the one part of the jar that is not classes: service
registrations that make a shim the platform default the way libcore's are on ART
(currently `javax.xml.parsers.SAXParserFactory`).

## How the list was decided

`audit-shim.sh` reproduces it:

* `jdeps -v` over `out/atlas/api-impl.jar` and the app jars lists every
  unresolved reference and who makes it. That includes references in method
  bodies that may never run.
* `../tools/ClassLoadSweep.java` loads every class with initialization off, so
  only supertype and interface failures show up: those break *linking*, not just
  one code path.

Implemented = something on the boot path needs it. Deferred = the audit finds
the reference, but no reachable caller was found; the entry below records who
would need it, so the next failure has an address.

## Implemented

| Class | Required by | Notes |
| --- | --- | --- |
| `libcore.util.NativeAllocationRegistry` | `android.graphics.{Canvas,Paint,Path}`, `android.graphics.text.*` | `java.lang.ref.Cleaner` plus a JNI call to the registered free function. The size hint is ignored: HotSpot has no native-allocation accounting. `SelfTest` is a hook so ShimCheck can prove the cleaner really reaches native code. |
| `libcore.util.EmptyArray` | `android.text.{SpannableStringBuilder,AutoGrowArray,PackedObjectVector}`, `android.util.SparseLongArray` | Implemented. |
| `libcore.util.Objects.equal` | `android.util.MapCollections` (so every `ArrayMap` iteration) | Implemented. |
| `libcore.io.IoUtils` | `android.app.SharedPreferencesImpl`, `android.os.ParcelFileDescriptor` | `closeQuietly` implemented; `setBlocking` needs libportshim.so. |
| `libcore.io.Memory.{peekInt,pokeInt}` | `android.os.ParcelFileDescriptor` | Implemented in pure Java. |
| `libcore.io.Libcore` + `libcore.io.Os` | `android.os.Process` | Three methods (`getpid`, `getppid`, `gettid`) — the real interface has about a hundred. `gettid` falls back to the pid without the JNI library. |
| `libcore.io.Posix` | the shim itself | Not a libcore stand-in: the JNI back end `android.system.Os` uses. |
| `libcore.internal.StringPool` | `android.util.JsonReader` | Builds the string; the pooling was an ART allocation optimisation. |
| `libcore.icu.ICU` | `android.text.format.DateFormat` | Approximate. `getDateFormatOrder` is exact; `getBestDateTimePattern` assembles a pattern from the locale's own short date/time formats instead of CLDR `availableFormats`, so field order, separators and the hour cycle follow the locale but wording like `d 'de' MMMM` does not. |
| `libcore.icu.LocaleData` | `android.text.format.DateFormat` | `java.text.DateFormatSymbols` for the formatting names, `java.time` `*_STANDALONE` styles for the stand-alone ones. Month arrays 0-based, weekday arrays 1-based, as libcore has them. |
| `dalvik.system.CloseGuard` | `android.database.*`, `android.os.ParcelFileDescriptor` | No-op: the port does not need leak warnings. |
| `dalvik.system.BlockGuard` | `android.app.SharedPreferencesImpl` | Permissive policy; there is no StrictMode here. |
| `dalvik.system.VMRuntime` | `android.content.res.TypedArray`, `com.android.internal.util.ArrayUtils` | `newUnpaddedArray`/`newNonMovableArray` return plain arrays. `addressOf` returns 0 — HotSpot arrays move and cannot be pinned; a caller that needs a real address has to be fixed in atlas. |
| `dalvik.system.VMDebug.threadCpuTimeNanos` | `android.os.Debug` | `ThreadMXBean`. |
| `android.system.Os` | `android.app.SharedPreferencesImpl`, `android.os.{ParcelFileDescriptor,StatFs}` | `stat`/`lstat`/`statvfs` through NIO; `open`, `dup`, `pipe`, `socketpair`, `lseek`, `read`, `write`, `close`, `fstat` through libportshim.so. |
| `android.system.{OsConstants,ErrnoException,StructStat,StructStatVfs}` | as above | Linux/x86_64 constant values. The constants are read at runtime (libcore fills them from native code), so the values here matter. |
| `android.icu.text.Bidi` | `android.text.AndroidBidi`, i.e. every text layout | Wraps `java.text.Bidi`. The level constants keep ICU's values because AndroidBidi has them inlined. |
| `android.icu.text.PluralRules` | `android.content.res.Resources.getQuantityString` | Approximate: the CLDR default (one/other) plus the Slavic one/few/many family. |
| `android.icu.util.ULocale` | `android.os.LocaleList` | Approximate: `addLikelySubtags` uses a short language-to-script table instead of the CLDR data. |
| `android.icu.text.Collator` | `org.telegram.messenger.TranslateController` | Delegates to `java.text.Collator`. |
| `android.icu.text.RelativeDateTimeFormatter` | `org.telegram.messenger.LocaleController$RelativeIcu` | Approximate and **English only**: the JDK has no relative-time patterns. A localised version needs CLDR data or the framework's own strings. |
| `org.json.*` (`JSONObject`, `JSONArray`, `JSONTokener`, `JSONStringer`, `JSONException`, `JSON`) | `org.telegram.ui.LaunchActivity.getClientNotActivatedFragment` on the boot path, plus 80 more app classes (`ApplicationLoader`, `SharedConfig`, `LoginActivity`, `Theme`) | Written out rather than taking a jar, so the port keeps building with no network. Android has org.json on the boot classpath and the JDK does not, so it is a shim by the same rule as `libcore.*` — even though it is a library rather than a runtime service. Lenient parsing (comments, single quotes, unquoted names) and the coercions org.json documents; `ShimCheck` covers a parse → read → build → `toString` → re-parse round trip. |
| `org.xmlpull.v1.*` | every `Drawable`, `LayoutInflater`, `Resources`, `XmlBlock$Parser` | The XmlPull v1 API (public domain). Constants match the published values because api-impl and the app have them inlined. |
| `org.apache.harmony.xml.parsers.SAXParserFactoryImpl` | `org.telegram.messenger.SvgHelper` (every SVG the app parses: forum topic bubbles, message placeholders), through `javax.xml.parsers.SAXParserFactory.newInstance()` | The JAXP default on ART, and it has to be the default here too — registered in `shim/resources/META-INF/services/javax.xml.parsers.SAXParserFactory`, which is the only thing in the jar that is not a class. Delegates to the JDK's own factory with namespaces always on, because libcore's Expat parser fills in `localName` whether it is namespace-aware or not and Xerces does not; `SvgHelper` switches on `localName`, so without this every SVG parsed into an empty drawable and the first caller indexing into it killed the process (BRINGUP_NOTES.md, under the chat-list bring-up). `isNamespaceAware()` still answers what the caller set. |
| `org.kxml2.io.KXmlParser` | `android.util.Xml.newPullParser()` (`LocaleController` parses language packs with it), `android.util.DecompiledXmlResourceParser` | An `XmlPullParser` over the JDK's StAX. `isEmptyElementTag()` always reports false (StAX does not expose it), `getNamespaceCount()` counts only the current element's declarations, and `defineEntityReplacementText()` is ignored. |

## Fixed in atlas, not shimmed

Commits on `linux-port/atlas` (atl-touch `master`):

* **`api-impl: build against the JDK's java.*, not libcore's`** — api-impl was
  compiled with `-bootclasspath core-all_classes.jar`, so javac bound libcore's
  additions to `java.*`: `System.arraycopy(char[], int, char[], int, int)` and
  its five siblings, `FileDescriptor.getInt$/setInt$`,
  `Socket.getFileDescriptor$`, `LinkedHashMap.eldest()`,
  `Thread.{get,set}UncaughtExceptionPreHandler`. Those call sites link on ART
  and throw `NoSuchMethodError` anywhere else, and **no shim can fix them** —
  `java.*` belongs to the JDK. Compiling with `--release 8` and core-all only on
  the *class* path binds the standard signatures, which ART has too; the five
  files that genuinely used ART-only APIs were changed (new
  `android.atl.FileDescriptorUtils` reaches the descriptor reflectively, and
  needs `--add-opens java.base/java.io=ALL-UNNAMED` on the JVM command line).
  `build-shim.sh` fails if such a reference ever comes back
  (`../tools/JdkRefCheck.java`).
* **`atl: use the runtime's own timezone database when it has the zone`** —
  `ATLTimeZone` built an Android tzdata blob and pushed it into
  `libcore.util.ZoneInfoDB`, because ART returns GMT without one. Any JDK
  already knows the host zone, so it now asks the runtime first. That is why
  `libcore.util.ZoneInfo`, `libcore.util.ZoneInfoDB`, `libcore.io.BufferIterator`
  and `libcore.io.MemoryMappedFile` are **not** in the shim: nothing reaches
  them any more.

## Deferred

Referenced, but no caller the port reaches was found. Listed so the first real
failure is already diagnosed:

* `org.apache.harmony.xml.ExpatReader` — `android.util.Xml.parse()`. No caller
  in the app; a SAX `XMLReader` from `SAXParserFactory` would satisfy it.
* `org.kxml2.io.KXmlSerializer` — `android.util.Xml.newSerializer()`, used by
  exoplayer's DASH manifest writer. `XmlPullParserFactory` skips class names it
  cannot load, so its absence does not break `newPullParser()`.
* `dalvik.system.{DexClassLoader,DexFile}` — `android.app.Instrumentation`,
  which only runs instrumentation tests. There is no dex here at all.

## Framework gaps (atlas territory, not the shim's)

`audit-shim.sh --all` also lists `android.*` classes api-impl does not
implement: camera2, MediaDrm/MediaParser, telecom, `android.window.OnBack*`,
`WindowInsetsAnimation$Callback` and so on. Those are framework gaps to fill in
atlas if a code path needs them, not runtime classes, and they belong to the
bring-up stories rather than here.
