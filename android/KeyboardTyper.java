import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.text.Normalizer;
import java.util.concurrent.ThreadLocalRandom;

final class KeyboardTyper {
    private final UiAutomation automation;
    private final AccessibilityNodeInfo editor;
    private final KeyboardReader.Layout keyboard;
    private final File cancellationMarker;
    private final ThreadLocalRandom random = ThreadLocalRandom.current();
    private final int minimum;
    private final int maximum;
    private final int total;
    private int done;

    private static final class TypingFailure extends Exception {
        final String status;
        TypingFailure(String status) { this.status = status; }
    }

    private KeyboardTyper(UiAutomation automation, JSONObject request) throws Exception {
        this.automation = automation;
        editor = focusedEditor(automation.getRootInActiveWindow());
        if (editor == null) throw new TypingFailure("editor_changed");
        String expectedPackage = request.getString("packageName");
        if (!expectedPackage.contentEquals(editor.getPackageName())) throw new TypingFailure("editor_changed");
        if (request.optBoolean("requireEmpty") && !text().isEmpty()) throw new TypingFailure("draft_exists");
        keyboard = KeyboardReader.layout(automation);
        if (keyboard.keys.size() < 28) throw new TypingFailure("keyboard_unavailable");
        cancellationMarker = new File(System.getenv("CLASSPATH"));
        minimum = Math.max(30, request.getInt("minimumDelay"));
        maximum = Math.min(1_000, request.getInt("maximumDelay"));
        if (maximum < minimum) throw new TypingFailure("invalid_request");
        JSONArray segments = request.getJSONArray("segments");
        int count = 0;
        for (int index = 0; index < segments.length(); index++) {
            JSONObject segment = segments.getJSONObject(index);
            count += segment.getString("keys").length() + segment.getString("separator").length();
        }
        total = count;
    }

    static JSONObject type(UiAutomation automation, JSONObject request) throws Exception {
        try {
            KeyboardTyper typer = new KeyboardTyper(automation, request);
            typer.run(request.getJSONArray("segments"));
            return new JSONObject().put("typingStatus", "typed").put("completed", typer.done);
        } catch (TypingFailure failure) {
            return new JSONObject().put("typingStatus", failure.status);
        }
    }

    private void run(JSONArray segments) throws Exception {
        checkFocus();
        // Typed text is not compared with the requested reply: Gboard may change words and typing continues.
        for (int index = 0; index < segments.length(); index++) {
            checkKeyboard();
            JSONObject segment = segments.getJSONObject(index);
            String word = normalize(segment.getString("text"));
            String keys = segment.getString("keys");
            String separator = segment.getString("separator");
            typeWord(keys, true);
            boolean addedSpace = !separator.isEmpty() && !word.isEmpty() && commitSuggestion(word, false);
            if (addedSpace && !separator.equals(" ")) {
                // Gboard adds a space when accepting a candidate. Remove only that new space
                // before punctuation; the next tap must not autocorrect the literal word.
                tap(keyboard.keys.get("delete"));
                SystemClock.sleep(100);
                addedSpace = false;
            }
            if (!separator.isEmpty()) {
                if (addedSpace) reportKey();
                else key(separator.charAt(0), true);
                pauseAfter(separator);
            } else {
                SystemClock.sleep(100);
            }
        }
    }

    private void typeWord(String keys, boolean progress) throws Exception {
        double pace = random.nextDouble(.2, .8);
        boolean checkCase = true;
        for (int index = 0; index < keys.length(); index++) {
            char key = keys.charAt(index);
            if (Character.isLetter(key) && (checkCase || Character.isUpperCase(key))) {
                KeyboardReader.Layout state = KeyboardReader.layout(automation);
                if (state.isUppercase() != Character.isUpperCase(key)) tap(keyboard.keys.get("shift"));
                checkCase = false;
            }
            key(key, progress);
            if (Character.isUpperCase(key)) checkCase = true;
            long delay = minimum;
            if (maximum > minimum) {
                double fraction = Math.max(0, Math.min(1, pace + random.nextDouble(-.2, .2)));
                delay += Math.round((maximum - minimum) * fraction);
            }
            SystemClock.sleep(delay);
        }
    }

    private void key(char key, boolean progress) throws Exception {
        String name = String.valueOf(Character.toLowerCase(key));
        if (key == ' ') name = "space";
        if (key == '\n') name = "enter";
        tap(keyboard.keys.get(name));
        if (progress) {
            reportKey();
        }
    }

    private void reportKey() throws Exception {
        done++;
        System.out.println(new JSONObject().put("event", "progress").put("stage", "typing")
            .put("completed", done).put("total", total));
        System.out.flush();
    }

    private boolean commitSuggestion(String word, boolean force) throws Exception {
        KeyboardReader.Layout state = KeyboardReader.layout(automation);
        Rect suggestion = state.suggestions.get(word);
        Rect q = state.keys.get("q");
        Rect p = state.keys.get("p");
        if (suggestion == null || q == null || p == null || suggestion.bottom > q.top) return false;
        int middle = (q.centerX() + p.centerX()) / 2;
        // The middle suggestion is Gboard's default. Choose the literal word only if it differs.
        if (!force && suggestion.left <= middle && suggestion.right >= middle) return false;
        String before = text();
        tap(suggestion);
        SystemClock.sleep(random.nextLong(140, 221));
        String after = text();
        if (after.length() != before.length() + 1) return false;
        int position = 0;
        while (position < before.length() && before.charAt(position) == after.charAt(position)) position++;
        return after.charAt(position) == ' ' && after.substring(position + 1).equals(before.substring(position));
    }

    private void pauseAfter(String separator) {
        if (minimum == maximum) { SystemClock.sleep(minimum); return; }
        if (separator.equals(".") || separator.equals("\n")) SystemClock.sleep(random.nextLong(450, 901));
        else if (separator.equals(",")) SystemClock.sleep(random.nextLong(250, 551));
        else {
            SystemClock.sleep(random.nextLong(120, 281));
            if (random.nextDouble() < .08) SystemClock.sleep(random.nextLong(180, 421));
        }
    }

    private void checkKeyboard() throws TypingFailure {
        checkFocus();
        KeyboardReader.Layout current = KeyboardReader.layout(automation);
        if (!sameKey(keyboard, current, "q") || !sameKey(keyboard, current, "space")) {
            throw new TypingFailure("keyboard_changed");
        }
    }

    private boolean sameKey(KeyboardReader.Layout first, KeyboardReader.Layout second, String key) {
        Rect rect = first.keys.get(key);
        return rect != null && rect.equals(second.keys.get(key));
    }

    private void checkFocus() throws TypingFailure {
        if (!cancellationMarker.exists()) throw new TypingFailure("cancelled");
        if (!editor.refresh() || !editor.isFocused() || !editor.isEditable()) throw new TypingFailure("editor_changed");
    }

    private String text() throws TypingFailure {
        if (!editor.refresh()) throw new TypingFailure("editor_changed");
        return normalize(editor.getText() == null ? "" : editor.getText().toString());
    }

    private void tap(Rect rect) throws Exception {
        checkFocus();
        if (rect == null || rect.isEmpty()) throw new TypingFailure("keyboard_unavailable");
        long down = SystemClock.uptimeMillis();
        float x = rect.centerX() + (float) random.nextDouble(-.1, .1) * rect.width();
        float y = rect.centerY() + (float) random.nextDouble(-.1, .1) * rect.height();
        float pressure = (float) random.nextDouble(.45, .75);
        inject(down, MotionEvent.ACTION_DOWN, x, y, pressure);
        try { SystemClock.sleep(random.nextLong(30, 61)); }
        finally { inject(down, MotionEvent.ACTION_UP, x, y, 0); }
    }

    private void inject(long down, int action, float x, float y, float pressure) throws TypingFailure {
        MotionEvent.PointerProperties finger = new MotionEvent.PointerProperties();
        finger.id = 0;
        finger.toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerCoords point = new MotionEvent.PointerCoords();
        point.x = x; point.y = y; point.pressure = pressure; point.size = .05f;
        MotionEvent event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1,
            new MotionEvent.PointerProperties[]{finger}, new MotionEvent.PointerCoords[]{point},
            0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            if (!automation.injectInputEvent(event, true)) throw new TypingFailure("input_failed");
        } finally { event.recycle(); }
    }

    private static AccessibilityNodeInfo focusedEditor(AccessibilityNodeInfo root) {
        if (root == null || !root.isVisibleToUser()) return null;
        if (root.isFocused() && root.isEditable()) return root;
        for (int index = 0; index < root.getChildCount(); index++) {
            AccessibilityNodeInfo match = focusedEditor(root.getChild(index));
            if (match != null) return match;
        }
        return null;
    }

    private static String normalize(String value) {
        return Normalizer.normalize(value, Normalizer.Form.NFC);
    }
}
