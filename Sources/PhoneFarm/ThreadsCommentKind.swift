import Foundation

enum ThreadsCommentKind: String, Codable, Sendable {
    case promotion, ordinary

    var title: String { self == .promotion ? "Giới thiệu" : "Thông thường" }
    var photoCount: Int { self == .promotion ? 3 : 0 }

    static let ordinaryPrompt = """
        Viết một bình luận trao đổi thông thường bằng tiếng Việt, bám đúng nội dung bài.
        Trả lời câu hỏi nếu dữ liệu đủ, góp một ý cụ thể hoặc hỏi thêm một điều có ý nghĩa.
        Không quảng cáo, không giới thiệu ứng dụng hay sản phẩm của người bình luận.
        Không nhắc Hoàn Xu, mã giới thiệu, link, QR, tải app hoặc kêu gọi mua hàng.
        Không giả vờ đã mua, đã sử dụng hay có trải nghiệm cá nhân không được cung cấp.
        Không cố lái chủ đề về mua sắm. Không dùng lời khen chung chung để lấp chỉ tiêu.
        """

    func allows(_ text: String) -> Bool {
        guard self == .ordinary else { return true }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        return folded.range(of: #"hoan\s*xu|ma gioi thieu|tai (app|ung dung)|app store|google play|https?://|www\.|@"#,
                            options: .regularExpression) == nil
    }
}
