import SwiftUI

struct DeviceInfoSheet: View {
    let device: AndroidDevice
    @ObservedObject var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var info: PhoneFarmStore.DeviceInfo?
    @State private var error: String?
    @State private var name = ""
    @State private var number = ""
    @State private var identityStatus: String?
    @State private var savingIdentity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Thông tin · \(device.name)").font(.title2.weight(.semibold))
            Text(device.serial).font(.caption.monospaced()).textSelection(.enabled)
            identityEditor
            if let info {
                Text("Lần kết nối gần nhất · " + date(info.lastSeen)).foregroundStyle(.secondary)
                if let proxy = info.proxy {
                    Text("Proxy đã lưu · " + (proxy.endpoint?.address ?? "Chưa có địa chỉ"))
                        .textSelection(.enabled)
                    Text("Lần kiểm tra proxy · " + date(proxy.updatedAt)).font(.caption).foregroundStyle(.secondary)
                    if let username = proxy.username {
                        Text("Tài khoản proxy · " + username).font(.caption).textSelection(.enabled)
                    }
                }
                Text("Các phiên Threads gần đây").font(.headline)
                if info.runs.isEmpty {
                    Text("Chưa có phiên Threads được lưu.").foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(info.runs) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(date(run.startedAt)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(state(run.state)).font(.caption)
                                }
                                Text(run.message).font(.callout).textSelection(.enabled)
                                if let end = run.finishedAt {
                                    Text("Kết thúc · " + date(end)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Đọc lại", action: load)
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            load()
            let identity = manager.identities[device.id]
            name = identity?.name ?? ""
            number = identity?.number.map(String.init) ?? ""
        }
    }

    /// Name and number stored on the phone (/sdcard/PhoneFarm/device.json) so they follow it to other Macs.
    private var identityEditor: some View {
        GroupBox("Nhận diện lưu trên điện thoại") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Tên máy, ví dụ Máy 01", text: $name)
                    TextField("Số máy", text: $number).frame(width: 80)
                    Button("Lưu vào điện thoại") { Task { await saveIdentity() } }
                        .disabled(savingIdentity || !device.isReady)
                }
                .textFieldStyle(.roundedBorder)
                Text("File \(DeviceIdentity.path) · Proxy trên máy: \(manager.identities[device.id]?.proxyAddress ?? "chưa có")")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let identityStatus { Text(identityStatus).font(.caption) }
            }
            .padding(4)
        }
    }

    private func saveIdentity() async {
        let trimmedNumber = number.trimmingCharacters(in: .whitespaces)
        guard trimmedNumber.isEmpty || Int(trimmedNumber) != nil else {
            identityStatus = "Số máy phải là số nguyên."
            return
        }
        savingIdentity = true
        defer { savingIdentity = false }
        do {
            try await manager.saveIdentity(device, name: name, number: Int(trimmedNumber))
            identityStatus = "Đã lưu vào điện thoại."
        } catch {
            identityStatus = error.localizedDescription
        }
    }

    private func load() {
        do {
            info = try PhoneFarmStore.shared.get().deviceInfo(serial: device.serial)
            error = info == nil ? "Chưa có thông tin được lưu cho thiết bị này." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func state(_ value: String) -> String {
        switch value {
        case "running": return "Đang chạy"
        case "completed": return "Hoàn tất"
        case "interrupted": return "Gián đoạn"
        default: return "Cần kiểm tra"
        }
    }

    private func date(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
