import XCTest
@testable import PhoneFarm

final class ThreadsLoopTests: XCTestCase {
    private enum Stop: Error { case done }

    func testRandomPlansAlwaysHaveFivePromotionsFollowedByOneOrTwoReplies() {
        var schedules = Set<[Int]>()
        for _ in 0..<1000 {
            let plan = ThreadsLoop.makePlan()
            XCTAssertEqual(plan.filter { $0.kind == .promotion }.count, 5)
            XCTAssertTrue((10...15).contains(plan.count))
            XCTAssertTrue(plan.allSatisfy { (0..<10800).contains($0.offset) })
            for group in 1...5 {
                let entries = plan.filter { $0.promotionNumber == group }
                XCTAssertEqual(entries.first?.kind, .promotion)
                XCTAssertTrue((1...2).contains(entries.dropFirst().count))
                XCTAssertTrue(entries.dropFirst().allSatisfy { $0.kind == .ordinary })
            }
            for (first, second) in zip(plan, plan.dropFirst()) {
                XCTAssertGreaterThanOrEqual(second.offset - first.offset, 480)
            }
            schedules.insert(plan.map(\.offset))
        }
        XCTAssertGreaterThan(schedules.count, 1)
    }

    @MainActor
    func testTwoCompleteCyclesUseThreeHourWindowsAndFourHourRests() async throws {
        let epoch = Date(timeIntervalSince1970: 0)
        var clock = epoch
        var plans = 0
        var sent: [(Int, ThreadsCommentKind, Date)] = []
        var rests: [(ThreadsLoop.Counts, Date, Date)] = []
        var largestSleep = 0
        do {
            try await ThreadsLoop.run(round: { _, cycle, _, kind, deadline in
                if cycle == 3 { throw Stop.done }
                XCTAssertLessThan(clock, deadline)
                sent.append((cycle, kind, clock))
                clock.addTimeInterval(30)
                return .init(submitted: true, readyForNext: true, message: "test")
            }, closeThreads: {}, event: { event in
                if case let .cycleResting(_, counts, until) = event { rests.append((counts, clock, until)) }
            }, plan: {
                plans += 1
                return ThreadsLoop.makePlan { plans == 1 ? $0.lowerBound : $0.upperBound }
            }, cooldown: { 180 }, now: { clock }, sleep: { seconds in
                largestSleep = max(largestSleep, seconds)
                clock.addTimeInterval(TimeInterval(seconds))
            })
            XCTFail("Expected test stop")
        } catch Stop.done { }
        XCTAssertEqual(sent.filter { $0.0 == 1 && $0.1 == .promotion }.count, 5)
        XCTAssertEqual(sent.filter { $0.0 == 1 && $0.1 == .ordinary }.count, 5)
        XCTAssertEqual(sent.filter { $0.0 == 2 && $0.1 == .promotion }.count, 5)
        XCTAssertEqual(sent.filter { $0.0 == 2 && $0.1 == .ordinary }.count, 10)
        XCTAssertEqual(rests.count, 2)
        XCTAssertEqual(rests[0].1.timeIntervalSince(epoch), 10800)
        XCTAssertEqual(rests[1].1.timeIntervalSince(epoch), 36000)
        for rest in rests {
            XCTAssertEqual(rest.0.promotions, 5)
            XCTAssertEqual(rest.2.timeIntervalSince(rest.1), 14400)
        }
        XCTAssertLessThanOrEqual(largestSleep, 60)
    }

    @MainActor
    func testLateRoundNeverCatchesUpAfterTheWindow() async throws {
        var clock = Date(timeIntervalSince1970: 0)
        var calls = 0
        var restCounts: ThreadsLoop.Counts?
        do {
            try await ThreadsLoop.run(round: { _, cycle, _, _, deadline in
                calls += 1
                if cycle == 2 { throw Stop.done }
                clock = deadline.addingTimeInterval(2)
                throw ThreadsLoop.WindowEnded()
            }, closeThreads: {}, event: { event in
                if case let .cycleResting(_, counts, _) = event { restCounts = counts }
            }, plan: { ThreadsLoop.makePlan { $0.lowerBound } }, now: { clock }, sleep: { clock.addTimeInterval(TimeInterval($0)) })
        } catch Stop.done { }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(restCounts?.total, 0)
    }

    @MainActor
    func testWakingAfterTheWindowDoesNotSendOldScheduledComments() async throws {
        var clock = Date(timeIntervalSince1970: 0)
        var firstSleep = true
        var calledCycles: [Int] = []
        do {
            try await ThreadsLoop.run(round: { _, cycle, _, _, _ in
                calledCycles.append(cycle)
                throw Stop.done
            }, closeThreads: {}, event: { _ in }, plan: { ThreadsLoop.makePlan { $0.upperBound } }, now: { clock }, sleep: { seconds in
                clock.addTimeInterval(firstSleep ? 10801 : TimeInterval(seconds))
                firstSleep = false
            })
        } catch Stop.done { }
        XCTAssertEqual(calledCycles, [2])
    }

    @MainActor
    func testDelayedSlotsStillHaveACooldown() async throws {
        var clock = Date(timeIntervalSince1970: 0)
        var starts: [Date] = []
        var finishes: [Date] = []
        do {
            try await ThreadsLoop.run(round: { _, _, _, _, _ in
                if starts.count == 2 { throw Stop.done }
                starts.append(clock)
                clock.addTimeInterval(1600)
                finishes.append(clock)
                return .init(submitted: true, readyForNext: true, message: "test")
            }, closeThreads: {}, event: { _ in }, plan: { ThreadsLoop.makePlan { $0.lowerBound } }, cooldown: { 180 },
               now: { clock }, sleep: { clock.addTimeInterval(TimeInterval($0)) })
        } catch Stop.done { }
        XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(finishes[0]), 180)
    }

    @MainActor
    func testFailedSendStopsWithoutCountingOrResting() async throws {
        var submitted = false
        var slept = false
        do {
            try await ThreadsLoop.run(round: { _, _, _, _, _ in
                .init(submitted: false, readyForNext: false, message: "draft exists")
            }, closeThreads: {}, event: { event in
                if case .submitted = event { submitted = true }
                if case .cycleResting = event { XCTFail("Should stop on failed send") }
            }, plan: { ThreadsLoop.makePlan { $0.lowerBound } }, sleep: { _ in slept = true })
            XCTFail("Expected send failure")
        } catch is ThreadsLoop.LoopError { }
        XCTAssertFalse(submitted)
        XCTAssertFalse(slept)
    }

    @MainActor
    func testCancellationInterruptsScheduledWait() async throws {
        let task = Task {
            try await ThreadsLoop.run(round: { _, _, _, _, _ in
                XCTFail("Cancelled waiting task must not post")
                return .init(submitted: true, readyForNext: true, message: "")
            }, closeThreads: {}, event: { _ in }, plan: { ThreadsLoop.makePlan { $0.upperBound } })
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testPostingDeadlineBoundaryAndOrdinaryReplyPolicy() throws {
        let deadline = Date()
        XCTAssertThrowsError(try ThreadsLoop.checkDeadline(deadline, now: deadline)) { XCTAssertTrue($0 is ThreadsLoop.WindowEnded) }
        XCTAssertNoThrow(try ThreadsLoop.checkDeadline(deadline, now: deadline.addingTimeInterval(-1)))
        XCTAssertFalse(ThreadsCommentKind.ordinary.allows("Bạn tải Hoàn Xu để lấy mã giới thiệu nhé."))
        XCTAssertFalse(ThreadsCommentKind.ordinary.allows("Bạn có thể tải app trên Google Play."))
        XCTAssertTrue(ThreadsCommentKind.ordinary.allows("Bạn ưu tiên độ bền hay trọng lượng của ba lô."))
        XCTAssertTrue(ThreadsCommentKind.ordinary.allows("Trường hợp trả hàng này có được hoàn tiền không."))
    }

    func testOrdinaryModeDoesNotRequireAnImageFolder() throws {
        let settings = ThreadsSettings(topics: "du lịch", replyPrompt: "prompt", imageFolder: "/nonexistent-phone-farm-image-folder")
        XCTAssertNoThrow(try settings.validated(validateImages: false))
        XCTAssertThrowsError(try settings.validated())
    }

    @MainActor
    func testOrdinaryAIUsesSeparatePromptAndRejectsAnAdvertisingReply() async throws {
        let settings = ThreadsSettings(topics: "SHILL_TOPIC_SENTINEL", replyPrompt: "SHILL_PROMPT_SENTINEL", imageFolder: "", environment: .dev)
        let posts = [ThreadsReplyAI.Candidate(index: 1, text: "Mình cần mua một chiếc ba lô nhẹ.", canLike: false, canReply: true),
                     ThreadsReplyAI.Candidate(index: 2, text: "Hôm nay trời đẹp.", canLike: true, canReply: false)]
        var calls = 0
        let decision = try await ThreadsReplyAI.choose(from: posts, key: "unused", settings: settings, kind: .ordinary, completion: { system, _ in
            XCTAssertFalse(system.contains("SHILL_PROMPT_SENTINEL"))
            XCTAssertFalse(system.contains("SHILL_TOPIC_SENTINEL"))
            calls += 1
            let text = calls == 1 ? "Bạn tải Hoàn Xu để lấy mã giới thiệu." : "Bạn thường mang laptop hay chỉ cần đựng đồ gọn nhẹ."
            let data = try JSONSerialization.data(withJSONObject: ["like": 2, "reply": ["index": 1, "text": text]])
            return String(decoding: data, as: UTF8.self)
        })
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(decision.reply.text.contains("laptop"))
        XCTAssertEqual(decision.like, 2)
    }

    @MainActor
    func testPromotionStillUsesTheConfiguredPrompt() async throws {
        let settings = ThreadsSettings(topics: "TOPIC_SENTINEL", replyPrompt: "PROMO_PROMPT_SENTINEL", imageFolder: "", environment: .dev)
        let posts = [ThreadsReplyAI.Candidate(index: 1, text: "Bài hỏi mua đồ.", canLike: false, canReply: true)]
        let result = try await ThreadsReplyAI.choose(from: posts, key: "unused", settings: settings, kind: .promotion, completion: { system, _ in
            XCTAssertTrue(system.contains("PROMO_PROMPT_SENTINEL"))
            XCTAssertTrue(system.contains("TOPIC_SENTINEL"))
            return #"{"like":null,"reply":{"index":1,"text":"Bạn đang tìm sản phẩm trong tầm giá nào."}}"#
        })
        XCTAssertNil(result.like)
    }
}
