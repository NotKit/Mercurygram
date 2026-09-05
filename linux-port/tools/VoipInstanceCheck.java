import org.telegram.messenger.NativeLoader;
import org.telegram.messenger.voip.NativeInstance;

/**
 * Proves the tgcalls/webrtc JNI bridge is live in the port's libtmessages.so.
 *
 * jni/voip/ is built here (native/voip.cmake), so JNI_OnLoad runs the real
 * tgvoipOnJNILoad instead of the old stub: it registers libtgvoip's methods
 * and looks up the app's AudioRecordJNI/AudioTrackJNI classes. getAllVersions
 * then answers from tgcalls itself, and createVideoCapturer builds the whole
 * Android platform interface (AndroidInterface -> VideoCapturerDevice ->
 * EglBase, Camera1Enumerator).
 *
 * Making an Instance needs an application context, so that half is covered by
 * a boot, not here.
 */
public class VoipInstanceCheck {

	public static void main(String[] args) throws Exception {
		// Same escape hatch the boot uses: -Dtmessages.native.path, since there
		// is no apk to extract the library from here (see NativeLoaderCheck).
		NativeLoader.initNativeLibs(null);
		if (!NativeLoader.loaded()) {
			fail("library not loaded: " + NativeLoader.log);
		}
		System.out.println("library loaded");

		String[] versions = NativeInstance.getAllVersions();
		if (versions.length == 0) {
			fail("tgcalls reported no versions");
		}
		System.out.println("tgcalls versions: " + String.join(", ", versions));

		// libtgvoip's own registration, a different mechanism: RegisterNatives
		// from tgvoipOnJNILoad rather than a statically named symbol.
		int size = org.telegram.messenger.voip.Resampler.convert44to48(
				java.nio.ByteBuffer.allocateDirect(1764), java.nio.ByteBuffer.allocateDirect(1920));
		if (size <= 0) {
			fail("Resampler.convert44to48 returned " + size);
		}
		System.out.println("libtgvoip registered natives work: resampled " + size + " bytes");

		System.out.println("voip instance check: passed");
	}

	private static void fail(String message) {
		System.out.println("FAIL: " + message);
		System.exit(1);
	}
}
