import Foundation
import CryptoKit

/// A saved test configuration. Selection is deliberately distinct from applying it to Android.
struct DeviceTestProfile: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case captured, randomized }
    var id: UUID
    var name: String
    let createdAt: Date
    let kind: Kind
    /// A test seed, not an Android ID, IMEI, or hardware serial.
    let seed: UUID
    let properties: [String: String]
    let locale: String
    let timezone: String
    /// Version of the synthetic QA generator, absent on captured/legacy profiles.
    var generatorVersion: Int? = nil

    static let propertyKeys = [
        "ro.product.brand", "ro.product.manufacturer", "ro.product.model",
        "ro.product.name", "ro.product.device", "ro.build.id", "ro.build.display.id",
        "ro.build.version.release", "ro.build.version.sdk", "ro.build.version.incremental",
        "ro.build.fingerprint", "ro.build.type", "ro.build.tags"
    ]

    static func capture(_ output: String, name: String = "Hiện trạng") throws -> Self {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasPrefix("["), text.hasSuffix("]"),
                  let separator = text.range(of: "]: [") else { continue }
            values[String(text[text.index(after: text.startIndex)..<separator.lowerBound])] =
                String(text[separator.upperBound..<text.index(before: text.endIndex)])
        }
        guard let model = values["ro.product.model"], !model.isEmpty,
              let sdk = values["ro.build.version.sdk"], Int(sdk) != nil else {
            throw ProfileError("Không đọc được model và SDK từ điện thoại.")
        }
        let result = Self(id: UUID(), name: name, createdAt: Date(), kind: .captured, seed: UUID(),
                          properties: values.filter { propertyKeys.contains($0.key) },
                          locale: values["persist.sys.locale"] ?? "",
                          timezone: values["persist.sys.timezone"] ?? "")
        try result.validate()
        return result
    }

    static func read(adb: URL, serial: String) async throws -> Self {
        let command = try RunningCommand(adb, arguments: ["-s", serial, "shell", "getprop"])
        let result = await command.result(timeout: 12, outputLimit: 256_000)
        guard result.status == 0 else { throw ProfileError("Không đọc được cấu hình qua ADB. " + result.diagnostics) }
        return try capture(result.output)
    }

    static func readVisible(adb: URL, serial: String) async throws -> Self {
        let result = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .deviceProfile, timeout: 12)
        guard result.status == 0,
              let line = result.output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }) else {
            throw ProfileError("Không đọc được cấu hình qua API Android. " + result.diagnostics)
        }
        return try decodeVisible(Data(line.utf8))
    }

    static func decodeVisible(_ data: Data) throws -> Self {
        struct Visible: Decodable {
            let schemaVersion: Int
            let scope: String
            let properties: [String: String]
            let locale: String
            let timezone: String
        }
        let value = try JSONDecoder().decode(Visible.self, from: data)
        guard value.schemaVersion == 1, value.scope == "shell_process" else {
            throw ProfileError("Kết quả API Android sai phiên bản hoặc phạm vi đọc.")
        }
        let profile = Self(id: UUID(), name: "Hiện trạng qua API Android", createdAt: Date(), kind: .captured,
                           seed: UUID(), properties: value.properties, locale: value.locale, timezone: value.timezone)
        try profile.validate()
        return profile
    }

    /// Synthetic QA values, reproducible from the seed and the baseline OS.
    /// A model template changes metadata only; it does not emulate that model's hardware.
    func randomized(name: String, seed: UUID = UUID()) throws -> Self {
        let templates: [(brand: String, maker: String, model: String, product: String, device: String)] = [
            ("samsung", "samsung", "SM-G960N", "starlteks", "starlte"),
            ("samsung", "samsung", "SM-G960F", "starltexx", "starlte"),
            ("google", "Google", "Pixel 3a", "sargo", "sargo"),
            ("google", "Google", "Pixel 4", "flame", "flame")
        ]
        let regions = [("vi-VN", "Asia/Ho_Chi_Minh"), ("en-US", "America/New_York"),
                       ("en-GB", "Europe/London"), ("ja-JP", "Asia/Tokyo")]
        var values = properties
        // These four QA templates cover the Android 10 baseline. For other OS versions keep
        // the captured model, rather than inventing unsupported model/OS combinations.
        if values["ro.build.version.sdk"] == "29", values["ro.build.version.release"]?.split(separator: ".").first == "10" {
            let template = templates[Int(Self.seedNumber(seed, component: "model") % UInt64(templates.count))]
            values["ro.product.brand"] = template.brand
            values["ro.product.manufacturer"] = template.maker
            values["ro.product.model"] = template.model
            values["ro.product.name"] = template.product
            values["ro.product.device"] = template.device
        }
        let region = regions[Int(Self.seedNumber(seed, component: "region") % UInt64(regions.count))]
        let draft = Self(id: UUID(), name: name, createdAt: Date(), kind: .randomized, seed: seed,
                         properties: values, locale: region.0, timezone: region.1)
        return try draft.normalizedQA()
    }

    /// Repair build fields without changing the selected model, OS, seed, UUID, date or region.
    func normalizedQA() throws -> Self {
        guard kind == .randomized else { throw ProfileError("Chỉ đồng bộ cấu hình QA; bản chụp hiện trạng được giữ nguyên.") }
        var values = properties
        let token = seed.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
        let buildID = "PFTEST." + token
        values["ro.build.id"] = buildID
        values["ro.build.display.id"] = buildID
        values["ro.build.version.incremental"] = String(1_000_000_000 + Self.seedNumber(seed, component: "incremental") % 9_000_000_000)
        values["ro.build.type"] = "userdebug"
        values["ro.build.tags"] = "test-keys"
        values["ro.build.fingerprint"] = try Self.fingerprint(values)
        let repaired = Self(id: id, name: name, createdAt: createdAt, kind: kind, seed: seed,
                            properties: values, locale: locale, timezone: timezone, generatorVersion: 2)
        try repaired.validate()
        return repaired
    }

    var needsConsistencyRepair: Bool {
        kind == .randomized && (generatorVersion != 2 || !consistencyIssues.isEmpty)
    }

    var consistencyIssues: [String] {
        var issues: [String] = []
        if let expected = try? Self.fingerprint(properties) {
            if properties["ro.build.fingerprint"] != expected {
                issues.append("Fingerprint không khớp brand/product/device và các trường build")
            }
        } else { issues.append("Thiếu trường hoặc thành phần fingerprint không hợp lệ") }
        // DISPLAY is an independent Android field. Equality is a convention of our QA generator,
        // not a requirement imposed on captured OEM builds.
        if kind == .randomized, properties["ro.build.display.id"] != properties["ro.build.id"] {
            issues.append("Cấu hình QA có display ID khác build ID")
        }
        if properties["ro.build.version.sdk"] == "29", properties["ro.build.version.release"]?.split(separator: ".").first != "10" {
            issues.append("SDK 29 cần đi cùng Android 10 trong mẫu QA")
        }
        return issues
    }

    private static func seedNumber(_ seed: UUID, component: String) -> UInt64 {
        let bytes = SHA256.hash(data: Data(("phonefarm.qa.v2/" + component + "/" + seed.uuidString.lowercased()).utf8))
        return bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func fingerprint(_ values: [String: String]) throws -> String {
        let keys = ["ro.product.brand", "ro.product.name", "ro.product.device", "ro.build.version.release",
                    "ro.build.id", "ro.build.version.incremental", "ro.build.type", "ro.build.tags"]
        let parts = try keys.map { key -> String in
            guard let value = values[key], !value.isEmpty,
                  value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw ProfileError("Không ghép được fingerprint: trường \(key) thiếu hoặc không hợp lệ.")
            }
            return value
        }
        return "\(parts[0])/\(parts[1])/\(parts[2]):\(parts[3])/\(parts[4])/\(parts[5]):\(parts[6])/\(parts[7])"
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              !properties.isEmpty, Set(properties.keys).isSubset(of: Set(Self.propertyKeys)),
              properties.values.allSatisfy({ $0.utf8.count <= 1024 && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              properties["ro.product.model"]?.isEmpty == false,
              let sdk = properties["ro.build.version.sdk"], let sdkNumber = Int(sdk), sdkNumber > 0,
              locale.count <= 64, !locale.contains("\n"), !locale.contains("\0"),
              timezone.isEmpty || TimeZone(identifier: timezone) != nil else {
            throw ProfileError("Profile không hợp lệ hoặc có trường chưa được hỗ trợ.")
        }
        guard generatorVersion == nil || generatorVersion == 2 else {
            throw ProfileError("Phiên bản bộ sinh QA chưa được hỗ trợ.")
        }
        if generatorVersion == 2 {
            guard kind == .randomized, consistencyIssues.isEmpty,
                  properties["ro.build.type"] == "userdebug", properties["ro.build.tags"] == "test-keys",
                  properties["ro.build.id"]?.hasPrefix("PFTEST.") == true,
                  properties["ro.build.version.incremental"]?.range(of: #"^[0-9]{10}$"#, options: .regularExpression) != nil else {
                throw ProfileError("Các trường cấu hình QA không nhất quán. Hãy đồng bộ lại từ seed đã lưu.")
            }
        }
    }

    struct ProfileError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

struct DeviceProfileLibrary: Codable, Equatable {
    var schemaVersion = 1
    /// The physical ADB transport, shared by the library; each profile has its own UUID.
    let serial: String
    var selectedID: UUID?
    var profiles: [DeviceTestProfile] = []

    func validate(for expectedSerial: String) throws {
        guard schemaVersion == 1, serial == expectedSerial, profiles.count <= 1000,
              Set(profiles.map(\.id)).count == profiles.count,
              selectedID == nil || profiles.contains(where: { $0.id == selectedID }) else {
            throw DeviceTestProfile.ProfileError("Thư viện profile sai phiên bản, sai máy hoặc bị hỏng. File gốc được giữ nguyên.")
        }
        try profiles.forEach { try $0.validate() }
    }
}

/// One atomic JSON file per physical ADB serial; selecting a profile never changes the phone.
struct DeviceProfileRepository {
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Phone Farm/device-profiles", isDirectory: true)) {
        self.directory = directory
    }

    func url(serial: String) -> URL {
        let hash = SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    func load(serial: String) throws -> DeviceProfileLibrary {
        let file = url(serial: serial)
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(serial: serial) }
        let library = try Self.decode(Data(contentsOf: file), serial: serial)
        return library
    }

    static func decode(_ data: Data, serial: String) throws -> DeviceProfileLibrary {
        guard data.count <= 8_000_000 else { throw DeviceTestProfile.ProfileError("File profile quá lớn.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(DeviceProfileLibrary.self, from: data)
        try library.validate(for: serial)
        return library
    }

    static func encode(_ library: DeviceProfileLibrary) throws -> Data {
        try library.validate(for: library.serial)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(library)
    }

    @discardableResult
    func save(_ library: DeviceProfileLibrary, backupExisting: Bool = false) throws -> URL? {
        let data = try Self.encode(library)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = url(serial: library.serial)
        var backup: URL?
        if backupExisting, FileManager.default.fileExists(atPath: file.path) {
            let folder = directory.appendingPathComponent("backups", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let destination = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + ".json")
            try FileManager.default.copyItem(at: file, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            backup = destination
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return backup
    }
}
