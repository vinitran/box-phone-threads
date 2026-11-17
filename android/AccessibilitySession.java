import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;

final class AccessibilitySession {
    interface Operation {
        void run(UiAutomation automation) throws Exception;
    }

    /**
     * Android 10 fills the interactive window list asynchronously after connecting: right away it can be
     * empty or miss the keyboard and Threads. Wait until the count is non-zero and unchanged across
     * three reads (at most 2 s); Android 12 is usually stable on the first reads.
     */
    private static void waitForWindows(UiAutomation automation) {
        long deadline = SystemClock.uptimeMillis() + 2_000;
        int previous = -1;
        int stable = 0;
        while (SystemClock.uptimeMillis() < deadline) {
            int count = automation.getWindows().size();
            stable = count > 0 && count == previous ? stable + 1 : 0;
            if (stable >= 2) return;
            previous = count;
            SystemClock.sleep(150);
        }
    }

    private static void profileFailure(String reason) {
        // Android's app_process can be killed after an uncaught Java exception without forwarding
        // its stack trace to ADB. Emit a fixed, credential-free reason before aborting.
        System.err.println("{\"error\":\"" + reason + "\"}");
        System.err.flush();
        throw new IllegalStateException(reason);
    }

    static void requireProfile() {
        String until = System.getenv("PF_ACTION_DEADLINE");
        if (until != null) {
            try {
                double expiry = Double.parseDouble(until);
                if (!Double.isFinite(expiry) || System.currentTimeMillis() / 1000.0 >= expiry)
                    profileFailure("session_expired");
            } catch (NumberFormatException e) { profileFailure("session_expired"); }
        }
        String expected = System.getenv("PF_EXPECTED_USER");
        if (expected == null) return;
        try {
            int current = (Integer) Class.forName("android.app.ActivityManager")
                .getDeclaredMethod("getCurrentUser").invoke(null);
            if (current != Integer.parseInt(expected)) profileFailure("profile_changed");
        } catch (ReflectiveOperationException e) {
            profileFailure("profile_check_failed");
        }
    }

    static void run(Operation operation) throws Exception {
        requireProfile();
        HandlerThread callbacks = new HandlerThread("PhoneFarmAccessibility");
        callbacks.start();
        try {
            // The ADB shell can query windows without installing an app.
            Class<?> connectionType = Class.forName("android.app.IUiAutomationConnection");
            Object connection = Class.forName("android.app.UiAutomationConnection").getConstructor().newInstance();
            UiAutomation automation = UiAutomation.class.getConstructor(Looper.class, connectionType)
                .newInstance(callbacks.getLooper(), connection);
            UiAutomation.class.getMethod("connect", int.class)
                .invoke(automation, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            try {
                AccessibilityServiceInfo service = automation.getServiceInfo();
                service.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                    | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
                    | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
                automation.setServiceInfo(service);
                waitForWindows(automation);
                requireProfile();
                operation.run(automation);
            } finally {
                UiAutomation.class.getMethod("disconnect").invoke(automation);
            }
        } finally {
            callbacks.quitSafely();
        }
    }
}
