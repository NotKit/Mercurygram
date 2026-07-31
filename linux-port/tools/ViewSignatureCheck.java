import java.io.File;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/**
 * Finds framework classes that are missing from a *View subclass's method
 * signatures*.
 *
 * atlas's View.overridesOnDraw() asks every view for its declared methods
 * before drawing it, and getDeclaredMethods() loads the parameter and return
 * types of all of them. One type the framework does not have turns into a
 * NoClassDefFoundError on the draw, which kills the whole frame -- the view is
 * never at fault, and neither is the method (nothing ever calls it).
 *
 * Usage: ViewSignatureCheck jar...    (the jars are also on the class path)
 * Exits 1 if any view cannot enumerate its methods.
 */
public class ViewSignatureCheck {
	public static void main(String[] args) throws Exception {
		ClassLoader loader = ViewSignatureCheck.class.getClassLoader();
		Class<?> view = Class.forName("android.view.View", false, loader);

		List<String> broken = new ArrayList<>();
		List<String> other = new ArrayList<>();
		int views = 0;
		for (String jar : args) {
			try (JarFile file = new JarFile(new File(jar))) {
				for (Enumeration<JarEntry> e = file.entries(); e.hasMoreElements();) {
					String name = e.nextElement().getName();
					if (!name.endsWith(".class"))
						continue;
					name = name.substring(0, name.length() - 6).replace('/', '.');
					Class<?> cls;
					try {
						cls = Class.forName(name, false, loader);
					} catch (Throwable t) {
						continue; // a class that cannot even load is ClassLoadSweep's business
					}
					if (!view.isAssignableFrom(cls))
						continue;
					views++;
					try {
						cls.getDeclaredMethods();
					} catch (NoClassDefFoundError err) {
						broken.add(cls.getName() + " needs " + err.getMessage().replace('/', '.'));
					} catch (Throwable t) {
						// a view that does not verify is broken too, but for
						// another reason (a wrong supertype in api-impl); it
						// does not take the whole frame down, so only report it
						// first line only: a VerifyError's message is a whole
						// bytecode dump
						other.add(cls.getName() + ": " + String.valueOf(t).split("\n", 2)[0]);
					}
				}
			}
		}

		for (String line : other)
			System.out.println("note: " + line);

		if (!broken.isEmpty()) {
			System.err.println(broken.size() + " view(s) cannot be drawn, their signatures name missing classes:");
			for (String line : broken)
				System.err.println("  " + line);
			System.err.println("add them to api-impl in $ATLAS_DIR (a stub is enough: nothing calls these methods)");
			System.exit(1);
		}
		System.out.println("ok   " + views + " views can enumerate their methods");
	}
}
