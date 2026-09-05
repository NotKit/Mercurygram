import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Stream;

/**
 * Reports the framework methods and fields an app class names but atlas does
 * not have.
 *
 * A missing method is a NoSuchMethodError at the moment the line runs, not at
 * class load, so it hides until exactly the wrong time: VoIPService.onCreate
 * died on AudioManager.registerMediaButtonEventReceiver halfway through
 * starting a call, and since it is an Error the app's own catch (Exception)
 * did not stop it killing the process. Reading the constant pool finds the
 * whole set at once instead of one per device round trip.
 *
 * Usage: FrameworkApiCheck <class-dir> [<class-dir>...]
 * Everything is resolved against this JVM's class path, so run it with atlas's
 * api-impl.jar (plus the shim) on that path.
 */
public class FrameworkApiCheck {

	/** Only these owners are atlas's problem; app and library classes are not. */
	private static boolean isFramework(String internalName) {
		return internalName.startsWith("android/")
				|| internalName.startsWith("dalvik/")
				|| internalName.startsWith("libcore/")
				|| internalName.startsWith("javax/microedition/");
	}

	public static void main(String[] args) throws Exception {
		if (args.length == 0) {
			System.out.println("usage: FrameworkApiCheck <class-dir>...");
			System.exit(2);
		}

		Set<String> missing = new LinkedHashSet<>();
		Set<String> missingClasses = new LinkedHashSet<>();
		int scanned = 0;

		for (String dir : args) {
			try (Stream<Path> paths = Files.walk(Paths.get(dir))) {
				List<Path> classes = paths.filter(p -> p.toString().endsWith(".class")).toList();
				for (Path p : classes) {
					scanned++;
					try (InputStream in = Files.newInputStream(p)) {
						check(new ConstantPool(in), missing, missingClasses);
					} catch (IOException e) {
						System.out.println("could not read " + p + ": " + e);
					}
				}
			}
		}

		System.out.println("scanned " + scanned + " classes");
		for (String c : missingClasses) {
			System.out.println("MISSING CLASS  " + c);
		}
		for (String m : missing) {
			System.out.println("MISSING        " + m);
		}
		System.out.println("missing: " + (missingClasses.size() + missing.size()));
	}

	private static void check(ConstantPool cp, Set<String> missing, Set<String> missingClasses) {
		for (ConstantPool.Ref ref : cp.refs()) {
			if (!isFramework(ref.owner)) {
				continue;
			}
			String owner = ref.owner.replace('/', '.');
			Class<?> cls;
			try {
				cls = Class.forName(owner, false, FrameworkApiCheck.class.getClassLoader());
			} catch (Throwable t) {
				missingClasses.add(owner);
				continue;
			}
			if (!ref.isMethod) {
				if (!hasField(cls, ref.name)) {
					missing.add(owner + "." + ref.name + " (field)");
				}
				continue;
			}
			if (!hasMethod(cls, ref.name, ref.descriptor)) {
				missing.add(owner + "." + ref.name + ref.descriptor);
			}
		}
	}

	private static boolean hasField(Class<?> cls, String name) {
		for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
			try {
				c.getDeclaredField(name);
				return true;
			} catch (NoSuchFieldException ignored) {
				// keep walking
			}
			for (Class<?> i : c.getInterfaces()) {
				if (hasField(i, name)) {
					return true;
				}
			}
		}
		return false;
	}

	private static boolean hasMethod(Class<?> cls, String name, String descriptor) {
		if (name.equals("<init>")) {
			for (Constructor<?> ctor : cls.getDeclaredConstructors()) {
				if (descriptorOf(ctor.getParameterTypes(), void.class).equals(descriptor)) {
					return true;
				}
			}
			return false;
		}
		for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
			if (declares(c, name, descriptor)) {
				return true;
			}
		}
		// default methods and constants come from interfaces
		return interfaceDeclares(cls, name, descriptor);
	}

	private static boolean interfaceDeclares(Class<?> cls, String name, String descriptor) {
		for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
			for (Class<?> i : c.getInterfaces()) {
				if (declares(i, name, descriptor) || interfaceDeclares(i, name, descriptor)) {
					return true;
				}
			}
		}
		return false;
	}

	private static boolean declares(Class<?> c, String name, String descriptor) {
		for (Method m : c.getDeclaredMethods()) {
			if (m.getName().equals(name)
					&& descriptorOf(m.getParameterTypes(), m.getReturnType()).equals(descriptor)) {
				return true;
			}
		}
		return false;
	}

	private static String descriptorOf(Class<?>[] params, Class<?> ret) {
		StringBuilder sb = new StringBuilder("(");
		for (Class<?> p : params) {
			sb.append(typeOf(p));
		}
		return sb.append(')').append(typeOf(ret)).toString();
	}

	private static String typeOf(Class<?> c) {
		if (c == void.class) return "V";
		if (c == boolean.class) return "Z";
		if (c == byte.class) return "B";
		if (c == char.class) return "C";
		if (c == short.class) return "S";
		if (c == int.class) return "I";
		if (c == long.class) return "J";
		if (c == float.class) return "F";
		if (c == double.class) return "D";
		if (c.isArray()) return "[" + typeOf(c.getComponentType());
		return "L" + c.getName().replace('.', '/') + ";";
	}

	/** Just enough class file parsing to read Methodref/Fieldref entries. */
	private static final class ConstantPool {

		record Ref(String owner, String name, String descriptor, boolean isMethod) {}

		private final int[] tags;
		private final int[] classIndex;      // for refs: the Class entry
		private final int[] nameAndType;     // for refs: the NameAndType entry
		private final int[] utf8Index;       // for Class/NameAndType: name index
		private final int[] descIndex;       // for NameAndType: descriptor index
		private final String[] strings;

		ConstantPool(InputStream stream) throws IOException {
			DataInputStream in = new DataInputStream(stream);
			if (in.readInt() != 0xCAFEBABE) {
				throw new IOException("not a class file");
			}
			in.readUnsignedShort(); // minor
			in.readUnsignedShort(); // major
			int count = in.readUnsignedShort();
			tags = new int[count];
			classIndex = new int[count];
			nameAndType = new int[count];
			utf8Index = new int[count];
			descIndex = new int[count];
			strings = new String[count];

			for (int i = 1; i < count; i++) {
				int tag = in.readUnsignedByte();
				tags[i] = tag;
				switch (tag) {
				case 1 -> strings[i] = in.readUTF();
				case 7, 8, 16, 19, 20 -> utf8Index[i] = in.readUnsignedShort();
				case 15 -> { in.readUnsignedByte(); in.readUnsignedShort(); }
				case 9, 10, 11 -> {
					classIndex[i] = in.readUnsignedShort();
					nameAndType[i] = in.readUnsignedShort();
				}
				case 12 -> {
					utf8Index[i] = in.readUnsignedShort();
					descIndex[i] = in.readUnsignedShort();
				}
				case 3, 4, 17, 18 -> in.readInt();
				case 5, 6 -> { in.readLong(); i++; } // long/double take two slots
				default -> throw new IOException("unknown constant pool tag " + tag);
				}
			}
		}

		List<Ref> refs() {
			List<Ref> out = new ArrayList<>();
			for (int i = 1; i < tags.length; i++) {
				int tag = tags[i];
				if (tag != 9 && tag != 10 && tag != 11) {
					continue;
				}
				String owner = strings[utf8Index[classIndex[i]]];
				int nat = nameAndType[i];
				out.add(new Ref(owner, strings[utf8Index[nat]], strings[descIndex[nat]], tag != 9));
			}
			return out;
		}
	}
}
