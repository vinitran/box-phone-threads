import SwiftUI
import UniformTypeIdentifiers

struct ThreadsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ThreadsSettings(topics: "", replyPrompt: "", imageFolder: "")
    @State private var images: [URL] = []
    @State private var status = ""
    @State private var loaded = false
    @State private var selectedPrompt = 0

    private var promptText: Binding<String> {
        Binding(get: {
            if settings.runEnvironment == .dev { return settings.replyPrompt }
            if let bank = settings.replyPrompts, bank.indices.contains(selectedPrompt) { return bank[selectedPrompt].text }
            return settings.replyPrompt
        }, set: { value in
            if settings.runEnvironment == .dev { settings.replyPrompt = value; return }
            if let bank = settings.replyPrompts, bank.indices.contains(selectedPrompt) { settings.replyPrompts?[selectedPrompt].text = value }
            else { settings.replyPrompt = value }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cấu hình Threads").font(.title2.weight(.semibold))
            Text("Dùng chung cho các điện thoại. Thay đổi được áp dụng từ lượt Threads tiếp theo.")
                .foregroundStyle(.secondary)
            Picker("Chế độ chạy", selection: Binding(get: { settings.runEnvironment }, set: { settings.environment = $0 })) {
                ForEach(ThreadsSettings.Environment.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            Text("\(settings.runEnvironment.title): giữ Threads mở 1 phút sau Đăng, tắt hẳn rồi nghỉ \(settings.runEnvironment.restLabel). Chế độ áp dụng khi bắt đầu phiên mới.")
                .font(.caption).foregroundStyle(.secondary)
            TabView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chủ đề AI ưu tiên").font(.headline)
                    Text("Ngăn cách bằng dấu phẩy hoặc xuống dòng. AI luôn chọn một bài gần các chủ đề này nhất và một bài khác để thả tim.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $settings.topics).accessibilityLabel("Chủ đề AI ưu tiên")
                        .padding(6).border(.secondary.opacity(0.3))
                    Button("Dùng danh sách mặc định") { settings.topics = ThreadsSettings.defaultTopics }
                }.padding(16).tabItem { Text("Chủ đề") }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Prompt trả lời bài viết").font(.headline)
                        Spacer()
                        Button("Nhập file TXT…", action: importPrompt)
                        Button("Nhập 10 prompt…", action: importPromptBank)
                    }
                    if settings.runEnvironment == .dev {
                        Text("Dev luôn dùng prompt mặc định. Có thể xem hoặc sửa nội dung ở dưới.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let bank = settings.replyPrompts {
                        Picker("Xem / sửa prompt", selection: $selectedPrompt) {
                            ForEach(Array(bank.enumerated()), id: \.element.id) { index, prompt in Text(prompt.name).tag(index) }
                        }
                        Text("Mỗi lần soạn bình luận, AI dùng ngẫu nhiên một trong \(bank.count) prompt. Chọn ở đây để xem hoặc sửa.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextEditor(text: promptText).accessibilityLabel("Prompt trả lời bài viết")
                        .padding(6).border(.secondary.opacity(0.3))
                    Text("\(promptText.wrappedValue.count) ký tự · lưu toàn bộ bộ prompt vào SQLite")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Bình luận không dùng emoji hoặc icon. Số được viết bằng chữ để gõ Telex.")
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
                    Text("Ảnh đã nhập được giữ trên điện thoại để dùng lại. Chỉ chuyển thêm ảnh mới, ảnh thay đổi hoặc ảnh bị xóa.")
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
        do { promptText.wrappedValue = try String(contentsOf: file, encoding: .utf8); status = "" }
        catch { status = error.localizedDescription }
    }

    private func importPromptBank() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            guard panel.urls.count == 10 else { throw ThreadsSettings.SettingsError("Chọn đủ 10 file TXT.") }
            settings.replyPrompts = try panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                .init(id: UUID().uuidString, name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8))
            }
            selectedPrompt = 0
            status = ""
        } catch { status = error.localizedDescription }
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
