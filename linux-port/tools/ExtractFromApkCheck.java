// Proves AssetManager.extractFromAPK reads the apk it is given, with no
// class path involved.
//
// Meant to be run inside the launcher (--run-class ExtractFromApkCheck) with
// -Dcheck.apk pointing at the apk. The three assertions are the three
// behaviours a caller depends on: the single-file branch copies real apk bytes,
// a name the apk does not hold is a silent no-op (SoundPool passes bare
// resource entry names), and the directory branch still walks the archive.
//
// Exits non-zero on any failure; System.exit(0) at the end so a stray
// non-daemon thread cannot make the run hang.

import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import android.content.res.AssetManager;
import android.os.Environment;

public class ExtractFromApkCheck {

    private static final String ICON = "res/drawable-mdpi-v4/notification.webp";
    private static final String DIR = "res/drawable-mdpi-v4/";
    private static final String MISSING = "sound_in"; // what SoundPool passes
    private static final int MISSES = 200;
    private static final long MISS_BUDGET_MS = 50;
    // only in framework-res.apk: android.R.drawable.stat_sys_upload
    private static final String FRAMEWORK = "res/drawable-mdpi-v4/stat_sys_upload_anim0.png";

    public static void main(String[] args) throws Exception {
        String apk = System.getProperty("check.apk");
        require(apk != null && !apk.isEmpty(), "-Dcheck.apk is not set");
        File dataDir = Environment.getExternalStorageDirectory();
        System.out.println("apk " + apk + ", data dir " + dataDir);


        // 1. single file: the bytes must be the apk's own, not some other jar's
        File icon = new File(dataDir, ICON);
        require(!icon.exists(), "stale " + icon + ": the mtime guard would hide the copy");
        AssetManager.extractFromAPK(apk, ICON, ICON);
        require(icon.isFile(), "extractFromAPK did not create " + icon);
        byte[] want = entryBytes(apk, ICON);
        byte[] got = Files.readAllBytes(icon.toPath());
        require(java.util.Arrays.equals(want, got),
                "extracted " + got.length + " bytes, the apk entry has " + want.length);
        System.out.println("single file: " + ICON + " extracted, " + got.length
                + " bytes identical to the apk entry");

        // 2. a name the apk does not hold must stay a silent no-op
        File missing = new File(dataDir, MISSING);
        AssetManager.extractFromAPK(apk, MISSING, MISSING);
        require(!missing.exists(), "extractFromAPK created " + missing + " out of nothing");
        System.out.println("missing entry: '" + MISSING + "' threw nothing and created nothing");

        // 3. the directory branch still enumerates the apk
        int inApk = 0;
        try (ZipFile zip = new ZipFile(apk)) {
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements())
                if (entries.nextElement().getName().startsWith(DIR))
                    inApk++;
        }
        require(inApk > 1, "the apk holds only " + inApk + " entries under " + DIR);
        AssetManager.extractFromAPK(apk, DIR, DIR);
        String[] extracted = new File(dataDir, DIR).list();
        require(extracted != null && extracted.length >= inApk,
                "directory branch extracted " + (extracted == null ? 0 : extracted.length)
                        + " of " + inApk + " entries");
        System.out.println("directory: " + extracted.length + " files under " + DIR
                + " for " + inApk + " apk entries");

        // 4. a framework resource is in framework-res.apk, not in the app's apk
        require(entry(apk, FRAMEWORK) == null, apk + " unexpectedly holds " + FRAMEWORK);
        File frameworkFile = new File(dataDir, FRAMEWORK);
        require(!frameworkFile.exists(), "stale " + frameworkFile);
        AssetManager.extractFromAPK(apk, FRAMEWORK, FRAMEWORK);
        require(frameworkFile.isFile(),
                "extractFromAPK did not fall back to framework-res.apk for " + FRAMEWORK);
        System.out.println("framework resource: " + FRAMEWORK + " extracted from framework-res.apk, "
                + frameworkFile.length() + " bytes");

        // 5. an apk that cannot be opened is a miss, not an exception: the only
        //    native caller (util.c extract_from_apk) cannot report one, and the
        //    launcher does not check that --framework-res exists
        File bogusTarget = new File(dataDir, "bogus_target");
        AssetManager.extractFromAPK("/nonexistent/no-such.apk", MISSING, "bogus_target");
        require(!bogusTarget.exists(), "extractFromAPK created " + bogusTarget);
        System.out.println("unreadable apk: '/nonexistent/no-such.apk' threw nothing and created nothing");

        // 6. a miss walks every apk, so it must not re-parse their central
        //    directories: that is SoundPool's and MediaPlayer's normal path.
        //    One cold JarFile open of this apk (64 MB, 9450 entries) measured
        //    0.9 ms, and the old code paid one per apk on every miss.
        //    No timing is taken here for the opens themselves: the JDK shares a
        //    parsed ZipFile.Source between handles on the same file, and the
        //    launcher's own boot extraction already holds this apk open.
        long miss_start = System.nanoTime();
        for (int i = 0; i < MISSES; i++)
            AssetManager.extractFromAPK(apk, MISSING, MISSING);
        long miss_ms = (System.nanoTime() - miss_start) / 1_000_000;
        System.out.println("misses: " + MISSES + " lookups of '" + MISSING + "' in " + miss_ms
                + " ms (budget " + MISS_BUDGET_MS + " ms; two apk opens each would be ~"
                + (MISSES * 2 * 9 / 10) + " ms)");
        require(miss_ms < MISS_BUDGET_MS, "a miss still costs an apk open: " + miss_ms + " ms");

        System.out.println("extract-from-apk check: passed");
        System.exit(0);
    }

    private static byte[] entryBytes(String apk, String name) throws Exception {
        try (ZipFile zip = new ZipFile(apk)) {
            ZipEntry entry = zip.getEntry(name);
            require(entry != null, apk + " has no entry " + name);
            try (InputStream in = zip.getInputStream(entry)) {
                return in.readAllBytes();
            }
        }
    }

    private static ZipEntry entry(String apk, String name) throws Exception {
        try (ZipFile zip = new ZipFile(apk)) {
            return zip.getEntry(name);
        }
    }

    private static void require(boolean ok, String message) {
        if (!ok) {
            System.out.println("extract-from-apk check: FAILED: " + message);
            System.exit(1);
        }
    }
}
