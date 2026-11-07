import android.os.Process;
import android.util.Base64;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.Semaphore;

public final class ProxyRelay {
    public static void main(String[] args) throws Exception {
        File directory = new File(args[args.length - 1]);
        if (!directory.getName().matches("phone-farm-proxy-[a-f0-9-]{36}")) return;
        File state = new File(directory, "state.json");
        if (args.length == 2) {
            if (!state.isFile()) return;
            JSONObject info = new JSONObject(new String(Files.readAllBytes(state.toPath()), StandardCharsets.UTF_8));
            int pid = info.getInt("pid");
            String command = new String(Files.readAllBytes(new File("/proc/" + pid + "/cmdline").toPath()), StandardCharsets.UTF_8);
            if (pid > 1 && command.contains(directory.getName())) {
                Process.sendSignal(pid, 15);
            }
            return;
        }
        File config = new File(directory, "config.json");
        JSONObject request;
        try {
            request = new JSONObject(new String(Files.readAllBytes(config.toPath()), StandardCharsets.UTF_8));
        } finally {
            config.delete();
        }
        String host = request.getString("host");
        int port = request.getInt("port");
        JSONObject login = request.getJSONObject("login");
        String authorization = Base64.encodeToString((login.getString("username") + ":" + login.getString("password"))
            .getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
        ServerSocket listener = new ServerSocket(0, 32, InetAddress.getByName("127.0.0.1"));
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try { listener.close(); } catch (IOException ignored) {}
            state.delete();
        }));
        JSONObject ready = new JSONObject().put("pid", Process.myPid()).put("port", listener.getLocalPort());
        try (FileOutputStream output = new FileOutputStream(state)) {
            output.write(ready.toString().getBytes(StandardCharsets.UTF_8));
        }
        Semaphore clients = new Semaphore(32);
        while (!listener.isClosed()) {
            Socket client = listener.accept();
            if (!clients.tryAcquire()) {
                client.close();
                continue;
            }
            new Thread(() -> {
                try { forward(client, host, port, authorization); }
                catch (IOException ignored) {}
                finally {
                    try { client.close(); } catch (IOException ignored) {}
                    clients.release();
                }
            }, "PhoneFarmProxy").start();
        }
    }

    private static void forward(Socket client, String host, int port, String authorization) throws IOException {
        client.setSoTimeout(30_000);
        InputStream input = client.getInputStream();
        ByteArrayOutputStream header = new ByteArrayOutputStream();
        int matched = 0;
        byte[] delimiter = {'\r', '\n', '\r', '\n'};
        while (matched < delimiter.length) {
            int value = input.read();
            if (value < 0) return;
            header.write(value);
            if (header.size() > 65_536) throw new IOException("Header too large");
            matched = value == delimiter[matched] ? matched + 1 : value == '\r' ? 1 : 0;
        }
        String[] lines = new String(header.toByteArray(), StandardCharsets.ISO_8859_1).split("\r\n");
        String[] request = lines[0].split(" ", 3);
        if (request.length != 3 || !request[2].matches("HTTP/1\\.[01]")) return;
        boolean tunnel = request[0].equals("CONNECT");
        if (!tunnel && !request[1].startsWith("http://")) return;
        StringBuilder authenticated = new StringBuilder(lines[0]).append("\r\n");
        for (int index = 1; index < lines.length; index++) {
            String name = lines[index].split(":", 2)[0].trim();
            if (name.equalsIgnoreCase("Proxy-Authorization") || name.equalsIgnoreCase("Proxy-Connection")) continue;
            if (!tunnel && name.equalsIgnoreCase("Connection")) continue;
            authenticated.append(lines[index]).append("\r\n");
        }
        authenticated.append("Proxy-Authorization: Basic ").append(authorization).append("\r\n");
        if (!tunnel) authenticated.append("Connection: close\r\nProxy-Connection: close\r\n");
        authenticated.append("\r\n");
        try (Socket upstream = new Socket()) {
            upstream.connect(new InetSocketAddress(host, port), 15_000);
            upstream.setSoTimeout(120_000);
            client.setSoTimeout(120_000);
            upstream.getOutputStream().write(authenticated.toString().getBytes(StandardCharsets.ISO_8859_1));
            upstream.getOutputStream().flush();
            Thread upload = new Thread(() -> {
                try {
                    copy(input, upstream.getOutputStream());
                    upstream.shutdownOutput();
                } catch (IOException ignored) {
                    try { upstream.close(); } catch (IOException ignoredAgain) {}
                }
            }, "PhoneFarmProxyUpload");
            upload.start();
            try {
                copy(upstream.getInputStream(), client.getOutputStream());
            } finally {
                // Closing both sockets also releases a client upload waiting for more bytes.
                client.close();
                upstream.close();
                try { upload.join(1_000); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            }
        }
    }

    private static void copy(InputStream input, OutputStream output) throws IOException {
        byte[] buffer = new byte[32_768];
        int count;
        while ((count = input.read(buffer)) != -1) {
            output.write(buffer, 0, count);
            output.flush();
        }
    }
}
