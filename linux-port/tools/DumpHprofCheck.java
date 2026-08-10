// Proves android.os.Debug.dumpHprofData exists and fails the way an app expects.
//
// FileLog.dumpMemory() calls it inside `catch (Exception)`. atlas had no such
// method, so the call raised NoSuchMethodError, which that catch does not catch,
// and FileLog.fatal() then killed the app. The framework fix is an honest stub
// in atlas; this check is what says it is there and that a plain
// `catch (Exception)` is enough.
//
// Meant to be run inside the launcher: --run-class DumpHprofCheck.
// Exits non-zero on any failure; System.exit(0) at the end so a stray
// non-daemon thread cannot make the run hang.

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Method;

import android.os.Debug;

public class DumpHprofCheck {

    public static void main(String[] args) throws Exception {
        // 1. the method is declared with AOSP's signature
        Method m = Debug.class.getDeclaredMethod("dumpHprofData", String.class);
        require(m.getReturnType() == void.class, "dumpHprofData returns " + m.getReturnType());
        boolean declaresIOException = false;
        for (Class<?> t : m.getExceptionTypes())
            declaresIOException |= t == IOException.class;
        require(declaresIOException, "dumpHprofData does not declare IOException");
        System.out.println("signature: " + m);

        // 2. FileLog.dumpMemory's own shape: a linked call inside catch (Exception).
        //    Before the fix this frame died with NoSuchMethodError instead.
        File dump = new File(System.getProperty("java.io.tmpdir"), "atl_check_heap.hprof");
        dump.delete();
        String caught;
        try {
            Debug.dumpHprofData(dump.getAbsolutePath());
            caught = null;
        } catch (Exception e) {
            caught = e.getClass().getName() + ": " + e.getMessage();
        }
        if (caught == null) {
            // a later real implementation is fine too, as long as it delivers
            require(dump.isFile() && dump.length() > 0,
                    "dumpHprofData returned normally but " + dump + " is empty or missing");
            System.out.println("wrote a real dump: " + dump.length() + " bytes");
        } else {
            require(caught.startsWith("java.io.IOException"), "dumpHprofData threw " + caught);
            require(!dump.exists(), "dumpHprofData created " + dump + " after failing");
            System.out.println("caught by catch (Exception): " + caught);
        }

        System.out.println("dump-hprof check: passed");
        System.exit(0);
    }

    private static void require(boolean ok, String message) {
        if (!ok) {
            System.out.println("dump-hprof check: FAILED: " + message);
            System.exit(1);
        }
    }
}
