package org.telegram.messenger;

import android.graphics.Bitmap;

import java.lang.reflect.Array;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;

/**
 * Ubuntu Touch's content-hub, reached through the translation layer's
 * android.atl.ATLContentHub. A confined UT app cannot browse the filesystem or
 * the gallery: files arrive through the content-hub broker, which lists the
 * apps that can supply a content type and runs the transfer.
 *
 * Everything here is behind -Dtmessages.contenthub, set only by the Ubuntu
 * Touch package. Without it {@link #isEnabled} is false, nothing is loaded by
 * reflection, and the Android build takes its usual gallery/file paths.
 */
public class ContentHub {

    private static final String ENABLED_PROPERTY = "tmessages.contenthub";
    private static final String HUB_CLASS = "android.atl.ATLContentHub";

    // content-hub type ids, as the broker's peers advertise them
    public static final String TYPE_PICTURES = "pictures";
    public static final String TYPE_VIDEOS = "videos";
    public static final String TYPE_DOCUMENTS = "documents";
    public static final String TYPE_MUSIC = "music";
    public static final String TYPE_ALL = "all";

    private static final int SELECT_MULTIPLE = 1;

    // an imported file carries no mime type, only the name the source app gave it
    private static final HashSet<String> IMAGE_EXTENSIONS = new HashSet<>(Arrays.asList(
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"));
    private static final HashSet<String> VIDEO_EXTENSIONS = new HashSet<>(Arrays.asList(
        "mp4", "mkv", "webm", "mov", "avi", "3gp", "m4v"));

    /** An app that can supply content, as content-hub reports it. */
    public static class Source {
        public final String id;
        public final String name;
        /** The type it was found under; the import has to ask for the same one. */
        public final String type;
        /** The app's icon, or null when the peer carries none we can decode. */
        public final Bitmap icon;

        private Source(String id, String name, String type, Bitmap icon) {
            this.id = id;
            this.name = name;
            this.type = type;
            this.icon = icon;
        }
    }

    private static boolean checked;
    private static boolean enabled;
    private static Method listSources;
    private static Method nativeImport;
    private static Method iconBitmap;

    /** Whether the app should attach files through content-hub instead of its own pickers. */
    public static synchronized boolean isEnabled() {
        if (!checked) {
            checked = true;
            enabled = resolve();
        }
        return enabled;
    }

    private static boolean resolve() {
        String property = System.getProperty(ENABLED_PROPERTY);
        if (property == null || property.length() == 0 || "0".equals(property) || "false".equals(property)) {
            return false;
        }
        try {
            Class<?> hub = Class.forName(HUB_CLASS);
            Class<?> peer = Class.forName(HUB_CLASS + "$Peer");
            listSources = hub.getMethod("listSources", String.class);
            nativeImport = hub.getMethod("nativeImport", String.class, String.class, int.class);
            iconBitmap = hub.getMethod("iconBitmap", peer, int.class);
            return true;
        } catch (Throwable e) {
            FileLog.e("content-hub unavailable", e);
            return false;
        }
    }

    /**
     * The apps that can supply any of {@code types}, in the order the types are
     * given and without duplicates, with their icons decoded to {@code iconSize}
     * px. Blocks on the broker and on icon rasterization, so call it off the UI
     * thread.
     */
    public static ArrayList<Source> listSources(int iconSize, String... types) {
        ArrayList<Source> sources = new ArrayList<>();
        if (!isEnabled()) {
            return sources;
        }
        HashSet<String> seen = new HashSet<>();
        for (String type : types) {
            Object peers;
            try {
                peers = listSources.invoke(null, type);
            } catch (Throwable e) {
                // a type this build of content-hub doesn't know is not an error;
                // a missing native is, and it means there is no broker at all
                FileLog.e("content-hub listSources(" + type + ")", e);
                if (isMissingNatives(e)) {
                    disable();
                    return sources;
                }
                continue;
            }
            if (peers == null) {
                continue;
            }
            for (int a = 0, size = Array.getLength(peers); a < size; a++) {
                Object peer = Array.get(peers, a);
                try {
                    String id = (String) peer.getClass().getField("id").get(peer);
                    String name = (String) peer.getClass().getField("name").get(peer);
                    if (id == null || !seen.add(id)) {
                        continue;
                    }
                    Bitmap icon = null;
                    try {
                        icon = (Bitmap) iconBitmap.invoke(null, peer, iconSize);
                    } catch (Throwable e) {
                        FileLog.e(e);
                    }
                    sources.add(new Source(id, name == null || name.length() == 0 ? id : name, type, icon));
                } catch (Throwable e) {
                    FileLog.e(e);
                }
            }
        }
        return sources;
    }

    /**
     * The translation layer only links the content-hub natives where the broker
     * exists (the device, not the desktop), so the class resolves but its methods
     * do not bind. Callers see {@link #isEnabled} go false and take their normal
     * gallery and file paths from then on.
     */
    private static boolean isMissingNatives(Throwable e) {
        for (Throwable cause = e; cause != null; cause = cause.getCause()) {
            if (cause instanceof UnsatisfiedLinkError) {
                return true;
            }
        }
        return false;
    }

    private static synchronized void disable() {
        enabled = false;
    }

    public static boolean isVideo(String path) {
        return VIDEO_EXTENSIONS.contains(extensionOf(path));
    }

    public static boolean isMedia(String path) {
        String extension = extensionOf(path);
        return IMAGE_EXTENSIONS.contains(extension) || VIDEO_EXTENSIONS.contains(extension);
    }

    private static String extensionOf(String path) {
        if (path == null) {
            return "";
        }
        int dot = path.lastIndexOf('.');
        return dot < 0 ? "" : path.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    /**
     * Import from {@code source}. content-hub foregrounds the source app and the
     * user picks there, so this blocks for as long as they take: it runs on a
     * background thread and answers on the UI thread with the imported files'
     * local paths (empty when the user backed out).
     */
    public static void importFrom(Source source, Utilities.Callback<ArrayList<String>> onResult) {
        Utilities.globalQueue.postRunnable(() -> {
            ArrayList<String> paths = new ArrayList<>();
            try {
                Object result = nativeImport.invoke(null, source.id, source.type, SELECT_MULTIPLE);
                if (result != null) {
                    for (int a = 0, size = Array.getLength(result); a < size; a++) {
                        Object path = Array.get(result, a);
                        if (path != null) {
                            paths.add((String) path);
                        }
                    }
                }
            } catch (Throwable e) {
                FileLog.e("content-hub import from " + source.id, e);
            }
            AndroidUtilities.runOnUIThread(() -> onResult.run(paths));
        });
    }
}
