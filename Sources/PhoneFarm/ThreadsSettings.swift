import Foundation
import ImageIO

struct ThreadsSettings: Codable, Equatable {
    var topics: String
    var replyPrompt: String
    var imageFolder: String
    var replyPrompts: [ReplyPrompt]? = nil
    var environment: Environment? = nil
    var runEnvironment: Environment { environment ?? .production }

    enum Environment: String, Codable, CaseIterable {
        case dev, production
        var title: String { self == .dev ? "Dev" : "Production" }
    }

    struct ReplyPrompt: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var text: String
    }

    static func bundledPrompts() throws -> [ReplyPrompt] {
        guard let resources = Bundle.main.resourceURL else { throw SettingsError("Không tìm thấy bộ prompt mặc định.") }
        return try (1...10).map { index in
            let name = String(format: "prompt-bo-tu-%02d.txt", index)
            let file = resources.appendingPathComponent("ThreadsDefaults/prompts/" + name)
            return ReplyPrompt(id: name, name: String(format: "Bộ từ %02d", index),
                               text: try String(contentsOf: file, encoding: .utf8))
        }
    }

    func pickReplyPrompt() -> ReplyPrompt {
        if runEnvironment == .dev {
            return ReplyPrompt(id: "default", name: "Prompt mặc định · Dev", text: replyPrompt)
        }
        return replyPrompts?.randomElement() ?? ReplyPrompt(id: "custom", name: "Prompt mặc định", text: replyPrompt)
    }

    static let defaultTopics = "mua sắm online, hỏi mua đồ, xin review, đánh giá sản phẩm, so sánh sản phẩm, săn sale, mã giảm giá, voucher, freeship, giỏ hàng, chốt đơn, shopee, sàn S, tiktok shop, tíc tóc, lazada, mua quà, đồ gia dụng, đồ dùng học tập, phụ kiện điện thoại, mỹ phẩm, skincare, quần áo, thời trang, outfit, váy, giày, túi xách, đồ ăn đặt online"

    struct SettingsError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @MainActor static func defaults() throws -> ThreadsSettings {
        guard let resources = Bundle.main.resourceURL else { throw SettingsError("Không tìm thấy cấu hình mặc định.") }
        let source = resources.appendingPathComponent("ThreadsDefaults", isDirectory: true)
        let folder = PhoneFarmStore.databaseURL.deletingLastPathComponent().appendingPathComponent("threads-images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.copyItem(at: source.appendingPathComponent("images"), to: folder)
        }
        return ThreadsSettings(topics: defaultTopics,
                               replyPrompt: try String(contentsOf: source.appendingPathComponent("prompt.txt"), encoding: .utf8),
                               imageFolder: folder.path, replyPrompts: try bundledPrompts())
    }

    func validated(validateImages: Bool = true) throws -> ThreadsSettings {
        var value = self
        value.topics = topics.trimmingCharacters(in: .whitespacesAndNewlines)
        value.replyPrompt = replyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        value.imageFolder = (imageFolder as NSString).expandingTildeInPath
        guard !value.topics.isEmpty, value.topics.count <= 8_000 else {
            throw SettingsError("Nhập chủ đề AI sẽ ưu tiên, tối đa 8.000 ký tự.")
        }
        guard !value.replyPrompt.isEmpty, value.replyPrompt.count <= 40_000 else {
            throw SettingsError("Nhập prompt trả lời, tối đa 40.000 ký tự.")
        }
        if let prompts = value.replyPrompts {
            guard prompts.count == 10, Set(prompts.map(\.id)).count == 10,
                  prompts.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 40_000 }) else {
                throw SettingsError("Cần đúng 10 prompt khác nhau, mỗi prompt không rỗng và tối đa 40.000 ký tự.")
            }
        }
        if validateImages { _ = try value.images() }
        return value
    }

    func images() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: imageFolder, isDirectory: true),
                                                                includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
            .filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.contains(where: { $0.lastPathComponent.lowercased() == "app_store.png" }), files.count >= 3 else {
            throw SettingsError("Thư mục cần có app_store.png và ít nhất hai ảnh khác để đính kèm đủ ba ảnh.")
        }
        for file in files {
            guard let image = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                throw SettingsError("Không đọc được ảnh \(file.lastPathComponent).")
            }
        }
        return files
    }

    func pickImages() throws -> [URL] {
        let files = try images()
        let middle = files.first { $0.lastPathComponent.lowercased() == "app_store.png" }!
        let others = files.filter { $0 != middle }.shuffled()
        return [others[0], middle, others[1]]
    }
}
