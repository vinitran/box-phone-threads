import AppKit
import Foundation

/// Keeps what the AI answered whenever the app had to reject or clean a reply, in
/// ~/Library/Application Support/Phone Farm/ai-replies.log (kept under 1 MB), so the
/// exact answer can be copied from the device card and handed over for a fix.
enum AIReplyLog {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Farm")
            .appendingPathComponent("ai-replies.log")
    }

    private static let queue = DispatchQueue(label: "local.phonefarm.ai-replies-log")

    static func record(_ outcome: String, reason: String, raw: String, cleaned: String? = nil) {
        var entry = "=== \(ISO8601DateFormatter().string(from: Date())) · \(outcome) · \(reason)\n"
        entry += "AI trả về:\n\(raw)\n"
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

    /// The newest entries (about 40 KB), whole entries only.
    static func recent(limit: Int = 40_000) -> String {
        queue.sync {}
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return "" }
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        guard let start = tail.range(of: "=== ") else { return String(tail) }
        return String(tail[start.lowerBound...])
    }

    /// Copies a report for one phone: app version, the card's message and the recent AI log.
    static func copyReport(device: String, message: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let log = recent()
        let report = """
            Phone Farm \(version) · \(device)
            Thông báo trên thẻ: \(message)
            File log: \(file.path)

            \(log.isEmpty ? "(Chưa có lần nào AI bị loại hoặc phải làm sạch.)" : log)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
