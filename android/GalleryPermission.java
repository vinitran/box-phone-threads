import java.util.Locale;

/** Limit the automatic Allow tap to a system photo/storage request naming Threads. */
final class GalleryPermission {
    static boolean controller(String name) {
        return name.equals("com.android.permissioncontroller") || name.equals("com.google.android.permissioncontroller")
            || name.equals("com.samsung.android.permissioncontroller") || name.equals("com.android.packageinstaller")
            || name.equals("com.google.android.packageinstaller");
    }
    static boolean canAllow(String packageName, String message) {
        if (!controller(packageName)) return false;
        String text = message.toLowerCase(Locale.ROOT);
        if (!text.contains("threads")) return false;
        for (String other : new String[]{"contacts", "danh bạ", "location", "vị trí", "microphone", "micrô", "camera", "máy ảnh"})
            if (text.contains(other)) return false;
        for (String photo : new String[]{"photos", "media", "storage", "files", "ảnh", "bộ nhớ", "tệp"})
            if (text.contains(photo)) return true;
        return false;
    }
}
