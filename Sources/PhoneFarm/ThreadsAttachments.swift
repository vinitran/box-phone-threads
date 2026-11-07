import Foundation
import CryptoKit

enum ThreadsAttachments {
    @MainActor private static var cleaningSerials: Set<String> = []

    struct Batch: Codable {
        let album: String
        let ids: [Int]
        let paths: [String]
        var reusable: Bool? = nil

        var isDisposable: Bool {
            reusable != true && album.hasPrefix("PF-") && album.dropFirst(3).count == 32
                && album.dropFirst(3).allSatisfy { $0.isHexDigit }
        }
    }

    struct ImageCache: Codable {
        let album: String
        var ids: [String: Int] = [:]
        var uploadedHashes: [String: String]? = nil

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
        let album = "PF-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = "/sdcard/Pictures/" + album
        let names = ["01.png", "02.png", "03.png"]
        let paths = names.map { directory + "/" + $0 }
        let pending = Batch(album: album, ids: [], paths: paths, reusable: false)
        do {
            _ = try await command(adb, serial, ["shell", "mkdir", "-p", directory])
            for index in images.indices {
                try Task.checkCancellation()
                progress(DeviceProgress(message: "Đang chuyển ảnh mới \(index + 1)/3 · thêm chấm pixel ngẫu nhiên", completed: index, total: 3))
                _ = try await pushVariant(adb: adb, serial: serial, source: images[index], path: paths[index])
                _ = try await command(adb, serial, ["shell", "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://" + paths[index]])
            }
            var registered: [String: Int] = [:]
            for _ in 0..<16 {
                registered = try await registeredImages(adb: adb, serial: serial, album: album)
                if names.allSatisfy({ registered[$0] != nil }) { break }
                try await Task.sleep(for: .milliseconds(350))
            }
            let ids = names.compactMap { registered[$0] }
            guard ids.count == 3 else { throw ThreadsSettings.SettingsError("Android chưa nhận đủ ba ảnh. Chưa đăng bình luận.") }
            let now = Int(Date().timeIntervalSince1970) + 6
            for (index, id) in ids.enumerated() {
                let date = now - index * 2
                let uri = "content://media/external/images/media/\(id)"
                _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind is_pending:i:1"])
                _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind date_added:l:\(date)"])
                _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind is_pending:i:0"])
            }
            let batch = Batch(album: album, ids: ids, paths: paths, reusable: false)
            try await verify(batch, adb: adb, serial: serial)
            progress(DeviceProgress(message: "Đã chuyển đủ 3 ảnh mới", completed: 3, total: 3))
            return batch
        } catch {
            // No composer has received this batch yet. Clean incomplete imports even
            // when the preparation task was cancelled, using an uncancelled task.
            _ = await Task.detached { await remove(pending, adb: adb, serial: serial) }.value
            throw error
        }
    }

    /// Imports one image (content-addressed, reused when unchanged) and makes it the newest photo,
    /// so it is the first item in the picker. Returns its MediaStore id.
    @MainActor
    static func prepareAvatar(adb: URL, serial: String, image: URL) async throws -> Int {
        let store = try PhoneFarmStore.shared.get()
        var cache = try store.imageCache(serial: serial)
            ?? ImageCache(album: "PF-CACHE-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        guard cache.isValid else { throw ThreadsSettings.SettingsError("Dữ liệu ảnh đã lưu trên điện thoại không hợp lệ.") }
        try store.saveImageCache(cache, serial: serial)
        let directory = "/sdcard/Pictures/" + cache.album
        let hash = SHA256.hash(data: try Data(contentsOf: image, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        let name = hash + "-pixels-v1.png"
        let path = directory + "/" + name
        _ = try await command(adb, serial, ["shell", "mkdir", "-p", directory])
        let remote = try await command(adb, serial, ["shell", "sha256sum " + path + " 2>/dev/null || true"]).output
        var registered = try await registeredImages(adb: adb, serial: serial, album: cache.album)
        let remoteMatches = cache.uploadedHashes?[name].map { remote.hasPrefix($0 + " ") } ?? false
        if !remoteMatches || registered[name] == nil {
            if !remoteMatches {
                let uploadedHash = try await pushVariant(adb: adb, serial: serial, source: image, path: path)
                if cache.uploadedHashes == nil { cache.uploadedHashes = [:] }
                cache.uploadedHashes?[name] = uploadedHash
            }
            _ = try await command(adb, serial, ["shell", "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://" + path])
            for _ in 0..<16 where registered[name] == nil {
                try await Task.sleep(for: .milliseconds(350))
                registered = try await registeredImages(adb: adb, serial: serial, album: cache.album)
            }
        }
        guard let id = registered[name] else { throw ThreadsSettings.SettingsError("Android chưa nhận ảnh đại diện.") }
        cache.ids[name] = id
        try store.saveImageCache(cache, serial: serial)
        let uri = "content://media/external/images/media/\(id)"
        let date = Int(Date().timeIntervalSince1970) + 6
        _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind is_pending:i:1"])
        _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind date_added:l:\(date)"])
        _ = try await command(adb, serial, ["shell", "content update --uri \(uri) --bind is_pending:i:0"])
        try await verifyAvatar(id: id, adb: adb, serial: serial)
        return id
    }

    static func verifyAvatar(id: Int, adb: URL, serial: String) async throws {
        let newest = try await command(adb, serial, ["shell", "content query --uri content://media/external/file --projection _id --where '(media_type=1 OR media_type=3) AND is_pending=0' --sort 'date_added DESC, _id DESC' | head -n 1"])
        let first = newest.output.range(of: #"_id=(\d+)"#, options: .regularExpression)
            .flatMap { Int(newest.output[$0].dropFirst(4)) }
        guard first == id else {
            throw ThreadsSettings.SettingsError("Ảnh đại diện chưa nằm đầu thư viện trên Android.")
        }
    }

    private static func pushVariant(adb: URL, serial: String, source: URL, path: String) async throws -> String {
        try Task.checkCancellation()
        let temporary = try ImageUploadVariant.prepare(source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hash = SHA256.hash(data: try Data(contentsOf: temporary, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        _ = try await command(adb, serial, ["push", temporary.path, path])
        return hash
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
            // Android 10 registers scanned files without width/height (NULL); only reject explicit bad sizes.
            func sizeOK(_ value: String?) -> Bool { value == "NULL" || (Int(value ?? "") ?? 0) > 0 }
            if fields["is_pending"] == "0", let id = fields["_id"].flatMap(Int.init),
               let name = fields["_display_name"], sizeOK(fields["width"]), sizeOK(fields["height"]) { registered[name] = id }
        }
        return registered
    }

    @discardableResult
    static func remove(_ batch: Batch, adb: URL, serial: String) async -> Bool {
        guard batch.isDisposable else { return false }
        do {
            _ = try await command(adb, serial, ["shell", "content delete --uri content://media/external/images/media --where \"relative_path='Pictures/\(batch.album)/'\""])
            // Includes partially transferred files not yet registered by MediaStore.
            // isDisposable restricts this path to a single generated PF-<UUID> album.
            _ = try await command(adb, serial, ["shell", "rm", "-rf", "/sdcard/Pictures/" + batch.album])
            let remaining = try await command(adb, serial, ["shell", "content query --uri content://media/external/images/media --projection _id --where \"relative_path='Pictures/\(batch.album)/'\""])
            return !remaining.output.contains("_id=")
        } catch { return false }
    }

    @MainActor
    static func cleanupSubmitted(adb: URL, serial: String) async throws {
        guard cleaningSerials.insert(serial).inserted else { return }
        defer { cleaningSerials.remove(serial) }
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
