import AppKit
import Foundation

/// Keeps the details the device card has no room for: what the AI answered whenever a reply was
/// rejected or cleaned, and the output of every failed ADB step. Written to
/// ~/Library/Application Support/Phone Farm/diagnostics.log (kept under 1 MB) so the exact
/// failure can be copied from the device card and handed over for a fix.
enum DiagnosticLog {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Farm")
            .appendingPathComponent("diagnostics.log")
    }

    private static let queue = DispatchQueue(label: "local.phonefarm.diagnostics-log")

    static func record(_ outcome: String, reason: String, raw: String, cleaned: String? = nil, serial: String? = nil) {
        var entry = "=== \(ISO8601DateFormatter().string(from: Date())) · \(serial.map { $0 + " · " } ?? "")\(outcome) · \(reason)\n"
        entry += "\(serial == nil ? "AI trả về" : "Output"):\n\(raw)\n"
        if let cleaned { entry += "Sau khi làm sạch:\n\(cleaned)\n" }
        entry += "\n"
        let target = file
        queue.async {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: target)
            }
            guard let handle = try? FileHandle(forWritingTo: target) else {
                try? Data(entry.utf8).write(to: target)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        }
    }

    /// Turns a failed ADB step into an error that says what went wrong, and logs the full output.
    static func adbFailure(_ step: String, serial: String, result: CommandResult, timeout: Int? = nil) -> TypingError {
        let reason = adbReason(result, timeout: timeout)
        let lines = result.output.split(whereSeparator: \.isNewline)
        record("ADB lỗi", reason: "\(step): \(reason) (mã thoát \(result.status))",
               raw: lines.isEmpty ? "(không có output)" : lines.suffix(40).joined(separator: "\n"), serial: serial)
        return .commandFailed("\(step): \(reason)")
    }

    static func adbReason(_ result: CommandResult, timeout: Int? = nil) -> String {
        let output = result.output
        let lower = output.lowercased()
        if ["device offline", "no devices/emulators", "error: closed", "protocol fault", "device unauthorized"]
            .contains(where: lower.contains) || lower.range(of: #"device '[^']*' not found"#, options: .regularExpression) != nil {
            return "mất kết nối ADB với điện thoại"
        }
        if result.status == 124 { return "quá \(timeout.map { "\($0) giây" } ?? "thời gian") mà chưa xong" }
        if result.status == 15 { return "ADB không phản hồi, app đã dừng lệnh" }
        if let crash = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("Exception") || $0.contains("Error:") }) {
            return "lỗi trên điện thoại: " + crash.trimmingCharacters(in: .whitespaces).prefix(160)
        }
        if result.status != 0 { return "mã thoát \(result.status)" }
        return "điện thoại trả về kết quả không đọc được"
    }

    /// The newest entries (about 40 KB), whole entries only.
    static func recent(limit: Int = 40_000) -> String {
        queue.sync {}
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return "" }
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        guard let start = tail.range(of: "=== ") else { return String(tail) }
        return String(tail[start.lowerBound...])
    }

    /// Copies a report for one phone: app version, the card's message and the recent log.
    static func copyReport(device: String, message: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let log = recent()
        let report = """
            Phone Farm \(version) · \(device)
            Thông báo trên thẻ: \(message)
            File log: \(file.path)

            \(log.isEmpty ? "(Chưa có lỗi ADB hoặc lần AI bị loại nào được ghi lại.)" : log)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
