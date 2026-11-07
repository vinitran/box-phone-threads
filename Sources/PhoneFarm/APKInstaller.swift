import Foundation

/// Installs one APK, several split APKs, or an `.apks`/`.xapk` bundle on a phone with ADB.
enum APKInstaller {
    static let extensions = ["apk", "apks", "xapk"]

    struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Returns a short description of what was installed.
    static func install(_ files: [URL], adb: URL, serial: String) async throws -> String {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneFarmAPK-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        var apks: [URL] = []
        for file in files {
            switch file.pathExtension.lowercased() {
            case "apk":
                apks.append(file)
            case "apks", "xapk":
                apks += try await unpack(file, into: work.appendingPathComponent(UUID().uuidString))
            default:
                throw InstallError("\(file.lastPathComponent) không phải file APK.")
            }
        }
        guard !apks.isEmpty else { throw InstallError("Không tìm thấy file APK nào để cài.") }
        // -r keeps the app's data when it is already installed.
        let mode = apks.count == 1 ? ["install", "-r"] : ["install-multiple", "-r"]
        let command = try RunningCommand(adb, arguments: ["-s", serial] + mode + apks.map(\.path))
        let result = await command.result(timeout: 600)
        guard result.status == 0, result.output.contains("Success") else {
            throw InstallError(failureMessage(result.output.isEmpty ? result.diagnostics : result.output))
        }
        return apks.count == 1 ? apks[0].lastPathComponent : "\(apks.count) file APK"
    }

    /// Version name of an installed package, e.g. Threads after an install.
    static func installedVersion(of package: String, adb: URL, serial: String) async -> String? {
        guard let command = try? RunningCommand(adb, arguments: ["-s", serial, "shell", "dumpsys", "package", package]) else { return nil }
        let output = await command.result(timeout: 15).output
        return output.split(whereSeparator: \.isNewline)
            .lazy.compactMap { line -> String? in
                let text = line.trimmingCharacters(in: .whitespaces)
                return text.hasPrefix("versionName=") ? String(text.dropFirst("versionName=".count)) : nil
            }
            .first
    }

    private static func unpack(_ archive: URL, into directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = try RunningCommand(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, directory.path])
        guard await command.result(timeout: 120).status == 0 else {
            throw InstallError("Không giải nén được \(archive.lastPathComponent).")
        }
        // Bundles keep the base and split APKs at the top level; OBB data is not installed here.
        let apks = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "apk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !apks.isEmpty else { throw InstallError("\(archive.lastPathComponent) không chứa file APK.") }
        return apks
    }

    private static func failureMessage(_ output: String) -> String {
        let reason = output.split(whereSeparator: \.isNewline).last { $0.contains("Failure") || $0.contains("INSTALL_") }
            .map(String.init) ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.contains("INSTALL_FAILED_VERSION_DOWNGRADE") {
            return "Máy đang có bản mới hơn file APK này. Gỡ app cũ trước nếu muốn cài bản thấp hơn."
        }
        if reason.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            return "App trên máy được ký bằng chữ ký khác với file APK. Gỡ app cũ trước rồi cài lại."
        }
        if reason.contains("INSTALL_FAILED_NO_MATCHING_ABIS") {
            return "File APK không hỗ trợ kiến trúc CPU của máy này. Hãy chọn bản arm64-v8a."
        }
        if reason.contains("INSTALL_FAILED_MISSING_SPLIT") {
            return "Thiếu file APK phụ (split). Hãy chọn đủ các file APK hoặc dùng file .apks/.xapk."
        }
        if reason.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
            return "Điện thoại không đủ dung lượng trống để cài."
        }
        return reason.isEmpty ? "ADB không xác nhận cài đặt thành công." : reason
    }
}
