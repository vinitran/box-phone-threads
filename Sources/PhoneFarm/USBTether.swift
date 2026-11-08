import Foundation

/// Internet over the USB cable with gnirehtet. Each phone runs the gnirehtet VPN client, which
/// sends all of its traffic over adb to a relay on the Mac. Every phone gets its own relay
/// (Phone Farm's build of gnirehtet, see gnirehtet-relay/), started with that phone's proxy so
/// each TCP connection leaves through the proxy with HTTP CONNECT. Wi-Fi and mobile data are
/// turned off, so the phone has no other way to the internet. A phone switched to its own network
/// (DeviceManager.NetworkMode.phone) stops the VPN and gets Wi-Fi and data back.
enum USBTether {
    static let package = "com.genymobile.gnirehtet"
    /// Relays listen on consecutive ports from here, one per phone (gnirehtet's default is 31416).
    static let firstPort = 31_420

    struct TetherError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Appends to ~/Library/Application Support/Phone Farm/usb-tether.log, kept under 1 MB.
    static func log(_ serial: String, _ message: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Farm")
        let file = directory.appendingPathComponent("usb-tether.log")
        let line = ISO8601DateFormatter().string(from: Date()) + " " + serial + " " + message + "\n"
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? Data(line.utf8).write(to: file)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    struct Tools {
        let gnirehtet: URL
        let apk: URL

        static var bundled: Tools? {
            guard let gnirehtet = Bundle.main.url(forResource: "gnirehtet", withExtension: nil, subdirectory: "gnirehtet"),
                  let apk = Bundle.main.url(forResource: "gnirehtet", withExtension: "apk", subdirectory: "gnirehtet")
            else { return nil }
            return Tools(gnirehtet: gnirehtet, apk: apk)
        }
    }

    static func environment(tools: Tools, adb: URL, proxy: ProxyProfile? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adb.path
        environment["GNIREHTET_APK"] = tools.apk.path
        environment.removeValue(forKey: "GNIREHTET_PROXY")
        environment.removeValue(forKey: "GNIREHTET_PROXY_AUTH")
        if let proxy {
            environment["GNIREHTET_PROXY"] = proxy.endpoint.address
            if let login = proxy.login {
                environment["GNIREHTET_PROXY_AUTH"] = Data("\(login.username):\(login.password)".utf8).base64EncodedString()
            }
        }
        return environment
    }

    /// Starts the Mac side for one phone. Without a proxy, traffic leaves through the Mac's own network.
    static func startRelay(tools: Tools, adb: URL, port: Int, proxy: ProxyProfile?) throws -> RunningCommand {
        try RunningCommand(tools.gnirehtet, arguments: ["relay", "-p", String(port)],
                           environment: environment(tools: tools, adb: adb, proxy: proxy))
    }

    /// Installs the client when missing, starts its VPN towards the relay on `port`, then cuts
    /// Wi-Fi and mobile data and removes the old per-phone proxy so nothing bypasses the cable.
    static func connect(serial: String, tools: Tools, adb: URL, port: Int) async throws {
        let shell = ["-s", serial, "shell"]
        if await AppBundles.installedPackages(adb: adb, serial: serial)?.contains(package) != true {
            let install = await (try RunningCommand(tools.gnirehtet, arguments: ["install", serial],
                                                    environment: environment(tools: tools, adb: adb)))
                .result(timeout: 120)
            guard install.status == 0 else {
                throw TetherError("Không cài được app gnirehtet lên điện thoại. " + install.diagnostics)
            }
        }
        // The VPN consent ("Connection request") is the ACTIVATE_VPN app-op; granting it avoids the dialog.
        _ = await (try RunningCommand(adb, arguments: shell + ["appops", "set", package, "ACTIVATE_VPN", "allow"]))
            .result(timeout: 10)
        // `start` points the phone's tunnel at this port even when the client is already running.
        let start = await (try RunningCommand(tools.gnirehtet, arguments: ["start", serial, "-p", String(port), "-d", "8.8.8.8,1.1.1.1"],
                                              environment: environment(tools: tools, adb: adb)))
            .result(timeout: 30)
        guard start.status == 0 else {
            throw TetherError("Không khởi động được VPN gnirehtet trên điện thoại. " + start.diagnostics)
        }
        var connected = false
        for _ in 0..<30 {
            if await isConnected(adb: adb, serial: serial) { connected = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard connected else {
            throw TetherError("VPN gnirehtet chưa bật. Mở khóa điện thoại và bấm OK nếu Android hỏi quyền VPN.")
        }
        // The old system-wide proxy would send apps to the proxy a second time inside the tunnel.
        let cleanup = """
            settings put global http_proxy :0; svc wifi disable; svc data disable; \
            for d in /data/local/tmp/phone-farm-proxy-*; do [ -d "$d" ] || continue; \
            [ -f "$d/state.json" ] && CLASSPATH="$d/relay.dex" timeout 8 app_process /system/bin ProxyRelay stop "$d"; \
            rm -rf "$d"; done; true
            """
        _ = await (try RunningCommand(adb, arguments: shell + [cleanup])).result(timeout: 30)
    }

    /// Stops the gnirehtet VPN and turns Wi-Fi and mobile data back on, so the phone uses its own network.
    static func disconnect(serial: String, adb: URL) async throws {
        let stop = "am start -a com.genymobile.gnirehtet.STOP -n \(package)/.GnirehtetActivity >/dev/null 2>&1; "
            + "sleep 1; am force-stop \(package); svc wifi enable; svc data enable; true"
        let result = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", stop])).result(timeout: 30)
        _ = await (try? RunningCommand(adb, arguments: ["-s", serial, "reverse", "--remove", "localabstract:gnirehtet"]))?
            .result(timeout: 10)
        guard result.status == 0 else {
            throw TetherError("Không tắt được VPN gnirehtet trên điện thoại. " + result.diagnostics)
        }
        for _ in 0..<10 {
            if !(await isConnected(adb: adb, serial: serial)) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TetherError("VPN gnirehtet vẫn còn bật trên điện thoại.")
    }

    /// True when a connected VPN network uses gnirehtet's tun0 interface.
    /// Android 10 prints `type: VPN …, state: CONNECTED/CONNECTED`; Android 12 prints `ni{VPN CONNECTED …}`.
    static func isConnected(adb: URL, serial: String) async -> Bool {
        guard let command = try? RunningCommand(adb, arguments: ["-s", serial, "shell", "dumpsys", "connectivity"]) else { return false }
        let output = await command.result(timeout: 10, outputLimit: 400_000).output
        return output.split(whereSeparator: \.isNewline).contains { line in
            line.contains("NetworkAgentInfo") && line.contains("InterfaceName: tun0")
                && (line.contains("CONNECTED/CONNECTED") || line.contains("VPN CONNECTED"))
        }
    }

    /// The address websites see for the phone, read on the phone itself through the tunnel.
    static func publicIP(adb: URL, serial: String) async -> String? {
        struct Result: Decodable { let status: String; let ip: String? }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard let output = try? await AndroidAccessibility.read(adb: adb, serial: serial, entry: .proxyCheck,
                                                                    timeout: 30, payload: Data("{}".utf8)),
                  let line = output.output.split(whereSeparator: \.isNewline).last,
                  let result = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)),
                  result.status == "ok", let ip = result.ip else { continue }
            return ip
        }
        return nil
    }
}

/// Checks a proxy from the Mac with an HTTPS request tunnelled through CONNECT, like the relay does.
enum ProxyTester {
    static func publicIP(through profile: ProxyProfile) async throws -> String {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var config = [
            "proxy = " + quoted("http://" + profile.endpoint.address),
            "proxytunnel",
            "url = \"https://api.ipify.org\"",
            "max-time = 25",
            "silent",
            "write-out = \"\\n%{http_connect} %{http_code}\"",
        ]
        if let login = profile.login {
            config.append("proxy-user = " + quoted(login.username + ":" + login.password))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("phone-farm-proxy-\(UUID().uuidString).conf")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(config.joined(separator: "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw ProxyError.unreachable }
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await (try RunningCommand(URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["-K", file.path]))
            .result(timeout: 30, outputLimit: 8_192)
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        let codes = lines.last?.split(separator: " ").map(String.init) ?? []
        if codes.first == "407" { throw ProxyError.authentication }
        guard result.status == 0, codes.last == "200", lines.count >= 2 else { throw ProxyError.unreachable }
        let ip = lines[lines.count - 2].trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, ip.count <= 45 else { throw ProxyError.unreachable }
        return ip
    }
}
