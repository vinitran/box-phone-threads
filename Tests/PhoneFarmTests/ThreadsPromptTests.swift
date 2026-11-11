import XCTest
@testable import PhoneFarm

final class ThreadsPromptTests: XCTestCase {
    @MainActor
    func testDevAndProductionUseTheSameFixedPromptEvenWithALegacyBank() async throws {
        let bank = (1...10).map { ThreadsSettings.ReplyPrompt(id: "bank-\($0)", name: "Bank \($0)", text: "LEGACY_BANK_\($0)") }
        for mode in ThreadsSettings.Environment.allCases {
            let settings = ThreadsSettings(topics: "mua sắm", replyPrompt: "FIXED_PROMPT_SENTINEL", imageFolder: "", replyPrompts: bank, environment: mode)
            let restored = try JSONDecoder().decode(ThreadsSettings.self, from: JSONEncoder().encode(settings))
            let posts = [ThreadsReplyAI.Candidate(index: 1, text: "Mình cần tìm chiếc ba lô nhẹ.", canLike: false, canReply: true)]
            let decision = try await ThreadsReplyAI.choose(from: posts, key: "unused", settings: restored, completion: { system, _ in
                XCTAssertTrue(system.contains("FIXED_PROMPT_SENTINEL"))
                XCTAssertFalse(system.contains("LEGACY_BANK_"))
                XCTAssertTrue(system.contains("Không kết thúc bình luận bằng dấu chấm"))
                return #"{"like":null,"reply":{"index":1,"text":"Bạn ưu tiên độ bền hay trọng lượng của ba lô..."}}"#
            })
            XCTAssertEqual(decision.reply.text, "Bạn ưu tiên độ bền hay trọng lượng của ba lô")
            XCTAssertEqual(restored.replyPrompts?.count, 10)
        }
    }

    @MainActor
    func testOrdinaryAIRepliesAlsoLoseTerminalDotsAndKeepSentencePunctuation() async throws {
        let settings = ThreadsSettings(topics: "mua sắm", replyPrompt: "PROMO_SENTINEL", imageFolder: "", environment: .production)
        let posts = [ThreadsReplyAI.Candidate(index: 1, text: "Hôm nay trời mát, mọi người đi đâu.", canLike: false, canReply: true)]
        let decision = try await ThreadsReplyAI.choose(from: posts, key: "unused", settings: settings, kind: .ordinary, completion: { system, _ in
            XCTAssertFalse(system.contains("PROMO_SENTINEL"))
            let response: [String: Any] = ["like": NSNull(), "reply": ["index": 1, "text": "Trời mát hợp đi bộ. Bạn định đi khu nào... \n"]]
            return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        })
        XCTAssertEqual(decision.reply.text, "Trời mát hợp đi bộ. Bạn định đi khu nào")
    }

    func testCommentCleanupPreservesInteriorDotsAndOtherPunctuation() {
        XCTAssertEqual(ThreadsCommentText.prepared("  Xin chào. \n"), "Xin chào")
        XCTAssertEqual(ThreadsCommentText.prepared("Câu một. Câu hai..."), "Câu một. Câu hai")
        XCTAssertEqual(ThreadsCommentText.prepared("Xin chào . . … 。 ． \n"), "Xin chào")
        XCTAssertEqual(ThreadsCommentText.prepared(" . … \n"), "")
        XCTAssertEqual(ThreadsCommentText.prepared("Bạn thử nhé!"), "Bạn thử nhé!")
        XCTAssertEqual(ThreadsCommentText.prepared("Đã bỏ dấu chấm"), "Đã bỏ dấu chấm")
    }

    @MainActor
    func testDotOnlyCommentIsRejectedBeforeAnyPhoneAction() async throws {
        var progressWasCalled = false
        let result = try await ThreadsComment.send(adb: URL(fileURLWithPath: "/nonexistent-adb"), serial: "test", id: "test", text: " . . \n", kind: .ordinary) { _ in
            progressWasCalled = true
        }
        XCTAssertEqual(result, "invalid_reply")
        XCTAssertFalse(progressWasCalled)
    }
}
