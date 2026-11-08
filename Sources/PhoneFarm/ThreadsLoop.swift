import Foundation

@MainActor
enum ThreadsLoop {
    nonisolated static let promotionsPerCycle = 5
    nonisolated static let activeSeconds = 3 * 60 * 60
    nonisolated static let cycleRestSeconds = 4 * 60 * 60

    struct Slot: Equatable {
        let kind: ThreadsCommentKind
        let offset: Int
        let promotionNumber: Int
    }

    struct Counts: Equatable {
        var promotions = 0
        var ordinary = 0
        var total: Int { promotions + ordinary }
        var label: String { "\(promotions)/5 giới thiệu · \(ordinary) thông thường" }
        mutating func record(_ kind: ThreadsCommentKind) {
            if kind == .promotion { promotions += 1 } else { ordinary += 1 }
        }
    }

    struct Round {
        let submitted: Bool
        let readyForNext: Bool
        let message: String
    }

    enum Event {
        case waiting(cycle: Int, counts: Counts, slot: Slot, until: Date)
        case starting(cycle: Int, counts: Counts, slot: Slot, deadline: Date)
        case submitted(cycle: Int, counts: Counts)
        case keepingOpen(cycle: Int, counts: Counts, until: Date)
        case finishingWindow(cycle: Int, counts: Counts, until: Date)
        case cycleResting(cycle: Int, counts: Counts, until: Date)
    }

    struct LoopError: LocalizedError { let errorDescription: String? }
    struct WindowEnded: LocalizedError {
        var errorDescription: String? { "Đã hết khung 3 giờ, không gửi thêm bình luận." }
    }

    nonisolated static func checkDeadline(_ deadline: Date?, now: Date = Date()) throws {
        try Task.checkCancellation()
        if let deadline, now >= deadline { throw WindowEnded() }
    }

    /// Five 36-minute groups, each with one promotion and one or two ordinary replies.
    nonisolated static func makePlan(random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> [Slot] {
        let groupSeconds = activeSeconds / promotionsPerCycle
        var result: [Slot] = []
        for group in 0..<promotionsPerCycle {
            let ordinary = random(1...2)
            precondition((1...2).contains(ordinary))
            let segment = groupSeconds / (ordinary + 1)
            let start = group * groupSeconds
            result.append(Slot(kind: .promotion, offset: start + random(0...120), promotionNumber: group + 1))
            for index in 1...ordinary {
                let jitter = random((-segment / 6)...(segment / 6))
                result.append(Slot(kind: .ordinary, offset: start + index * segment + jitter, promotionNumber: group + 1))
            }
        }
        return result
    }

    static func run(
        round: (Bool, Int, Int, ThreadsCommentKind, Date) async throws -> Round,
        closeThreads: () async throws -> Void,
        event: (Event) -> Void,
        plan: () -> [Slot] = { makePlan() },
        cooldown: () -> Int = { Int.random(in: 180...300) },
        now: () -> Date = Date.init,
        sleep: (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws {
        func wait(until: Date) async throws {
            while now() < until {
                try Task.checkCancellation()
                try await sleep(min(60, max(1, Int(ceil(until.timeIntervalSince(now()))))))
            }
            try Task.checkCancellation()
        }
        var cycle = 1
        while true {
            try Task.checkCancellation()
            let start = now()
            let deadline = start.addingTimeInterval(TimeInterval(activeSeconds))
            let slots = plan()
            var counts = Counts()
            var earliestNext = start
            for slot in slots {
                let scheduled = max(start.addingTimeInterval(TimeInterval(slot.offset)), earliestNext)
                guard scheduled < deadline, now() < deadline else { break }
                if now() < scheduled {
                    event(.waiting(cycle: cycle, counts: counts, slot: slot, until: scheduled))
                    try await wait(until: scheduled)
                }
                guard now() < deadline else { break }
                event(.starting(cycle: cycle, counts: counts, slot: slot, deadline: deadline))
                let result: Round
                do {
                    result = try await round(true, cycle, counts.total + 1, slot.kind, deadline)
                } catch is WindowEnded {
                    break
                }
                guard result.submitted else {
                    throw LoopError(errorDescription: "\(counts.label) · " + result.message)
                }
                counts.record(slot.kind)
                event(.submitted(cycle: cycle, counts: counts))
                let finished = now()
                let graceEnd = finished.addingTimeInterval(60)
                event(.keepingOpen(cycle: cycle, counts: counts, until: graceEnd))
                try await wait(until: graceEnd)
                try await closeThreads()
                earliestNext = finished.addingTimeInterval(TimeInterval(max(180, cooldown())))
            }
            try await closeThreads()
            if now() < deadline {
                event(.finishingWindow(cycle: cycle, counts: counts, until: deadline))
                try await wait(until: deadline)
            }
            let resume = now().addingTimeInterval(TimeInterval(cycleRestSeconds))
            event(.cycleResting(cycle: cycle, counts: counts, until: resume))
            try await wait(until: resume)
            cycle += 1
        }
    }
}
