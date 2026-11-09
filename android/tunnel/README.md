# Phone Farm Tunnel (Android VPN app)

Fork of the [gnirehtet](https://github.com/Genymobile/gnirehtet) 2.5.1 Android client and Java relay
(Apache License 2.0, see `LICENSE`), installed on phones as `local.phonefarm.tunnel`.

Changes from upstream:

- `relay/` holds gnirehtet's Java relay, run inside the app (`LocalRelay`) when started with
  `--ez localRelay true`. The tunnel then connects to it on `127.0.0.1:31499` instead of the adb
  socket, so the phone uses its own Wi-Fi or SIM. Without `--es proxy host:port` it refuses to start.
- `relay/UpstreamProxy.java` (port of `gnirehtet-relay/src/relay/upstream_proxy.rs`): every TCP
  connection opens through the HTTP proxy with `CONNECT` (`--es proxyAuth` = base64 `user:pass`);
  a refused or failed CONNECT resets the connection. UDP is dropped except DNS (53) and NTP (123).
- The app excludes itself from its VPN (`addDisallowedApplication`) so the in-app relay reaches the
  proxy over the real network.
- `TunnelServer` binds `127.0.0.1` (Android's `getLoopbackAddress()` is `::1`).
- `BuildConfig.java` replaces the Gradle-generated class; app name and notification texts changed.

Over USB, the app behaves like upstream and talks to the relay on the Mac (`gnirehtet-relay/`).

Build with `./build.sh`, which writes `Resources/gnirehtet/gnirehtet.apk`; commit that APK and raise
`android:versionCode` in `AndroidManifest.xml` and `USBTether.apkVersionCode` together so phones update.
