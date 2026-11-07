import SwiftUI

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var adbError: String?
    @Published private(set) var scrcpyAvailable = false
    @Published private(set) var sessions: [String: RunningCommand] = [:]
    @Published private(set) var stopping: Set<String> = []
    @Published private(set) var runningThreads: Set<String> = []
    @Published private(set) var installingAPK: Set<String> = []
    @Published private(set) var updatingProfile: Set<String> = []
    /// Identity files read from each phone (/sdcard/PhoneFarm/device.json), kept while offline.
    @Published private(set) var identities: [String: DeviceIdentity] = [:]
    private var identitiesChecked: Set<String> = []
    /// Threads/Instagram missing on each connected phone, checked once per connection.
    @Published private(set) var missingApps: [String: [AppBundles.App]] = [:]
    private var appsChecked: Set<String> = []

    enum BundleStatus: Equatable {
        case idle, working(String), ready(String), failed(String)
    }
    /// Whether the Threads/Instagram APKs are downloaded on this Mac and ready to install.
    @Published private(set) var bundleStatus: BundleStatus = .idle
    private var bundlesTask: Task<[AppBundles.Prepared], Error>?
    private var bundlesPreparedAt: Date?
    @Published private(set) var nextThreadsRun: [String: Date] = [:]
    @Published private(set) var activities: [String: Activity] = [:]
    @Published private(set) var storageError: String?
    @Published private(set) var savedProxies: [String: PhoneFarmStore.SavedProxy] = [:]
    /// Comments submitted since local midnight, keyed by serial.
    @Published private(set) var commentsToday: [String: Int] = [:]
    @Published var actionError: ActionError?

    private let storage: PhoneFarmStore?
    private var threadsTasks: [String: Task<Void, Never>] = [:]
    private var photoCleanupTasks: [String: Task<Void, Never>] = [:]

    init() {
        switch PhoneFarmStore.shared {
        case .success(let store):
            storage = store
            do {
                devices = try store.devices()
                try reloadSavedProxies()
                reloadCommentCounts()
            } catch {
                storageError = error.localizedDescription
            }
        case .failure(let error):
            storage = nil
            storageError = error.localizedDescription
        }
    }

    func reloadSavedProxies() throws {
        guard let storage else { return }
        var saved: [String: PhoneFarmStore.SavedProxy] = [:]
        for device in devices { saved[device.id] = try storage.savedProxy(serial: device.serial) }
        savedProxies = saved
    }

    func reloadCommentCounts() {
        guard let storage else { return }
        do {
            let counts = try storage.commentCounts(since: Calendar.current.startOfDay(for: Date()))
            if counts != commentsToday { commentsToday = counts }
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func recordResult(_ device: AndroidDevice, runID: String, message: String, hasIssue: Bool) {
        do { try storage?.finishRun(id: runID, message: message, hasIssue: hasIssue) }
        catch { storageError = error.localizedDescription }
        updateThreadsActivity(device, progress: DeviceProgress(message: message), hasIssue: hasIssue)
        reloadCommentCounts()
    }

    struct ActionError: Identifiable {
        let id = UUID()
        let title: String
        let details: String
    }

    struct Activity {
        let progress: DeviceProgress
        var hasIssue = false
        var startedAt: Date?
    }

    func reportActivity(_ device: AndroidDevice, progress: DeviceProgress, hasIssue: Bool = false) {
        guard !runningThreads.contains(device.id) else { return }
        activities[device.id] = Activity(progress: progress, hasIssue: hasIssue)
    }

    private func updateThreadsActivity(_ device: AndroidDevice, progress: DeviceProgress, hasIssue: Bool = false) {
        activities[device.id] = Activity(progress: progress, hasIssue: hasIssue,
                                         startedAt: activities[device.id]?.startedAt)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            hasLoaded = true
            isRefreshing = false
        }
        scrcpyAvailable = ToolPaths.scrcpy() != nil

        guard let adb = ToolPaths.adb() else {
            adbError = "Chưa tìm thấy ADB. Cài Android Platform Tools bằng lệnh brew install --cask android-platform-tools."
            return
        }

        do {
            let command = try RunningCommand(adb, arguments: ["devices", "-l"])
            let result = await command.result(timeout: 8)
            guard result.status == 0, let discovered = AndroidDevice.parseList(result.output) else {
                adbError = result.diagnostics.isEmpty
                    ? "ADB không trả về danh sách thiết bị. Hãy thử làm mới." : result.diagnostics
                return
            }
            if let storage {
                do {
                    try storage.remember(discovered)
                    let connected = Set(discovered.map(\.serial))
                    devices = (discovered + (try storage.devices()).filter { !connected.contains($0.serial) })
                        .sorted { $0.serial < $1.serial }
                    try reloadSavedProxies()
                    storageError = nil
                    reloadCommentCounts()
                    checkInstalledApps()
                    checkIdentities()
                } catch {
                    devices = discovered
                    storageError = error.localizedDescription
                }
            } else {
                devices = discovered
            }
            adbError = nil
            cleanSubmittedPhotos(adb: adb)
        } catch {
            adbError = error.localizedDescription
        }
    }

    private func cleanSubmittedPhotos(adb: URL) {
        guard let storage else { return }
        for device in devices where device.isReady && photoCleanupTasks[device.serial] == nil {
            do {
                guard try storage.submittedPhotos(serial: device.serial).contains(where: { $0.removeAfter <= Date() }) else { continue }
            } catch {
                storageError = error.localizedDescription
                continue
            }
            photoCleanupTasks[device.serial] = Task {
                defer { photoCleanupTasks.removeValue(forKey: device.serial) }
                do { try await ThreadsAttachments.cleanupSubmitted(adb: adb, serial: device.serial) }
                catch is CancellationError { }
                catch { storageError = error.localizedDescription }
            }
        }
    }

    /// True when the phone's identity file or the Mac's database has a proxy for it.
    func hasProxy(_ device: AndroidDevice) -> Bool { proxyAddress(device) != nil }

    /// The phone's own proxy comes first, so a phone keeps its proxy on another Mac.
    func proxyAddress(_ device: AndroidDevice) -> String? {
        identities[device.id]?.proxyAddress ?? savedProxies[device.id]?.endpoint?.address
    }

    // MARK: Identity file on the phone

    func displayName(_ device: AndroidDevice) -> String {
        let name = identities[device.id]?.name?.trimmingCharacters(in: .whitespaces)
        return name?.isEmpty == false ? name! : device.name
    }

    private func checkIdentities() {
        let ready = Set(devices.filter(\.isReady).map(\.id))
        identitiesChecked.formIntersection(ready)
        for device in devices where device.isReady && !identitiesChecked.contains(device.id) {
            identitiesChecked.insert(device.id)
            Task { await loadIdentity(device) }
        }
    }

    func loadIdentity(_ device: AndroidDevice) async {
        guard let adb = ToolPaths.adb() else { return }
        if let identity = await DeviceIdentity.read(adb: adb, serial: device.serial) {
            identities[device.id] = identity
        } else {
            identities.removeValue(forKey: device.id)
        }
    }

    /// Writes name and number to the phone, keeping its proxy.
    func saveIdentity(_ device: AndroidDevice, name: String, number: Int?) async throws {
        guard let adb = ToolPaths.adb() else { throw DeviceIdentity.IdentityError("Không tìm thấy ADB.") }
        var identity = await DeviceIdentity.read(adb: adb, serial: device.serial) ?? DeviceIdentity()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        identity.name = trimmed.isEmpty ? nil : trimmed
        identity.number = number
        try await DeviceIdentity.write(identity, adb: adb, serial: device.serial)
        await loadIdentity(device)
    }

    /// Records the proxy applied from the Proxy window (nil after removing it) in the phone's file.
    func recordProxy(_ device: AndroidDevice, line: String?) async {
        guard let adb = ToolPaths.adb() else { return }
        var identity = await DeviceIdentity.read(adb: adb, serial: device.serial) ?? DeviceIdentity()
        identity.proxy = line?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await DeviceIdentity.write(identity, adb: adb, serial: device.serial)
            await loadIdentity(device)
        } catch {
            actionError = ActionError(title: "Chưa ghi được proxy vào \(device.name)", details: error.localizedDescription)
        }
    }

    func open(_ device: AndroidDevice) {
        guard device.isReady, adbError == nil, sessions[device.id] == nil else { return }
        guard let adb = ToolPaths.adb(), let scrcpy = ToolPaths.scrcpy() else {
            actionError = ActionError(title: "Không thể chạy scrcpy cho \(device.name)",
                                      details: "Cần cài ADB và scrcpy để mở cửa sổ điều khiển.")
            return
        }

        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adb.path
        let title = device.name == device.serial ? device.serial : "\(device.name) · \(device.serial)"
        do {
            let command = try RunningCommand(scrcpy, arguments: [
                "--serial", device.serial, "--window-title", title, "--no-audio"
            ], environment: environment)
            sessions[device.id] = command
            reportActivity(device, progress: DeviceProgress(message: "Đang xem màn hình bằng scrcpy"))
            Task {
                let result = await command.result(outputLimit: 32_768)
                sessions.removeValue(forKey: device.id)
                let wasStopped = stopping.remove(device.id) != nil
                reportActivity(device, progress: DeviceProgress(message: "Đã đóng scrcpy"))
                if result.status != 0, !wasStopped {
                    let details = result.diagnostics.isEmpty ? "Mã thoát \(result.status)." : result.diagnostics
                    actionError = ActionError(title: "Không thể chạy scrcpy cho \(device.name)", details: details)
                }
            }
        } catch {
            actionError = ActionError(title: "Không thể chạy scrcpy cho \(device.name)", details: error.localizedDescription)
        }
    }

    func openThreads(_ device: AndroidDevice) async -> Bool {
        guard device.isReady, adbError == nil, runningThreads.insert(device.id).inserted else { return false }
        defer { runningThreads.remove(device.id) }
        activities[device.id] = Activity(progress: DeviceProgress(message: "Đang mở Threads"), startedAt: Date())
        do {
            try await launchThreads(device)
            updateThreadsActivity(device, progress: DeviceProgress(message: "Đang điều khiển Threads thủ công"))
            return true
        } catch {
            updateThreadsActivity(device, progress: DeviceProgress(message: error.localizedDescription), hasIssue: true)
            actionError = ActionError(title: "Không thể mở Threads trên \(device.name)", details: error.localizedDescription)
            return false
        }
    }

    private func checkInstalledApps() {
        let ready = Set(devices.filter(\.isReady).map(\.id))
        appsChecked.formIntersection(ready)
        missingApps = missingApps.filter { ready.contains($0.key) }
        for device in devices where device.isReady && !appsChecked.contains(device.id) {
            appsChecked.insert(device.id)
            Task { await refreshInstalledApps(device) }
        }
    }

    private func refreshInstalledApps(_ device: AndroidDevice) async {
        guard let adb = ToolPaths.adb(), let packages = await AppBundles.installedPackages(adb: adb, serial: device.serial) else {
            appsChecked.remove(device.id)
            return
        }
        let missing = AppBundles.apps.filter { !packages.contains($0.package) }
        if missing.isEmpty { missingApps.removeValue(forKey: device.id) } else { missingApps[device.id] = missing }
    }

    /// Downloads missing APKs once; concurrent callers share the same download.
    /// A successful result is reused for 6 hours, then R2 is checked again for a newer version.
    @discardableResult
    func prepareBundledApps(force: Bool = false) async throws -> [AppBundles.Prepared] {
        if force || (bundlesPreparedAt.map { Date().timeIntervalSince($0) > 6 * 60 * 60 } ?? false) {
            if bundlesPreparedAt != nil { bundlesTask = nil }
        }
        if let task = bundlesTask { return try await task.value }
        bundleStatus = .working("Đang kiểm tra APK Threads & Instagram…")
        let task = Task { @MainActor in
            try await AppBundles.prepare { self.bundleStatus = .working($0) }
        }
        bundlesTask = task
        do {
            let prepared = try await task.value
            bundlesPreparedAt = Date()
            bundleStatus = .ready(prepared.map { "\($0.app.name) \($0.manifest.versionName)" }.joined(separator: " · "))
            return prepared
        } catch {
            bundlesTask = nil
            bundlesPreparedAt = nil
            bundleStatus = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Installs Threads and Instagram from the APKs hosted on R2 (cached on the Mac).
    func installBundledApps(_ device: AndroidDevice) async {
        guard device.isReady, adbError == nil, !runningThreads.contains(device.id),
              installingAPK.insert(device.id).inserted else { return }
        defer { installingAPK.remove(device.id) }
        guard let adb = ToolPaths.adb() else { return }
        do {
            reportActivity(device, progress: DeviceProgress(message: "Đang chuẩn bị APK Threads & Instagram…"))
            let prepared = try await prepareBundledApps()
            let summary = try await AppBundles.install(prepared, on: device.serial, adb: adb) { message in
                self.reportActivity(device, progress: DeviceProgress(message: message))
            }
            reportActivity(device, progress: DeviceProgress(message: "Đã cài · " + summary))
        } catch {
            reportActivity(device, progress: DeviceProgress(message: "Chưa cài được: " + error.localizedDescription), hasIssue: true)
            actionError = ActionError(title: "Không thể cài Threads & Instagram lên \(device.name)", details: error.localizedDescription)
        }
        await refreshInstalledApps(device)
    }

    /// One click: AI bio plus a random avatar, saved in Threads without further confirmation.
    func autoUpdateProfile(_ device: AndroidDevice) async {
        guard device.isReady, adbError == nil, !runningThreads.contains(device.id),
              updatingProfile.insert(device.id).inserted else { return }
        defer { updatingProfile.remove(device.id) }
        guard let key = ThreadsKey.load() else {
            actionError = ActionError(title: "Không thể đổi hồ sơ trên \(device.name)", details: "Chưa có khóa AI.")
            return
        }
        reportActivity(device, progress: DeviceProgress(message: "Đang mở Threads để đổi ảnh đại diện và bio…"))
        do {
            let adb = try await launchThreads(device)
            let summary = try await ProfileAutomation.run(adb: adb, serial: device.serial, key: key) { message in
                self.reportActivity(device, progress: DeviceProgress(message: message))
            }
            reportActivity(device, progress: DeviceProgress(message: summary))
        } catch {
            reportActivity(device, progress: DeviceProgress(message: "Chưa đổi được hồ sơ: " + error.localizedDescription), hasIssue: true)
            actionError = ActionError(title: "Không thể đổi ảnh đại diện và bio trên \(device.name)", details: error.localizedDescription)
        }
    }

    func installAPK(_ device: AndroidDevice, files: [URL]) async {
        guard device.isReady, adbError == nil, !files.isEmpty, !runningThreads.contains(device.id),
              installingAPK.insert(device.id).inserted else { return }
        defer { installingAPK.remove(device.id) }
        guard let adb = ToolPaths.adb() else {
            actionError = ActionError(title: "Không thể cài APK lên \(device.name)", details: "Không tìm thấy ADB.")
            return
        }
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) file"
        reportActivity(device, progress: DeviceProgress(message: "Đang cài \(name)…"))
        do {
            let installed = try await APKInstaller.install(files, adb: adb, serial: device.serial)
            let threads = await APKInstaller.installedVersion(of: "com.instagram.barcelona", adb: adb, serial: device.serial)
            reportActivity(device, progress: DeviceProgress(message: "Đã cài \(installed)" + (threads.map { " · Threads \($0)" } ?? "")))
            await refreshInstalledApps(device)
        } catch {
            reportActivity(device, progress: DeviceProgress(message: "Chưa cài được APK: \(error.localizedDescription)"), hasIssue: true)
            actionError = ActionError(title: "Không thể cài APK lên \(device.name)", details: error.localizedDescription)
        }
    }

    func canStopThreads(_ device: AndroidDevice) -> Bool { threadsTasks[device.id] != nil }

    func stopThreads(_ device: AndroidDevice) {
        threadsTasks[device.id]?.cancel()
        nextThreadsRun.removeValue(forKey: device.id)
        updateThreadsActivity(device, progress: DeviceProgress(message: "Đang dừng chu kỳ Threads…"))
    }

    func runThreads(_ device: AndroidDevice) {
        guard device.isReady, adbError == nil, runningThreads.insert(device.id).inserted else { return }
        activities[device.id] = Activity(progress: DeviceProgress(message: "Đang mở Threads"), startedAt: Date())
        threadsTasks[device.id] = Task { await self.executeThreadsLoop(device) }
    }

    private func executeThreadsLoop(_ device: AndroidDevice) async {
        defer {
            threadsTasks.removeValue(forKey: device.id)
            runningThreads.remove(device.id)
            nextThreadsRun.removeValue(forKey: device.id)
        }
        guard let storage else {
            updateThreadsActivity(device, progress: DeviceProgress(message: storageError ?? "Chưa mở được dữ liệu SQLite."), hasIssue: true)
            return
        }
        guard let key = ThreadsKey.load() else {
            updateThreadsActivity(device, progress: DeviceProgress(message: "Chưa có khóa AI. Tạo file khóa mã hóa bằng lệnh --encrypt-threads-key rồi build lại app."), hasIssue: true)
            return
        }
        // Comments are typed with Gboard's Vietnamese Telex layout; stop early on phones using another keyboard.
        if let adb = ToolPaths.adb(),
           let ime = try? await RunningCommand(adb, arguments: ["-s", device.serial, "shell", "settings", "get", "secure", "default_input_method"])
                .result(timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines),
           !ime.isEmpty, !ime.hasPrefix("com.google.android.inputmethod.latin/") {
            updateThreadsActivity(device, progress: DeviceProgress(message: "Máy đang dùng bàn phím \(ime), chưa phải Gboard. Cài Gboard, đặt làm bàn phím mặc định và bật Tiếng Việt Telex rồi chạy lại."), hasIssue: true)
            return
        }
        do {
            let environment = try storage.threadsSettings().runEnvironment
            try await ThreadsLoop.run(round: { prepareFeed, cycle, ordinal in
                try Task.checkCancellation()
                guard self.devices.contains(where: { $0.serial == device.serial && $0.isReady }) else {
                    throw ThreadsLaunchError(errorDescription: "Điện thoại đã ngắt kết nối. Chu kỳ đã dừng.")
                }
                let runID = try storage.startRun(device: device)
                let prefix = "Chu kỳ \(cycle) · Lượt \(ordinal)/10 · "
                do {
                    let adb = try await self.launchThreads(device)
                    try await ThreadsAttachments.cleanupSubmitted(adb: adb, serial: device.serial)
                    let result = try await ThreadsAutomation.run(adb: adb, serial: device.serial, key: key,
                                                                 prepareFeed: prepareFeed) { progress in
                        self.updateThreadsActivity(device, progress: DeviceProgress(message: prefix + progress.message,
                                                                                   completed: progress.completed, total: progress.total))
                    }
                    self.recordResult(device, runID: runID, message: prefix + result.message, hasIssue: result.hasIssue)
                    return ThreadsLoop.Round(submitted: result.submitted, readyForNext: result.feedReady, message: result.message)
                } catch {
                    self.recordResult(device, runID: runID, message: prefix + (Task.isCancelled ? "Đã dừng." : error.localizedDescription), hasIssue: true)
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }, closeThreads: {
                guard let adb = ToolPaths.adb() else { throw ThreadsLaunchError(errorDescription: "Không tìm thấy ADB.") }
                // The one-minute post-send grace period finishes before force-stop.
                let command = try RunningCommand(adb, arguments: ["-s", device.serial, "shell", "am", "force-stop", "--user", "current", "com.instagram.barcelona"])
                let result = await command.result(timeout: 10)
                guard result.status == 0 else { throw ThreadsLaunchError(errorDescription: "Chưa đóng được Threads để nghỉ.") }
            }, event: { event in
                switch event {
                case let .starting(cycle, submitted):
                    self.nextThreadsRun.removeValue(forKey: device.id)
                    self.activities[device.id]?.startedAt = Date()
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · Đã bấm Đăng \(submitted)/10"))
                case let .submitted(cycle, count):
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · Đã bấm Đăng \(count)/10"))
                case let .keepingOpen(cycle, count, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · Đã bấm Đăng \(count)/10 · Giữ Threads mở 1 phút trước khi thoát"))
                case let .resting(cycle, count, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "\(environment.title) · Chu kỳ \(cycle) · Đã bấm Đăng \(count)/10 · Đã tắt Threads · nghỉ \(environment.restLabel)"))
                case let .cycleResting(cycle, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · Đã bấm Đăng 10/10 · Đã tắt Threads · nghỉ 3 giờ trước chu kỳ \(cycle + 1)"))
                }
            }, restRange: environment.restRange)
        } catch {
            updateThreadsActivity(device, progress: DeviceProgress(message: Task.isCancelled ? "Đã dừng chu kỳ Threads." : error.localizedDescription),
                                  hasIssue: !Task.isCancelled)
        }
    }

    private struct ThreadsLaunchError: LocalizedError {
        let errorDescription: String?
    }

    @discardableResult
    private func launchThreads(_ device: AndroidDevice) async throws -> URL {
        guard let adb = ToolPaths.adb() else {
            throw ThreadsLaunchError(errorDescription: "Không tìm thấy ADB.")
        }
        let shell = ["-s", device.serial, "shell"]
        let package = "com.instagram.barcelona"
        let launcher = ["-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER"]
        let lookup = try RunningCommand(adb, arguments: shell + [
            "cmd", "package", "resolve-activity", "--brief", "--user", "current"
        ] + launcher + ["-p", package])
        let resolved = await lookup.result(timeout: 8)
        guard resolved.status == 0,
              let component = resolved.output.split(whereSeparator: \.isNewline)
                .first(where: { $0.hasPrefix(package + "/") }) else {
            let details = resolved.output.contains("No activity found")
                ? "Hãy cài hoặc bật ứng dụng Threads trong hồ sơ Android hiện tại."
                : (resolved.diagnostics.isEmpty ? "Android không trả về thông tin ứng dụng." : resolved.diagnostics)
            throw ThreadsLaunchError(errorDescription: details)
        }
        let quotedComponent = "'" + component.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = try RunningCommand(adb, arguments: shell + [
            "am", "start", "-W", "--user", "current"
        ] + launcher + ["-n", quotedComponent])
        let result = await command.result(timeout: 15)
        guard result.status == 0, result.output.split(whereSeparator: \.isNewline).contains("Status: ok") else {
            let details = result.diagnostics.isEmpty ? "Android không xác nhận đã mở Threads." : result.diagnostics
            throw ThreadsLaunchError(errorDescription: details)
        }
        return adb
    }

    func close(_ device: AndroidDevice) {
        guard let command = sessions[device.id], stopping.insert(device.id).inserted else { return }
        command.stop()
    }

    func stopAll() {
        for task in threadsTasks.values { task.cancel() }
        for task in photoCleanupTasks.values { task.cancel() }
        for command in sessions.values {
            command.stop()
        }
    }
}
