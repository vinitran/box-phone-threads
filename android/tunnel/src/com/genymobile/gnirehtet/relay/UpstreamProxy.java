/*
 * Phone Farm addition to gnirehtet (Apache License 2.0), the Java port of
 * gnirehtet-relay/src/relay/upstream_proxy.rs.
 *
 * Every TCP connection opens through an HTTP proxy with CONNECT. UDP is dropped except DNS and NTP,
 * because an HTTP proxy cannot carry it; QUIC is blocked so apps fall back to TCP through the proxy.
 */

package com.genymobile.gnirehtet.relay;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;

public final class UpstreamProxy {

    private static final String TAG = UpstreamProxy.class.getSimpleName();
    private static final long RESOLVE_CACHE_MS = 5 * 60 * 1000;
    private static final int MAX_RESPONSE_LENGTH = 8192;

    private static volatile UpstreamProxy current;

    private final String host;
    private final int port;
    /** base64("user:pass"), or null. */
    private final String auth;
    private InetSocketAddress resolved;
    private long resolvedAt;

    private UpstreamProxy(String host, int port, String auth) {
        this.host = host;
        this.port = port;
        this.auth = auth;
    }

    /** Sets the proxy from "host:port" and an optional base64 login; null removes it. */
    public static void configure(String address, String auth) {
        if (address == null || address.isEmpty()) {
            current = null;
            return;
        }
        int colon = address.lastIndexOf(':');
        if (colon <= 0) {
            throw new IllegalArgumentException("Invalid proxy address: " + address);
        }
        String host = address.substring(0, colon);
        int port = Integer.parseInt(address.substring(colon + 1));
        current = new UpstreamProxy(host, port, auth == null || auth.isEmpty() ? null : auth);
        Log.i(TAG, "Upstream proxy " + host + ":" + port);
    }

    public static UpstreamProxy get() {
        return current;
    }

    public static boolean allowsUdp(int port) {
        return current == null || port == 53 || port == 123;
    }

    /** Resolves the proxy host, cached for a few minutes. */
    synchronized InetSocketAddress address() throws IOException {
        long now = System.currentTimeMillis();
        if (resolved == null || now - resolvedAt > RESOLVE_CACHE_MS) {
            resolved = new InetSocketAddress(InetAddress.getByName(host), port);
            resolvedAt = now;
        }
        return resolved;
    }

    synchronized void forgetAddress() {
        resolved = null;
    }

    Handshake handshake(InetSocketAddress destination) {
        String target = destination.getAddress().getHostAddress() + ":" + destination.getPort();
        StringBuilder request = new StringBuilder()
                .append("CONNECT ").append(target).append(" HTTP/1.1\r\n")
                .append("Host: ").append(target).append("\r\n");
        if (auth != null) {
            request.append("Proxy-Authorization: Basic ").append(auth).append("\r\n");
        }
        request.append("\r\n");
        return new Handshake(request.toString().getBytes(StandardCharsets.US_ASCII));
    }

    /** One CONNECT exchange on a freshly connected socket. */
    static final class Handshake {
        private final ByteBuffer request;
        private final ByteBuffer one = ByteBuffer.allocate(1);
        private final StringBuilder response = new StringBuilder();
        final long startedAt = System.currentTimeMillis();

        Handshake(byte[] request) {
            this.request = ByteBuffer.wrap(request);
        }

        boolean wantsWrite() {
            return request.hasRemaining();
        }

        /**
         * Writes the request, then reads the reply one byte at a time so no tunnelled byte is consumed.
         *
         * @return true once the proxy accepted the tunnel, false while waiting
         * @throws IOException if the proxy refused or closed the connection
         */
        boolean advance(SocketChannel channel) throws IOException {
            if (request.hasRemaining()) {
                channel.write(request);
                return false;
            }
            while (true) {
                one.clear();
                int r = channel.read(one);
                if (r < 0) {
                    throw new IOException("Proxy closed the connection during CONNECT");
                }
                if (r == 0) {
                    return false;
                }
                response.append((char) (one.get(0) & 0xff));
                if (response.length() > MAX_RESPONSE_LENGTH) {
                    throw new IOException("Proxy response too long");
                }
                int length = response.length();
                if (length >= 4 && response.substring(length - 4).equals("\r\n\r\n")) {
                    String statusLine = response.substring(0, response.indexOf("\r\n"));
                    String[] parts = statusLine.split(" ");
                    if (parts.length >= 2 && parts[1].length() == 3 && parts[1].charAt(0) == '2') {
                        return true;
                    }
                    throw new IOException("Proxy refused CONNECT: " + statusLine);
                }
            }
        }
    }
}
