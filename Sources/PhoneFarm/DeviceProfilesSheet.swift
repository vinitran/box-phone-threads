import SwiftUI
import UniformTypeIdentifiers

struct DeviceProfilesSheet: View {
    let device: AndroidDevice
    @Environment(\.dismiss) private var dismiss
    @State private var library: DeviceProfileLibrary?
    @State private var current: DeviceTestProfile?
    @State private var name = ""
    @State private var reading = false
    @State private var message: String?
    @State private var failure: String?
    private let repository = DeviceProfileRepository()

    private var selected: DeviceTestProfile? {
        library?.profiles.first { $0.id == library?.selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cấu hình QA · \(device.name)").font(.title2.weight(.semibold))
            Text("Serial ADB của máy · \(device.serial)").font(.caption.monospaced()).textSelection(.enabled)
            Text("Tạo và lưu cấu hình kiểm thử. Chọn lại profile sẽ giữ nguyên bộ giá trị đã lưu.")
                .foregroundStyle(.secondary)
            Label("Cấu hình QA lưu trên Mac · Android user/proxy được quản lý ở nút Profiles trên thẻ máy", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.orange)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profile đã lưu").font(.headline)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(library?.profiles ?? []) { profile in
                                Button {
                                    guard var next = library else { return }
                                    next.selectedID = profile.id
                                    if commit(next) { name = profile.name }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).fontWeight(.medium)
                                        Text(profile.kind == .captured ? "Hiện trạng đã chụp" : "Cấu hình random kiểm thử")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(9)
                                    .background(selected?.id == profile.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                            if library?.profiles.isEmpty == true {
                                Text("Chưa có profile. Đọc hiện trạng rồi tạo profile đầu tiên.")
                                    .font(.callout).foregroundStyle(.secondary).padding(.vertical)
                            }
                        }
                    }
                    HStack {
                        Button("Nhập JSON…", action: importLibrary)
                        Button("Xuất JSON…", action: exportLibrary).disabled(library?.profiles.isEmpty != false)
                    }
                    .disabled(library == nil)
                }
                .frame(width: 245)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        HStack {
                            TextField("Tên profile", text: $name).textFieldStyle(.roundedBorder)
                            Button("Lưu tên", action: rename).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Đang chọn để xem · \(selected.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if selected.needsConsistencyRepair {
                                    Button("Đồng bộ thuộc tính QA", action: normalizeSelected)
                                    Text("Giữ model, OS, UUID và seed; tạo bản sao file gốc trước khi sửa các trường build.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if !selected.consistencyIssues.isEmpty {
                                    Text(selected.consistencyIssues.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                field("Profile ID riêng", selected.id.uuidString)
                                field("Seed kiểm thử", selected.seed.uuidString)
                                ForEach(DeviceTestProfile.propertyKeys, id: \.self) { key in
                                    field(key, selected.properties[key] ?? "—")
                                }
                                field("Ngôn ngữ", selected.locale.isEmpty ? "Chưa ghi nhận" : selected.locale)
                                field("Múi giờ", selected.timezone.isEmpty ? "Chưa ghi nhận" : selected.timezone)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("Chọn profile để xem bộ thông tin đã lưu.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Text("Mẫu QA dùng userdebug/test-keys; lưu hiện trạng để giữ nguyên các trường build thực tế. Serial ADB dùng chung cho máy, UUID dùng riêng cho từng profile. Thư viện này không thay đổi dữ liệu app hoặc phần cứng trên Android.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            Divider()
            HStack {
                Button(reading ? "Đang đọc…" : "Đọc hiện trạng") { Task { await readCurrent() } }
                    .disabled(reading || !device.isReady)
                Button("Đọc API Android") { Task { await readCurrent(viaAPI: true) } }
                    .disabled(reading || !device.isReady)
                Button("Lưu hiện trạng", action: saveCurrent).disabled(current == nil || library == nil || reading)
                Button("Random & lưu profile", action: randomize)
                    .disabled(library == nil || (current == nil && library?.profiles.first(where: { $0.kind == .captured }) == nil))
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 820, height: 650)
        .task {
            do {
                library = try repository.load(serial: device.serial)
                name = selected?.name ?? ""
            } catch { failure = "Không mở được thư viện profile: " + error.localizedDescription }
            if device.isReady { await readCurrent() }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
    }

    private func readCurrent(viaAPI: Bool = false) async {
        reading = true
        defer { reading = false }
        do {
            guard let adb = ToolPaths.adb() else { throw DeviceTestProfile.ProfileError("Không tìm thấy ADB.") }
            if viaAPI {
                current = try await DeviceTestProfile.readVisible(adb: adb, serial: device.serial)
            } else {
                current = try await DeviceTestProfile.read(adb: adb, serial: device.serial)
            }
            failure = nil
            message = viaAPI
                ? "Đã đọc các API Build trong tiến trình shell mới. Kết quả chưa chứng minh mọi app khác đọc giống nhau. Bấm Lưu hiện trạng để xem và giữ bản ghi."
                : "Đã đọc thuộc tính hệ thống. Bấm Lưu hiện trạng để xem và giữ bản ghi."
        } catch {
            current = nil
            failure = error.localizedDescription
            message = nil
        }
    }

    private func append(_ profile: DeviceTestProfile) {
        guard var next = library else { return }
        next.profiles.append(profile)
        next.selectedID = profile.id
        if commit(next) {
            name = profile.name
            message = "Đã lưu \(profile.name). Chưa áp dụng lên điện thoại."
        }
    }

    private func saveCurrent() {
        guard var profile = current else { return }
        profile.id = UUID()
        profile.name += " " + Date().formatted(date: .abbreviated, time: .shortened)
        append(profile)
    }

    private func randomize() {
        guard let baseline = current ?? library?.profiles.first(where: { $0.kind == .captured }) else { return }
        let number = (library?.profiles.filter { $0.kind == .randomized }.count ?? 0) + 1
        do { append(try baseline.randomized(name: String(format: "Profile %03d", number))) }
        catch { failure = error.localizedDescription }
    }

    private func normalizeSelected() {
        guard var next = library, let index = next.profiles.firstIndex(where: { $0.id == next.selectedID }) else { return }
        do {
            next.profiles[index] = try next.profiles[index].normalizedQA()
            let backup = try repository.save(next, backupExisting: true)
            library = next
            failure = nil
            message = "Đã đồng bộ thuộc tính QA" + (backup.map { ". Bản gốc: " + $0.path } ?? "")
        } catch { failure = error.localizedDescription }
    }

    private func rename() {
        guard var next = library, let index = next.profiles.firstIndex(where: { $0.id == next.selectedID }) else { return }
        next.profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if commit(next) { message = "Đã lưu tên profile." }
    }

    @discardableResult
    private func commit(_ next: DeviceProfileLibrary) -> Bool {
        do {
            try repository.save(next)
            library = next
            failure = nil
            return true
        } catch {
            failure = error.localizedDescription
            message = nil
            return false
        }
    }

    private func exportLibrary() {
        guard let library else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "phone-farm-profiles.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DeviceProfileRepository.encode(library).write(to: url, options: .atomic)
            message = "Đã xuất thư viện profile."
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    private func importLibrary() {
        guard var next = library else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try DeviceProfileRepository.decode(Data(contentsOf: url), serial: device.serial)
            for profile in incoming.profiles {
                if let existing = next.profiles.first(where: { $0.id == profile.id }) {
                    guard existing.properties == profile.properties, existing.seed == profile.seed,
                          existing.kind == profile.kind, existing.generatorVersion == profile.generatorVersion,
                          existing.locale == profile.locale, existing.timezone == profile.timezone else {
                        throw DeviceTestProfile.ProfileError("Trùng ID nhưng cấu hình khác nhau. Không nhập để tránh mất profile cũ.")
                    }
                } else { next.profiles.append(profile) }
            }
            if next.selectedID == nil { next.selectedID = incoming.selectedID }
            if commit(next) {
                name = selected?.name ?? ""
                message = "Đã nhập profile của đúng máy, giữ lại các profile hiện có."
            }
        } catch { failure = error.localizedDescription }
    }
}
