/** Checks the build flags of the jars the JVM port actually ships. */
public class PortBuildCheck {
    public static void main(String[] args) throws Exception {
        Class<?> library = Class.forName("org.telegram.messenger.BuildConfig");
        Class<?> app = Class.forName("org.telegram.messenger.regular.BuildConfig");
        requireFalse(library, "DEBUG");
        requireFalse(library, "DEBUG_VERSION");
        requireFalse(library, "DEBUG_PRIVATE_VERSION");
        requireFalse(app, "DEBUG");
        if (!"jvm".equals(library.getField("BUILD_TYPE").get(null))
                || !"jvm".equals(app.getField("BUILD_TYPE").get(null))) {
            throw new AssertionError("the classpath contains a different build variant");
        }
        String applicationId = (String)app.getField("APPLICATION_ID").get(null);
        if (!applicationId.endsWith(".beta")) {
            throw new AssertionError("the port's application ID changed");
        }
        System.out.println("JVM build: debug flags disabled, application ID preserved");
    }

    private static void requireFalse(Class<?> config, String name) throws Exception {
        if (config.getField(name).getBoolean(null)) {
            throw new AssertionError(config.getName() + "." + name + " is enabled");
        }
    }
}
