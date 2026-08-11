/*
 * Proves, from inside the VM, that the launcher's -D properties arrived.
 *
 * The launcher's own "vm property:" lines are read back through JNI from the
 * launcher process; this class is the other end, run with --vm-check on either
 * launcher. On the image path it is the only evidence that a property crossed
 * into Java rather than merely being accepted by JNI_CreateJavaVM.
 *
 * Built into $PORT_OUT/tools by the script that uses it
 * (linux-port/launcher/image-smoke-test.sh), and compiled into the stub image
 * by linux-port/build-image.sh --stub.
 */
public class VmCheck {

	/* what the launcher must deliver for the framework to boot at all */
	private static final String[] REQUIRED = {
		"Build.VERSION.SDK_INT",
		"atl.apk.path",
		"atl.data.dir",
		"atl.app.id",
		"java.library.path",
	};

	/* delivered by run.sh through -X, and only present when it ran */
	private static final String[] OPTIONAL = {
		"atl.framework.res.path",
		"tmessages.native.path",
		"tmessages.tldump",
		"java.class.path",
		"user.language",
		"user.country",
	};

	public static void main(String[] args) {
		System.err.println("vm check: alive on " + System.getProperty("java.vm.name")
			+ " " + System.getProperty("java.vm.version"));

		int missing = 0;
		for (String key : REQUIRED) {
			String value = System.getProperty(key);
			System.err.println("vm check: " + key + "=" + value);
			if (value == null || value.isEmpty()) {
				System.err.println("vm check: MISSING " + key);
				missing++;
			}
		}
		for (String key : OPTIONAL) {
			String value = System.getProperty(key);
			if (value != null)
				System.err.println("vm check: " + key + "=" + value);
		}

		reportMappedLibraries();

		if (missing > 0) {
			System.err.println("vm check: " + missing + " required properties never reached Java");
			System.exit(1);
		}
		System.err.println("vm check: all " + REQUIRED.length + " required properties reached Java");
	}

	/*
	 * Which shared objects this process actually has mapped, read from inside
	 * the VM rather than from a racing `cat /proc/<pid>/maps` outside it. On the
	 * image path "libjvm.so mapped: no" is the whole point; the port's
	 * own libraries are listed because that is where the VM came from.
	 */
	private static void reportMappedLibraries() {
		java.util.Set<String> objects = new java.util.TreeSet<>();
		boolean libjvm = false;
		try (java.io.BufferedReader maps = new java.io.BufferedReader(
				new java.io.FileReader("/proc/self/maps"))) {
			String line;
			while ((line = maps.readLine()) != null) {
				int slash = line.indexOf(" /");
				if (slash < 0)
					continue;
				String path = line.substring(slash + 1).trim();
				if (!path.contains(".so"))
					continue;
				if (path.endsWith("libjvm.so"))
					libjvm = true;
				/* the distro's own libraries are noise here */
				if (!path.startsWith("/usr/") && !path.startsWith("/lib"))
					objects.add(path);
			}
		} catch (java.io.IOException e) {
			System.err.println("vm check: cannot read /proc/self/maps: " + e);
			return;
		}

		System.err.println("vm check: libjvm.so mapped: " + (libjvm ? "yes" : "no"));
		for (String path : objects)
			System.err.println("vm check: mapped: " + path);
	}
}
