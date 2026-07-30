import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.TreeSet;

/**
 * Reports which java.* / javax.* members a jar refers to that this JDK does not
 * have.
 *
 * The framework is AOSP code compiled against libcore, which adds methods to
 * java.* classes: System.arraycopy(char[], int, char[], int, int),
 * FileDescriptor.getInt$, LinkedHashMap.eldest and friends. Those call sites
 * link on ART and throw NoSuchMethodError anywhere else, and no shim can fix
 * them because java.* belongs to the JDK -- they have to be compiled away.
 *
 * Input on stdin: one "owner/name:descriptor" per line, as printed by
 * `javap -c` comments. Output: the ones that do not resolve, exit 1 if any.
 */
public class JdkRefCheck {
	public static void main(String[] args) throws Exception {
		BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
		Set<String> missing = new TreeSet<>();
		String line;
		while ((line = in.readLine()) != null) {
			line = line.trim().replace("\"<init>\"", "<init>");
			int colon = line.lastIndexOf(':');
			int dot = colon < 0 ? -1 : line.lastIndexOf('.', colon);
			if (dot < 0)
				continue;
			String owner = line.substring(0, dot).replace('/', '.');
			String name = line.substring(dot + 1, colon);
			String descriptor = line.substring(colon + 1);
			try {
				Class<?> cls = Class.forName(owner, false, JdkRefCheck.class.getClassLoader());
				if (!resolves(cls, name, descriptor))
					missing.add(line);
			} catch (ClassNotFoundException e) {
				missing.add(line + "\t(no such class)");
			}
		}
		missing.forEach(System.out::println);
		System.exit(missing.isEmpty() ? 0 : 1);
	}

	private static boolean resolves(Class<?> cls, String name, String descriptor) {
		if (!descriptor.startsWith("("))
			return field(cls, name, descriptor);
		if (name.equals("<init>")) {
			for (Constructor<?> c : cls.getDeclaredConstructors()) {
				if (descriptorOf(c.getParameterTypes(), void.class).equals(descriptor))
					return true;
			}
			return false;
		}
		for (Class<?> k = cls; k != null; k = k.getSuperclass()) {
			if (method(k, name, descriptor))
				return true;
		}
		for (Class<?> i : interfacesOf(cls)) {
			if (method(i, name, descriptor))
				return true;
		}
		// an interface method ref may name an Object method, which is always inherited
		return cls.isInterface() && method(Object.class, name, descriptor);
	}

	private static boolean method(Class<?> cls, String name, String descriptor) {
		for (Method m : cls.getDeclaredMethods()) {
			if (m.getName().equals(name)
			    && descriptorOf(m.getParameterTypes(), m.getReturnType()).equals(descriptor))
				return true;
		}
		return false;
	}

	private static boolean field(Class<?> cls, String name, String descriptor) {
		for (Class<?> k = cls; k != null; k = k.getSuperclass()) {
			for (Field f : k.getDeclaredFields()) {
				if (f.getName().equals(name) && descriptorOf(f.getType()).equals(descriptor))
					return true;
			}
		}
		for (Class<?> i : interfacesOf(cls)) {
			for (Field f : i.getDeclaredFields()) {
				if (f.getName().equals(name) && descriptorOf(f.getType()).equals(descriptor))
					return true;
			}
		}
		return false;
	}

	private static Set<Class<?>> interfacesOf(Class<?> cls) {
		Set<Class<?>> all = new LinkedHashSet<>();
		for (Class<?> k = cls; k != null; k = k.getSuperclass()) {
			for (Class<?> i : k.getInterfaces()) {
				all.add(i);
				all.addAll(interfacesOf(i));
			}
		}
		return all;
	}

	private static String descriptorOf(Class<?>[] parameters, Class<?> returnType) {
		StringBuilder out = new StringBuilder("(");
		for (Class<?> p : parameters)
			out.append(descriptorOf(p));
		return out.append(')').append(descriptorOf(returnType)).toString();
	}

	private static String descriptorOf(Class<?> cls) {
		if (cls.isArray())
			return "[" + descriptorOf(cls.getComponentType());
		if (cls == void.class)
			return "V";
		if (cls == boolean.class)
			return "Z";
		if (cls == byte.class)
			return "B";
		if (cls == char.class)
			return "C";
		if (cls == short.class)
			return "S";
		if (cls == int.class)
			return "I";
		if (cls == long.class)
			return "J";
		if (cls == float.class)
			return "F";
		if (cls == double.class)
			return "D";
		return "L" + cls.getName().replace('.', '/') + ";";
	}
}
