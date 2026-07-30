import java.io.File;
import java.io.StringReader;
import java.util.Locale;

import org.xmlpull.v1.XmlPullParser;

/**
 * Headless test runner for the compat shim. Runs api-impl code that
 * reaches into libcore/dalvik and checks the answers, so a shim that merely
 * links still fails here if it does the wrong thing.
 *
 * Classpath: out/shim.jar + out/atlas/api-impl.jar, -Djava.library.path=out.
 */
public class ShimCheck {
	private static int failures;

	public static void main(String[] args) {
		check("libportshim.so loads", () -> {
			if (!libcore.io.Posix.isAvailable())
				throw new IllegalStateException("not loaded: " + libcore.io.Posix.loadError());
		});

		// --- api-impl classes that reference the shim ---
		check("android.graphics.Rect", () -> {
			android.graphics.Rect rect = new android.graphics.Rect(1, 2, 11, 22);
			expect(rect.width() == 10 && rect.height() == 20, "wrong size: " + rect);
		});
		check("android.text.TextUtils", () -> {
			expect(android.text.TextUtils.isEmpty(""), "\"\" is empty");
			expect(!android.text.TextUtils.isEmpty("x"), "\"x\" is not empty");
		});
		check("android.text.SpannableStringBuilder (libcore.util.EmptyArray)", () -> {
			android.text.SpannableStringBuilder sb = new android.text.SpannableStringBuilder("abc");
			sb.append("de");
			expect("abcde".contentEquals(sb), "got " + sb);
		});
		check("android.util.ArrayMap (libcore.util.Objects)", () -> {
			android.util.ArrayMap<String, String> map = new android.util.ArrayMap<>();
			map.put("k", "v");
			expect("v".equals(map.entrySet().iterator().next().getValue()), "entrySet is broken");
		});
		check("android.text.AndroidBidi (android.icu.text.Bidi)", () -> {
			char[] text = "abc".toCharArray();
			byte[] levels = new byte[text.length];
			int dir = android.text.AndroidBidi.bidi(2 /* DIR_REQUEST_DEFAULT_LTR */, text, levels);
			expect(dir == 1 /* DIR_LEFT_TO_RIGHT */, "latin text came back rtl");
			char[] rtl = "אבג".toCharArray();
			expect(android.text.AndroidBidi.bidi(2, rtl, new byte[rtl.length]) == -1,
			    "hebrew text came back ltr");
		});
		check("android.os.Process (libcore.io.Libcore)", () -> {
			expect(android.os.Process.myPid() == (int)ProcessHandle.current().pid(), "wrong pid");
			expect(android.os.Process.myTid() > 0, "no tid");
		});
		check("android.util.Xml (org.kxml2.io.KXmlParser)", () -> {
			XmlPullParser parser = android.util.Xml.newPullParser();
			parser.setInput(new StringReader("<root a=\"1\"><child>text</child></root>"));
			expect(parser.next() == XmlPullParser.START_TAG && "root".equals(parser.getName()),
			    "no root start tag");
			expect("1".equals(parser.getAttributeValue(null, "a")), "attribute a is missing");
			expect(parser.next() == XmlPullParser.START_TAG && parser.getDepth() == 2,
			    "child is not at depth 2");
			expect("text".equals(parser.nextText()), "child text is wrong");
			expect(parser.next() == XmlPullParser.END_TAG, "no root end tag");
			expect(parser.next() == XmlPullParser.END_DOCUMENT, "no end of document");
		});
		check("android.text.format.DateFormat (libcore.icu)", () -> {
			String pattern = android.text.format.DateFormat.getBestDateTimePattern(Locale.US, "Hm");
			expect("HH:mm".equals(pattern), "unexpected 24h pattern: " + pattern);
			pattern = android.text.format.DateFormat.getBestDateTimePattern(Locale.US, "hms");
			expect("h:mm:ss a".equals(pattern), "unexpected 12h pattern: " + pattern);
			pattern = android.text.format.DateFormat.getBestDateTimePattern(Locale.US, "yMd");
			expect("M/d/y".equals(pattern), "unexpected en_US date pattern: " + pattern);
			pattern = android.text.format.DateFormat.getBestDateTimePattern(new Locale("ru"), "yMd");
			expect("d.M.y".equals(pattern), "unexpected ru date pattern: " + pattern);
		});

		// --- shim classes on their own ---
		check("android.system.Os.stat", () -> {
			File file = File.createTempFile("shimcheck", null);
			try {
				android.system.StructStat st = android.system.Os.stat(file.getPath());
				expect(android.system.OsConstants.S_ISREG(st.st_mode), "not a regular file");
				expect(st.st_size == 0, "unexpected size " + st.st_size);
				expect(Math.abs(st.st_mtime - System.currentTimeMillis() / 1000) < 60,
				    "mtime is not now: " + st.st_mtime);
			} finally {
				file.delete();
			}
		});
		check("android.system.Os fd calls", () -> {
			java.io.FileDescriptor[] pipe = android.system.Os.pipe();
			byte[] out = {1, 2, 3};
			android.system.Os.write(pipe[1], out, 0, out.length);
			byte[] in = new byte[3];
			expect(android.system.Os.read(pipe[0], in, 0, 3) == 3, "short read");
			expect(java.util.Arrays.equals(out, in), "pipe corrupted the bytes");
			libcore.io.IoUtils.closeQuietly(pipe[0]);
			libcore.io.IoUtils.closeQuietly(pipe[1]);
		});
		check("android.os.StatFs (android.system.Os.statvfs)", () -> {
			android.os.StatFs stat = new android.os.StatFs(System.getProperty("java.io.tmpdir"));
			expect(stat.getBlockSizeLong() > 0 && stat.getAvailableBlocksLong() > 0,
			    "no free space reported");
		});
		check("libcore.io.Memory", () -> {
			byte[] buf = new byte[4];
			libcore.io.Memory.pokeInt(buf, 0, 0x01020304, java.nio.ByteOrder.BIG_ENDIAN);
			expect(buf[0] == 1 && buf[3] == 4, "big-endian poke is wrong");
			expect(libcore.io.Memory.peekInt(buf, 0, java.nio.ByteOrder.BIG_ENDIAN) == 0x01020304,
			    "peek does not round-trip");
			expect(libcore.io.Memory.peekInt(buf, 0, java.nio.ByteOrder.LITTLE_ENDIAN) == 0x04030201,
			    "little-endian peek is wrong");
		});
		check("dalvik.system.VMRuntime", () -> {
			byte[] array = (byte[])dalvik.system.VMRuntime.getRuntime().newUnpaddedArray(byte.class, 7);
			expect(array.length >= 7, "array is too short");
		});
		check("libcore.icu.LocaleData", () -> {
			libcore.icu.LocaleData data = libcore.icu.LocaleData.get(Locale.US);
			expect("January".equals(data.longMonthNames[java.util.Calendar.JANUARY]),
			    "month 0 is " + data.longMonthNames[0]);
			expect("Sunday".equals(data.longWeekdayNames[java.util.Calendar.SUNDAY]),
			    "weekday 1 is " + data.longWeekdayNames[1]);
			expect(data.amPm.length == 2, "no am/pm strings");
			libcore.icu.LocaleData ru = libcore.icu.LocaleData.get(new Locale("ru"));
			expect(!ru.longStandAloneMonthNames[0].equals(ru.longMonthNames[0]),
			    "russian stand-alone months should differ from the formatting ones");
		});
		check("libcore.icu.ICU.getDateFormatOrder", () -> {
			expect(java.util.Arrays.equals(libcore.icu.ICU.getDateFormatOrder("dd.MM.yyyy"),
			           new char[] {'d', 'M', 'y'}),
			    "wrong order for dd.MM.yyyy");
			expect(java.util.Arrays.equals(libcore.icu.ICU.getDateFormatOrder("M/d/yy 'y'"),
			           new char[] {'M', 'd', 'y'}),
			    "wrong order for M/d/yy");
		});
		check("android.icu.text.PluralRules", () -> {
			expect("one".equals(android.icu.text.PluralRules.forLocale(Locale.US).select(1)), "en 1");
			expect("other".equals(android.icu.text.PluralRules.forLocale(Locale.US).select(5)), "en 5");
			android.icu.text.PluralRules ru = android.icu.text.PluralRules.forLocale(new Locale("ru"));
			expect("one".equals(ru.select(21)) && "few".equals(ru.select(3))
			        && "many".equals(ru.select(11)),
			    "russian rules are wrong");
		});
		check("android.icu.text.Collator", () -> {
			android.icu.text.Collator collator = android.icu.text.Collator.getInstance(Locale.US);
			expect(collator.compare("a", "b") < 0 && collator.compare("b", "a") > 0, "wrong order");
		});
		check("android.icu.text.RelativeDateTimeFormatter", () -> {
			android.icu.text.RelativeDateTimeFormatter formatter =
			    android.icu.text.RelativeDateTimeFormatter.getInstance(Locale.US);
			expect("5 minutes ago".equals(formatter.format(5,
			           android.icu.text.RelativeDateTimeFormatter.Direction.LAST,
			           android.icu.text.RelativeDateTimeFormatter.RelativeUnit.MINUTES)),
			    "wrong past wording");
			expect("in 1 hour".equals(formatter.format(1,
			           android.icu.text.RelativeDateTimeFormatter.Direction.NEXT,
			           android.icu.text.RelativeDateTimeFormatter.RelativeUnit.HOURS)),
			    "wrong future wording");
		});
		check("android.icu.util.ULocale", () -> {
			expect("Cyrl".equals(android.icu.util.ULocale
			                         .addLikelySubtags(android.icu.util.ULocale.forLocale(new Locale("ru")))
			                         .getScript()),
			    "ru should be Cyrl");
		});
		check("org.json round trip", () -> {
			org.json.JSONObject parsed = new org.json.JSONObject(
			    "{\"n\": 1, \"s\": \"a\\\"b\", \"f\": 1.5, \"t\": true, \"a\": [1, \"two\", null], \"o\": {\"k\": \"v\"}}");
			expect(parsed.getInt("n") == 1 && parsed.getLong("n") == 1L, "n is not 1");
			expect("a\"b".equals(parsed.getString("s")), "escape not decoded: " + parsed.optString("s"));
			expect(parsed.getDouble("f") == 1.5 && parsed.getBoolean("t"), "f/t are wrong");
			expect(parsed.getJSONArray("a").length() == 3, "array length");
			expect("two".equals(parsed.getJSONArray("a").getString(1)), "a[1]");
			expect(parsed.getJSONArray("a").isNull(2), "a[2] should be null");
			expect("v".equals(parsed.getJSONObject("o").getString("k")), "nested object");
			expect(parsed.optString("missing", "d").equals("d"), "optString fallback");
			expect(!parsed.has("missing") && parsed.isNull("missing"), "missing key");

			org.json.JSONObject built = new org.json.JSONObject();
			built.put("s", "x\"y").put("n", 2).put("a", new org.json.JSONArray().put(1).put(2));
			org.json.JSONObject again = new org.json.JSONObject(built.toString());
			expect("x\"y".equals(again.getString("s")) && again.getInt("n") == 2,
			    "did not survive toString(): " + built);
			expect(again.getJSONArray("a").getInt(1) == 2, "array did not survive toString()");

			// a type the getter cannot coerce has to throw, not return a default
			try {
				parsed.getJSONObject("n");
				throw new AssertionError("getJSONObject on a number did not throw");
			} catch (org.json.JSONException expected) {
			}
		});
		check("libcore.util.NativeAllocationRegistry frees the peer", () -> {
			long freeFunction = libcore.util.NativeAllocationRegistry.SelfTest.freeFunction();
			long before = libcore.util.NativeAllocationRegistry.SelfTest.freeCalls();
			libcore.util.NativeAllocationRegistry registry =
			    new libcore.util.NativeAllocationRegistry(ShimCheck.class.getClassLoader(), freeFunction, 64);

			Object referent = new Object();
			registry.registerNativeAllocation(referent, libcore.util.NativeAllocationRegistry.SelfTest.allocate(64));
			referent = null;

			for (int i = 0; i < 200; i++) {
				if (libcore.util.NativeAllocationRegistry.SelfTest.freeCalls() > before)
					break;
				System.gc();
				Thread.sleep(10);
			}
			expect(libcore.util.NativeAllocationRegistry.SelfTest.freeCalls() == before + 1,
			    "the cleaner never called the free function");

			// and the returned Runnable frees on demand
			Runnable free = registry.registerNativeAllocation(new Object(),
			    libcore.util.NativeAllocationRegistry.SelfTest.allocate(64));
			free.run();
			expect(libcore.util.NativeAllocationRegistry.SelfTest.freeCalls() == before + 2,
			    "the returned Runnable did not free");
		});

		System.out.println(failures == 0 ? "ShimCheck: all checks passed"
		                                 : "ShimCheck: " + failures + " check(s) FAILED");
		System.exit(failures == 0 ? 0 : 1);
	}

	private interface Check {
		void run() throws Exception;
	}

	private static void check(String name, Check body) {
		try {
			body.run();
			System.out.println("  ok    " + name);
		} catch (Throwable t) {
			failures++;
			System.out.println("  FAIL  " + name + ": " + t);
			t.printStackTrace(System.out);
		}
	}

	private static void expect(boolean condition, String message) {
		if (!condition)
			throw new AssertionError(message);
	}
}
