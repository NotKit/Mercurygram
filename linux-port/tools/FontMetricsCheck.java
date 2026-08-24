import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;

/**
 * Checks that the generic font families resolve to the bundled Roboto, with the
 * metrics Android would give them.
 *
 * The port used to build sans-serif from whatever fontconfig substituted — Noto
 * Sans on a desktop, Ubuntu on the phone. Same textSize, different font: Noto's
 * line box is 1.362 em against Roboto's 1.172, so every line in the app ran ~16%
 * tall and text measured wider than it does on Android (BRINGUP_NOTES.md).
 * TypefaceCollection.cpp now builds those families from res/fonts/ instead.
 *
 * Reads Paint's metrics and measured widths, so it needs no boot — but atlas
 * opens a window on start, so it needs a display.
 */
public class FontMetricsCheck {
	/** Roboto's hhea ascent/descent over unitsPerEm, which is what Skia reports. */
	private static final float ASCENT = -0.9277f, DESCENT = 0.2441f;
	/** ~0.4 px at the 100 px size below: rounding, not a different font. */
	private static final float TOLERANCE = 0.004f;
	/* Large on purpose. Full hinting rounds every glyph advance to a whole
	 * pixel, which at 100 px inflated Roboto Regular from 1974 to 1988 and left
	 * only 5 px between regular and medium -- too little to tell a weight from
	 * rounding. The error stays a few px per line while the widths scale. */
	private static final float SIZE = 400f;
	/** the pangram below in Roboto Regular at that size, from the file itself */
	private static final float ROBOTO_REGULAR_WIDTH = 7896f;
	private static final float MARGIN = 20f;
	private static final String SAMPLE = "The quick brown fox jumps over the lazy dog";

	private static int failures = 0;

	public static void main(String[] args) {
		/* a paint nobody gave a typeface to: naming any typeface used to be
		 * what put the SkFont on Roboto, so every case below hid the paint
		 * starting on fontconfig's default face */
		checkPaint("no typeface", new Paint(Paint.ANTI_ALIAS_FLAG));

		/* the default typeface, which is what most of the app draws with */
		checkMetrics("default", Typeface.DEFAULT);
		checkMetrics("sans-serif", Typeface.create("sans-serif", Typeface.NORMAL));
		checkMetrics("sans-serif-medium", Typeface.create("sans-serif-medium", Typeface.NORMAL));
		checkMetrics("DEFAULT_BOLD", Typeface.DEFAULT_BOLD);

		/* the weight aliases have to be distinct faces, not one substituted
		 * regular: fontconfig answers every sans-serif-* with the same file */
		float regular = width(Typeface.create("sans-serif", Typeface.NORMAL));
		float medium = width(Typeface.create("sans-serif-medium", Typeface.NORMAL));
		float light = width(Typeface.create("sans-serif-light", Typeface.NORMAL));
		float bold = width(Typeface.DEFAULT_BOLD);
		System.out.println("widths: light=" + light + " regular=" + regular
			+ " medium=" + medium + " bold=" + bold);
		/* the real gaps between these faces are 49-114 px at this size, so a
		 * 20 px margin is clear of advance rounding */
		if (!(regular - light > MARGIN && medium - regular > MARGIN
			&& bold - medium > MARGIN)) {
			System.out.println("weights are not distinct: expected light < regular < medium < bold,"
				+ " each by more than " + MARGIN + " px");
			failures++;
		}

		/* and the bundled Roboto has to be what they resolve to */
		if (Math.abs(regular - ROBOTO_REGULAR_WIDTH) > 160f) {
			System.out.println("sans-serif measures " + regular + " px for the pangram at "
				+ SIZE + " px; Roboto Regular is ~" + ROBOTO_REGULAR_WIDTH
				+ ", Noto Sans ~8372, DejaVu Sans ~8997");
			failures++;
		}

		checkEdging();

		if (failures != 0) {
			System.out.println("font metrics check: " + failures + " failure(s)");
			System.exit(1);
		}
		System.out.println("font metrics check: passed");
	}

	/**
	 * ANTI_ALIAS_FLAG has to reach the glyph rasteriser. Text is drawn from
	 * SkFont's edging, not from SkPaint's antialias, so setting only the latter
	 * left every paint antialiasing its text whatever the flag said.
	 */
	private static void checkEdging() {
		int shades = shadesOfGrey(true), aliased = shadesOfGrey(false);
		System.out.println("grey levels in a glyph: antialiased=" + shades
			+ " aliased=" + aliased);
		if (shades <= 2) {
			System.out.println("ANTI_ALIAS_FLAG draws no intermediate shades");
			failures++;
		}
		if (aliased != 2) {
			System.out.println("text without ANTI_ALIAS_FLAG is still antialiased");
			failures++;
		}
	}

	/** Distinct grey levels in a glyph drawn black on white. */
	private static int shadesOfGrey(boolean antiAlias) {
		Bitmap bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888);
		Canvas canvas = new Canvas(bitmap);
		canvas.drawColor(Color.WHITE);
		Paint paint = new Paint(antiAlias ? Paint.ANTI_ALIAS_FLAG : 0);
		paint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
		paint.setColor(Color.BLACK);
		paint.setTextSize(48f);
		/* a round glyph, so the outline crosses the pixel grid at every angle */
		canvas.drawText("e", 8, 48, paint);
		boolean[] seen = new boolean[256];
		int count = 0;
		for (int y = 0; y < 64; y++) {
			for (int x = 0; x < 64; x++) {
				int grey = Color.red(bitmap.getPixel(x, y));
				if (!seen[grey]) {
					seen[grey] = true;
					count++;
				}
			}
		}
		return count;
	}

	private static void checkMetrics(String name, Typeface typeface) {
		checkPaint(name, paint(typeface));
	}

	private static void checkPaint(String name, Paint paint) {
		paint.setTextSize(SIZE);
		Paint.FontMetrics fm = paint.getFontMetrics();
		float ascent = fm.ascent / SIZE, descent = fm.descent / SIZE;
		boolean ok = Math.abs(ascent - ASCENT) < TOLERANCE
			&& Math.abs(descent - DESCENT) < TOLERANCE;
		System.out.printf("%-18s ascent=%+.4f descent=%+.4f line=%.4f em  %s%n",
			name, ascent, descent, descent - ascent, ok ? "roboto" : "NOT ROBOTO");
		if (!ok) {
			System.out.printf("%-18s expected ascent=%+.4f descent=%+.4f%n",
				"", ASCENT, DESCENT);
			failures++;
		}
	}

	private static float width(Typeface typeface) {
		return paint(typeface).measureText(SAMPLE);
	}

	private static Paint paint(Typeface typeface) {
		Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
		paint.setTypeface(typeface);
		paint.setTextSize(SIZE);
		return paint;
	}
}
