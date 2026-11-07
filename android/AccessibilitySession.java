import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.os.HandlerThread;
import android.os.Looper;

final class AccessibilitySession {
    interface Operation {
        void run(UiAutomation automation) throws Exception;
    }

    static void run(Operation operation) throws Exception {
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
                operation.run(automation);
            } finally {
                UiAutomation.class.getMethod("disconnect").invoke(automation);
            }
        } finally {
            callbacks.quitSafely();
        }
    }
}
