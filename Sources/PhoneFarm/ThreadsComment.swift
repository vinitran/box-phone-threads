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
        let photoCount = 3
        let composer: String
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
        progress: @escaping @MainActor @Sendable (DeviceProgress) -> Void
    ) async throws -> String {
        let keys = try Telex.keys(for: text)
        try await ThreadsAttachments.cleanupSubmitted(adb: adb, serial: serial)
        let settings = try PhoneFarmStore.shared.get().threadsSettings().validated()
        let batch = try await ThreadsAttachments.prepare(adb: adb, serial: serial, images: settings.pickImages(), progress: progress)
        progress(DeviceProgress(message: "Đang tìm bài để bình luận"))
        let request = Request(id: id, action: "reply",
                              reply: text, stable: stable, forward: forward)
        let prepared = try await perform(request, adb: adb, serial: serial, progress: progress)
        guard prepared.actionStatus == "reply_ready", let target = prepared.target, let author = prepared.author,
              let postID = prepared.postID
        else {
            await ThreadsAttachments.remove(batch, adb: adb, serial: serial)
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
        try Task.checkCancellation()
        progress(DeviceProgress(message: "Đang đính kèm 3 ảnh · app_store.png ở giữa"))
        try await ThreadsAttachments.verify(batch, adb: adb, serial: serial)
        let opened = try await perform(AttachmentRequest(action: "attach_reply", target: target, author: author, reply: text,
                                                            composer: prepared.composer ?? "inline", postID: postID, photos: batch),
                                         adb: adb, serial: serial, progress: progress)
        guard opened.actionStatus == "reply_picker_open" else { return opened.actionStatus }
        try await ThreadsAttachments.verify(batch, adb: adb, serial: serial)
        let attached = try await perform(AttachmentRequest(action: "select_reply_photos", target: target, author: author, reply: text,
                                                           composer: prepared.composer ?? "inline", postID: postID, photos: batch),
                                        adb: adb, serial: serial, progress: progress)
        guard attached.actionStatus == "reply_ready", let finalTarget = attached.target else { return attached.actionStatus }
        try Task.checkCancellation()
        let result = try await perform(Submission(target: finalTarget, author: author, reply: text,
                                                   composer: attached.composer ?? "full"),
                                       adb: adb, serial: serial, progress: progress)
        if result.actionStatus == "reply_submitted" {
            do { try PhoneFarmStore.shared.get().recordComment(serial: serial) }
            catch { logger.error("Could not record submitted comment") }
            do { try PhoneFarmStore.shared.get().queueSubmittedPhotos(batch, serial: serial) }
            catch { logger.error("Could not queue submitted photo cleanup") }
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
        guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last else {
            throw TypingError.commandFailed
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(line.utf8))
        if response.actionStatus == "target_changed" {
            logger.error("Reply verification failed at \(response.phase ?? "unknown", privacy: .public): \(response.reason ?? "unknown", privacy: .public)")
        }
        return response
    }
}
