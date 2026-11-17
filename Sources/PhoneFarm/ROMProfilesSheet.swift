import SwiftUI

struct ROMProfilesSheet: View {
    let device: AndroidDevice
    @ObservedObject var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var creating = false
    @State private var proxyLine = ""
    @State private var account = ""
    @State private var profileName = ""
    @State private var deleteTarget: ROMProfile?
    @State private var deleteUser = ""
    @State private var rotationMode: ROMProfileRotation.Mode?
    @State private var inputError: String?

    private var list: ROMProfileList? { manager.romProfiles[device.id] }
    private var selected: ROMProfile? { list?.profiles.first { $0.id == selectedID } }
    private var busy: Bool { manager.romBusy.contains(device.id) || manager.romChecking.contains(device.id) }
    private var canMutate: Bool { manager.romCanMutate(device) && !manager.romNeedsReconcile.contains(device.id) && selected?.isDeleting != true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Profiles · \(manager.displayName(device))", systemImage: "person.2.crop.square.stack")
                    .font(.title2.weight(.semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Làm mới") { Task { await manager.refreshROMProfiles(device) } }.disabled(!manager.romCanMutate(device))
            }
            Text("Mỗi profile là một Android user riêng: dữ liệu Threads, phiên đăng nhập, thư viện ảnh và proxy được giữ riêng. Một điện thoại chỉ chạy một profile tại một thời điểm.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let list {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(list.profiles.count)/\(list.maxProfiles) profiles").font(.headline)
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(list.profiles) { profile in
                                    Button {
                                        creating = false; selectedID = profile.id
                                        loadSelection(profile)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Image(systemName: profile.userID == list.activeUser ? "checkmark.circle.fill" : "person.crop.circle")
                                                    .foregroundStyle(profile.userID == list.activeUser ? .green : .secondary)
                                                Text(profile.name).fontWeight(.medium)
                                            }
                                            Text("User \(profile.userID) · \(manager.romAccountLabel(device, profile: profile).isEmpty ? "Chưa ghi nhãn Threads" : manager.romAccountLabel(device, profile: profile))")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(profile.isDeleting ? "Đang xoá trên Android · bấm Làm mới" : profile.proxy?.address ?? "Chưa gắn proxy").font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                            .background(selectedID == profile.id && !creating ? Color.accentColor.opacity(0.12) : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain).disabled(busy)
                                }
                            }
                        }.frame(width: 250, height: 280)
                        Button("Tạo profile mới…", systemImage: "plus") {
                            creating = true; selectedID = nil; clearProxy(); account = ""; profileName = ""; inputError = nil
                        }.disabled(!canMutate || list.profiles.count >= list.maxProfiles)
                        Button("Chạy 2 profile theo ca nghỉ…") { rotationMode = .restWindows }
                            .buttonStyle(.borderedProminent).disabled(!manager.romCanMutate(device))
                        Button("Đổi profile mỗi 5 phút…") { rotationMode = .fiveMinutes }
                            .disabled(!manager.romCanMutate(device))
                    }
                    Divider()
                    ScrollView { editor.frame(maxWidth: .infinity, alignment: .topLeading) }.frame(height: 370)
                }
            } else {
                Text("Cần engine ROM Profiles API v1 trên điện thoại. App tự nhận diện khi kết nối; không thay ROM hoặc xóa user đang có.")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
            if let error = inputError ?? manager.romErrors[device.id] {
                Text(error).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if manager.romVerified.contains(device.id) {
                Label("Proxy đang dùng và chặn mạng giữa các user đã được kiểm tra", systemImage: "checkmark.shield.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            Divider()
            HStack {
                Text("Đăng nhập Threads một lần trong từng profile. Nhãn tài khoản chỉ để nhận biết, không phải xác nhận đã đăng nhập.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .padding(22).frame(width: 850, height: 730)
        .interactiveDismissDisabled(busy)
        .sheet(item: $rotationMode) { mode in ROMProfileRotationSheet(device: device, manager: manager, fixedMode: mode) }
        .alert("Xoá vĩnh viễn profile?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { profile in
            TextField("Nhập số user \(profile.userID) để xác nhận", text: $deleteUser)
            Button("Xoá vĩnh viễn", role: .destructive) {
                execute(ROMRequest(operation: "profile.delete", userId: profile.userID,
                                   expectedProfileId: profile.id, confirmDeletion: true))
            }.disabled(deleteUser != String(profile.userID))
            Button("Huỷ", role: .cancel) { deleteTarget = nil }
        } message: { profile in
            Text("\(profile.name) · User \(profile.userID)\nAndroid sẽ xoá ứng dụng, dữ liệu và phiên đăng nhập riêng của profile này. Engine phải sao lưu thành công trước khi xoá; bản sao lưu không bảo đảm khôi phục được khoá hoặc phiên đăng nhập. Các profile khác được giữ lại.")
        }
        .task {
            await manager.refreshROMProfiles(device)
            if let active = list?.active { selectedID = active.id; loadSelection(active) }
        }
    }

    @ViewBuilder private var editor: some View {
        if creating || selected != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text(creating ? "Profile mới · tự chuyển sang sau khi tạo" : "\(selected!.name) · User \(selected!.userID)")
                    .font(.headline)
                if creating {
                    TextField("Tên profile (không bắt buộc)", text: $profileName)
                    TextField("Nhãn tài khoản Threads (không bắt buộc)", text: $account)
                    Text("Lấy danh sách app từ profile đang dùng; dữ liệu và tài khoản của profile mới bắt đầu riêng.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let selected, !creating {
                    HStack {
                        TextField("Nhãn tài khoản Threads, ví dụ @ten", text: $account)
                        Button("Lưu nhãn") { manager.saveROMAccountLabel(device, profile: selected, label: account) }
                    }
                    HStack {
                        Button(selected.userID == list?.activeUser ? "Đang dùng" : "Chuyển sang profile này") {
                            execute(ROMRequest(operation: "profile.activate", userId: selected.userID, backupCurrent: true))
                        }.buttonStyle(.borderedProminent).disabled(!canMutate || selected.userID == list?.activeUser || selected.proxy?.enforced != true)
                        Button("Sao lưu") { execute(ROMRequest(operation: "profile.backup", userId: selected.userID)) }.disabled(!canMutate)
                        Button("Xoá…", role: .destructive) { deleteUser = ""; deleteTarget = selected }
                            .disabled(!canMutate || selected.userID == 0 || selected.userID == list?.activeUser || list?.capabilities?.contains("profile.delete") != true)
                    }
                    if selected.userID == 0 {
                        Text("Owner được giữ lại và không thể xoá.").font(.caption).foregroundStyle(.secondary)
                    } else if selected.userID == list?.activeUser {
                        Text("Chuyển sang profile khác trước khi xoá profile này.").font(.caption).foregroundStyle(.secondary)
                    } else if list?.capabilities?.contains("profile.delete") != true {
                        Text("Cần engine 1.5.0 trở lên để xoá profile.").font(.caption).foregroundStyle(.orange)
                    }
                    Text("Proxy đã lưu: \(selected.proxy?.address ?? "chưa có") · \(selected.proxy?.enforced == true ? "ép tuyến trên điện thoại" : "cần gắn proxy ép tuyến")")
                        .font(.caption).foregroundStyle(.secondary)
                    if selected.proxy?.enforced != true {
                        Text("Gắn proxy riêng ở dưới trước khi chuyển sang profile này.").font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                }
                Text(creating ? "Proxy HTTP riêng · bắt buộc" : "Thay proxy của profile đã chọn").fontWeight(.medium)
                SecureField("Dán host:port:username:password", text: $proxyLine).onSubmit { applyProxy() }
                Text("Dán một dòng: host:port:username:password hoặc host:port nếu không cần xác thực. Thông tin lưu theo profile trong vùng root của điện thoại.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Chỉ tạo profile sau khi gọi HTTPS và đọc IP thành công qua proxy. Proxy lỗi hoặc trùng host:cổng với profile khác sẽ dừng trước khi tạo.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(creating ? "Kiểm tra proxy và tạo profile" : "Kiểm tra và lưu proxy") { applyProxy() }
                    .buttonStyle(.borderedProminent).disabled(!canMutate || proxyLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !creating, selected?.userID == list?.activeUser {
                    Button("Đồng bộ app vào engine") { execute(ROMRequest(operation: "apps.sync")) }.disabled(!canMutate)
                }
                Text("Chuyển profile tự sao lưu profile hiện tại. Dữ liệu ứng dụng tách theo user; phần cứng và một số dịch vụ hệ thống vẫn dùng chung.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.textFieldStyle(.roundedBorder).disabled(busy)
        } else { Text("Chọn một profile hoặc tạo profile mới").foregroundStyle(.secondary) }
    }

    private func clearProxy() { proxyLine = "" }
    private func applyProxy() {
        guard canMutate, !busy else { return }
        do {
            let proxy = try ROMProxyConfiguration(line: proxyLine)
            execute(ROMRequest(operation: creating ? "profile.create" : "proxy.set", userId: creating ? nil : selected?.userID,
                               proxy: proxy, name: creating ? profileName : nil))
        } catch { inputError = error.localizedDescription }
    }
    private func loadSelection(_ profile: ROMProfile) {
        clearProxy(); inputError = nil
        account = manager.romAccountLabel(device, profile: profile)
    }
    private func execute(_ request: ROMRequest) {
        inputError = nil
        let newAccountLabel = creating ? account : nil
        clearProxy()
        Task {
            await manager.performROM(device, request: request)
            if manager.romErrors[device.id] == nil, let active = list?.active {
                if let newAccountLabel { manager.saveROMAccountLabel(device, profile: active, label: newAccountLabel) }
                creating = false; selectedID = active.id; loadSelection(active)
            }
        }
    }
}
