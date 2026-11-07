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
    /** Per-comment speed: some replies are typed a little faster or slower than others. */
    private final double sessionPace;
    private final double keyboardWidth;

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
        sessionPace = Math.exp(0.12 * random.nextGaussian());
        Rect q = keyboard.keys.get("q");
        Rect p = keyboard.keys.get("p");
        keyboardWidth = q != null && p != null ? Math.max(1, p.right - q.left) : 1_000;
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
        // A person reads the composer and starts typing after a moment, not instantly.
        if (minimum != maximum) SystemClock.sleep(random.nextLong(700, 2_001));
        // Typed text is not compared with the requested reply: Gboard may change words and typing continues.
        for (int index = 0; index < segments.length(); index++) {
            checkKeyboard();
            JSONObject segment = segments.getJSONObject(index);
            String word = normalize(segment.getString("text"));
            String keys = segment.getString("keys");
            String separator = segment.getString("separator");
            typeWord(word, keys, true);
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

    private void typeWord(String word, String keys, boolean progress) throws Exception {
        boolean checkCase = true;
        // Telex adds keys beyond the visible letters; a trailing tone key gets a short hesitation.
        boolean toneAtEnd = keys.length() > word.length() && "sfrxjSFRXJ".indexOf(keys.charAt(keys.length() - 1)) >= 0;
        for (int index = 0; index < keys.length(); index++) {
            char key = keys.charAt(index);
            if (index > 0) {
                boolean tone = toneAtEnd && index == keys.length() - 1;
                SystemClock.sleep(keyInterval(keys.charAt(index - 1), key, index == 1, tone));
            }
            if (Character.isLetter(key) && (checkCase || Character.isUpperCase(key))) {
                KeyboardReader.Layout state = KeyboardReader.layout(automation);
                if (state.isUppercase() != Character.isUpperCase(key)) tap(keyboard.keys.get("shift"));
                checkCase = false;
            }
            key(key, progress);
            if (Character.isUpperCase(key)) checkCase = true;
        }
    }

    /**
     * Time between two key taps inside a word. Human inter-key intervals are right-skewed
     * (log-normal), grow with the distance the thumb travels and shrink for a repeated key.
     */
    private long keyInterval(char previous, char next, boolean early, boolean tone) {
        if (minimum == maximum) return minimum;
        double median = (minimum + maximum) / 2.0 * sessionPace;
        Rect from = keyboard.keys.get(String.valueOf(Character.toLowerCase(previous)));
        Rect to = keyboard.keys.get(String.valueOf(Character.toLowerCase(next)));
        if (Character.toLowerCase(previous) == Character.toLowerCase(next)) {
            median *= 0.6;
        } else if (from != null && to != null) {
            double distance = Math.hypot(from.centerX() - to.centerX(), from.centerY() - to.centerY());
            median *= 0.8 + 0.45 * Math.min(1, distance / (keyboardWidth * 0.7));
        }
        if (early) median *= 1.15;
        if (tone) median *= 1.35;
        double sample = median * Math.exp(0.33 * random.nextGaussian());
        return Math.round(Math.max(minimum * 0.5, Math.min(maximum * 3.0, sample)));
    }

    /** Log-normal pause scaled by the comment's pace. */
    private long pause(double median, double spread) {
        return Math.round(median * sessionPace * Math.exp(spread * random.nextGaussian()));
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
        if (separator.equals(".") || separator.equals("\n")) {
            SystemClock.sleep(Math.min(4_000, pause(1_300, .35)));
            // Sometimes re-read what was written before the next sentence.
            if (random.nextDouble() < .25) SystemClock.sleep(random.nextLong(800, 2_501));
        } else if (separator.equals(",")) {
            SystemClock.sleep(Math.min(2_500, pause(650, .35)));
        } else {
            SystemClock.sleep(Math.min(1_500, pause(330, .4)));
            // An occasional longer stop, as if thinking about the next word.
            if (random.nextDouble() < .06) SystemClock.sleep(random.nextLong(1_200, 3_501));
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
        // Thumb taps cluster around the key centre, slightly below it.
        double dx = Math.max(-.3, Math.min(.3, .12 * random.nextGaussian()));
        double dy = Math.max(-.25, Math.min(.35, .06 + .1 * random.nextGaussian()));
        float x = rect.centerX() + (float) dx * rect.width();
        float y = rect.centerY() + (float) dy * rect.height();
        float pressure = (float) random.nextDouble(.45, .75);
        long hold = Math.round(Math.max(45, Math.min(160, 85 * Math.exp(.25 * random.nextGaussian()))));
        inject(down, MotionEvent.ACTION_DOWN, x, y, pressure);
        try { SystemClock.sleep(hold); }
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
