import SwiftUI
import UniformTypeIdentifiers

struct ThreadsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ThreadsSettings(topics: "", replyPrompt: "", imageFolder: "")
    @State private var images: [URL] = []
    @State private var status = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cấu hình Threads").font(.title2.weight(.semibold))
            Text("Dùng chung cho các điện thoại. Thay đổi được áp dụng từ lượt Threads tiếp theo.")
                .foregroundStyle(.secondary)
            Picker("Chế độ chạy", selection: Binding(get: { settings.runEnvironment }, set: { settings.environment = $0 })) {
                ForEach(ThreadsSettings.Environment.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            Text("Mỗi khung 3 giờ: 5 comment giới thiệu, sau mỗi lần là ngẫu nhiên 1–2 comment thông thường không ảnh. Giờ gửi được xếp ngẫu nhiên; hết khung nghỉ 4 giờ. Dev và Production dùng cùng lịch và cùng prompt cố định.")
                .font(.caption).foregroundStyle(.secondary)
            TabView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chủ đề AI ưu tiên").font(.headline)
                    Text("Ngăn cách bằng dấu phẩy hoặc xuống dòng. Lượt giới thiệu ưu tiên các chủ đề này; lượt thông thường trao đổi theo nội dung bài, không quảng bá.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $settings.topics).accessibilityLabel("Chủ đề AI ưu tiên")
                        .padding(6).border(.secondary.opacity(0.3))
                    Button("Dùng danh sách mặc định") { settings.topics = ThreadsSettings.defaultTopics }
                }.padding(16).tabItem { Text("Chủ đề") }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Prompt giới thiệu cố định").font(.headline)
                        Spacer()
                        Button("Nhập file TXT…", action: importPrompt)
                    }
                    Text("Dev và Production luôn dùng prompt dưới đây cho comment giới thiệu. Comment thông thường dùng prompt riêng không quảng bá.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $settings.replyPrompt).accessibilityLabel("Prompt giới thiệu cố định")
                        .padding(6).border(.secondary.opacity(0.3))
                    Text("\(settings.replyPrompt.count) ký tự · lưu prompt cố định vào SQLite")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Bình luận không dùng emoji hoặc icon, không có dấu chấm ở cuối. Số được viết bằng chữ để gõ Telex.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).tabItem { Text("Prompt") }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Ảnh kèm mọi bình luận").font(.headline)
                        Spacer()
                        Button("Chọn thư mục…", action: chooseFolder)
                    }
                    Text(settings.imageFolder).font(.caption).textSelection(.enabled)
                        .foregroundStyle(.secondary).lineLimit(3)
                    Text("Hai ảnh khác nhau được chọn ngẫu nhiên. app_store.png luôn là ảnh thứ 2. Chỉ đăng khi đủ ba ảnh.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Chỉ comment giới thiệu chuyển mới ba ảnh với chấm pixel ngẫu nhiên; comment thông thường không kèm ảnh. Dọn bộ ảnh sau 20 phút kể từ lúc bấm Đăng; giữ ảnh của bản nháp chưa gửi.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, file in
                            VStack(spacing: 8) {
                                if let image = NSImage(contentsOf: file) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 190, height: 270)
                                }
                                Text(index == 1 ? "2 · app_store.png · cố định" : "\(index + 1) · ngẫu nhiên")
                                    .font(.caption).foregroundStyle(index == 1 ? Color.accentColor : .secondary)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(16).tabItem { Text("3 ảnh") }
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu cấu hình") {
                    do {
                        try PhoneFarmStore.shared.get().saveThreadsSettings(settings)
                        dismiss()
                    } catch { status = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!loaded)
            }
        }
        .padding(20).frame(width: 740, height: 620)
        .task {
            do {
                settings = try PhoneFarmStore.shared.get().threadsSettings()
                images = try settings.pickImages()
                loaded = true
            } catch { status = error.localizedDescription }
        }
    }

    private func importPrompt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { settings.replyPrompt = try String(contentsOf: file, encoding: .utf8); status = "" }
        catch { status = error.localizedDescription }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            var candidate = settings
            candidate.imageFolder = folder.path
            let preview = try candidate.pickImages()
            settings = candidate
            images = preview
            status = ""
        } catch { status = error.localizedDescription }
    }
}
