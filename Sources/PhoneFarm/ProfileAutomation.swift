import Foundation

/// One click: AI writes a bio, a random avatar from the avatar folder is selected and cropped,
/// and both are saved together in Threads' Edit profile.
enum ProfileAutomation {
    struct ProfileError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct Request: Encodable {
        let action: String
        var bio: String? = nil
        var photoID: Int? = nil
    }

    private struct Response: Decodable {
        let actionStatus: String?
    }

    @MainActor
    static func run(adb: URL, serial: String, key: String,
                    progress: @escaping @MainActor (String) -> Void) async throws -> String {
        progress("AI đang tạo bio…")
        let bio = try await ThreadsReplyAI.suggestBio(key: key) { message in await MainActor.run { progress(message) } }
        return try await apply(bio: bio, adb: adb, serial: serial, progress: progress)
    }

    /// Selects a random avatar and saves it together with `bio` in Threads' Edit profile.
    @MainActor
    static func apply(bio: String, adb: URL, serial: String,
                      progress: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        let image = try AvatarImages.randomImage()
        progress("Đang chuyển ảnh \(image.lastPathComponent) sang điện thoại…")
        let photoID = try await ThreadsAttachments.prepareAvatar(adb: adb, serial: serial, image: image)

        progress("Đang mở ảnh đại diện trong Threads…")
        try await expect(["avatar_picker_open"], Request(action: "avatar"), adb: adb, serial: serial, timeout: 30)
        try await ThreadsAttachments.verifyAvatar(id: photoID, adb: adb, serial: serial)
        try await expect(["avatar_ready"], Request(action: "select_avatar", photoID: photoID), adb: adb, serial: serial, timeout: 15)
        progress("Đang xác nhận ảnh đại diện…")
        try await expect(["avatar_confirmed"], Request(action: "confirm_avatar"), adb: adb, serial: serial, timeout: 20)

        progress("Đang lưu bio và ảnh đại diện…")
        let saved = try await expect(["bio_saved", "bio_unverified"], Request(action: "bio", bio: bio),
                                     adb: adb, serial: serial, timeout: 30)
        let suffix = saved == "bio_saved" ? "" : " (chưa thấy bio trên hồ sơ, hãy kiểm tra)"
        return "Đã đổi ảnh \(image.lastPathComponent) và bio: \(bio)" + suffix
    }

    @discardableResult
    private static func expect(_ accepted: Set<String>, _ request: Request, adb: URL, serial: String,
                               timeout: Int) async throws -> String {
        try Task.checkCancellation()
        let output = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .threadsProfile,
                                                         timeout: timeout, payload: JSONEncoder().encode(request))
        guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last,
              let status = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)).actionStatus else {
            throw ProfileError("Threads chưa phản hồi khi \(describe(request.action)).")
        }
        guard accepted.contains(status) else { throw ProfileError(message(for: status, action: request.action)) }
        return status
    }

    private static func describe(_ action: String) -> String {
        switch action {
        case "avatar": return "mở ảnh đại diện"
        case "select_avatar": return "chọn ảnh đại diện"
        case "confirm_avatar": return "xác nhận ảnh đại diện"
        default: return "lưu bio"
        }
    }

    private static func message(for status: String, action: String) -> String {
        switch status {
        case "permission_required": return "Threads cần quyền truy cập ảnh trên điện thoại."
        case "profile_unavailable": return "Không mở được trang chỉnh sửa hồ sơ. Hãy mở Threads ở trang chủ rồi thử lại."
        case "gallery_unavailable": return "Không mở được thư viện ảnh của Threads."
        case "photos_changed": return "Thư viện ảnh đã thay đổi trước khi chọn ảnh đại diện. Hãy thử lại."
        case "avatar_unavailable": return "Không chọn được ảnh đại diện trong Threads."
        case "bio_unavailable": return "Không lưu được bio trong Threads."
        case "invalid_bio": return "Bio AI tạo không hợp lệ."
        default: return "Threads trả về \(status) khi \(describe(action))."
        }
    }
}
