import android.util.Base64;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class ProxyCheck {
    public static void main(String[] args) throws Exception {
        JSONObject request = new JSONObject(new String(Base64.decode(args[0], Base64.DEFAULT), StandardCharsets.UTF_8));
        HttpURLConnection connection = null;
        JSONObject result = new JSONObject();
        try {
            // Without a host, check the phone's own route to the internet (the USB tunnel).
            Proxy proxy = request.has("host")
                ? new Proxy(Proxy.Type.HTTP, new InetSocketAddress(request.getString("host"), request.getInt("port")))
                : Proxy.NO_PROXY;
            connection = (HttpURLConnection) new URL("https://api.ipify.org?format=json").openConnection(proxy);
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(10_000);
            connection.setInstanceFollowRedirects(false);
            int status = connection.getResponseCode();
            if (status == 407) {
                result.put("status", "authentication_failed");
            } else if (status != 200) {
                result.put("status", "unreachable");
            } else {
                try (InputStream input = connection.getInputStream()) {
                    ByteArrayOutputStream body = new ByteArrayOutputStream();
                    byte[] buffer = new byte[256];
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        body.write(buffer, 0, count);
                        if (body.size() > 1_024) throw new IllegalStateException("Unexpected proxy response");
                    }
                    String ip = new JSONObject(new String(body.toByteArray(), StandardCharsets.UTF_8)).optString("ip");
                    if (ip.isEmpty()) result.put("status", "unreachable");
                    else result.put("status", "ok").put("ip", ip);
                }
            }
        } catch (Exception error) {
            String message = error.getMessage() == null ? "" : error.getMessage();
            boolean authentication = message.contains("407") || message.toLowerCase(java.util.Locale.ROOT).contains("authenticate");
            result.put("status", authentication ? "authentication_failed" : "unreachable");
        } finally {
            if (connection != null) connection.disconnect();
        }
        System.out.println(result);
    }
}
