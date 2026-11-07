import Foundation

/// Reverse tethering with gnirehtet: phones reach the internet through the Mac over the USB cable.
/// The Mac runs one relay; each phone runs the gnirehtet VPN client, which routes all traffic to it.
enum USBTether {
    static let package = "com.genymobile.gnirehtet"

    struct TetherError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func environment(adb: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adb.path
        environment["PATH"] = adb.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    static func startRelay(gnirehtet: URL, adb: URL) throws -> RunningCommand {
        try RunningCommand(gnirehtet, arguments: ["relay"], environment: environment(adb: adb))
    }

    /// Installs the client when missing, pre-authorizes its VPN, starts it and waits for the VPN.
    static func start(serial: String, gnirehtet: URL, adb: URL) async throws {
        if await AppBundles.installedPackages(adb: adb, serial: serial)?.contains(package) != true {
            let install = await (try RunningCommand(gnirehtet, arguments: ["install", serial], environment: environment(adb: adb)))
                .result(timeout: 120)
            guard install.status == 0 else { throw TetherError("Không cài được gnirehtet lên điện thoại.") }
        }
        // The VPN consent ("Connection request") is stored as the ACTIVATE_VPN app-op. Granting it via adb
        // avoids the dialog, which UI automation cannot see on newer Android versions.
        _ = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "appops", "set", package, "ACTIVATE_VPN", "allow"]))
            .result(timeout: 10)
        let start = await (try RunningCommand(gnirehtet, arguments: ["start", serial], environment: environment(adb: adb)))
            .result(timeout: 30)
        guard start.status == 0 else { throw TetherError("Không khởi động được gnirehtet trên điện thoại.") }
        for _ in 0..<30 {
            if await isConnected(adb: adb, serial: serial) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TetherError("VPN gnirehtet chưa bật. Mở khóa điện thoại và bấm OK nếu Android hỏi quyền VPN.")
    }

    static func stop(serial: String, gnirehtet: URL, adb: URL) async {
        guard let command = try? RunningCommand(gnirehtet, arguments: ["stop", serial], environment: environment(adb: adb)) else { return }
        _ = await command.result(timeout: 10)
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
}
