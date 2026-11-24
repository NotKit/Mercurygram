import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.app.ContextImpl;
import android.atl.ATLLoadedApp;
import android.content.Context;
import android.content.res.Resources;
import android.view.KeyEvent;
import android.widget.EditText;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Runs against the real system clipboard with the launcher's --run-class. */
public class ClipboardCheck {
    public static void main(String[] args) throws Exception {
        String mode = System.getProperty("check.mode", "roundtrip");
        String expected = new String(Files.readAllBytes(Paths.get(
                System.getProperty("check.text"))), StandardCharsets.UTF_8);
        ClipboardManager clipboard = new ClipboardManager();
        if (!mode.equals("paste")) {
            ClipData clip = ClipData.newPlainText("clipboard check", expected);
            clipboard.setPrimaryClip(clip);
        }
        ClipData actual = clipboard.getPrimaryClip();
        require(actual != null && actual.getItemCount() == 1, "missing clipboard item");
        require(expected.contentEquals(actual.getItemAt(0).coerceToText(null)),
                "clipboard text differs");
        require(actual.getDescription().hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN),
                "missing plain text MIME type");
        require(clipboard.hasPrimaryClip() == !expected.isEmpty(), "hasPrimaryClip differs");
        if (mode.equals("editor")) {
            Context context = new ContextImpl(Resources.getSystem(),
                    ATLLoadedApp.getPrimaryApplication(), com.android.internal.R.style.Theme_Material_Light);
            EditText field = new EditText(context);
            field.setText("before|after");
            field.setSelection(6, 7);
            require(shortcut(field, KeyEvent.KEYCODE_V), "Ctrl+V not handled");
            require(("before" + expected + "after").contentEquals(field.getText()), "paste did not replace selection");
            field.setSelection(6 + expected.length(), 6);
            require(shortcut(field, KeyEvent.KEYCODE_X), "Ctrl+X not handled");
            require("beforeafter".contentEquals(field.getText()), "cut did not remove selection");
            require(expected.contentEquals(clipboard.getPrimaryClip().getItemAt(0).coerceToText(null)),
                    "cut did not copy selected text");
            require(shortcut(field, KeyEvent.KEYCODE_A), "Ctrl+A not handled");
            require(shortcut(field, KeyEvent.KEYCODE_C), "Ctrl+C not handled");
            require("beforeafter".contentEquals(clipboard.getText()), "copy did not use selection");
            require(field.onTextContextMenuItem(android.R.id.pasteAsPlainText), "context paste not handled");
        }
        if (mode.equals("clear")) {
            clipboard.clearPrimaryClip();
            require(!clipboard.hasPrimaryClip(), "clipboard did not clear");
        }
        System.out.println("PASS clipboard " + mode + " (" + expected.length() + " UTF-16 units)");
        System.exit(0);
    }

    private static boolean shortcut(EditText field, int keyCode) {
        return field.onKeyDown(keyCode, new KeyEvent(0, 0, KeyEvent.ACTION_DOWN,
                keyCode, 0, KeyEvent.META_CTRL_ON));
    }

    private static void require(boolean condition, String message) {
        if (!condition)
            throw new AssertionError(message);
    }
}
