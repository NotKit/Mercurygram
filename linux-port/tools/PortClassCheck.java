// Loads classes off the port classpath and reports what is missing.
//
// Usage: java PortClassCheck <spec>... [--needs-android <spec>...]
//   Class            - resolve the class and its supertypes, without running
//                      static initializers (those pull in android.* / JNI)
//   Class#field      - also initialize the class and require a non-zero int in
//                      that static field (used to prove real resource IDs)
//
// Specs after --needs-android extend android.* directly. They pass either by
// resolving (atlas api-impl.jar on the classpath) or by failing on a missing
// android.* class and nothing else — anything else means the app classpath
// itself is incomplete.
//
// Exits 1 if any check fails, so the caller does not have to parse the output.
public class PortClassCheck {
    public static void main(String[] args) {
        int failed = 0;
        int checked = 0;
        boolean needsAndroid = false;
        for (String spec : args) {
            if (spec.equals("--needs-android")) {
                needsAndroid = true;
                continue;
            }
            checked++;
            int hash = spec.indexOf('#');
            String className = hash < 0 ? spec : spec.substring(0, hash);
            String fieldName = hash < 0 ? null : spec.substring(hash + 1);
            try {
                Class<?> c = Class.forName(className, fieldName != null,
                        PortClassCheck.class.getClassLoader());
                if (fieldName == null) {
                    System.out.println("ok   " + className);
                } else {
                    int value = c.getField(fieldName).getInt(null);
                    if (value == 0) {
                        System.out.println("FAIL " + spec + ": zero id (stub R class?)");
                        failed++;
                    } else {
                        System.out.printf("ok   %s = 0x%08x%n", spec, value);
                    }
                }
            } catch (NoClassDefFoundError e) {
                String missing = String.valueOf(e.getMessage());
                if (needsAndroid && missing.startsWith("android/")) {
                    System.out.println("ok   " + spec + " (pending framework jar: " + missing + ")");
                } else {
                    System.out.println("FAIL " + spec + ": missing " + missing);
                    failed++;
                }
            } catch (Throwable t) {
                System.out.println("FAIL " + spec + ": " + t);
                failed++;
            }
        }
        if (failed > 0) {
            System.out.println(failed + " of " + checked + " checks failed");
            System.exit(1);
        }
        System.out.println("all " + checked + " checks passed");
    }
}
