package libcore.icu;

import java.text.SimpleDateFormat;
import java.util.Locale;

/**
 * The two ICU4C entry points android.text.format.DateFormat uses.
 *
 * Approximate: the JDK has no skeleton-to-pattern service, so
 * {@link #getBestDateTimePattern} assembles a pattern from the locale's own
 * short date/time formats instead of from CLDR's availableFormats. Field order,
 * separators and the hour cycle follow the locale; wording like "d 'de' MMMM"
 * does not.
 */
public final class ICU {
	private ICU() {}

	public static String getBestDateTimePattern(String skeleton, Locale locale) {
		if (skeleton == null || skeleton.isEmpty())
			return skeleton;
		if (locale == null)
			locale = Locale.getDefault();

		StringBuilder date = new StringBuilder();
		StringBuilder time = new StringBuilder();
		boolean hour12 = isHour12(locale);
		String weekday = count(skeleton, 'E') > 0 ? repeat('E', count(skeleton, 'E')) : null;
		String datePattern = datePattern(locale);

		// the locale decides the order of the date fields, the skeleton which ones appear
		for (char field : getDateFormatOrder(datePattern)) {
			char asked = count(skeleton, field) > 0 ? field
			    : (field == 'M' && count(skeleton, 'L') > 0 ? 'L' : 0);
			if (asked == 0)
				continue;
			if (date.length() > 0)
				date.append(isTextual(skeleton, asked) ? " " : separator(datePattern));
			date.append(repeat(asked, count(skeleton, asked)));
		}

		if (count(skeleton, 'j') + count(skeleton, 'H') + count(skeleton, 'h') > 0) {
			boolean twelve = count(skeleton, 'h') > 0 || (count(skeleton, 'j') > 0 && hour12);
			// CLDR pads the hour only in the 24-hour cycle, and always pads minutes
			// and seconds, whatever width the skeleton asked for
			time.append(twelve ? "h" : "HH");
			if (count(skeleton, 'm') > 0)
				time.append(":mm");
			if (count(skeleton, 's') > 0)
				time.append(":ss");
			if (twelve)
				time.append(" a");
		}

		StringBuilder out = new StringBuilder();
		if (weekday != null)
			out.append(weekday);
		if (date.length() > 0)
			out.append(out.length() > 0 ? ", " : "").append(date);
		if (time.length() > 0)
			out.append(out.length() > 0 ? " " : "").append(time);
		return out.length() > 0 ? out.toString() : skeleton;
	}

	/**
	 * The order of the day, month and year fields in a numeric date pattern, as
	 * a three-character array of 'd', 'M' and 'y'.
	 */
	public static char[] getDateFormatOrder(String pattern) {
		char[] result = new char[3];
		int at = 0;
		boolean quoted = false;
		for (int i = 0; i < pattern.length() && at < 3; i++) {
			char c = pattern.charAt(i);
			if (c == '\'') {
				quoted = !quoted;
				continue;
			}
			if (quoted)
				continue;
			char field = normalise(c);
			if (field != 'd' && field != 'M' && field != 'y')
				continue;
			if (!contains(result, at, field))
				result[at++] = field;
		}
		return result;
	}

	private static boolean contains(char[] array, int length, char c) {
		for (int i = 0; i < length; i++) {
			if (array[i] == c)
				return true;
		}
		return false;
	}

	/** 'L' (stand-alone month) counts as a month, 'Y' (week year) as a year. */
	private static char normalise(char c) {
		if (c == 'L')
			return 'M';
		if (c == 'Y')
			return 'y';
		return c;
	}

	private static boolean isHour12(Locale locale) {
		String pattern = timePattern(locale);
		return pattern.indexOf('h') >= 0 || pattern.indexOf('K') >= 0;
	}

	private static String datePattern(Locale locale) {
		java.text.DateFormat format = java.text.DateFormat.getDateInstance(java.text.DateFormat.SHORT, locale);
		return format instanceof SimpleDateFormat ? ((SimpleDateFormat)format).toPattern() : "M/d/yy";
	}

	private static String timePattern(Locale locale) {
		java.text.DateFormat format = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT, locale);
		return format instanceof SimpleDateFormat ? ((SimpleDateFormat)format).toPattern() : "h:mm a";
	}

	/** The punctuation the locale puts between numeric date fields. */
	private static String separator(String pattern) {
		for (int i = 0; i < pattern.length(); i++) {
			char c = pattern.charAt(i);
			if (c == '.' || c == '/' || c == '-')
				return String.valueOf(c);
		}
		return " ";
	}

	private static boolean isTextual(String skeleton, char field) {
		return (field == 'M' || field == 'L') && count(skeleton, field) >= 3;
	}

	private static int count(String skeleton, char field) {
		int n = 0;
		for (int i = 0; i < skeleton.length(); i++) {
			if (skeleton.charAt(i) == field)
				n++;
		}
		return n;
	}

	private static String repeat(char c, int n) {
		return String.valueOf(c).repeat(n);
	}
}
