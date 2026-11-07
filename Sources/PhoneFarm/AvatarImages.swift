import Foundation
import ImageIO

/// Folder of avatar candidates on the Mac, used for random preview selection.
@MainActor
enum AvatarImages {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
    private static let settingKey = "avatar-folder"

    /// Bundled avatars (Resources/ThreadsDefaults/avatars), copied once into the app's data folder
    /// so they can be edited and do not depend on Downloads.
    static var defaultFolder: URL {
        let folder = PhoneFarmStore.databaseURL.deletingLastPathComponent().appendingPathComponent("avatars", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path),
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("ThreadsDefaults/avatars", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            try? FileManager.default.copyItem(at: bundled, to: folder)
        }
        return folder
    }

    static func folder() -> URL {
        if let path = (try? PhoneFarmStore.shared.get().setting(settingKey)) ?? nil, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultFolder
    }

    static func setFolder(_ url: URL) throws {
        guard !images(in: url).isEmpty else {
            throw ThreadsSettings.SettingsError("Thư mục chưa có ảnh JPG, PNG hoặc WEBP đọc được.")
        }
        try PhoneFarmStore.shared.get().saveSetting(settingKey, value: url.path)
    }

    static func images(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { file in
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return false }
                return CGImageSourceGetCount(source) > 0
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func randomImage(excluding current: URL? = nil) throws -> URL {
        let folder = folder()
        let files = images(in: folder)
        let candidates = files.count > 1 ? files.filter { $0 != current } : files
        guard let image = candidates.randomElement() else {
            throw ThreadsSettings.SettingsError("Thư mục \(folder.path) chưa có ảnh JPG, PNG hoặc WEBP.")
        }
        return image
    }
}
