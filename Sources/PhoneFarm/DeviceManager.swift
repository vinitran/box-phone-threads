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
    @Published private(set) var nextThreadsRun: [String: Date] = [:]
    @Published private(set) var activities: [String: Activity] = [:]
    @Published private(set) var storageError: String?
    @Published private(set) var savedProxies: [String: PhoneFarmStore.SavedProxy] = [:]
    /// Comments submitted since local midnight, keyed by serial.
    @Published private(set) var commentsToday: [String: Int] = [:]
    @Published var actionError: ActionError?

    private let storage: PhoneFarmStore?
    private var threadsTasks: [String: Task<Void, Never>] = [:]
    /// Serials whose screen was opened automatically during the current connection.
    /// Cleared when the device disconnects so the screen reopens on the next connection.
    private var autoOpened: Set<String> = []

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
                } catch {
                    devices = discovered
                    storageError = error.localizedDescription
                }
            } else {
                devices = discovered
            }
            adbError = nil
            openConnectedScreens()
        } catch {
            adbError = error.localizedDescription
        }
    }

    /// Opens scrcpy once per connection for every ready device. Closing the window keeps it
    /// closed until the phone disconnects and connects again.
    private func openConnectedScreens() {
        let ready = Set(devices.filter(\.isReady).map(\.id))
        autoOpened.formIntersection(ready)
        guard scrcpyAvailable else { return }
        for device in devices where device.isReady && !autoOpened.contains(device.id) {
            autoOpened.insert(device.id)
            open(device)
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
        for command in sessions.values {
            command.stop()
        }
    }
}
