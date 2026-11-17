import android.os.Build;
import org.json.JSONObject;
import java.util.Locale;
import java.util.TimeZone;

/** Reads public Android APIs from a fresh process, without hardware IDs or account data. */
public final class DeviceProfileReader {
    public static void main(String[] args) throws Exception {
        JSONObject properties = new JSONObject();
        properties.put("ro.product.brand", Build.BRAND);
        properties.put("ro.product.manufacturer", Build.MANUFACTURER);
        properties.put("ro.product.model", Build.MODEL);
        properties.put("ro.product.name", Build.PRODUCT);
        properties.put("ro.product.device", Build.DEVICE);
        properties.put("ro.build.id", Build.ID);
        properties.put("ro.build.display.id", Build.DISPLAY);
        properties.put("ro.build.version.release", Build.VERSION.RELEASE);
        properties.put("ro.build.version.sdk", Integer.toString(Build.VERSION.SDK_INT));
        properties.put("ro.build.version.incremental", Build.VERSION.INCREMENTAL);
        properties.put("ro.build.fingerprint", Build.FINGERPRINT);
        properties.put("ro.build.type", Build.TYPE);
        properties.put("ro.build.tags", Build.TAGS);
        JSONObject result = new JSONObject();
        result.put("schemaVersion", 1);
        result.put("scope", "shell_process");
        result.put("properties", properties);
        result.put("locale", Locale.getDefault().toLanguageTag());
        result.put("timezone", TimeZone.getDefault().getID());
        System.out.println(result.toString());
    }
}
