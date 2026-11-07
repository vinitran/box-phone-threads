import Foundation
import CryptoKit

enum ThreadsAttachments {
    struct Batch: Codable {
        let album: String
        let ids: [Int]
        let paths: [String]
        var reusable: Bool? = nil
    }

    struct ImageCache: Codable {
        let album: String
        var ids: [String: Int] = [:]

        var isValid: Bool {
            album.hasPrefix("PF-CACHE-") && album.dropFirst(9).count == 32
                && album.dropFirst(9).allSatisfy { $0.isHexDigit }
        }
    }

    @MainActor
    static func prepare(adb: URL, serial: String, images: [URL],
                        progress: @MainActor (DeviceProgress) -> Void) async throws -> Batch {
        guard images.count == 3, images[1].lastPathComponent.lowercased() == "app_store.png",
              Set(images).count == 3 else {
            throw ThreadsSettings.SettingsError("Cần đúng ba ảnh khác nhau và app_store.png ở giữa.")
        }
        let store = try PhoneFarmStore.shared.get()
        var cache = try store.imageCache(serial: serial)
            ?? ImageCache(album: "PF-CACHE-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        guard cache.isValid else { throw ThreadsSettings.SettingsError("Dữ liệu ảnh đã lưu trên điện thoại không hợp lệ.") }
        try store.saveImageCache(cache, serial: serial)
        let album = cache.album
        let directory = "/sdcard/Pictures/" + album
        let hashes = try images.map { image in
            SHA256.hash(data: try Data(contentsOf: image, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }
        let names = zip(images, hashes).map { image, hash in hash + "." + image.pathExtension.lowercased() }
        let paths = names.map { directory + "/" + $0 }
        _ = try await command(adb, serial, ["shell", "mkdir", "-p", directory])
        // Check only our three content-addressed paths, including after a restart.
        // Missing or modified files are reimported; no unrelated photo content is read.
        let checksum = try await command(adb, serial, ["shell", "sha256sum " + paths.joined(separator: " ") + " 2>/dev/null || true"])
        var remoteHashes: [String: String] = [:]
        for line in checksum.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0].count == 64 {
                remoteHashes[URL(fileURLWithPath: String(fields[1])).lastPathComponent] = String(fields[0])
            }
        }
        var registered = try await registeredImages(adb: adb, serial: serial, album: album)
        for index in images.indices {
            try Task.checkCancellation()
            if remoteHashes[names[index]] == hashes[index], registered[names[index]] != nil {
                progress(DeviceProgress(message: "Đang dùng lại ảnh \(index + 1)/3 trên điện thoại", completed: index + 1, total: 3))
            } else {
                progress(DeviceProgress(message: "Đang nhập ảnh \(index + 1)/3 vào điện thoại", completed: index, total: 3))
                if remoteHashes[names[index]] != hashes[index] {
                    _ = try await command(adb, serial, ["push", images[index].path, paths[index]])
                }
                _ = try await command(adb, serial, ["shell", "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://" + paths[index]])
            }
        }
        for _ in 0..<16 {
            registered = try await registeredImages(adb: adb, serial: serial, album: album)
            if names.allSatisfy({ registered[$0] != nil }) { break }
            try await Task.sleep(for: .milliseconds(350))
        }
        let ids = names.compactMap { registered[$0] }
        guard ids.count == 3 else { throw ThreadsSettings.SettingsError("Android chưa nhận đủ ba ảnh. Chưa đăng bình luận.") }
        for (name, id) in zip(names, ids) { cache.ids[name] = id }
        try store.saveImageCache(cache, serial: serial)
        // Promote the selected cached images in the requested order for Recents.
        let now = Int(Date().timeIntervalSince1970) + 6
        for (index, id) in ids.enumerated() {
            let date = now - index * 2
            let uri = "content://media/external/images/media/\(id)"
            _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind is_pending:i:1"])
            _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind date_added:l:\(date)"])
            _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind is_pending:i:0"])
        }
        try await verify(Batch(album: album, ids: ids, paths: paths, reusable: true), adb: adb, serial: serial)
        return Batch(album: album, ids: ids, paths: paths, reusable: true)
    }

    private static func registeredImages(adb: URL, serial: String, album: String) async throws -> [String: Int] {
        let query = "content query --uri content://media/external/images/media --projection _id:_display_name:width:height:is_pending --where \"relative_path='Pictures/\(album)/'\""
        let result = try await command(adb, serial, ["shell", query])
        var registered: [String: Int] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: ", ").reduce(into: [String: String]()) { values, field in
                let parts = field.components(separatedBy: "=")
                if parts.count == 2 { values[parts[0].components(separatedBy: " ").last!] = parts[1] }
            }
            if fields["is_pending"] == "0", let id = fields["_id"].flatMap(Int.init),
               let name = fields["_display_name"], (Int(fields["width"] ?? "") ?? 0) > 0,
               (Int(fields["height"] ?? "") ?? 0) > 0 { registered[name] = id }
        }
        return registered
    }

    @discardableResult
    static func remove(_ batch: Batch, adb: URL, serial: String) async -> Bool {
        guard batch.reusable != true, batch.album.hasPrefix("PF-"), batch.album.dropFirst(3).count == 32,
              batch.album.dropFirst(3).allSatisfy({ $0.isHexDigit }) else { return false }
        do {
            _ = try await command(adb, serial, ["shell", "content delete --uri content://media/external/images/media --where \"relative_path='Pictures/\(batch.album)/'\""])
            _ = try? await command(adb, serial, ["shell", "rmdir", "/sdcard/Pictures/" + batch.album])
            return true
        } catch { return false }
    }

    @MainActor
    static func cleanupSubmitted(adb: URL, serial: String) async throws {
        let store = try PhoneFarmStore.shared.get()
        for photo in try store.submittedPhotos(serial: serial) where photo.removeAfter <= Date() {
            try Task.checkCancellation()
            if await remove(photo.batch, adb: adb, serial: serial) {
                try store.removeSubmittedPhotos(album: photo.batch.album, serial: serial)
            }
        }
    }

    static func verify(_ batch: Batch, adb: URL, serial: String) async throws {
        let query = "content query --uri content://media/external/file --projection _id --where '(media_type=1 OR media_type=3) AND is_pending=0' --sort 'date_added DESC, _id DESC' | head -n 3"
        let result = try await command(adb, serial, ["shell", query])
        let expression = try NSRegularExpression(pattern: #"_id=(\d+)"#)
        let text = result.output as NSString
        let ids = expression.matches(in: result.output, range: NSRange(location: 0, length: text.length))
            .compactMap { Int(text.substring(with: $0.range(at: 1))) }
        guard ids == batch.ids else {
            throw ThreadsSettings.SettingsError("Thứ tự ảnh trên Android đã thay đổi. Bình luận chưa được đăng.")
        }
    }

    private static func command(_ adb: URL, _ serial: String, _ arguments: [String]) async throws -> CommandResult {
        try Task.checkCancellation()
        let result = await (try RunningCommand(adb, arguments: ["-s", serial] + arguments)).result(timeout: 30, outputLimit: 32_000)
        guard result.status == 0 else { throw ThreadsSettings.SettingsError("Không chuẩn bị được ảnh trên Android. " + result.output.suffix(300)) }
        return result
    }
}
