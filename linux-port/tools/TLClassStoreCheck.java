// FR-4: every arm of TLClassStore is instantiated, so a trace registers all of
// them and not just the ones a session happened to take.
//
// TLClassStore.TLdeserialize does `objClass.newInstance()` over a SparseArray of
// 20 constructor ids covering 19 distinct TLRPC classes -- updates, secret-chat
// messages, TL_error, TL_null. A run only ever takes the arms the server sends,
// and a class with no metadata fails newInstance() in an image; the catch there
// is `catch (Throwable) -> FileLog.e` and returns null, so the update is dropped
// in silence instead of crashing. This check takes every arm on purpose.
//
// The class names come from -Dcheck.tlclasses (comma separated), which
// check-tlstore.sh reads out of the built jar's own bytecode, so an arm added
// upstream is covered without editing anything here.
//
// Meant to be run inside the launcher: --run-class TLClassStoreCheck.
// Exits non-zero on any failure; System.exit(0) at the end so a stray
// non-daemon thread cannot make the run hang.

import org.telegram.tgnet.TLClassStore;
import org.telegram.tgnet.TLObject;

public class TLClassStoreCheck {

    public static void main(String[] args) throws Exception {
        String list = System.getProperty("check.tlclasses");
        require(list != null && !list.isEmpty(), "-Dcheck.tlclasses is not set");

        // The store itself has to build first: it is what names these classes.
        require(TLClassStore.Instance() != null, "TLClassStore.Instance() returned null");
        System.out.println("store: TLClassStore.Instance() built");

        String[] names = list.split(",");
        int done = 0;
        for (String name : names) {
            name = name.trim();
            if (name.isEmpty()) {
                continue;
            }
            // Exactly what TLdeserialize does with the class it looks up, so the
            // agent records the same metadata the app will ask for.
            Class<?> objClass = Class.forName(name);
            Object o;
            try {
                o = objClass.newInstance();
            } catch (Throwable e) {
                // TLdeserialize swallows this one and returns null; here it fails.
                System.out.println("tl-class-store check: FAILED: " + name
                        + " cannot be instantiated: " + e);
                System.exit(1);
                return;
            }
            require(o instanceof TLObject, name + " is not a TLObject: " + o.getClass());
            System.out.println("  instantiated " + name);
            done++;
        }

        require(done > 0, "no class names in -Dcheck.tlclasses");
        System.out.println("tl-class-store: " + done + " classes instantiated");
        System.out.println("tl-class-store check: passed");
        System.exit(0);
    }

    private static void require(boolean ok, String message) {
        if (!ok) {
            System.out.println("tl-class-store check: FAILED: " + message);
            System.exit(1);
        }
    }
}
