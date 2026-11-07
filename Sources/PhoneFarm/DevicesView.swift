import SwiftUI

/// Main window: an adaptive grid of device cards, so a farm of many phones fits on one screen
/// and the column count follows the window width.
struct DevicesView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var updater: AppUpdater
    @State private var pendingUpdate: AppUpdater.Release?
    @State private var reportsUpdateFailure = false
    @State private var proxyDevice: AndroidDevice?
    @State private var threadsDevice: AndroidDevice?
    @State private var infoDevice: AndroidDevice?
    @State private var showThreadsSettings = false
    @State private var filter: DeviceFilter = .all
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
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
            })
        }
        .sheet(item: $threadsDevice) { device in
            ThreadsFeedSheet(device: device) { manager.reportActivity(device, progress: DeviceProgress(message: $0)) }
        }
        .sheet(item: $infoDevice) { device in
            DeviceInfoSheet(device: device)
        }
        .sheet(isPresented: $showThreadsSettings) { ThreadsSettingsSheet() }
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

    @ViewBuilder
    private var updateControl: some View {
        let version = "v" + updater.currentVersion
        switch updater.state {
        case .available(let release):
            Button {
                pendingUpdate = release
            } label: {
                Label("Cập nhật v\(release.version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Đang dùng \(version). Có phiên bản v\(release.version) trên GitHub.")
        case .installing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(version) · Đang kiểm tra…").font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize()
        case .failed(let message):
            Button {
                Task { await updater.check() }
            } label: {
                Label(version, systemImage: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .help("Chưa kiểm tra được phiên bản mới: \(message) Bấm để thử lại.")
        case .idle, .upToDate:
            Button {
                Task { await updater.check() }
            } label: {
                Label(version, systemImage: "checkmark.seal")
            }
            .help(updater.state == .upToDate ? "Đang dùng bản mới nhất. Bấm để kiểm tra lại." : "Bấm để kiểm tra phiên bản mới.")
        }
    }

    private var updateMessage: String {
        let running = manager.runningThreads.count
        var text = "Phone Farm sẽ tải bản mới từ GitHub, đóng app, thay bản cũ rồi tự mở lại. Bạn cần nhập lại mật khẩu."
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
            }
            // Connected phones first; serial keeps the order stable while statuses change.
            .sorted { ($0.isReady ? 0 : 1, $0.serial) < ($1.isReady ? 0 : 1, $1.serial) }
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
            proxyRow
            Divider()
            actions
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
                Text(device.name).font(.headline).lineLimit(1)
                Text(device.name == device.serial ? "Chưa rõ model" : device.serial)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textSelection(.enabled)

            Spacer(minLength: 6)

            if manager.sessions[device.id] != nil {
                Image(systemName: "display")
                    .foregroundStyle(.secondary)
                    .help("Đang hiển thị màn hình bằng scrcpy")
                    .accessibilityLabel("Đang hiển thị màn hình")
            }

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
                Text(manager.savedProxies[device.id]?.endpoint?.address ?? "Chưa cấu hình proxy")
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
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Tùy chọn Threads")
            .disabled(!canUse || isRunning)

            Spacer(minLength: 8)

            threadsButton
                .fixedSize()
                .help("Sau mỗi lần bấm Đăng: về Trang chủ, giữ Threads mở 1 phút, tắt hẳn Threads và nghỉ theo chế độ: Dev 2 phút, Production 20–30 phút rồi chạy tiếp. Bộ đếm theo chu kỳ 10 lần. Giữ Phone Farm mở trên Mac; bấm Đóng để kết thúc.")
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
            Button {
                manager.runThreads(device)
            } label: {
                Label("Chạy Threads", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canUse || isRunning)
        }
    }
}
