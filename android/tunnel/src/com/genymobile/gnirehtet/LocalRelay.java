/*
 * Phone Farm addition to gnirehtet (Apache License 2.0).
 *
 * Runs the relay inside this app, on the phone's loopback, so the phone reaches the internet over
 * its own Wi-Fi or SIM while every TCP connection still leaves through the HTTP proxy. The app
 * excludes itself from its VPN, so the relay's own sockets use the real network.
 */

package com.genymobile.gnirehtet;

import android.util.Log;

import com.genymobile.gnirehtet.relay.Relay;

public final class LocalRelay {

    private static final String TAG = LocalRelay.class.getSimpleName();
    /** Loopback port of the in-app relay; adb's reverse tunnel uses an abstract socket instead. */
    public static final int PORT = 31499;

    private static volatile boolean enabled;
    private static Thread thread;

    private LocalRelay() {
    }

    public static boolean isEnabled() {
        return enabled;
    }

    /** Starts the relay once per process; Phone Farm force-stops the app to change its proxy. */
    public static synchronized void start() {
        enabled = true;
        if (thread != null) {
            return;
        }
        thread = new Thread(() -> {
            try {
                new Relay(PORT).run();
            } catch (Throwable e) {
                Log.e(TAG, "Local relay stopped", e);
            }
        }, "local-relay");
        thread.setDaemon(true);
        thread.start();
    }
}
