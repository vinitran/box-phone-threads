import SwiftUI

struct ThreadsFeedSheet: View {
    let device: AndroidDevice
    var profileOnly = false
    var onActivity: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var json = ""
    @State private var status = ""
    @State private var isWorking = false
    @State private var posts: [Post] = []
    @State private var selectedID: String?
    @State private var reply = ""
    @State private var apiKey = ""
    @State private var showJSON = false
    @State private var showProfile = false
    @State private var bio = ""
    @State private var avatarFolder = AvatarImages.defaultFolder
    @State private var avatarImage: URL?
    @State private var avatarCount = 0

    private struct Post: Decodable, Identifiable {
        let id: String
        let author: String
        let text: String?
    }

    private struct Result: Decodable {
        let requested: Int?
        let count: Int?
        let scrolled: Bool?
        let stopReason: String?
        let posts: [Post]?
        let actionStatus: String?
    }

    private struct Action: Encodable {
        let id: String
        let action: String
        let reply: String?
    }

    private struct ProfileAction: Encodable {
        let action: String
        let bio: String?
        var photoID: Int? = nil
    }

    private var selected: Post? { posts.first { $0.id == selectedID } }
    private var trimmedReply: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(profileOnly ? "Ảnh đại diện & Bio" : "Threads") · \(device.name)").font(.title2.weight(.semibold))
            Text(profileOnly ? "Nhập bio mới để cập nhật. Chọn ảnh đại diện ngẫu nhiên từ thư mục trên máy tính, xem trước rồi mở ảnh trong Threads để căn chỉnh và lưu." : "Mở tab Trang chủ trên điện thoại. Phone Farm có thể lướt xuống hoặc đọc ngẫu nhiên từ 5 đến 10 bài trong feed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !profileOnly { HStack {
                Button("Lướt xuống") { Task { await run(scrollOnly: true) } }
                Button("Đọc 5–10 bài") { Task { await run(scrollOnly: false) } }
                    .buttonStyle(.borderedProminent)
                Button("Hồ sơ") { showProfile.toggle() }
            }
            .disabled(isWorking)
            }

            if showProfile || profileOnly {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Bio mới", text: $bio)
                        Button("AI tạo bio") { Task { await generateBio() } }
                        Button("Cập nhật bio") { Task { await updateProfile("bio") } }
                            .disabled(bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bio.unicodeScalars.count > 150)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if let avatarImage, let image = NSImage(contentsOf: avatarImage) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 82, height: 82).clipShape(Circle())
                                .accessibilityLabel("Ảnh đại diện đã chọn: \(avatarImage.lastPathComponent)")
                        } else {
                            Image(systemName: "person.crop.circle").font(.system(size: 62))
                                .frame(width: 82, height: 82).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Ảnh đại diện · \(avatarCount) ảnh").font(.headline)
                            Text(avatarFolder.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).textSelection(.enabled)
                            if let avatarImage { Text(avatarImage.lastPathComponent).font(.caption).lineLimit(1) }
                            HStack {
                                Button("Chọn thư mục…", action: chooseAvatarFolder)
                                Button("Chọn ngẫu nhiên", action: chooseRandomAvatar)
                                    .disabled(avatarCount == 0)
                                Button("Đổi ảnh đại diện") { Task { await updateProfile("avatar") } }
                                    .disabled(avatarImage == nil)
                            }
                        }
                    }
                }
                .disabled(isWorking)
            }

            if isWorking {
                ProgressView().controlSize(.small)
            }
            if !status.isEmpty { Text(status).font(.callout) }
            if !posts.isEmpty { postActions }
            if showJSON && !json.isEmpty {
                ScrollView {
                    Text(verbatim: json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 200)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if !json.isEmpty {
                    Button(showJSON ? "Ẩn JSON" : "Xem JSON") { showJSON.toggle() }
                    Button("Sao chép JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                    }
                }
                Spacer()
                Button("Đóng") { dismiss() }
                    .disabled(isWorking)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .interactiveDismissDisabled(isWorking)
        .task { loadAvatarImages() }
        .onChange(of: selectedID) { _ in reply = "" }
        .onChange(of: status) { value in
            if !value.isEmpty { onActivity(value) }
        }
    }

    private func loadAvatarImages() {
        avatarFolder = AvatarImages.folder()
        avatarCount = AvatarImages.images(in: avatarFolder).count
        do { avatarImage = try AvatarImages.randomImage(excluding: avatarImage) }
        catch { avatarImage = nil }
    }

    private func chooseRandomAvatar() {
        do {
            avatarCount = AvatarImages.images(in: avatarFolder).count
            let image = try AvatarImages.randomImage(excluding: avatarImage)
            avatarImage = image
            status = "Đã chọn \(image.lastPathComponent). Bấm Đổi ảnh đại diện để dùng ảnh này."
        } catch {
            avatarImage = nil
            status = error.localizedDescription
        }
    }

    private func chooseAvatarFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = avatarFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try AvatarImages.setFolder(folder)
            avatarFolder = folder
            chooseRandomAvatar()
        } catch { status = error.localizedDescription }
    }

    private var postActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Bài viết", selection: $selectedID) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                    Text("\(index + 1). @\(post.author) · \(String((post.text ?? "Ảnh hoặc video").prefix(55)))")
                        .tag(Optional(post.id))
                }
            }
            if let selected {
                Text(selected.text ?? "Bài có ảnh hoặc video.")
                    .font(.callout).lineLimit(4).textSelection(.enabled)
                HStack {
                    SecureField("API key ai.hoanxu.com", text: $apiKey)
                    Button("Gợi ý trả lời") { Task { await suggest(for: selected) } }
                        .disabled(selected.text?.isEmpty != false)
                }
                TextEditor(text: $reply)
                    .accessibilityLabel("Bình luận")
                    .frame(height: 65)
                    .border(.quaternary)
                HStack {
                    Button("Thả tim") { Task { await act("like", post: selected) } }
                    Button("Đăng lại") { Task { await act("repost", post: selected) } }
                    Spacer()
                    Button("Gửi bình luận kèm 3 ảnh") { Task { await act("reply", post: selected, text: trimmedReply) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedReply.isEmpty || trimmedReply.unicodeScalars.count > 500)
                }
            }
        }
        .disabled(isWorking)
    }

    private func suggest(for post: Post) async {
        guard !isWorking, let text = post.text else { return }
        guard let key = trimmedKey.isEmpty ? ThreadsKey.load() : trimmedKey else {
            status = "Chưa có khóa AI."
            return
        }
        isWorking = true
        status = "Đang soạn bản nháp…"
        defer { isWorking = false }
        do {
            reply = try await ThreadsReplyAI.suggest(for: text, key: key, settings: PhoneFarmStore.shared.get().threadsSettings()) { message in
                await MainActor.run { status = message }
            }
            status = "Bạn có thể sửa bản nháp trước khi gửi."
        } catch {
            status = error.localizedDescription
        }
    }

    private func act(_ action: String, post: Post, text: String? = nil) async {
        guard !isWorking, let adb = ToolPaths.adb() else { return }
        isWorking = true
        status = "Đang tìm lại bài của @\(post.author)…"
        defer { isWorking = false }
        do {
            let actionStatus: String?
            if action == "reply" || action == "photo_reply" {
                actionStatus = try await ThreadsComment.send(
                    adb: adb, serial: device.serial, id: post.id, text: text ?? ""
                ) { update in status = update.message }
            } else {
                let payload = try JSONEncoder().encode(Action(id: post.id, action: action, reply: text))
                let output = try await AndroidAccessibility.read(adb: adb, serial: device.serial, entry: .threadsAction,
                                                                 timeout: 45, payload: payload)
                guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last else {
                    status = "Android chưa xác nhận thao tác. Hãy kiểm tra trên điện thoại trước khi thử lại."
                    return
                }
                let result = try JSONDecoder().decode(Result.self, from: Data(line.utf8))
                actionStatus = result.actionStatus
            }
            switch actionStatus {
            case "liked": status = "Đã thả tim."
            case "already_liked": status = "Bài này đã được thả tim."
            case "already_reposted": status = "Bài này đã được đăng lại."
            case "repost_requested": status = "Đã bấm Đăng lại trên Threads."
            case "reply_submitted":
                status = "Đã bấm Đăng kèm 3 ảnh."
                reply = ""
                let output = try await AndroidAccessibility.read(adb: adb, serial: device.serial, entry: .threadsHomeAfterPost,
                                                                 timeout: 45) { update in
                    await MainActor.run { status = update.deviceProgress.message }
                }
                let line = output.output.split(whereSeparator: \.isNewline).last
                let home = line.flatMap { try? JSONDecoder().decode(Result.self, from: Data($0.utf8)) }
                status = home?.actionStatus == "home_ready" ? "Đã bấm Đăng và về Trang chủ." : "Đã bấm Đăng · chưa về được Trang chủ."
            case "draft_exists": status = "Threads đang có bản nháp. Hãy kiểm tra bản nháp trên điện thoại."
            case "reply_picker_open": status = "Chọn ảnh trên điện thoại rồi bấm Đăng trong Threads."
            case "permission_required": status = "Hãy cấp quyền ảnh cho Threads trên điện thoại để tiếp tục."
            case "photos_failed", "photos_changed": status = "Chưa xác nhận đủ ba ảnh đúng thứ tự. Bình luận chưa được đăng."
            case "repost_menu_unavailable": status = "Không thấy lựa chọn Đăng lại trong Threads."
            case "draft_failed": status = "Chưa gửi được. Hãy kiểm tra bản nháp trên điện thoại."
            case "feed_unavailable": status = "Hãy mở lại tab Trang chủ trong Threads."
            case "composer_unavailable": status = "Đã thấy bài nhưng chưa mở được ô bình luận."
            case "not_found", "ambiguous", "target_changed":
                status = "Không xác định được đúng bài. Hãy đọc lại feed rồi chọn bài."
            default: status = "Android chưa xác nhận thao tác. Hãy kiểm tra trên điện thoại."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func updateProfile(_ action: String) async {
        guard !isWorking, let adb = ToolPaths.adb() else { return }
        isWorking = true
        status = "Đang mở trình chỉnh sửa hồ sơ Threads…"
        defer { isWorking = false }
        do {
            var request = ProfileAction(action: action, bio: action == "bio" ? bio : nil)
            if action == "avatar" {
                guard let avatarImage else {
                    status = "Chọn một ảnh đại diện trước khi tiếp tục."
                    return
                }
                status = "Đang chuyển ảnh \(avatarImage.lastPathComponent) sang điện thoại…"
                request.photoID = try await ThreadsAttachments.prepareAvatar(adb: adb, serial: device.serial, image: avatarImage)
                status = "Đang mở ảnh đại diện đã chọn trong Threads…"
            }
            let payload = try JSONEncoder().encode(request)
            let output = try await AndroidAccessibility.read(adb: adb, serial: device.serial, entry: .threadsProfile,
                                                             timeout: 75, payload: payload)
            guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last else {
                status = "Threads chưa xác nhận cập nhật hồ sơ."
                return
            }
            var result = try JSONDecoder().decode(Result.self, from: Data(line.utf8))
            if action == "avatar", result.actionStatus == "avatar_picker_open", let photoID = request.photoID {
                try await ThreadsAttachments.verifyAvatar(id: photoID, adb: adb, serial: device.serial)
                let selected = try await AndroidAccessibility.read(adb: adb, serial: device.serial, entry: .threadsProfile,
                    timeout: 10, payload: JSONEncoder().encode(ProfileAction(action: "select_avatar", bio: nil, photoID: photoID)))
                guard selected.status == 0, let selectedLine = selected.output.split(whereSeparator: \.isNewline).last else {
                    status = "Threads chưa xác nhận ảnh đại diện. Hãy kiểm tra ảnh trên điện thoại."
                    return
                }
                result = try JSONDecoder().decode(Result.self, from: Data(selectedLine.utf8))
            }
            switch result.actionStatus {
            case "bio_saved": status = "Bio mới đã xuất hiện trên hồ sơ."
            case "bio_unverified": status = "Đã bấm lưu. Hãy kiểm tra bio trên hồ sơ."
            case "avatar_picker_open": status = "Chọn ảnh trên điện thoại, sau đó lưu hồ sơ trong Threads."
            case "avatar_ready": status = "Đã mở ảnh \(avatarImage?.lastPathComponent ?? "đã chọn"). Căn chỉnh, bấm Done/Xong và lưu hồ sơ trên điện thoại."
            case "photos_changed", "avatar_unavailable": status = "Chưa xác nhận được ảnh đại diện đã chọn. Hãy đóng thư viện trên điện thoại rồi thử lại."
            case "permission_required": status = "Hãy cấp quyền ảnh cho Threads trên điện thoại để tiếp tục."
            default: status = "Chưa cập nhật được. Hãy mở hồ sơ của bạn trong Threads rồi thử lại."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func generateBio() async {
        guard !isWorking else { return }
        guard let key = ThreadsKey.load() else { status = "Chưa mở khóa AI."; return }
        isWorking = true
        defer { isWorking = false }
        do {
            status = "AI đang tạo bio…"
            bio = try await ThreadsReplyAI.suggestBio(key: key) { message in
                await MainActor.run { status = message }
            }
            status = "AI đã tạo bio. Bấm Cập nhật bio để lưu vào Threads."
        } catch { status = error.localizedDescription }
    }

    private func run(scrollOnly: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        status = scrollOnly ? "Đang lướt…" : "Đang lướt và đọc bài…"
        defer { isWorking = false }
        do {
            guard let adb = ToolPaths.adb() else {
                status = "Không tìm thấy ADB."
                return
            }
            let output = try await AndroidAccessibility.read(
                adb: adb, serial: device.serial, entry: scrollOnly ? .threadsScroll : .threads,
                timeout: scrollOnly ? 8 : 45
            ) { update in await MainActor.run { status = update.deviceProgress.message } }
            guard output.status == 0,
                  let line = output.output.split(whereSeparator: \.isNewline).last,
                  let data = line.data(using: .utf8) else {
                status = "Android không trả về dữ liệu Threads. Hãy mở lại tab Trang chủ rồi thử lại."
                return
            }
            let result = try JSONDecoder().decode(Result.self, from: data)
            if !scrollOnly {
                posts = result.posts ?? []
                selectedID = posts.first?.id
                reply = ""
                let object = try JSONSerialization.jsonObject(with: data)
                let pretty = try JSONSerialization.data(withJSONObject: object,
                                                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                json = String(decoding: pretty, as: UTF8.self)
            }
            if result.stopReason == "feed_unavailable" && (result.count ?? 0) == 0 {
                status = "Chưa thấy feed. Hãy mở tab Trang chủ trong Threads rồi thử lại."
            } else if let count = result.count {
                status = "Đã đọc \(count)/\(result.requested ?? 10) bài."
            } else {
                status = result.scrolled == true ? "Đã lướt xuống." : "Không lướt được feed."
            }
        } catch {
            status = "Không đọc được dữ liệu Threads. Hãy thử lại."
        }
    }

}
