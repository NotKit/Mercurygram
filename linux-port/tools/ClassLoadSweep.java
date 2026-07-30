import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/**
 * Loads every class in the given jars without running static initializers and
 * reports what could not be resolved.
 *
 * Class loading only resolves supertypes and interfaces, so a failure here is a
 * linking failure -- the class cannot exist at all -- as opposed to a missing
 * method a code path might never call. That is the difference between "the shim
 * must provide this" and "the shim probably should".
 *
 * Usage: java -cp <classpath> ClassLoadSweep <jar>...
 */
public class ClassLoadSweep {
	public static void main(String[] args) throws Exception {
		List<URL> urls = new ArrayList<>();
		for (String entry : System.getProperty("java.class.path").split(File.pathSeparator))
			urls.add(new File(entry).toURI().toURL());
		URLClassLoader loader =
		    new URLClassLoader(urls.toArray(new URL[0]), ClassLoadSweep.class.getClassLoader().getParent());

		Map<String, Set<String>> missing = new TreeMap<>();
		int loaded = 0, failed = 0;
		for (String jar : args) {
			try (JarFile file = new JarFile(jar)) {
				for (JarEntry entry : Collections.list(file.entries())) {
					if (!entry.getName().endsWith(".class"))
						continue;
					String name = entry.getName()
					                  .substring(0, entry.getName().length() - ".class".length())
					                  .replace('/', '.');
					try {
						Class.forName(name, false, loader);
						loaded++;
					} catch (Throwable t) {
						failed++;
						Throwable cause = t;
						while (cause.getCause() != null)
							cause = cause.getCause();
						String reason = cause.getMessage() == null ? cause.getClass().getName()
						                                           : cause.getMessage().replace('/', '.');
						missing.computeIfAbsent(reason.trim(), k -> new TreeSet<>()).add(name);
					}
				}
			}
		}

		for (Map.Entry<String, Set<String>> entry : missing.entrySet()) {
			System.out.println(entry.getKey() + " (" + entry.getValue().size() + " classes, e.g. "
			    + entry.getValue().iterator().next() + ")");
		}
		System.out.println("loaded " + loaded + ", failed " + failed);
	}
}
