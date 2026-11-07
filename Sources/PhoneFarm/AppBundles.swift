import CryptoKit
import Foundation

/// Threads and Instagram APKs hosted on Cloudflare R2, one folder per app with a `manifest.json`.
/// Files are downloaded once into a cache on the Mac, checked against SHA-256, and installed together.
enum AppBundles {
    static let remoteBase = "https://pub-70be8d706b394a62a42e9d972c395cb5.r2.dev"

    struct App: Hashable {
        let name: String
        let package: String
        let folder: String
    }

    struct Manifest: Codable {
        struct File: Codable {
            let name: String
            let size: Int
            let sha256: String
        }
        let app: String
        let package: String
        let versionName: String
        let versionCode: Int
        let minSdk: Int
        let files: [File]
    }

    static let gboard = App(name: "Gboard", package: "com.google.android.inputmethod.latin", folder: "gboard")
    /// Every phone needs all three before Threads can run: comments are typed with Gboard's Telex layout.
    static let apps = [gboard,
                       App(name: "Threads", package: "com.instagram.barcelona", folder: "threads"),
                       App(name: "Instagram", package: "com.instagram.android", folder: "instagram")]

    struct BundleError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Farm/apks", isDirectory: true)
    }

    // MARK: Phone queries

    static func installedPackages(adb: URL, serial: String) async -> Set<String>? {
        guard let command = try? RunningCommand(adb, arguments: ["-s", serial, "shell", "pm", "list", "packages"]) else { return nil }
        let result = await command.result(timeout: 15)
        guard result.status == 0 else { return nil }
        return Set(result.output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces) : nil
        })
    }

    private static func installedVersion(_ package: String, adb: URL, serial: String) async throws -> (name: String, code: Int)? {
        let output = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "dumpsys", "package", package])).result(timeout: 20).output
        func value(_ key: String) -> String? {
            guard let range = output.range(of: key + "=") else { return nil }
            return String(output[range.upperBound...].prefix { !$0.isWhitespace })
        }
        guard let name = value("versionName"), let code = value("versionCode").flatMap(Int.init) else { return nil }
        return (name, code)
    }

    private static func sdk(adb: URL, serial: String) async throws -> Int {
        let output = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "getprop", "ro.build.version.sdk"])).result(timeout: 10).output
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: Download

    private static func remoteManifest(_ app: App) async throws -> Manifest {
        var request = URLRequest(url: URL(string: "\(remoteBase)/\(app.folder)/manifest.json")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BundleError("Không tải được manifest của \(app.name).") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.package == app.package, !manifest.files.isEmpty,
              manifest.files.allSatisfy({ !$0.name.contains("/") && $0.name.hasSuffix(".apk") }) else {
            throw BundleError("Manifest của \(app.name) không hợp lệ.")
        }
        return manifest
    }

    private static func cachedManifest(_ app: App) -> Manifest? {
        let url = cacheDirectory.appendingPathComponent(app.package).appendingPathComponent("manifest.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    private static func sha256(_ url: URL) async throws -> String {
        try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Returns local APK files for the manifest, reusing cached files whose SHA-256 matches.
    private static func files(for manifest: Manifest, app: App, progress: @MainActor (String) -> Void) async throws -> [URL] {
        let folder = cacheDirectory.appendingPathComponent(app.package, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [URL] = []
        for (index, file) in manifest.files.enumerated() {
            let local = folder.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: local.path), try await sha256(local) == file.sha256 {
                result.append(local)
                continue
            }
            await progress("Đang tải \(app.name) \(manifest.versionName) · file \(index + 1)/\(manifest.files.count) (\(file.size / 1_048_576) MB)…")
            guard let url = URL(string: "\(remoteBase)/\(app.folder)/\(file.name)") else { throw BundleError("Tên file APK không hợp lệ.") }
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw BundleError("Không tải được \(file.name) của \(app.name).")
            }
            guard try await sha256(downloaded) == file.sha256 else {
                try? FileManager.default.removeItem(at: downloaded)
                throw BundleError("\(file.name) của \(app.name) tải về không khớp SHA-256. Hãy thử lại.")
            }
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: downloaded, to: local)
            result.append(local)
        }
        // Drop files from older versions so the cache holds one version per app.
        let keep = Set(manifest.files.map(\.name) + ["manifest.json"])
        for item in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(item) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(item))
        }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return result
    }

    /// Enables the package's keyboard and selects it. Android lists a newly installed keyboard after a short delay.
    static func makeDefaultKeyboard(_ package: String, adb: URL, serial: String) async throws {
        for _ in 0..<20 {
            let list = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "ime", "list", "-a", "-s"])).result(timeout: 10).output
            if let id = list.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix(package + "/") }) {
                _ = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "ime", "enable", id])).result(timeout: 10)
                _ = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "ime", "set", id])).result(timeout: 10)
                let current = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "settings", "get", "secure", "default_input_method"]))
                    .result(timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
                if current == id { return }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw BundleError("Chưa đặt được Gboard làm bàn phím mặc định. Hãy chọn Gboard trong Cài đặt → Ngôn ngữ & bàn phím.")
    }

    // MARK: Prepare and install

    struct Prepared {
        let app: App
        let manifest: Manifest
        let files: [URL]
    }

    /// Makes sure every app's APKs are on the Mac: downloads missing or changed files from R2,
    /// or uses the last downloaded version when R2 cannot be reached.
    static func prepare(progress: @MainActor (String) -> Void) async throws -> [Prepared] {
        var prepared: [Prepared] = []
        for app in apps {
            let manifest: Manifest
            do {
                manifest = try await remoteManifest(app)
            } catch {
                guard let cached = cachedManifest(app) else { throw error }
                manifest = cached
            }
            await progress("Đang kiểm tra APK \(app.name)…")
            prepared.append(Prepared(app: app, manifest: manifest, files: try await files(for: manifest, app: app, progress: progress)))
        }
        return prepared
    }

    /// Installs the prepared apps; skips an app the phone already has at the same or a newer version.
    static func install(_ prepared: [Prepared], on serial: String, adb: URL,
                        progress: @MainActor (String) -> Void) async throws -> String {
        let phoneSdk = try await sdk(adb: adb, serial: serial)
        var results: [String] = []
        for item in prepared {
            let app = item.app, manifest = item.manifest
            guard phoneSdk == 0 || phoneSdk >= manifest.minSdk else {
                throw BundleError("\(app.name) \(manifest.versionName) cần Android API \(manifest.minSdk) trở lên; máy này là API \(phoneSdk).")
            }
            if let current = try await installedVersion(app.package, adb: adb, serial: serial), current.code >= manifest.versionCode {
                results.append("\(app.name) đã có (\(current.name))")
            } else {
                await progress("Đang cài \(app.name) \(manifest.versionName)…")
                _ = try await APKInstaller.install(item.files, adb: adb, serial: serial)
                results.append("\(app.name) \(manifest.versionName)")
            }
            if app == gboard {
                await progress("Đang đặt Gboard làm bàn phím mặc định…")
                try await makeDefaultKeyboard(app.package, adb: adb, serial: serial)
            }
        }
        return results.joined(separator: " · ")
    }
}
