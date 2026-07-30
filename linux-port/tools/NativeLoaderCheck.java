// Proves NativeLoader loads the port's glibc libtmessages.so.
//
// Meant to be run inside the launcher (--run-class NativeLoaderCheck) with
// -Dtmessages.native.path pointing at the library: the class path, the
// framework and java.library.path are then exactly what a real run has.
//
// Exits non-zero on any failure; System.exit(0) at the end so a stray
// non-daemon thread cannot make the run hang.

import java.lang.reflect.Method;

import org.telegram.messenger.NativeLoader;
import org.telegram.tgnet.NativeByteBuffer;

public class NativeLoaderCheck {

    public static void main(String[] args) throws Exception {
        String path = System.getProperty("tmessages.native.path");
        require(path != null && !path.isEmpty(), "-Dtmessages.native.path is not set");
        require(!NativeLoader.loaded(), "the library was already loaded before initNativeLibs");

        // null Context on purpose: the escape hatch must not need one, since
        // nothing on the desktop has an apk to extract the library from
        NativeLoader.initNativeLibs(null);
        require(NativeLoader.loaded(), "initNativeLibs did not load the library: " + NativeLoader.log);
        System.out.println("NativeLoader.initNativeLibs loaded " + path);

        // Reaching this at all means JNI_OnLoad returned a version rather than
        // -1: image, video and tgnet all registered. Calling one of the methods
        // tgnet registers there proves the registration is live, not just that
        // the .so opened.
        long address = NativeByteBuffer.native_getFreeBuffer(64);
        require(address != 0, "native_getFreeBuffer(64) returned 0");
        require(NativeByteBuffer.native_limit(address) == 64,
                "native_limit disagrees: " + NativeByteBuffer.native_limit(address));
        NativeByteBuffer.native_reuse(address);
        System.out.println("JNI_OnLoad succeeded: tgnet's RegisterNatives methods work");

        // The other lookup path: a Java_org_telegram_* symbol the JVM resolves
        // by name on first call, in the class loader that did the System.load.
        Method init = NativeLoader.class.getDeclaredMethod("init", String.class, boolean.class);
        init.setAccessible(true);
        init.invoke(null, "/dev/null", false);
        System.out.println("statically named entry points resolve: NativeLoader.init");

        System.out.println("native loader check: passed");
        System.exit(0);
    }

    private static void require(boolean ok, String message) {
        if (!ok) {
            System.out.println("native loader check: FAILED: " + message);
            System.exit(1);
        }
    }
}
