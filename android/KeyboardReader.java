import android.graphics.Rect;
import android.app.UiAutomation;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import java.text.Normalizer;
import java.util.Locale;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import org.json.JSONObject;
import java.io.File;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;

public final class KeyboardReader {
    private static final String GBOARD = "com.google.android.inputmethod.latin";

    public static void main(String[] args) throws Exception {
        AccessibilitySession.run(automation -> {
            if (args.length == 2 && args[0].equals("type")) {
                File file = new File(args[1]);
                JSONObject request;
                try {
                    request = new JSONObject(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
                } finally {
                    file.delete();
                }
                System.out.println(KeyboardTyper.type(automation, request));
                return;
            }
            for (AccessibilityWindowInfo window : automation.getWindows()) {
                if (window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                    visit(window.getRoot(), null);
                }
            }
        });
    }

    static final class Layout {
        final Map<String, Rect> keys = new LinkedHashMap<>();
        final Map<String, Rect> suggestions = new LinkedHashMap<>();
        final Set<String> uppercase = new LinkedHashSet<>();

        boolean isUppercase() { return uppercase.size() >= 13; }
    }

    static Layout layout(UiAutomation automation) {
        Layout layout = new Layout();
        for (AccessibilityWindowInfo window : automation.getWindows()) {
            if (window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD) collect(window.getRoot(), null, layout);
        }
        return layout;
    }

    private static void collect(AccessibilityNodeInfo node, Rect clickable, Layout layout) {
        if (node == null || !node.isVisibleToUser()) return;
        if (node.getPackageName() != null && GBOARD.contentEquals(node.getPackageName())) {
            if (node.isClickable()) {
                clickable = new Rect();
                node.getBoundsInScreen(clickable);
            }
            if (clickable != null && !clickable.isEmpty()) {
                collectLabel(node.getText(), clickable, layout);
                collectLabel(node.getContentDescription(), clickable, layout);
            }
        }
        for (int index = 0; index < node.getChildCount(); index++) collect(node.getChild(index), clickable, layout);
    }

    private static void collectLabel(CharSequence label, Rect rect, Layout layout) {
        if (label == null) return;
        String raw = Normalizer.normalize(label, Normalizer.Form.NFC).trim();
        String key = keyName(raw);
        if (key != null) {
            if (!layout.keys.containsKey(key)) layout.keys.put(key, new Rect(rect));
            if (raw.matches("[A-Z]")) layout.uppercase.add(key);
        } else if (!raw.isEmpty()) {
            layout.suggestions.put(raw, new Rect(rect));
        }
    }

    private static void visit(AccessibilityNodeInfo node, Rect clickableBounds) {
        if (node == null) return;

        CharSequence packageName = node.getPackageName();
        if (packageName != null && GBOARD.contentEquals(packageName) && node.isVisibleToUser()) {
            if (node.isClickable()) {
                clickableBounds = new Rect();
                node.getBoundsInScreen(clickableBounds);
            }
            if (clickableBounds != null && !clickableBounds.isEmpty()) {
                printKey(node.getContentDescription(), clickableBounds);
                printKey(node.getText(), clickableBounds);
            }
        }
        for (int index = 0; index < node.getChildCount(); index++) {
            visit(node.getChild(index), clickableBounds);
        }
    }

    private static void printKey(CharSequence label, Rect bounds) {
        if (label == null) return;

        String key = keyName(label.toString());
        if (key == null) return;
        if (key.matches("[a-z]") && label.toString().matches("[A-Z]")) {
            System.out.println("state\tuppercase\t1");
        }
        System.out.println("key\t" + key + "\t" + bounds.centerX() + "\t" + bounds.centerY());
    }

    private static String keyName(String label) {
        String key = Normalizer.normalize(label, Normalizer.Form.NFC).trim().toLowerCase(Locale.ROOT);
        switch (key) {
            case "space":
            case "spacebar":
            case "dấu cách":
            case "khoảng trắng":
                key = "space";
                break;
            case "shift":
            case "shift enabled":
            case "shift disabled":
            case "shift locked":
            case "caps lock":
            case "viết hoa":
            case "đã bật viết hoa":
                key = "shift";
                break;
            case "enter":
            case "return":
            case "nhập":
            case "xuống dòng":
                key = "enter";
                break;
            case "delete":
            case "backspace":
            case "xóa":
            case "xoá":
                key = "delete";
                break;
            default:
                if (!key.matches("[a-z.,]")) return null;
        }
        return key;
    }
}
