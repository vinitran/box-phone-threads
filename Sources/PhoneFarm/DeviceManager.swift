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

    enum TetherState: Equatable {
        case starting
        /// Online through the phone's proxy; ip is the address websites see.
        case on(ip: String?)
        /// No proxy saved: the phone gets no internet and no action runs on it.
        case needsProxy
        case failed(String)
        /// Through the proxy over the phone's own Wi-Fi or SIM; ip is nil until it is checked.
        case phoneNetwork(ip: String?)
    }
    /// How a phone reaches the internet, chosen per phone with the button on its card.
    enum NetworkMode: String {
        /// Over the USB cable through the phone's proxy; Wi-Fi and SIM are turned off.
        case usb
        /// The phone's own Wi-Fi or SIM, still through the phone's proxy.
        case phone
    }
    /// Internet over the USB cable per connected phone, started automatically on connect.
    @Published private(set) var tether: [String: TetherState] = [:]
    /// Phones switched to their own network; every other phone uses the USB tunnel.
    @Published private(set) var phoneNetworkDevices: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "phoneNetworkDevices") ?? [])
    private var relays: [String: RunningCommand] = [:]
    private var relayPorts: [String: Int] = [:]
    /// Required apps (Gboard, Threads, Instagram) missing on each connected phone, checked once per connection.
    /// An empty list means the phone was checked and has all of them; no entry means not checked yet.
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

    /// The phone's own proxy comes first, so a phone keeps its proxy on another Mac.
    func proxyAddress(_ device: AndroidDevice) -> String? {
        if let address = identities[device.id]?.proxyAddress { return address }
        guard let saved = savedProxies[device.id], saved.isActive else { return nil }
        return saved.endpoint?.address
    }

    /// The proxy the phone's USB tunnel goes through, with its login. The phone's file comes first.
    func tunnelProxy(_ device: AndroidDevice) throws -> ProxyProfile? {
        if let line = identities[device.id]?.proxy, let profile = ProxyProfile(line: line) { return profile }
        guard let saved = savedProxies[device.id], saved.isActive else { return nil }
        guard let profile = saved.profile else {
            // Never fall back to the Mac's own network for a phone that has a proxy.
            throw USBTether.TetherError("Chưa có mật khẩu proxy \(saved.endpoint?.address ?? "") (bản cũ lưu trong Keychain). Bấm Proxy và nhập lại proxy.")
        }
        return profile
    }

    // MARK: Internet over USB through the phone's proxy, or the phone's own network

    func networkMode(_ device: AndroidDevice) -> NetworkMode {
        phoneNetworkDevices.contains(device.id) ? .phone : .usb
    }

    /// Switches the phone between the USB tunnel and its own Wi-Fi/SIM, and remembers the choice.
    func setNetworkMode(_ device: AndroidDevice, _ mode: NetworkMode) async {
        guard tether[device.id] != .starting, !runningThreads.contains(device.id) else { return }
        if mode == .phone { phoneNetworkDevices.insert(device.id) } else { phoneNetworkDevices.remove(device.id) }
        UserDefaults.standard.set(phoneNetworkDevices.sorted(), forKey: "phoneNetworkDevices")
        await startTether(device)
    }

    /// Brings up the phone's chosen network. Also used after the proxy changes: the phone's
    /// tunnel reconnects to the new relay by itself.
    func startTether(_ device: AndroidDevice) async {
        guard device.isReady, tether[device.id] != .starting, let adb = ToolPaths.adb() else { return }
        if networkMode(device) == .phone {
            await usePhoneNetwork(device, adb: adb)
            return
        }
        guard let tools = USBTether.Tools.bundled else {
            tether[device.id] = .failed("Bản Phone Farm này thiếu gnirehtet. Hãy cập nhật app.")
            return
        }
        tether[device.id] = .starting
        USBTether.log(device.serial, "start")
        // Re-read the phone's file, which may have a newer proxy than the one loaded on connect.
        await loadIdentity(device)
        do {
            guard let proxy = try tunnelProxy(device) else {
                // Phones never go online through the Mac's own network, nor without a proxy.
                relays.removeValue(forKey: device.id)?.stop()
                await USBTether.cutNetwork(serial: device.serial, adb: adb)
                USBTether.log(device.serial, "no proxy")
                tether[device.id] = .needsProxy
                return
            }
            USBTether.log(device.serial, "proxy " + proxy.endpoint.address)
            let port = relayPort(device)
            relays.removeValue(forKey: device.id)?.stop()
            // Let the old relay release the port before the new one listens on it.
            try await Task.sleep(for: .milliseconds(400))
            let relay = try USBTether.startRelay(tools: tools, adb: adb, port: port, proxy: proxy)
            relays[device.id] = relay
            watch(relay, device)
            try await Task.sleep(for: .milliseconds(300))
            try await USBTether.connect(serial: device.serial, tools: tools, adb: adb, port: port)
            guard relays[device.id] === relay else { return }
            tether[device.id] = .on(ip: nil)
            let ip = await USBTether.publicIP(adb: adb, serial: device.serial)
            guard relays[device.id] === relay else { return }
            USBTether.log(device.serial, "connected, ip " + (ip ?? "unknown"))
            tether[device.id] = ip == nil
                ? .failed("Đã bật VPN qua cáp nhưng điện thoại chưa ra được internet qua proxy \(proxy.endpoint.address). Kiểm tra proxy.")
                : .on(ip: ip)
        } catch {
            USBTether.log(device.serial, "failed: " + error.localizedDescription)
            tether[device.id] = .failed(error.localizedDescription)
        }
    }

    /// Runs the relay inside the phone's VPN app, over the phone's own Wi-Fi or SIM, still through its proxy.
    private func usePhoneNetwork(_ device: AndroidDevice, adb: URL) async {
        guard let tools = USBTether.Tools.bundled else {
            tether[device.id] = .failed("Bản Phone Farm này thiếu app VPN. Hãy cập nhật app.")
            return
        }
        tether[device.id] = .starting
        USBTether.log(device.serial, "phone network")
        relays.removeValue(forKey: device.id)?.stop()
        await loadIdentity(device)
        do {
            guard let proxy = try tunnelProxy(device) else {
                // Without a proxy the phone gets no internet at all.
                await USBTether.cutNetwork(serial: device.serial, adb: adb)
                USBTether.log(device.serial, "no proxy")
                tether[device.id] = .needsProxy
                return
            }
            USBTether.log(device.serial, "phone network, proxy " + proxy.endpoint.address)
            try await USBTether.connectLocal(serial: device.serial, tools: tools, adb: adb, proxy: proxy)
            guard networkMode(device) == .phone, relays[device.id] == nil else { return }
            tether[device.id] = .phoneNetwork(ip: nil)
            // Wi-Fi needs a few seconds to join its network after it is turned on.
            for attempt in 0..<4 {
                if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
                let ip = await USBTether.publicIP(adb: adb, serial: device.serial)
                guard networkMode(device) == .phone, relays[device.id] == nil, tether[device.id] == .phoneNetwork(ip: nil) else { return }
                if let ip {
                    USBTether.log(device.serial, "phone network ip " + ip)
                    tether[device.id] = .phoneNetwork(ip: ip)
                    watchPhoneNetwork(device, adb: adb)
                    return
                }
            }
            USBTether.log(device.serial, "phone network: no internet through the proxy")
            tether[device.id] = .failed("Đã bật VPN nhưng điện thoại chưa ra được internet qua proxy \(proxy.endpoint.address) bằng Wi-Fi/SIM. Kiểm tra Wi-Fi và proxy.")
        } catch {
            USBTether.log(device.serial, "phone network failed: " + error.localizedDescription)
            await USBTether.cutNetwork(serial: device.serial, adb: adb)
            tether[device.id] = .failed(error.localizedDescription)
        }
    }

    /// With Wi-Fi/SIM on, a VPN that stops would let apps out without the proxy, so Phone Farm checks
    /// it every 15 seconds and turns Wi-Fi and data off when it is gone.
    private func watchPhoneNetwork(_ device: AndroidDevice, adb: URL) {
        Task {
            while case .phoneNetwork = tether[device.id], networkMode(device) == .phone {
                try? await Task.sleep(for: .seconds(15))
                guard case .phoneNetwork = tether[device.id], networkMode(device) == .phone,
                      devices.contains(where: { $0.id == device.id && $0.isReady }) else { return }
                if await USBTether.isConnected(adb: adb, serial: device.serial) { continue }
                guard case .phoneNetwork = tether[device.id], networkMode(device) == .phone else { return }
                await USBTether.cutNetwork(serial: device.serial, adb: adb)
                USBTether.log(device.serial, "phone network: VPN gone, network cut")
                tether[device.id] = .failed("VPN trên điện thoại đã tắt nên Phone Farm đã tắt Wi-Fi/SIM để không ra internet ngoài proxy. Chuột phải biểu tượng mạng → Nối lại mạng.")
                return
            }
        }
    }

    private func relayPort(_ device: AndroidDevice) -> Int {
        if let port = relayPorts[device.id] { return port }
        let port = USBTether.firstPort + relayPorts.count
        relayPorts[device.id] = port
        return port
    }

    private func watch(_ relay: RunningCommand, _ device: AndroidDevice) {
        Task {
            let result = await relay.result(outputLimit: 16_000)
            USBTether.log(device.serial, "relay exited \(result.status): " + result.diagnostics)
            guard relays[device.id] === relay else { return }
            relays.removeValue(forKey: device.id)
            let reason = result.status == 3 ? "Không phân giải được địa chỉ proxy." : result.diagnostics
            tether[device.id] = .failed("Relay trên Mac đã dừng. " + reason)
        }
    }

    /// Every action on a phone needs its proxy: the tunnel must be up through it, over the USB
    /// cable or over the phone's own Wi-Fi/SIM.
    func isProxyReady(_ device: AndroidDevice) -> Bool {
        proxyBlockReason(device) == nil
    }

    /// Why actions are locked on this phone, or nil when its network is ready.
    func proxyBlockReason(_ device: AndroidDevice) -> String? {
        switch tether[device.id] {
        case .on, .phoneNetwork(ip: .some): return nil
        case .phoneNetwork(ip: nil): return "Đang kiểm tra internet qua proxy bằng Wi-Fi/SIM của điện thoại."
        case .starting:
            return networkMode(device) == .phone
                ? "Đang nối internet qua proxy bằng Wi-Fi/SIM của điện thoại. Chờ một chút."
                : "Đang nối internet qua cáp USB và proxy. Chờ biểu tượng cáp chuyển xanh."
        case .failed(let message):
            return networkMode(device) == .phone
                ? "Chưa có internet qua proxy bằng Wi-Fi/SIM: \(message)"
                : "Chưa có internet qua proxy: \(message)"
        case .needsProxy, nil:
            return "Máy chưa gắn proxy. Bấm Proxy để gắn proxy trước khi thao tác."
        }
    }

    /// Shows why the action cannot run and returns false when the phone's proxy is not ready.
    private func requireProxy(_ device: AndroidDevice) -> Bool {
        guard let reason = proxyBlockReason(device) else { return true }
        actionError = ActionError(title: "\(displayName(device)): cần proxy", details: reason)
        return false
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
            Task {
                await loadIdentity(device)
                // The phone's own proxy is read first, so the tunnel starts with the right one.
                await startTether(device)
            }
        }
        for id in relays.keys where !ready.contains(id) {
            relays.removeValue(forKey: id)?.stop()
            tether.removeValue(forKey: id)
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
        guard device.isReady, adbError == nil, sessions[device.id] == nil, requireProxy(device) else { return }
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
        guard device.isReady, adbError == nil, requireProxy(device), runningThreads.insert(device.id).inserted else { return false }
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
        missingApps[device.id] = AppBundles.apps.filter { !packages.contains($0.package) }
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
        guard device.isReady, adbError == nil, !runningThreads.contains(device.id), requireProxy(device),
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
        guard device.isReady, adbError == nil, !runningThreads.contains(device.id), requireProxy(device),
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
        guard device.isReady, adbError == nil, !files.isEmpty, !runningThreads.contains(device.id), requireProxy(device),
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

    /// Stops the cycle and closes Threads on the phone completely (force-stop).
    func stopThreads(_ device: AndroidDevice) {
        let task = threadsTasks[device.id]
        task?.cancel()
        nextThreadsRun.removeValue(forKey: device.id)
        updateThreadsActivity(device, progress: DeviceProgress(message: "Đang dừng chu kỳ và tắt Threads…"))
        Task {
            await forceStopThreads(device)
            // Again once the cycle has unwound, in case a step reopened Threads meanwhile.
            await task?.value
            let closed = await forceStopThreads(device)
            reportActivity(device, progress: DeviceProgress(message: closed ? "Đã dừng chu kỳ và tắt Threads."
                                                                            : "Đã dừng chu kỳ nhưng chưa tắt được Threads trên điện thoại."),
                           hasIssue: !closed)
        }
    }

    /// Ends this phone's helper processes first: the typing helper keeps running after its task is
    /// cancelled and, once Threads is gone, its key taps would land on the home screen.
    @discardableResult
    private func forceStopThreads(_ device: AndroidDevice) async -> Bool {
        let script = "pkill -f 'app_process /system/bin (KeyboardReader|ThreadsReader)'; "
            + "am force-stop --user current com.instagram.barcelona"
        guard let adb = ToolPaths.adb(),
              let command = try? RunningCommand(adb, arguments: ["-s", device.serial, "shell", script])
        else { return false }
        return await command.result(timeout: 10).status == 0
    }

    /// Threads may only run after the phone was checked and has Gboard, Threads and Instagram.
    func hasRequiredApps(_ device: AndroidDevice) -> Bool { missingApps[device.id]?.isEmpty == true }

    func runThreads(_ device: AndroidDevice) {
        guard requireProxy(device) else { return }
        guard hasRequiredApps(device) else {
            let missing = missingApps[device.id].map { $0.map(\.name).joined(separator: ", ") } ?? "chưa kiểm tra"
            actionError = ActionError(title: "Chưa chạy được Threads trên \(device.name)",
                                      details: "Cần cài đủ Gboard, Threads và Instagram trước (còn thiếu: \(missing)). Bấm Cài trên thẻ máy.")
            return
        }
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
            var lastIssue: String?
            try await ThreadsLoop.run(round: { prepareFeed, cycle, ordinal, kind, deadline in
                try Task.checkCancellation()
                guard self.devices.contains(where: { $0.serial == device.serial && $0.isReady }) else {
                    throw ThreadsLaunchError(errorDescription: "Điện thoại đang ngắt kết nối ADB.")
                }
                if let reason = self.proxyBlockReason(device) {
                    throw ThreadsStopError(errorDescription: reason + " Chu kỳ đã dừng.")
                }
                let runID = try storage.startRun(device: device)
                let prefix = "Chu kỳ \(cycle) · \(kind.title) · Lượt \(ordinal) · "
                do {
                    let adb = try await self.launchThreads(device)
                    try await ThreadsAttachments.cleanupSubmitted(adb: adb, serial: device.serial)
                    let result = try await ThreadsAutomation.run(adb: adb, serial: device.serial, key: key,
                                                                 prepareFeed: prepareFeed, kind: kind, deadline: deadline) { progress in
                        self.updateThreadsActivity(device, progress: DeviceProgress(message: prefix + progress.message,
                                                                                   completed: progress.completed, total: progress.total))
                    }
                    self.recordResult(device, runID: runID, message: prefix + result.message, hasIssue: result.hasIssue)
                    return ThreadsLoop.Round(submitted: result.submitted, readyForNext: result.feedReady, message: result.message,
                                             retryable: !result.mayHavePosted)
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
            }, recover: { reason in
                guard let adb = ToolPaths.adb() else { return }
                DiagnosticLog.record("Khởi động lại", reason: reason,
                                     raw: "Dừng tiến trình điều khiển còn treo trên điện thoại và tắt Threads trước khi thử lại.", serial: device.serial)
                // A reader the Mac gave up on can stay alive holding UiAutomation, which makes every later reader
                // fail. The bracket keeps the pattern from matching this shell's own command line.
                let restart = "pkill -f '[/]data/local/tmp/phone-farm-'; am force-stop --user current com.instagram.barcelona"
                _ = await (try? RunningCommand(adb, arguments: ["-s", device.serial, "shell", restart]))?.result(timeout: 15)
            }, event: { event in
                switch event {
                case let .waiting(cycle, counts, slot, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label) · Chờ lượt \(slot.kind.title.lowercased())"))
                case let .starting(cycle, counts, slot, _):
                    self.nextThreadsRun.removeValue(forKey: device.id)
                    self.activities[device.id]?.startedAt = Date()
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "\(environment.title) · Chu kỳ \(cycle) · \(counts.label) · Đang chạy lượt \(slot.kind.title.lowercased())"))
                case let .submitted(cycle, counts):
                    lastIssue = nil
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label)"))
                case let .keepingOpen(cycle, counts, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label) · Giữ Threads mở 1 phút trước khi thoát"))
                case let .finishingWindow(cycle, counts, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label) · Đã tắt Threads · chờ hết khung 3 giờ"
                                                                               + (lastIssue.map { " · " + $0 } ?? "")))
                case let .cycleResting(cycle, counts, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label) · Hết khung 3 giờ · nghỉ 4 giờ trước chu kỳ \(cycle + 1)"
                                                                               + (lastIssue.map { " · " + $0 } ?? "")))
                case let .retrying(cycle, counts, attempt, total, reason, until):
                    self.nextThreadsRun[device.id] = until
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label) · Lỗi: \(reason) · Đã khởi động lại Threads, thử lại lần \(attempt)/\(total)"))
                case let .skipped(cycle, counts, reason):
                    lastIssue = "Lượt trước bị bỏ qua sau \(ThreadsLoop.retryDelays.count) lần thử lại. Lỗi cuối: \(reason)"
                    self.updateThreadsActivity(device, progress: DeviceProgress(message: "Chu kỳ \(cycle) · \(counts.label) · " + lastIssue!))
                case let .windowAbandoned(_, _, reason):
                    lastIssue = "\(ThreadsLoop.failedSlotsBeforeRest) lượt liên tiếp lỗi, nghỉ đến chu kỳ sau rồi tự chạy lại. Lỗi cuối: \(reason)"
                }
            })
        } catch {
            updateThreadsActivity(device, progress: DeviceProgress(message: Task.isCancelled ? "Đã dừng chu kỳ Threads." : error.localizedDescription),
                                  hasIssue: !Task.isCancelled)
        }
    }

    private struct ThreadsLaunchError: LocalizedError {
        let errorDescription: String?
    }

    /// A problem retrying cannot fix (missing proxy settings), so the loop stops and shows it.
    private struct ThreadsStopError: LocalizedError, ThreadsLoopStop {
        let errorDescription: String?
    }

    @discardableResult
    private func launchThreads(_ device: AndroidDevice) async throws -> URL {
        guard let adb = ToolPaths.adb() else {
            throw ThreadsLaunchError(errorDescription: "Không tìm thấy ADB.")
        }
        let shell = ["-s", device.serial, "shell"]
        // Android does not resume Threads while the screen is off, so `am start -W` hangs until the
        // timeout. Keep the screen on while plugged in, wake it and dismiss a non-secure lock screen.
        _ = await (try? RunningCommand(adb, arguments: shell + [
            "settings put global stay_on_while_plugged_in 7; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard"
        ]))?.result(timeout: 10)
        let power = await (try? RunningCommand(adb, arguments: shell + ["dumpsys", "power"]))?.result(timeout: 10)
        if let power, power.output.contains("mWakefulness="), !power.output.contains("mWakefulness=Awake") {
            throw ThreadsLaunchError(errorDescription: "Màn hình điện thoại đang tắt và không bật lên được. Hãy bật màn hình.")
        }
        // Close the notification shade if someone left it open; it covers Threads and the keyboard.
        _ = await (try? RunningCommand(adb, arguments: shell + ["cmd", "statusbar", "collapse"]))?.result(timeout: 8)
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
        let result = await command.result(timeout: 20)
        if result.status == 0, result.output.split(whereSeparator: \.isNewline).contains("Status: ok") {
            return adb
        }
        // `am start -W` can time out on a slow phone even though Threads did open.
        let activities = await (try? RunningCommand(adb, arguments: shell + ["dumpsys", "activity", "activities"]))?
            .result(timeout: 10, outputLimit: 512_000)
        let resumed = activities?.output.split(whereSeparator: \.isNewline)
            .contains { $0.contains("ResumedActivity") && $0.contains(package + "/") } ?? false
        guard resumed else {
            throw ThreadsLaunchError(errorDescription: "Android chưa mở được Threads sau 20 giây. Hãy kiểm tra màn hình điện thoại đang bật và không bị khoá.")
        }
        return adb
    }

    func close(_ device: AndroidDevice) {
        guard let command = sessions[device.id], stopping.insert(device.id).inserted else { return }
        command.stop()
    }

    func stopAll() {
        // Phones keep Wi-Fi and data off: without Phone Farm they stay offline rather than leave without the proxy.
        for relay in relays.values { relay.stop() }
        relays.removeAll()
        for task in threadsTasks.values { task.cancel() }
        for task in photoCleanupTasks.values { task.cancel() }
        for command in sessions.values {
            command.stop()
        }
    }
}
