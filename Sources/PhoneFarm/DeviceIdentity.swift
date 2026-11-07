import Foundation

/// Identity file kept on each phone at /sdcard/PhoneFarm/device.json, so a phone keeps its name,
/// number and proxy when it is plugged into another Mac. Its proxy takes priority over the Mac's database.
struct DeviceIdentity: Codable, Equatable {
    var version = 1
    var name: String?
    var number: Int?
    /// Proxy line in the same format as the Proxy window: host:port or host:port:user:pass.
    var proxy: String?
    var updatedAt: Date?

    static let directory = "/sdcard/PhoneFarm"
    static let path = directory + "/device.json"

    struct IdentityError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    var proxyAddress: String? { proxy.flatMap { ProxyProfile(line: $0)?.endpoint.address } }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Returns nil when the phone has no identity file yet or it cannot be read.
    static func read(adb: URL, serial: String) async -> DeviceIdentity? {
        guard let command = try? RunningCommand(adb, arguments: ["-s", serial, "shell", "cat \(path) 2>/dev/null"]) else { return nil }
        let result = await command.result(timeout: 10, outputLimit: 64_000)
        guard result.status == 0, let start = result.data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return try? decoder.decode(DeviceIdentity.self, from: result.data[start...])
    }

    static func write(_ identity: DeviceIdentity, adb: URL, serial: String) async throws {
        var value = identity
        // Whole seconds, so the value read back from ISO 8601 compares equal.
        value.updatedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("phone-farm-device-\(UUID().uuidString).json")
        try encoder.encode(value).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let mkdir = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "mkdir", "-p", directory])).result(timeout: 10)
        let push = await (try RunningCommand(adb, arguments: ["-s", serial, "push", local.path, path])).result(timeout: 20)
        guard mkdir.status == 0, push.status == 0 else {
            throw IdentityError("Không ghi được \(path) trên điện thoại. " + push.diagnostics)
        }
        guard await read(adb: adb, serial: serial) == value else {
            throw IdentityError("Đã ghi \(path) nhưng đọc lại không khớp.")
        }
    }
}
