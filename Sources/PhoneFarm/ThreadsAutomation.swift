import Foundation
import OSLog

enum ThreadsAutomation {
    private static let logger = Logger(subsystem: "local.phonefarm.mac", category: "Threads")
    private struct Post: Decodable {
        let stableID: String
        let text: String?
        let engagement: [String: String]
    }

    private struct Feed: Decodable {
        let requested: Int
        let posts: [Post]
        let stopReason: String
    }

    private struct Action: Encodable {
        let id: String
        let action: String
        let reply: String?
        let stable = true
        let forward: Bool
    }

    private struct ActionResult: Decodable {
        let actionStatus: String
    }

    private struct ScrollResult: Decodable { let scrolled: Bool }

    struct Result {
        let message: String
        let hasIssue: Bool
        var submitted = false
        var feedReady = false
    }

    private struct Interactions {
        var likes = 0
        var replies = 0
        var warning: String?
        var needsNewPosts = false
    }

    @MainActor
    static func run(adb: URL, serial: String, key: String,
                    prepareFeed: Bool = true,
                    progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void) async throws -> Result {
        let settings = try PhoneFarmStore.shared.get().threadsSettings().validated()
        if prepareFeed {
            progress(DeviceProgress(message: "Đang bấm Trang chủ và chờ feed"))
            let refresh: ActionResult = try await read(adb: adb, serial: serial, entry: .threadsRefresh, progress: progress)
            guard refresh.actionStatus == "home_ready" else {
                let message = refresh.actionStatus == "draft_exists"
                    ? "Threads đang có bình luận chưa gửi. Hãy xử lý bản nháp trên điện thoại."
                    : "Feed chưa tải xong sau khi làm mới. Hãy thử lại."
                return Result(message: message, hasIssue: true)
            }
        }
        progress(DeviceProgress(message: "Feed đã sẵn sàng · đang chọn ngẫu nhiên 5–10 bài để đọc"))
        var feed: Feed = try await read(adb: adb, serial: serial, entry: .threadsAutoFeed, progress: progress)
        logger.info("Feed returned \(feed.posts.count) posts, status \(feed.stopReason, privacy: .public)")
        if feed.stopReason == "feed_unavailable" {
            return Result(message: "Không mở được Trang chủ Threads.", hasIssue: true)
        }
        if feed.stopReason == "draft_exists" {
            return Result(message: "Threads đang có bình luận chưa gửi. Hãy xử lý bản nháp trên điện thoại.", hasIssue: true)
        }
        var interactions = try await interact(with: feed, adb: adb, serial: serial, key: key, settings: settings, progress: progress)
        for _ in 0..<3 where interactions.needsNewPosts {
            progress(DeviceProgress(message: "Các bài này đã được xử lý · đang lướt tìm bài mới"))
            let scroll: ScrollResult = try await read(adb: adb, serial: serial, entry: .threadsScroll, progress: progress)
            guard scroll.scrolled else { break }
            feed = try await read(adb: adb, serial: serial, entry: .threadsAutoFeed, progress: progress)
            interactions = try await interact(with: feed, adb: adb, serial: serial, key: key, settings: settings, progress: progress)
        }
        let scanWarning = feed.posts.count < feed.requested ? "Feed dừng trước số bài đã chọn." : nil
        let summary = "Đã đọc \(feed.posts.count)/\(feed.requested) bài · \(interactions.likes) lượt thích · Đã bấm Đăng \(interactions.replies) lần"
        let warning = interactions.warning ?? scanWarning
        var result = Result(message: summary + (warning.map { " · " + $0 } ?? ""), hasIssue: warning != nil,
                            submitted: interactions.replies > 0)
        if result.submitted {
            progress(DeviceProgress(message: "Đã bấm Đăng · đang về Trang chủ và làm mới"))
            do {
                let home: ActionResult = try await read(adb: adb, serial: serial, entry: .threadsHomeAfterPost, progress: progress)
                result.feedReady = home.actionStatus == "home_ready"
                if !result.feedReady {
                    result = Result(message: summary + " · Chưa về được Trang chủ sau khi bấm Đăng.", hasIssue: true, submitted: true)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result = Result(message: summary + " · " + error.localizedDescription, hasIssue: true, submitted: true)
            }
        }
        return result
    }

    @MainActor
    private static func interact(with feed: Feed, adb: URL, serial: String, key: String,
                                 settings: ThreadsSettings,
                                 progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void) async throws -> Interactions {
        var interactions = Interactions()
        let storage = try PhoneFarmStore.shared.get()
        let attempted = try storage.attemptedReplies(serial: serial)
        let counts = Dictionary(grouping: feed.posts, by: \.stableID)
        let candidates = feed.posts.enumerated().compactMap { index, post -> ThreadsReplyAI.Candidate? in
            guard counts[post.stableID]?.count == 1, let text = post.text, !text.isEmpty else { return nil }
            let label = post.engagement["like"]?.lowercased() ?? ""
            let canLike = label.hasPrefix("like") || label.hasPrefix("thích")
            let canReply = post.engagement["reply"] != nil && !attempted.contains(post.stableID)
            guard canLike || canReply else { return nil }
            return .init(index: index + 1, text: text, canLike: canLike, canReply: canReply)
        }
        guard candidates.contains(where: \.canReply) else {
            interactions.warning = "Chưa có bài mới đủ nội dung để bình luận."
            interactions.needsNewPosts = true
            return interactions
        }
        progress(DeviceProgress(message: "AI đang chọn theo chủ đề đã lưu và soạn bình luận"))
        let decision = try await ThreadsReplyAI.choose(from: candidates, key: key, settings: settings) { message in
            await progress(DeviceProgress(message: message))
        }
        try Task.checkCancellation()
        let allowed = Dictionary(uniqueKeysWithValues: candidates.map { ($0.index, $0) })
        let reply = decision.reply
        guard allowed[reply.index]?.canReply == true else {
            interactions.warning = "AI chưa trả về đúng bài để bình luận."
            return interactions
        }
        let likes = [decision.like].compactMap { $0 }.filter {
            $0 != reply.index && allowed[$0]?.canLike == true
        }
        logger.info("Selected \(likes.count) likes, reply selected: true")
        var position = feed.posts.count
        for index in likes {
            progress(DeviceProgress(message: "Đang tìm bài \(index)/\(feed.posts.count) để thả tim"))
            let action = Action(id: feed.posts[index - 1].stableID, action: "like", reply: nil, forward: index > position)
            let status = try await perform(action, adb: adb, serial: serial, progress: progress)
            logger.info("Like result: \(status, privacy: .public)")
            if status == "liked" || status == "already_liked" {
                position = index
                if status == "liked" { interactions.likes += 1 }
            } else {
                interactions.warning = "Threads chưa xác nhận lượt thích."
            }
        }
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 500,
              text.range(of: #"(?i)https?://|www\.|@"#, options: .regularExpression) == nil else {
            interactions.warning = "Nội dung AI trả về chưa hợp lệ để đăng."
            return interactions
        }
        _ = try Telex.keys(for: text)
        let id = feed.posts[reply.index - 1].stableID
        progress(DeviceProgress(message: "Đã chọn bài \(reply.index)/\(feed.posts.count) gần chủ đề đã lưu nhất để bình luận"))
        try Task.checkCancellation()
        // Reserve before sending so an interrupted ADB call cannot cause a duplicate.
        guard try storage.reserveReply(serial: serial, postID: id) else {
            interactions.warning = "Bài này đã có lượt bình luận được ghi nhận."
            return interactions
        }
        let status = try await ThreadsComment.send(adb: adb, serial: serial, id: id, text: text,
                                                   stable: true, forward: reply.index > position, progress: progress)
        logger.info("Reply result: \(status, privacy: .public)")
        switch status {
        case "reply_submitted":
            interactions.replies += 1
        case "draft_exists":
            interactions.warning = "Bài đã chọn đang có bình luận chưa gửi."
        case "draft_failed":
            interactions.warning = "Chưa đăng được. Kiểm tra nội dung trong ô bình luận trên điện thoại."
        case "not_found":
            interactions.warning = "Chưa tìm lại được bài đã chọn trong feed."
        case "ambiguous", "target_changed":
            interactions.warning = "Đã thấy bài nhưng chưa xác minh được tác giả và nội dung ở màn hình trả lời."
        case "composer_unavailable", "control_unavailable":
            interactions.warning = "Đã thấy bài nhưng chưa mở được ô bình luận."
        case "feed_unavailable":
            interactions.warning = "Chưa trở về được feed để tìm bài bình luận."
        case "invalid_reply":
            interactions.warning = "Nội dung bình luận không hợp lệ."
        case "photos_failed", "photos_changed":
            interactions.warning = "Chưa xác nhận đủ ba ảnh đúng thứ tự. Bình luận chưa được đăng."
        case "permission_required":
            interactions.warning = "Threads cần quyền truy cập ảnh trên điện thoại. Bình luận chưa được đăng."
        case "gallery_unavailable":
            interactions.warning = "Chưa mở được thư viện ảnh. Nội dung còn trong bản nháp, chưa đăng bình luận."
        default:
            interactions.warning = "Threads chưa xác nhận bình luận."
        }
        let unsent = ["draft_exists", "not_found", "ambiguous", "target_changed",
                      "control_unavailable", "composer_unavailable", "feed_unavailable", "invalid_reply"]
        if unsent.contains(status) {
            try storage.releaseReply(serial: serial, postID: id)
        }
        return interactions
    }

    private static func perform(_ action: Action, adb: URL, serial: String,
                                progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void) async throws -> String {
        let result: ActionResult = try await read(adb: adb, serial: serial, entry: .threadsAction,
                                                 payload: JSONEncoder().encode(action), progress: progress)
        return result.actionStatus
    }

    private static func read<Result: Decodable>(
        adb: URL, serial: String, entry: AndroidAccessibility.Entry, payload: Data? = nil,
        progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void
    ) async throws -> Result {
        try Task.checkCancellation()
        let timeout: Int
        switch entry {
        case .threadsRefresh, .threadsHomeAfterPost: timeout = 45
        case .threadsAutoFeed: timeout = 180
        case .threadsAction: timeout = 120
        default: timeout = 20
        }
        let output = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: entry,
                                                         timeout: timeout, payload: payload) { update in
            await progress(update.deviceProgress)
        }
        guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last else {
            throw CocoaError(.fileReadUnknown)
        }
        return try JSONDecoder().decode(Result.self, from: Data(line.utf8))
    }
}
