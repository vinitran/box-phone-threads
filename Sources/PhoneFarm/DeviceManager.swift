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
    @Published private(set) var stoppingThreads: Set<String> = []
    @Published private(set) var profileRotation: [String: ROMProfileRotation.Status] = [:]
    @Published private(set) var installingAPK: Set<String> = []
    @Published private(set) var updatingProfile: Set<String> = []
    /// Identity files read from each phone (/sdcard/PhoneFarm/device.json), kept while offline.
    @Published private(set) var identities: [String: DeviceIdentity] = [:]
    @Published private(set) var romDevices: Set<String> = []
    @Published private(set) var romChecking: Set<String> = []
    @Published private(set) var romNeedsReconcile: Set<String> = []
    @Published private(set) var romBusy: Set<String> = []
    @Published private(set) var romProfiles: [String: ROMProfileList] = [:]
    @Published private(set) var romErrors: [String: String] = [:]
    @Published private(set) var romVerified: Set<String> = []
    @Published var manualDevices: Set<String> = []
    private var romGenerations: [String: Int] = [:]
    private var romLastPoll: [String: Date] = [:]
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
    private var threadsSessions: [String: ROMSession] = [:]
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
                } catch {
                    devices = discovered
                    storageError = error.localizedDescription
                }
            } else {
                devices = discovered
            }
            checkInstalledApps()
            checkIdentities()
            adbError = nil
            pollROMProfiles()
            cleanSubmittedPhotos(adb: adb)
        } catch {
            adbError = error.localizedDescription
        }
    }

    private func cleanSubmittedPhotos(adb: URL) {
        guard let storage else { return }
        for device in devices where device.isReady && photoCleanupTasks[device.serial] == nil && !romChecking.contains(device.id) && !romBusy.contains(device.id) {
            if romDevices.contains(device.id) && !romVerified.contains(device.id) { continue }
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
        if romDevices.contains(device.id) { return romProfiles[device.id]?.active?.proxy?.address }
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
        romDevices.contains(device.id) || phoneNetworkDevices.contains(device.id) ? .phone : .usb
    }

    /// Switches the phone between the USB tunnel and its own Wi-Fi/SIM, and remembers the choice.
    func setNetworkMode(_ device: AndroidDevice, _ mode: NetworkMode) async {
        guard !romDevices.contains(device.id), !romChecking.contains(device.id) else { return }
        guard tether[device.id] != .starting, !runningThreads.contains(device.id) else { return }
        if mode == .phone { phoneNetworkDevices.insert(device.id) } else { phoneNetworkDevices.remove(device.id) }
        UserDefaults.standard.set(phoneNetworkDevices.sorted(), forKey: "phoneNetworkDevices")
        await startTether(device)
    }

    /// Brings up the phone's chosen network. Also used after the proxy changes: the phone's
    /// tunnel reconnects to the new relay by itself.
    func startTether(_ device: AndroidDevice) async {
        guard !romChecking.contains(device.id) else { return }
        if romDevices.contains(device.id) { await refreshROMProfiles(device); return }
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
            while case .phoneNetwork = tether[device.id], networkMode(device) == .phone, !romDevices.contains(device.id) {
                try? await Task.sleep(for: .seconds(15))
                guard !romDevices.contains(device.id), case .phoneNetwork = tether[device.id], networkMode(device) == .phone,
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
        if romChecking.contains(device.id) { return "Đang nhận diện engine profile trên điện thoại." }
        if romDevices.contains(device.id) {
            if romBusy.contains(device.id) { return "Đang xử lý profile; các thao tác trên máy đang khóa." }
            if !romVerified.contains(device.id) { return romErrors[device.id] ?? "Mở Profiles để gắn và xác minh proxy riêng của profile đang dùng." }
        }
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
            romChecking.insert(device.id)
            Task {
                await detectROMProfiles(device)
                romChecking.remove(device.id)
                if romDevices.contains(device.id) {
                    await loadIdentity(device)
                    await refreshROMProfiles(device)
                    return
                }
                await loadIdentity(device)
                // The phone's own proxy is read first, so the tunnel starts with the right one.
                await startTether(device)
            }
        }
        for id in romDevices where !ready.contains(id) {
            romVerified.remove(id)
            ROMRuntime.shared.set(id, managed: true, session: nil)
            stopThreadsByID(id)
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
        guard !romDevices.contains(device.id), let adb = ToolPaths.adb() else { return }
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
            missingApps.removeValue(forKey: device.id)
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
            try await syncInstalledROMApps(device, adb: adb)
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
            try await syncInstalledROMApps(device, adb: adb)
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
        guard stoppingThreads.insert(device.id).inserted else { return }
        let task = threadsTasks[device.id]
        let expectedUser = threadsSessions[device.id]?.userID
        task?.cancel()
        nextThreadsRun.removeValue(forKey: device.id)
        updateThreadsActivity(device, progress: DeviceProgress(message: "Đang dừng chu kỳ và tắt Threads…"))
        Task {
            defer { stoppingThreads.remove(device.id) }
            await forceStopThreads(device, expectedUser: expectedUser)
            // Again once the cycle has unwound, in case a step reopened Threads meanwhile.
            await task?.value
            let closed = await forceStopThreads(device, expectedUser: romProfiles[device.id]?.activeUser ?? expectedUser)
            reportActivity(device, progress: DeviceProgress(message: closed ? "Đã dừng chu kỳ và tắt Threads."
                                                                            : "Đã dừng chu kỳ nhưng chưa tắt được Threads trên điện thoại."),
                           hasIssue: !closed)
        }
    }

    /// Ends this phone's helper processes first: the typing helper keeps running after its task is
    /// cancelled and, once Threads is gone, its key taps would land on the home screen.
    @discardableResult
    private func forceStopThreads(_ device: AndroidDevice, expectedUser: Int? = nil) async -> Bool {
        let user = expectedUser.map(String.init) ?? "current"
        let script = "pkill -f 'app_process /system/bin (KeyboardReader|ThreadsReader)'; "
            + "am force-stop --user \(user) com.instagram.barcelona"
        guard let adb = ToolPaths.adb(),
              let command = try? RunningCommand(adb, arguments: ["-s", device.serial, "shell", script])
        else { return false }
        return await command.result(timeout: 10).status == 0
    }

    /// Threads may only run after the phone was checked and has Gboard, Threads and Instagram.
    func hasRequiredApps(_ device: AndroidDevice) -> Bool { missingApps[device.id]?.isEmpty == true }
    func canPrepareThreads(_ device: AndroidDevice) -> Bool {
        missingApps[device.id].map { $0.allSatisfy { $0 == AppBundles.gboard } } ?? false
    }

    func runThreads(_ device: AndroidDevice) {
        guard !stoppingThreads.contains(device.id), romCanMutate(device) else { return }
        guard requireProxy(device) else { return }
        guard canPrepareThreads(device) else {
            let missing = missingApps[device.id].map { $0.map(\.name).joined(separator: ", ") } ?? "chưa kiểm tra"
            actionError = ActionError(title: "Chưa chạy được Threads trên \(device.name)",
                                      details: "Cần cài đủ Gboard, Threads và Instagram trước (còn thiếu: \(missing)). Bấm Cài trên thẻ máy.")
            return
        }
        guard device.isReady, adbError == nil, runningThreads.insert(device.id).inserted else { return }
        activities[device.id] = Activity(progress: DeviceProgress(message: "Đang mở Threads"), startedAt: Date())
        let session = try? ROMRuntime.shared.session(device.serial)
        threadsSessions[device.id] = session
        threadsTasks[device.id] = Task {
            await ROMTaskContext.$session.withValue(session) { await self.executeThreadsLoop(device) }
        }
    }

    private func executeThreadsLoop(_ device: AndroidDevice) async {
        defer { finishThreadsTask(device) }
        do { try await runThreadsLoopBody(device) }
        catch {
            updateThreadsActivity(device, progress: DeviceProgress(message: Task.isCancelled ? "Đã dừng chu kỳ Threads." : error.localizedDescription),
                                  hasIssue: !Task.isCancelled)
        }
    }

    private func finishThreadsTask(_ device: AndroidDevice) {
        threadsTasks.removeValue(forKey: device.id)
        threadsSessions.removeValue(forKey: device.id)
        runningThreads.remove(device.id)
        nextThreadsRun.removeValue(forKey: device.id)
        profileRotation.removeValue(forKey: device.id)
    }

    private func runThreadsLoopBody(_ device: AndroidDevice, state: ThreadsLoop.State? = nil, yieldAtCycleRest: Bool = false) async throws {
        guard let storage else {
            throw ThreadsLaunchError(errorDescription: storageError ?? "Chưa mở được dữ liệu SQLite.")
        }
        guard let key = ThreadsKey.load() else {
            throw ThreadsLaunchError(errorDescription: "Chưa có khóa AI. Tạo file khóa mã hóa bằng lệnh --encrypt-threads-key rồi build lại app.")
        }
        guard let adb = ToolPaths.adb() else { throw TypingError.unavailable }
        try await GboardSetup.ensure(adb: adb, serial: device.serial) { message in
            self.updateThreadsActivity(device, progress: DeviceProgress(message: message))
        }
        await refreshInstalledApps(device)
        let environment = try storage.threadsSettings().runEnvironment
        var lastIssue: String?
        try await ThreadsLoop.run(state: state, yieldAtCycleRest: yieldAtCycleRest, round: { prepareFeed, cycle, ordinal, kind, deadline in
            try Task.checkCancellation()
            guard self.devices.contains(where: { $0.serial == device.serial && $0.isReady }) else {
                throw ThreadsLaunchError(errorDescription: "Điện thoại đang ngắt kết nối ADB.")
            }
            if let reason = self.proxyBlockReason(device) {
                // A tunnel that is reconnecting or dropped can come back; only a phone without a proxy stops the loop.
                switch self.tether[device.id] {
                case .needsProxy, nil: throw ThreadsStopError(errorDescription: reason + " Chu kỳ đã dừng.")
                default: throw ThreadsLaunchError(errorDescription: reason)
                }
            }
            do {
                let session = try ROMRuntime.shared.session(device.serial)
                if let session, let adb = ToolPaths.adb() {
                    try await ROMRuntime.checkForeground(session, adb: adb, serial: device.serial)
                    let current = try await ROMProfilesClient(adb: adb, serial: device.serial).list()
                    guard current.active?.id == session.profileID, current.networkGuard?.protects(session.userID) == true else { throw ROMError.wrongProfile }
                }
            } catch { throw ThreadsStopError(errorDescription: error.localizedDescription) }
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
            let session = try ROMRuntime.shared.session(device.serial)
            try await ROMRuntime.checkForeground(session, adb: adb, serial: device.serial)
            // The one-minute post-send grace period finishes before force-stop.
            let user = session.map { String($0.userID) } ?? "current"
            let command = try RunningCommand(adb, arguments: ["-s", device.serial, "shell", "am", "force-stop", "--user", user, "com.instagram.barcelona"])
            let result = await command.result(timeout: 10)
            guard result.status == 0 else { throw ThreadsLaunchError(errorDescription: "Chưa đóng được Threads để nghỉ.") }
        }, recover: { reason in
            if self.romDevices.contains(device.id) {
                _ = await self.forceStopThreads(device, expectedUser: self.threadsSessions[device.id]?.userID)
                return
            }
            guard let adb = ToolPaths.adb() else { return }
            DiagnosticLog.record("Khởi động lại", reason: reason,
                                 raw: "Dừng tiến trình điều khiển còn treo trên điện thoại và tắt Threads trước khi thử lại.", serial: device.serial)
            // A reader the Mac gave up on can stay alive holding UiAutomation, which makes every later reader
            // fail. The bracket keeps the pattern from matching this shell's own command line.
            let restart = "pkill -f '[/]data/local/tmp/phone-farm-'; am force-stop --user current com.instagram.barcelona"
            _ = await (try? RunningCommand(adb, arguments: ["-s", device.serial, "shell", restart]))?.result(timeout: 15)
            // No internet through the proxy (or a dropped tunnel): bring the VPN and relay up again.
            guard self.devices.contains(where: { $0.id == device.id && $0.isReady }), self.tether[device.id] != .starting else { return }
            var offline = false
            if case .failed = self.tether[device.id] { offline = true }
            if !offline { offline = await USBTether.publicIP(adb: adb, serial: device.serial) == nil }
            guard offline else { return }
            DiagnosticLog.record("Nối lại mạng", reason: "Điện thoại không ra được internet qua proxy",
                                 raw: "Khởi động lại VPN và relay của điện thoại trước khi thử lại.", serial: device.serial)
            await self.startTether(device)
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
        let session = try ROMRuntime.shared.session(device.serial)
        if let adb = ToolPaths.adb() { try await ROMRuntime.checkForeground(session, adb: adb, serial: device.serial) }
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


// Real Android-user profiles, managed by the installed ROM engine. No legacy VPN/identity writes.
extension DeviceManager {
    func romCanMutate(_ device: AndroidDevice) -> Bool {
        device.isReady && !romBusy.contains(device.id) && !romChecking.contains(device.id)
            && !runningThreads.contains(device.id) && !stoppingThreads.contains(device.id) && !installingAPK.contains(device.id)
            && !updatingProfile.contains(device.id) && !manualDevices.contains(device.id)
    }

    private func stopThreadsByID(_ id: String) {
        threadsTasks[id]?.cancel()
    }

    private func detectROMProfiles(_ device: AndroidDevice) async {
        guard let adb = ToolPaths.adb() else { return }
        let probe = await (try? RunningCommand(adb, arguments: ["-s", device.serial, "shell", "pm", "list", "packages", "vn.romprofiles"]))?.result(timeout: 10)
        // Failure to identify a device is not permission to start a competing VPN.
        guard let probe, probe.status == 0 else {
            romDevices.insert(device.id)
            ROMRuntime.shared.set(device.serial, managed: true, session: nil)
            romErrors[device.id] = ROMError.unavailable.localizedDescription
            return
        }
        if probe.output.contains("package:") {
            romDevices.insert(device.id)
            ROMRuntime.shared.set(device.serial, managed: true, session: nil)
            relays.removeValue(forKey: device.id)?.stop()
        } else {
            romDevices.remove(device.id)
            ROMRuntime.shared.set(device.serial, managed: false, session: nil)
        }
    }

    func refreshROMProfiles(_ device: AndroidDevice) async {
        guard romCanMutate(device), let adb = ToolPaths.adb() else { return }
        if !romDevices.contains(device.id) { await detectROMProfiles(device) }
        guard romDevices.contains(device.id) else {
            romErrors[device.id] = "Máy chưa cài ROM Profiles. Cài engine có sẵn trong Documents/rom trên máy đã hỗ trợ root trước."
            return
        }
        romGenerations[device.id, default: 0] += 1
        romBusy.insert(device.id)
        ROMRuntime.shared.set(device.serial, managed: true, session: nil)
        romVerified.remove(device.id)
        defer { romBusy.remove(device.id) }
        do {
            let client = ROMProfilesClient(adb: adb, serial: device.serial)
            romProfiles[device.id] = try await client.list()
            if romProfiles[device.id]?.capabilities?.contains("profile.reconcile") == true {
                _ = try await client.call(ROMRequest(operation: "profile.reconcile"), timeout: 90)
                romProfiles[device.id] = try await client.list()
                guard romProfiles[device.id]?.profiles.contains(where: \.isDeleting) != true else { throw ROMError.resultUnknown }
            }
            _ = try await client.call(ROMRequest(operation: "proxy.status", userId: romProfiles[device.id]?.activeUser), timeout: 20)
            romNeedsReconcile.remove(device.id)
            try await verifyROMNetwork(device, client: client)
            await refreshInstalledApps(device)
        } catch {
            romErrors[device.id] = error.localizedDescription
            tether[device.id] = .failed(error.localizedDescription)
        }
    }

    private func verifyROMNetwork(_ device: AndroidDevice, client: ROMProfilesClient) async throws {
        let list = try await client.list()
        romProfiles[device.id] = list
        guard let active = list.active, active.proxy?.enforced == true,
              list.networkGuard?.protects(active.userID) == true else { throw ROMError.notProtected }
        let verified = try await client.call(ROMRequest(operation: "network.verify", userId: active.userID), timeout: 90)
        guard verified.passed else { throw ROMError.notProtected }
        let egress = try await client.call(ROMRequest(operation: "proxy.egress", userId: active.userID), timeout: 60)
        guard let ip = egress.egressIP else { throw ROMError.notProtected }
        let final = try await client.list()
        guard final.active?.id == active.id, final.networkGuard?.protects(active.userID) == true else { throw ROMError.wrongProfile }
        romProfiles[device.id] = final
        ROMRuntime.shared.set(device.serial, managed: true, session: ROMSession(profileID: active.id, userID: active.userID))
        romVerified.insert(device.id)
        romErrors.removeValue(forKey: device.id)
        tether[device.id] = .phoneNetwork(ip: ip)
        romLastPoll[device.id] = Date()
    }

    /// Mutations are locked per physical device. A failed/unknown result stays blocked until a
    /// subsequent explicit refresh verifies what the engine actually committed.
    func performROM(_ device: AndroidDevice, request: ROMRequest) async {
        guard romDevices.contains(device.id), !romNeedsReconcile.contains(device.id), romCanMutate(device), let adb = ToolPaths.adb() else { return }
        romGenerations[device.id, default: 0] += 1
        romBusy.insert(device.id)
        romVerified.remove(device.id)
        // Finish any photo cleanup before switching the Android user it belongs to.
        await photoCleanupTasks[device.serial]?.value
        ROMRuntime.shared.set(device.serial, managed: true, session: nil)
        romErrors.removeValue(forKey: device.id)
        reportActivity(device, progress: DeviceProgress(message: "Đang xử lý profile · giữ kết nối USB"))
        defer { romBusy.remove(device.id) }
        let client = ROMProfilesClient(adb: adb, serial: device.serial)
        do {
            // Check the selected user still exists, and refuse sharing an upstream with another profile.
            let before = try await client.list()
            if let user = request.userId, !before.profiles.contains(where: { $0.userID == user }) { throw ROMError.wrongProfile }
            if request.operation == "profile.create", request.proxy == nil { throw ROMError.proxyRequired }
            if ["profile.activate", "profile.restore"].contains(request.operation) {
                guard let target = before.profiles.first(where: { $0.userID == request.userId }), !target.isDeleting, target.proxy?.enforced == true else { throw ROMError.notProtected }
                if before.profiles.contains(where: { $0.id != target.id && $0.proxy?.address?.lowercased() == target.proxy?.address?.lowercased() }) { throw ROMError.duplicateProxy }
            }
            if let proxy = request.proxy, before.profiles.contains(where: {
                $0.userID != request.userId && $0.proxy?.host?.lowercased() == proxy.host.lowercased() && $0.proxy?.port == proxy.port
            }) { throw ROMError.duplicateProxy }
            if let proxy = request.proxy {
                reportActivity(device, progress: DeviceProgress(message: "Đang gọi HTTPS qua proxy · chưa thay đổi profile"))
                _ = try await client.call(ROMRequest(operation: "proxy.test", proxy: proxy), timeout: 60)
            }
            var mutation = request
            if let target = before.profiles.first(where: { $0.userID == request.userId }) {
                if request.operation == "profile.delete" {
                    guard before.capabilities?.contains("profile.delete") == true, target.userID > 0,
                          target.userID != before.activeUser, !target.isDeleting, request.confirmDeletion == true,
                          request.expectedProfileId == target.id else { throw ROMError.wrongProfile }
                }
                if ["profile.activate", "profile.restore"].contains(request.operation) { mutation.expectedProfileId = target.id }
            }
            _ = try await client.call(mutation, timeout: 600)
            romProfiles[device.id] = try await client.list()
            if request.operation == "profile.delete" {
                do { try await verifyROMNetwork(device, client: client) }
                catch {
                    ROMRuntime.shared.set(device.serial, managed: true, session: nil)
                    romVerified.remove(device.id)
                    tether[device.id] = .failed(error.localizedDescription)
                    let message = "Đã xoá profile đã chọn và giữ bản sao lưu. Mạng của profile đang dùng cần kiểm tra: " + error.localizedDescription
                    romErrors[device.id] = message
                    reportActivity(device, progress: DeviceProgress(message: message), hasIssue: true)
                    return
                }
                reportActivity(device, progress: DeviceProgress(message: "Đã xoá profile đã chọn · giữ các profile khác và bản sao lưu"))
                return
            }
            try await verifyROMNetwork(device, client: client)
            await refreshInstalledApps(device)
            reportActivity(device, progress: DeviceProgress(message: "Profile đã sẵn sàng · proxy và chặn mạng đã xác minh"))
        } catch {
            if error as? ROMError == .resultUnknown || error as? ROMError == .invalidResponse { romNeedsReconcile.insert(device.id) }
            // Reading state is safe, including after a timeout; never repeat the mutation.
            romProfiles[device.id] = try? await client.list()
            romErrors[device.id] = error.localizedDescription
            tether[device.id] = .failed(error.localizedDescription)
            reportActivity(device, progress: DeviceProgress(message: error.localizedDescription), hasIssue: true)
        }
    }

    private func pollROMProfiles() {
        for device in devices where device.isReady && romDevices.contains(device.id) && !romBusy.contains(device.id) && !romChecking.contains(device.id) {
            guard Date().timeIntervalSince(romLastPoll[device.id] ?? .distantPast) >= 15, let adb = ToolPaths.adb() else { continue }
            romLastPoll[device.id] = Date()
            let generation = romGenerations[device.id, default: 0]
            Task {
                do {
                    let list = try await ROMProfilesClient(adb: adb, serial: device.serial).list()
                    guard !romBusy.contains(device.id), romGenerations[device.id, default: 0] == generation else { return }
                    let previous = romProfiles[device.id]?.active
                    romProfiles[device.id] = list
                    if previous != list.active || list.networkGuard?.protects(list.activeUser) != true {
                        romVerified.remove(device.id)
                        ROMRuntime.shared.set(device.serial, managed: true, session: nil)
                        stopThreadsByID(device.id)
                        romErrors[device.id] = ROMError.wrongProfile.localizedDescription
                    }
                } catch {
                    guard !romBusy.contains(device.id), romGenerations[device.id, default: 0] == generation else { return }
                    romVerified.remove(device.id)
                    ROMRuntime.shared.set(device.serial, managed: true, session: nil)
                    stopThreadsByID(device.id)
                    romErrors[device.id] = error.localizedDescription
                }
            }
        }
    }

    private func syncInstalledROMApps(_ device: AndroidDevice, adb: URL) async throws {
        guard romDevices.contains(device.id) else { return }
        let session = try ROMRuntime.shared.session(device.serial)
        try await ROMRuntime.checkForeground(session, adb: adb, serial: device.serial)
        _ = try await ROMProfilesClient(adb: adb, serial: device.serial).call(ROMRequest(operation: "apps.sync"), timeout: 90)
    }

    func romAccountLabel(_ device: AndroidDevice, profile: ROMProfile) -> String {
        (try? storage?.setting("rom.account.\(device.serial).\(profile.id)")) ?? ""
    }
    func saveROMAccountLabel(_ device: AndroidDevice, profile: ROMProfile, label: String) {
        do {
            try storage?.saveSetting("rom.account.\(device.serial).\(profile.id)", value: String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)))
            objectWillChange.send()
        } catch { romErrors[device.id] = error.localizedDescription }
    }
}

extension DeviceManager {
    func runRotatingThreads(_ device: AndroidDevice, profileIDs: Set<String>, mode: ROMProfileRotation.Mode = .restWindows) {
        guard romCanMutate(device), romDevices.contains(device.id), !romNeedsReconcile.contains(device.id),
              let list = romProfiles[device.id] else { return }
        let selected = list.profiles.filter { profileIDs.contains($0.id) }
        do {
            if mode == .restWindows, selected.count != 2 { throw ROMProfileAlternation.SelectionError() }
            _ = try ROMProfileRotation.ordered(selected, startingAt: list.active?.id)
        }
        catch { actionError = ActionError(title: "Chưa chạy được luân phiên profile", details: error.localizedDescription); return }
        guard runningThreads.insert(device.id).inserted else { return }
        activities[device.id] = Activity(progress: DeviceProgress(message: "Đang chuẩn bị chạy luân phiên profile"), startedAt: Date())
        threadsTasks[device.id] = Task {
            defer { finishThreadsTask(device) }
            var states: [String: ThreadsLoop.State] = [:]
            do {
                let prepare: @MainActor @Sendable (ROMProfile) async throws -> Void = { profile in
                    // An Android-user mutation must settle and reconcile even if Stop was pressed.
                    try await Task.detached { @MainActor in try await self.prepareRotationProfile(device, target: profile) }.value
                }
                let runWindow: @MainActor @Sendable (ROMProfile, ThreadsLoop.State) async throws -> Void = { profile, state in
                    let session = ROMSession(profileID: profile.id, userID: profile.userID)
                    self.threadsSessions[device.id] = session
                    try await ROMTaskContext.$session.withValue(session) {
                        try await self.runThreadsLoopBody(device, state: state, yieldAtCycleRest: mode == .restWindows)
                    }
                }
                let stopSession: @MainActor @Sendable (ROMProfile) async -> Bool = { profile in
                    await self.forceStopThreads(device, expectedUser: profile.userID)
                }
                let event: @MainActor (ROMProfileRotation.Status) -> Void = { status in
                    self.profileRotation[device.id] = status
                    if let wake = status.wakeAt {
                        self.nextThreadsRun[device.id] = wake
                        self.updateThreadsActivity(device, progress: DeviceProgress(message: "Đang nghỉ · chuẩn bị tiếp \(status.next.name) khi đến lịch · giữ nguyên profile hiện tại"))
                    } else if status.switchAt == nil {
                        self.nextThreadsRun.removeValue(forKey: device.id)
                        self.updateThreadsActivity(device, progress: DeviceProgress(message: "Đang chuẩn bị \(status.profile.name) · sao lưu và kiểm tra proxy"))
                    }
                }
                if mode == .restWindows {
                    try await ROMProfileAlternation.run(profiles: selected, startingAt: list.active?.id,
                        prepare: prepare, runWindow: runWindow, stopSession: stopSession, event: event)
                } else {
                    try await ROMProfileRotation.run(profiles: selected, startingAt: list.active?.id, prepare: prepare,
                        runSession: { profile, _ in
                            let state = states[profile.id] ?? ThreadsLoop.State()
                            states[profile.id] = state
                            try await runWindow(profile, state)
                        }, stopSession: stopSession, event: event)
                }
            } catch {
                let closed = await Task.detached { @MainActor in
                    await self.forceStopThreads(device, expectedUser: self.romProfiles[device.id]?.activeUser)
                }.value
                let message = Task.isCancelled ? "Đã dừng chạy luân phiên profile." : error.localizedDescription
                updateThreadsActivity(device, progress: DeviceProgress(message: message + (closed ? "" : " Chưa đóng được Threads.")),
                                      hasIssue: !Task.isCancelled || !closed)
            }
        }
    }

    private func prepareRotationProfile(_ device: AndroidDevice, target: ROMProfile) async throws {
        guard devices.contains(where: { $0.id == device.id && $0.isReady }), let adb = ToolPaths.adb(),
              !romNeedsReconcile.contains(device.id) else { throw ROMError.unavailable }
        romGenerations[device.id, default: 0] += 1
        romBusy.insert(device.id)
        defer { romBusy.remove(device.id) }
        await photoCleanupTasks[device.serial]?.value
        threadsSessions.removeValue(forKey: device.id)
        ROMRuntime.shared.set(device.serial, managed: true, session: nil)
        romVerified.remove(device.id)
        let client = ROMProfilesClient(adb: adb, serial: device.serial)
        do {
            let before = try await client.list()
            guard let current = before.profiles.first(where: { $0.id == target.id && $0.userID == target.userID }), current.canRotate else {
                throw ROMError.wrongProfile
            }
            guard !before.profiles.contains(where: { $0.id != current.id && $0.proxy?.address?.lowercased() == current.proxy?.address?.lowercased() }) else {
                throw ROMError.duplicateProxy
            }
            if before.active?.id != target.id {
                _ = try await client.call(ROMRequest(operation: "profile.activate", userId: target.userID, backupCurrent: true,
                                                    expectedProfileId: target.id), timeout: 600)
            }
            try await verifyROMNetwork(device, client: client)
            guard romProfiles[device.id]?.active?.id == target.id else { throw ROMError.wrongProfile }
            try await GboardSetup.ensure(adb: adb, serial: device.serial) { message in
                self.updateThreadsActivity(device, progress: DeviceProgress(message: message))
            }
            await refreshInstalledApps(device)
            guard hasRequiredApps(device) else {
                let missing = missingApps[device.id]?.map(\.name).joined(separator: ", ") ?? "chưa kiểm tra được ứng dụng"
                throw ThreadsLaunchError(errorDescription: "\(target.name) chưa sẵn sàng: thiếu \(missing). Cài và đăng nhập Threads trong profile này trước.")
            }
        } catch {
            if error as? ROMError == .resultUnknown || error as? ROMError == .invalidResponse { romNeedsReconcile.insert(device.id) }
            romProfiles[device.id] = try? await client.list()
            if error is ROMError || !romVerified.contains(device.id) {
                romVerified.remove(device.id)
                ROMRuntime.shared.set(device.serial, managed: true, session: nil)
                tether[device.id] = .failed(error.localizedDescription)
            }
            romErrors[device.id] = error.localizedDescription
            throw error
        }
    }
}
