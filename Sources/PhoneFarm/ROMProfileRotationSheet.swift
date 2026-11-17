import SwiftUI

struct ROMProfileRotationSheet: View {
    let device: AndroidDevice
    @ObservedObject var manager: DeviceManager
    let fixedMode: ROMProfileRotation.Mode?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var mode: ROMProfileRotation.Mode

    init(device: AndroidDevice, manager: DeviceManager, fixedMode: ROMProfileRotation.Mode? = nil) {
        self.device = device
        self.manager = manager
        self.fixedMode = fixedMode
        _mode = State(initialValue: fixedMode ?? .restWindows)
    }

    private var profiles: [ROMProfile] { manager.romProfiles[device.id]?.profiles ?? [] }
    private var validSelection: Bool {
        (mode != .restWindows || selected.count == 2)
            && (try? ROMProfileRotation.ordered(profiles.filter { selected.contains($0.id) }, startingAt: nil)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fixedMode == .restWindows ? "Chạy 2 profile theo ca nghỉ" : fixedMode == .fiveMinutes ? "Đổi profile mỗi 5 phút" : "Tự động đổi profile")
                .font(.title2.weight(.semibold))
            if fixedMode == nil {
                Picker("Kịch bản", selection: $mode) {
                    ForEach(ROMProfileRotation.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
            }
            Text("Dùng cùng logic Chạy Threads: lịch 5 lượt giới thiệu trong 3 giờ, xen kẽ 1–2 reply thông thường rồi nghỉ 4 giờ. Mỗi profile chỉ thực hiện lượt khi đang hoạt động; lịch được giữ khi chuyển qua lại.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(mode == .restWindows
                 ? "A chạy khung 3 giờ rồi nghỉ 4 giờ; B dùng thời gian A nghỉ để chạy khung 3 giờ riêng. Không đổi ở các khoảng chờ ngắn giữa comment. Nếu cả hai còn nghỉ thì giữ nguyên máy; đo thời gian chuyển để chuẩn bị sớm cho ca tiếp theo."
                 : "Hết 5 phút sẽ ngắt lượt đang chạy, đóng Threads rồi chuyển sang profile tiếp theo và lặp lại. Thời gian sao lưu/chuyển profile không tính vào 5 phút chạy.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profiles) { (profile: ROMProfile) in
                        Toggle(isOn: Binding(get: { selected.contains(profile.id) }, set: { enabled in
                            if enabled { selected.insert(profile.id) } else { selected.remove(profile.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(profile.name) · User \(profile.userID)").fontWeight(.medium)
                                Text(profile.canRotate ? profile.proxy?.address ?? "" : profile.isDeleting ? "Đang xoá" : "Cần profile riêng với proxy ép tuyến")
                                    .font(.caption).foregroundStyle(profile.canRotate ? Color.secondary : Color.orange)
                            }
                        }.disabled(!profile.canRotate)
                    }
                }.padding(4)
            }.frame(minHeight: 150, maxHeight: 270)
            Text((mode == .restWindows ? "Chọn đúng 2 profile. " : "Chọn ít nhất 2 profile. ") + "Cài Gboard/Threads/Instagram và đăng nhập tài khoản riêng trước. Mỗi profile cần proxy riêng, kể cả Owner. Nếu profile chưa sẵn sàng hoặc proxy lỗi, luồng dừng và báo profile cần kiểm tra.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode == .restWindows ? "Chạy 2 profile theo ca nghỉ" : "Chạy luân phiên \(selected.count) profile") {
                    manager.runRotatingThreads(device, profileIDs: selected, mode: mode)
                    if manager.runningThreads.contains(device.id) { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(!validSelection || !manager.romCanMutate(device) || manager.romNeedsReconcile.contains(device.id))
            }
        }.padding(22).frame(width: 590)
        .task {
            await manager.refreshROMProfiles(device)
            let eligible = profiles.filter(\.canRotate)
            let ordered = (try? ROMProfileRotation.ordered(eligible, startingAt: manager.romProfiles[device.id]?.active?.id)) ?? eligible
            selected = Set((mode == .restWindows ? Array(ordered.prefix(2)) : ordered).map(\.id))
        }
    }
}
