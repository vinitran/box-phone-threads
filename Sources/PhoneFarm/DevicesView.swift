import SwiftUI
import UniformTypeIdentifiers

/// Main window: an adaptive grid of device cards, so a farm of many phones fits on one screen
/// and the column count follows the window width.
struct DevicesView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var updater: AppUpdater
    @State private var pendingUpdate: AppUpdater.Release?
    @State private var proxyWarning: ProxyWarning?
    @State private var reportsUpdateFailure = false
    @State private var proxyDevice: AndroidDevice?
    @State private var threadsDevice: AndroidDevice?
    @State private var profileDevice: AndroidDevice?
    @State private var infoDevice: AndroidDevice?
    @State private var showThreadsSettings = false
    @State private var filter: DeviceFilter = .all
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .alert(proxyWarning.map { "\($0.device.name) chưa gắn proxy" } ?? "",
                       isPresented: Binding(get: { proxyWarning != nil }, set: { if !$0 { proxyWarning = nil } }),
                       presenting: proxyWarning) { warning in
                    Button(warning.action.continueTitle) { perform(warning.action, on: warning.device) }
                    Button("Gắn proxy…") { proxyDevice = warning.device }
                    Button("Hủy", role: .cancel) {}
                } message: { warning in
                    Text("\(warning.device.serial) chưa có proxy đã lưu. Threads trên máy này sẽ dùng IP mạng hiện tại của điện thoại.")
                }
            Divider()
            if let adbError = manager.adbError {
                banner("Không đọc được danh sách thiết bị", details: adbError)
            }
            if let storageError = manager.storageError {
                banner("Chưa lưu được dữ liệu", details: storageError)
            }
            if manager.hasLoaded, !manager.scrcpyAvailable {
                banner("Chưa tìm thấy scrcpy", details: "Cài bằng lệnh brew install scrcpy, sau đó bấm Làm mới.")
            }
            content
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await manager.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            // Check on launch, then every 6 hours while the app stays open.
            while !Task.isCancelled {
                await updater.check()
                // Keep the Threads/Instagram APKs downloaded so new phones can be set up right away.
                _ = try? await manager.prepareBundledApps()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
        .onChange(of: updater.state) { state in
            guard reportsUpdateFailure, case .failed(let message) = state else { return }
            reportsUpdateFailure = false
            manager.actionError = .init(title: "Chưa cập nhật được", details: message)
        }
        .confirmationDialog(pendingUpdate.map { "Cập nhật lên v\($0.version)?" } ?? "",
                            isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } }),
                            presenting: pendingUpdate) { release in
            Button("Tải và cài v\(release.version)") {
                reportsUpdateFailure = true
                Task { await updater.install(release) }
            }
            Button("Xem thay đổi trên GitHub") { NSWorkspace.shared.open(release.pageURL) }
            Button("Để sau", role: .cancel) {}
        } message: { _ in
            Text(updateMessage)
        }
        .alert(item: $manager.actionError) { error in
            Alert(title: Text(error.title), message: Text(error.details), dismissButton: .default(Text("Đóng")))
        }
        .sheet(item: $proxyDevice) { device in
            ProxySheet(device: device, onActivity: {
                manager.reportActivity(device, progress: DeviceProgress(message: $0))
            }, onSaved: {
                do { try manager.reloadSavedProxies() }
                catch { manager.actionError = .init(title: "Chưa đọc được proxy đã lưu", details: error.localizedDescription) }
            }, phoneProxy: manager.identities[device.id]?.proxy, onApplied: { line in
                Task { await manager.recordProxy(device, line: line) }
            })
        }
        .sheet(item: $threadsDevice) { device in
            ThreadsFeedSheet(device: device) { manager.reportActivity(device, progress: DeviceProgress(message: $0)) }
        }
        .sheet(item: $profileDevice) { device in
            ThreadsFeedSheet(device: device, profileOnly: true) { manager.reportActivity(device, progress: DeviceProgress(message: $0)) }
        }
        .sheet(item: $infoDevice) { device in
            DeviceInfoSheet(device: device, manager: manager)
        }
        .sheet(isPresented: $showThreadsSettings) { ThreadsSettingsSheet() }
    }

    // MARK: Proxy check

    struct ProxyWarning: Identifiable {
        enum Action {
            case threads, profile
            var continueTitle: String { self == .threads ? "Vẫn chạy Threads" : "Vẫn đổi ảnh đại diện & bio" }
        }
        let device: AndroidDevice
        let action: Action
        var id: String { device.id }
    }

    /// Runs the action right away when the phone has a saved proxy, otherwise asks first.
    private func checkProxy(_ device: AndroidDevice, _ action: ProxyWarning.Action) {
        if manager.hasProxy(device) { perform(action, on: device) }
        else { proxyWarning = ProxyWarning(device: device, action: action) }
    }

    private func perform(_ action: ProxyWarning.Action, on device: AndroidDevice) {
        switch action {
        case .threads: manager.runThreads(device)
        case .profile: Task { await manager.autoUpdateProfile(device) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Thiết bị Android").font(.title2.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary)
                }

                Spacer()
                Button {
                    showThreadsSettings = true
                } label: {
                    Label("Cấu hình Threads", systemImage: "gearshape")
                }
                Button {
                    Task { await manager.refresh() }
                } label: {
                    Label("Làm mới", systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }

            HStack(spacing: 12) {
                Picker("Lọc thiết bị", selection: $filter) {
                    ForEach(DeviceFilter.allCases) { item in
                        Text("\(item.title) \(count(item))").tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 8)

                bundleControl
                updateControl

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tìm theo tên hoặc serial", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Xóa tìm kiếm")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// State of the Threads/Instagram APKs on this Mac; click to check R2 again.
    @ViewBuilder
    private var bundleControl: some View {
        switch manager.bundleStatus {
        case .working(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("APK").font(.callout).foregroundStyle(.secondary)
            }
            .help(message)
            .fixedSize()
        case .ready(let summary):
            Button {
                Task { _ = try? await manager.prepareBundledApps(force: true) }
            } label: {
                Label("APK", systemImage: "checkmark.circle")
            }
            .help("APK đã sẵn sàng để cài: \(summary). Bấm để kiểm tra bản mới trên máy chủ.")
        case .failed(let message):
            Button {
                Task { _ = try? await manager.prepareBundledApps(force: true) }
            } label: {
                Label("APK", systemImage: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .help("Chưa tải được APK Threads & Instagram: \(message) Bấm để thử lại.")
        case .idle:
            EmptyView()
        }
    }

    /// Running version (or the update button when GitHub has a newer release) plus a button to check again.
    @ViewBuilder
    private var updateControl: some View {
        let version = "v" + updater.currentVersion
        HStack(spacing: 6) {
            switch updater.state {
            case .available(let release):
                Button {
                    pendingUpdate = release
                } label: {
                    Label("Cập nhật v\(release.version)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Đang dùng \(version). Bấm để tải và cài bản mới nhất trên GitHub.")
            case .installing(let message):
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(.secondary)
            case .checking:
                Label(version, systemImage: "checkmark.seal").font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                Label(version, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .help("Chưa kiểm tra được phiên bản mới: \(message)")
            case .idle, .upToDate:
                Label(version, systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(updater.state == .upToDate ? "Đang dùng bản mới nhất." : "Chưa kiểm tra phiên bản mới.")
            }
            if updater.state == .checking {
                ProgressView().controlSize(.small).frame(width: 28)
            } else if !isInstallingUpdate {
                Button {
                    Task { await updater.check() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Kiểm tra lại phiên bản mới nhất trên GitHub")
                .accessibilityLabel("Kiểm tra phiên bản mới")
            }
        }
        .fixedSize()
    }

    private var isInstallingUpdate: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    private var updateMessage: String {
        let running = manager.runningThreads.count
        var text = "Phone Farm sẽ tải bản mới nhất từ GitHub, đóng app, thay bản cũ rồi tự mở lại. Bạn cần nhập lại mật khẩu."
        if running > 0 {
            text += " Threads đang chạy trên \(running) máy sẽ bị dừng."
        }
        return text
    }

    private var summary: String {
        if !manager.hasLoaded { return "Đang tìm thiết bị…" }
        if manager.adbError != nil { return "Danh sách chưa được cập nhật" }
        let ready = manager.devices.filter(\.isReady).count
        let running = manager.devices.filter { manager.runningThreads.contains($0.id) }.count
        var parts = ["\(manager.devices.count) thiết bị", "\(ready) sẵn sàng"]
        if running > 0 { parts.append("\(running) đang chạy Threads") }
        parts.append("\(manager.commentsToday.values.reduce(0, +)) bình luận hôm nay")
        return parts.joined(separator: " · ")
    }

    // MARK: Filtering

    private func matches(_ device: AndroidDevice, _ filter: DeviceFilter) -> Bool {
        let running = manager.runningThreads.contains(device.id)
        let hasIssue = manager.activities[device.id]?.hasIssue == true
        switch filter {
        case .all: return true
        case .running: return running
        case .idle: return device.isReady && !running && !hasIssue
        case .attention: return !device.isReady || (hasIssue && !running)
        }
    }

    private func count(_ filter: DeviceFilter) -> Int {
        manager.devices.filter { matches($0, filter) }.count
    }

    private var visibleDevices: [AndroidDevice] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return manager.devices
            .filter { matches($0, filter) }
            .filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.serial.localizedCaseInsensitiveContains(query)
                    || manager.displayName($0).localizedCaseInsensitiveContains(query)
            }
            // Connected phones first, then by the number in the phone's identity file; serial keeps the order stable.
            .sorted { lhs, rhs in
                let left = (lhs.isReady ? 0 : 1, manager.identities[lhs.id]?.number ?? Int.max, lhs.serial)
                let right = (rhs.isReady ? 0 : 1, manager.identities[rhs.id]?.number ?? Int.max, rhs.serial)
                return left < right
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let devices = visibleDevices
        if manager.devices.isEmpty {
            emptyState
        } else if devices.isEmpty {
            placeholder(icon: "line.3.horizontal.decrease.circle", title: "Không có thiết bị phù hợp",
                        message: "Thử bộ lọc khác hoặc xóa nội dung tìm kiếm.") {
                Button("Xem tất cả thiết bị") {
                    filter = .all
                    search = ""
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(devices) { device in
                        DeviceCard(device: device, manager: manager,
                                   showInfo: { infoDevice = device },
                                   showProxy: { proxyDevice = device },
                                   openProfile: {
                                       Task { if await manager.openThreads(device) { profileDevice = device } }
                                   },
                                   autoProfile: { checkProxy(device, .profile) },
                                   runThreads: { checkProxy(device, .threads) },
                                   openManual: {
                                       Task { if await manager.openThreads(device) { threadsDevice = device } }
                                   })
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !manager.hasLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.adbError == nil {
            placeholder(icon: "cable.connector", title: "Chưa có thiết bị",
                        message: "Kết nối điện thoại bằng USB, bật USB debugging và chấp nhận yêu cầu cấp quyền trên điện thoại.") {
                EmptyView()
            }
        } else {
            Spacer()
        }
    }

    private func placeholder<Actions: View>(icon: String, title: String, message: String,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            actions()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ title: String, details: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(details).font(.callout).textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

enum DeviceFilter: String, CaseIterable, Identifiable {
    case all, running, idle, attention

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "Tất cả"
        case .running: return "Đang chạy"
        case .idle: return "Sẵn sàng"
        case .attention: return "Cần chú ý"
        }
    }
}

// MARK: - Device card

private struct DeviceCard: View {
    let device: AndroidDevice
    @ObservedObject var manager: DeviceManager
    let showInfo: () -> Void
    let showProxy: () -> Void
    let openProfile: () -> Void
    let autoProfile: () -> Void
    let runThreads: () -> Void
    let openManual: () -> Void

    private var isRunning: Bool { manager.runningThreads.contains(device.id) }
    private var activity: DeviceManager.Activity? { manager.activities[device.id] }
    private var hasIssue: Bool { activity?.hasIssue == true && !isRunning }
    private var canUse: Bool { device.isReady && manager.adbError == nil }

    private var tone: (label: String, color: Color) {
        if !device.isReady {
            return (device.statusLabel, device.status == "unauthorized" ? .yellow : .secondary)
        }
        if isRunning { return ("Đang chạy", .accentColor) }
        if hasIssue { return ("Cần chú ý", .orange) }
        return ("Sẵn sàng", .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            activityBlock
            if let missing = manager.missingApps[device.id], !missing.isEmpty {
                installAppsButton(missing)
            }
            proxyRow
            Divider()
            actions
            let updatingProfile = manager.updatingProfile.contains(device.id)
            Button(action: autoProfile) {
                HStack(spacing: 6) {
                    if updatingProfile { ProgressView().controlSize(.small) }
                    Label(updatingProfile ? "Đang đổi ảnh đại diện & bio…" : "Đổi ảnh đại diện & Bio",
                          systemImage: "person.crop.circle")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canUse || isRunning || updatingProfile || manager.installingAPK.contains(device.id))
            .help("Tự động: AI tạo bio, chọn ngẫu nhiên một ảnh trong thư mục ảnh đại diện, rồi lưu cả hai trong Threads.")
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isRunning || hasIssue ? tone.color.opacity(0.7) : Color(nsColor: .separatorColor),
                              lineWidth: isRunning || hasIssue ? 1.5 : 1)
        )
        .opacity(device.isReady ? 1 : 0.7)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(tone.color)
                .frame(width: 34, height: 34)
                .background(tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.displayName(device)).font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textSelection(.enabled)

            Spacer(minLength: 6)

            screenButton

            HStack(spacing: 5) {
                Circle().fill(tone.color).frame(width: 7, height: 7)
                Text(tone.label).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.12), in: Capsule())
            .fixedSize()
        }
    }

    private var message: String {
        if !device.isReady && !isRunning {
            switch device.status {
            case "unauthorized": return "Mở khóa điện thoại và cho phép USB debugging."
            case "no permissions": return "Mac chưa có quyền truy cập thiết bị qua ADB."
            default: return activity?.progress.message ?? "Đã ngắt kết nối. Cắm lại điện thoại để tiếp tục."
            }
        }
        return activity?.progress.message ?? "Chưa chạy Threads."
    }

    private var activityBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: hasIssue ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(hasIssue ? Color.orange : Color.secondary)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(hasIssue ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(message)
            }
            if isRunning {
                HStack(spacing: 8) {
                    if let fraction = activity?.progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if let next = manager.nextThreadsRun[device.id] {
                        Label { Text(next, style: .timer) } icon: { Image(systemName: "hourglass") }
                            .help("Thời gian còn lại trước lượt tiếp theo")
                            .fixedSize()
                    } else if let started = activity?.startedAt {
                        Label { Text(started, style: .timer) } icon: { Image(systemName: "clock") }
                            .help("Thời gian đã chạy")
                            .fixedSize()
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        // Fixed minimum height keeps every card in a row the same size.
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
    }

    private var proxyRow: some View {
        HStack(spacing: 10) {
            Label {
                Text(manager.proxyAddress(device) ?? "Chưa cấu hình proxy")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "network")
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            let comments = manager.commentsToday[device.id] ?? 0
            Label {
                Text("\(comments) bình luận hôm nay").monospacedDigit()
            } icon: {
                Image(systemName: "text.bubble")
            }
            .foregroundStyle(comments > 0 ? Color.primary : Color.secondary)
            .fixedSize()
            .help("Số bình luận đã bấm Đăng từ 0 giờ hôm nay")
        }
        .font(.caption)
    }

    /// Shown while the phone lacks Threads or Instagram; installs both from the APKs saved on the Mac.
    private func installAppsButton(_ missing: [AppBundles.App]) -> some View {
        let installing = manager.installingAPK.contains(device.id)
        return Button {
            Task { await manager.installBundledApps(device) }
        } label: {
            HStack(spacing: 6) {
                if installing { ProgressView().controlSize(.small) }
                Label(installing ? "Đang cài…" : "Cài " + missing.map(\.name).joined(separator: " & "),
                      systemImage: "square.and.arrow.down")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canUse || isRunning || installing)
        .help("Tải APK Gboard, Threads và Instagram (lần đầu, sau đó dùng lại trên Mac), kiểm tra SHA-256 rồi cài và đặt Gboard làm bàn phím mặc định. Máy đã có app cùng hoặc mới hơn sẽ được bỏ qua. Cần đủ ba app mới chạy được Threads.")
    }

    /// Picks one APK, several split APKs or an .apks/.xapk bundle and installs it on this phone.
    private func chooseAPK() {
        let panel = NSOpenPanel()
        panel.title = "Chọn APK để cài lên \(device.name)"
        panel.prompt = "Cài"
        panel.message = "Chọn một file .apk, nhiều file APK của cùng một app (split APK), hoặc file .apks/.xapk."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = APKInstaller.extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = panel.urls
        Task { await manager.installAPK(device, files: files) }
    }

    /// Number from the phone's identity file, then the model when a custom name is shown, then the serial.
    private var subtitle: String {
        let identity = manager.identities[device.id]
        var parts: [String] = []
        if let number = identity?.number { parts.append("Số \(number)") }
        if manager.displayName(device) != device.name, device.name != device.serial { parts.append(device.name) }
        parts.append(device.name == device.serial && parts.isEmpty ? "Chưa rõ model" : device.serial)
        return parts.joined(separator: " · ")
    }

    /// Opens or closes this phone's screen (scrcpy). Screens open only on request.
    private var screenButton: some View {
        let isOpen = manager.sessions[device.id] != nil
        let isClosing = manager.stopping.contains(device.id)
        return Button {
            if isOpen { manager.close(device) } else { manager.open(device) }
        } label: {
            Image(systemName: "display")
                .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(isClosing || (!isOpen && (!canUse || !manager.scrcpyAvailable)))
        .help(isOpen ? "Đóng màn hình điện thoại" : "Mở màn hình điện thoại (scrcpy)")
        .accessibilityLabel(isOpen ? "Đóng màn hình" : "Mở màn hình")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: showInfo) {
                Image(systemName: "info.circle")
            }
            .help("Thông tin thiết bị và các phiên Threads gần đây")
            .accessibilityLabel("Thông tin")

            Button("Proxy", action: showProxy)
                .disabled(!canUse || isRunning)

            Menu {
                Button("Điều khiển thủ công", action: openManual)
                Divider()
                Button("Cài Gboard, Threads & Instagram") { Task { await manager.installBundledApps(device) } }
                Button("Cài APK…", action: chooseAPK)
                Button("Ảnh đại diện & Bio thủ công…", action: openProfile)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Tùy chọn Threads")
            .disabled(!canUse || isRunning || manager.installingAPK.contains(device.id) || manager.updatingProfile.contains(device.id))

            Spacer(minLength: 8)

            threadsButton
                .fixedSize()
                .help("Sau mỗi lần bấm Đăng: về Trang chủ, giữ Threads mở 1 phút, tắt hẳn Threads và nghỉ theo chế độ: Dev 2 phút, Production 20–30 phút rồi chạy tiếp. Sau bình luận thứ 10 của mỗi chu kỳ: tắt Threads và nghỉ 3 giờ. Giữ Phone Farm mở trên Mac; bấm Đóng để kết thúc.")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var threadsButton: some View {
        if manager.canStopThreads(device) {
            Button {
                manager.stopThreads(device)
            } label: {
                Label("Đóng", systemImage: "stop.fill")
            }
            .tint(.red)
        } else {
            Button(action: runThreads) {
                Label("Chạy Threads", systemImage: "play.fill")
            }
            .disabled(!manager.hasRequiredApps(device))
            .buttonStyle(.borderedProminent)
            .disabled(!canUse || isRunning)
        }
    }
}
