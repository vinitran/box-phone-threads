import Foundation
import OSLog

enum ThreadsComment {
    private static let logger = Logger(subsystem: "local.phonefarm.mac", category: "Threads")
    private struct Request: Encodable {
        let id: String
        let action: String
        let reply: String
        let stable: Bool
        let forward: Bool
    }

    private struct Submission: Encodable {
        let action = "submit_reply"
        let target: String
        let author: String
        let reply: String
        let photoCount: Int
        let composer: String
        let deadline: Double?
    }

    private struct AttachmentRequest: Encodable {
        let action: String
        let target: String
        let author: String
        let reply: String
        let composer: String
        let postID: String
        let photos: ThreadsAttachments.Batch
    }

    private struct Response: Decodable {
        let actionStatus: String
        let target: String?
        let author: String?
        let composer: String?
        let postID: String?
        let phase: String?
        let reason: String?
    }

    @MainActor
    static func send(
        adb: URL, serial: String, id: String, text: String,
        stable: Bool = false, forward: Bool = false,
        kind: ThreadsCommentKind = .promotion, deadline: Date? = nil,
        progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void
    ) async throws -> String {
        let keys = try Telex.keys(for: text)
        try ThreadsLoop.checkDeadline(deadline)
        guard kind.allows(text) else { return "invalid_reply" }
        try await ThreadsAttachments.cleanupSubmitted(adb: adb, serial: serial)
        let batch: ThreadsAttachments.Batch?
        if kind.photoCount > 0 {
            let settings = try PhoneFarmStore.shared.get().threadsSettings().validated()
            batch = try await ThreadsAttachments.prepare(adb: adb, serial: serial, images: settings.pickImages(), progress: progress)
        } else { batch = nil }
        do { try ThreadsLoop.checkDeadline(deadline) }
        catch {
            if let batch { _ = await Task.detached { await ThreadsAttachments.remove(batch, adb: adb, serial: serial) }.value }
            throw error
        }
        progress(DeviceProgress(message: "Đang tìm bài để bình luận"))
        let request = Request(id: id, action: "reply",
                              reply: text, stable: stable, forward: forward)
        let prepared = try await perform(request, adb: adb, serial: serial, progress: progress)
        guard prepared.actionStatus == "reply_ready", let target = prepared.target, let author = prepared.author,
              let postID = prepared.postID
        else {
            if let batch { await ThreadsAttachments.remove(batch, adb: adb, serial: serial) }
            return prepared.actionStatus
        }
        if !keys.isEmpty {
            progress(DeviceProgress(message: "Đang đọc vị trí phím Gboard"))
            let typing = TelexTyping(adb: adb, serial: serial)
            let context = try await typing.prepare(for: keys)
            try await typing.typeText(text, context: context, pauseMilliseconds: 140...260, requireEmpty: true) { done, total in
                progress(DeviceProgress(message: "Đang gõ Telex · \(done)/\(total) phím",
                                        completed: done, total: total))
            }
        }
        try ThreadsLoop.checkDeadline(deadline)
        var finalTarget = target
        var composer = prepared.composer ?? "inline"
        if let batch {
            progress(DeviceProgress(message: "Đang đính kèm 3 ảnh · app_store.png ở giữa"))
            try await ThreadsAttachments.verify(batch, adb: adb, serial: serial)
            let opened = try await perform(AttachmentRequest(action: "attach_reply", target: target, author: author, reply: text,
                                                                composer: composer, postID: postID, photos: batch),
                                             adb: adb, serial: serial, progress: progress)
            guard opened.actionStatus == "reply_picker_open" else { return opened.actionStatus }
            try await ThreadsAttachments.verify(batch, adb: adb, serial: serial)
            let attached = try await perform(AttachmentRequest(action: "select_reply_photos", target: target, author: author, reply: text,
                                                               composer: composer, postID: postID, photos: batch),
                                            adb: adb, serial: serial, progress: progress)
            guard attached.actionStatus == "reply_ready", let attachedTarget = attached.target else { return attached.actionStatus }
            finalTarget = attachedTarget
            composer = attached.composer ?? "full"
        }
        try ThreadsLoop.checkDeadline(deadline)
        let result = try await perform(Submission(target: finalTarget, author: author, reply: text,
                                                   photoCount: kind.photoCount, composer: composer, deadline: deadline?.timeIntervalSince1970),
                                       adb: adb, serial: serial, progress: progress)
        if result.actionStatus == "posting_window_ended" { throw ThreadsLoop.WindowEnded() }
        if result.actionStatus == "reply_submitted" {
            do { try PhoneFarmStore.shared.get().recordComment(serial: serial) }
            catch { logger.error("Could not record submitted comment") }
            if let batch {
                do { try PhoneFarmStore.shared.get().queueSubmittedPhotos(batch, serial: serial) }
                catch { logger.error("Could not queue submitted photo cleanup") }
            }
        }
        return result.actionStatus
    }

    private static func perform<Request: Encodable>(
        _ request: Request, adb: URL, serial: String,
        progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void
    ) async throws -> Response {
        let output = try await AndroidAccessibility.read(
            adb: adb, serial: serial, entry: .threadsAction, timeout: 120,
            payload: JSONEncoder().encode(request)
        ) { update in await progress(update.deviceProgress) }
        guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last,
              let response = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)) else {
            let action = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])?["action"] as? String
            throw DiagnosticLog.adbFailure("thao tác Threads \(action ?? "")", serial: serial, result: output, timeout: 120)
        }
        if response.actionStatus == "target_changed" {
            logger.error("Reply verification failed at \(response.phase ?? "unknown", privacy: .public): \(response.reason ?? "unknown", privacy: .public)")
        }
        return response
    }
}
