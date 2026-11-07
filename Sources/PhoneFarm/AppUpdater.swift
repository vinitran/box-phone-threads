import AppKit
import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer build and installs it in place of the running app.
@MainActor
final class AppUpdater: ObservableObject {
    static let repository = "vinitran/box-phone-threads"

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let zipURL: URL
        let checksumURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: return true
        default: return false
        }
    }

    // MARK: Checking

    func check() async {
        guard !isBusy else { return }
        state = .checking
        do {
            let release = try await latestRelease()
            lastChecked = Date()
            state = Self.isVersion(release.version, newerThan: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reads the latest tag from the github.com redirect instead of the REST API,
    /// which allows only 60 unauthenticated requests per hour per IP.
    private func latestRelease() async throws -> Release {
        let base = "https://github.com/\(Self.repository)/releases"
        var request = URLRequest(url: URL(string: base + "/latest")!)
        request.httpMethod = "HEAD"
        request.setValue("PhoneFarm-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url else { throw UpdateError("GitHub không phản hồi.") }
        guard http.statusCode == 200 else { throw UpdateError("GitHub trả về mã \(http.statusCode). Thử lại sau.") }
        let parts = final.pathComponents
        guard let index = parts.lastIndex(of: "tag"), index + 1 < parts.count else {
            throw UpdateError("Chưa có phiên bản nào trên GitHub.")
        }
        let tag = parts[index + 1]
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zipName = "PhoneFarm-macOS-\(tag).zip"
        guard let page = URL(string: "\(base)/tag/\(tag)"),
              let zip = URL(string: "\(base)/download/\(tag)/\(zipName)"),
              let checksum = URL(string: "\(base)/download/\(tag)/\(zipName).sha256") else {
            throw UpdateError("Tên phiên bản trên GitHub không hợp lệ.")
        }
        return Release(version: version, pageURL: page, zipURL: zip, checksumURL: checksum)
    }

    /// Numeric comparison of dotted versions; anything after "-" (e.g. "-dev.3") is ignored.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let core = version.drop(while: { $0 == "v" }).split(separator: "-").first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: Installing

    /// Downloads, verifies and stages the release, then quits; a helper script swaps the bundle and relaunches.
    func install(_ release: Release) async {
        guard !isBusy else { return }
        do {
            // Always install the newest release at the moment of the click, not the one found hours ago.
            state = .installing("Đang kiểm tra bản mới nhất…")
            var target = release
            if let latest = try? await latestRelease(), Self.isVersion(latest.version, newerThan: target.version) {
                target = latest
            }
            let staged = try await stage(target, replacing: Bundle.main.bundleURL)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [staged.script.path, String(ProcessInfo.processInfo.processIdentifier),
                                staged.current.path, staged.app.path, staged.backup.path, staged.work.path]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            state = .installing("Đang khởi động lại…")
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    struct StagedUpdate {
        let current: URL
        let app: URL
        let backup: URL
        let work: URL
        let script: URL
    }

    /// Downloads and verifies the release and places it next to `current`, ready for the swap.
    func stage(_ release: Release, replacing current: URL) async throws -> StagedUpdate {
        let parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app", !current.path.contains("/AppTranslocation/") else {
            throw UpdateError("macOS đang chạy app từ vị trí tạm. Hãy chuyển Phone Farm.app vào thư mục Applications rồi mở lại.")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Không có quyền ghi vào \(parent.path). Hãy chuyển app tới thư mục bạn có quyền ghi.")
        }

        state = .installing("Đang tải v\(release.version)…")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneFarmUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Không tải được file cập nhật.") }
        try FileManager.default.moveItem(at: downloaded, to: zip)

        if let checksumURL = release.checksumURL {
            state = .installing("Đang kiểm tra file tải về…")
            let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksumURL)
            guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("Không tải được mã SHA-256 của bản cập nhật.")
            }
            let expected = String(decoding: checksumData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)
            let actual = try await Task.detached {
                SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            }.value
            guard expected?.lowercased() == actual else { throw UpdateError("File tải về không khớp mã SHA-256. Hãy thử lại.") }
        }

        state = .installing("Đang giải nén…")
        let unpacked = work.appendingPathComponent("unpacked")
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], failure: "Không giải nén được bản cập nhật.")
        guard let newApp = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == (Bundle(url: current)?.bundleIdentifier ?? Bundle.main.bundleIdentifier),
              info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("Bản tải về không đúng ứng dụng Phone Farm v\(release.version).")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path],
                      failure: "Chữ ký của bản tải về không hợp lệ.")
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], failure: "")

        // Stage next to the current app so the final swap is a rename on the same volume.
        let staged = parent.appendingPathComponent(".\(current.lastPathComponent).update")
        let backup = parent.appendingPathComponent(".\(current.lastPathComponent).old")
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: newApp, to: staged)

        let script = work.appendingPathComponent("install.sh")
        try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
        return StagedUpdate(current: current, app: staged, backup: backup, work: work, script: script)
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String], failure: String) async throws -> CommandResult {
        let result = await (try RunningCommand(URL(fileURLWithPath: path), arguments: arguments)).result(timeout: 120)
        guard result.status == 0 else { throw UpdateError(failure) }
        return result
    }

    /// Waits for Phone Farm to quit, swaps the bundles (restoring the old one on failure) and relaunches.
    static let installScript = """
        #!/bin/sh
        pid="$1"; current="$2"; staged="$3"; backup="$4"; work="$5"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$current" "$backup"; then
            if mv "$staged" "$current"; then
                rm -rf "$backup"
            else
                mv "$backup" "$current"
            fi
        fi
        rm -rf "$staged" "$work"
        open "$current"
        """
}
