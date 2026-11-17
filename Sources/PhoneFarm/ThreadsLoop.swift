import Foundation

/// An error the Threads loop must not retry: stop the loop and show it.
protocol ThreadsLoopStop: Error {}

enum ThreadsRunContext { @TaskLocal static var deadline: Date? }

@MainActor
enum ThreadsLoop {
    nonisolated static let promotionsPerCycle = 5
    nonisolated static let activeSeconds = 3 * 60 * 60
    nonisolated static let cycleRestSeconds = 4 * 60 * 60
    /// A failed round is retried after 1, 3 and 5 minutes, each time after `recover` restarted Threads.
    nonisolated static let retryDelays = [60, 180, 300]
    /// This many slots in a row failing every retry ends the 3-hour window early; the next cycle starts as usual.
    nonisolated static let failedSlotsBeforeRest = 3

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
        /// False when Post may already have been tapped, so trying again could comment twice.
        var retryable = true
    }

    enum Event {
        case waiting(cycle: Int, counts: Counts, slot: Slot, until: Date)
        case starting(cycle: Int, counts: Counts, slot: Slot, deadline: Date)
        case submitted(cycle: Int, counts: Counts)
        case keepingOpen(cycle: Int, counts: Counts, until: Date)
        case finishingWindow(cycle: Int, counts: Counts, until: Date)
        case cycleResting(cycle: Int, counts: Counts, until: Date)
        case retrying(cycle: Int, counts: Counts, attempt: Int, of: Int, reason: String, until: Date)
        case skipped(cycle: Int, counts: Counts, reason: String)
        case windowAbandoned(cycle: Int, counts: Counts, reason: String)
    }

    struct LoopError: LocalizedError { let errorDescription: String? }
    struct WindowEnded: LocalizedError {
        var errorDescription: String? { "Đã hết khung 3 giờ, không gửi thêm bình luận." }
    }

    struct SliceEnded: Error, ThreadsLoopStop {}
    struct CycleRest: Error { let until: Date }

    /// Kept per account while a runner visits other profiles.
    final class State {
        var cycle = 1
        var start: Date?
        var slots: [Slot] = []
        var nextSlot = 0
        var counts = Counts()
        var earliestNext = Date.distantPast
        var failedSlots = 0
        var graceEnd: Date?
        var restUntil: Date?

        func beginIfNeeded(at date: Date, plan: () -> [Slot]) {
            guard start == nil else { return }
            start = date; slots = plan(); earliestNext = date
        }
    }

    nonisolated static func checkDeadline(_ deadline: Date?, now: Date = Date()) throws {
        try Task.checkCancellation()
        if let slice = ThreadsRunContext.deadline, now >= slice { throw SliceEnded() }
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
        state suppliedState: State? = nil,
        yieldAtCycleRest: Bool = false,
        round: (Bool, Int, Int, ThreadsCommentKind, Date) async throws -> Round,
        closeThreads: () async throws -> Void,
        recover: (String) async -> Void = { _ in },
        event: (Event) -> Void,
        plan: () -> [Slot] = { makePlan() },
        cooldown: () -> Int = { Int.random(in: 180...300) },
        now: () -> Date = Date.init,
        sleep: (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws {
        let state = suppliedState ?? State()
        func wait(until: Date) async throws {
            while now() < until {
                try checkDeadline(nil, now: now())
                try await sleep(min(60, max(1, Int(ceil(until.timeIntervalSince(now()))))))
            }
            try checkDeadline(nil, now: now())
        }
        while true {
            try checkDeadline(nil, now: now())
            state.beginIfNeeded(at: now(), plan: plan)
            let start = state.start!
            let cycle = state.cycle
            let deadline = start.addingTimeInterval(TimeInterval(activeSeconds))
            if let resume = state.restUntil {
                event(.cycleResting(cycle: cycle, counts: state.counts, until: resume))
                // A completed window can hand the phone to another account. Its own four-hour
                // rest continues on the wall clock while the other profile is active.
                if yieldAtCycleRest, now() < resume { throw CycleRest(until: resume) }
                try await wait(until: resume)
                state.cycle += 1; state.start = nil; state.slots = []; state.nextSlot = 0
                state.counts = Counts(); state.failedSlots = 0; state.restUntil = nil; state.graceEnd = nil
                continue
            }
            if let grace = state.graceEnd {
                if now() < grace {
                    event(.keepingOpen(cycle: cycle, counts: state.counts, until: grace))
                    try await wait(until: grace)
                }
                try? await closeThreads()
                state.graceEnd = nil
            }
            slots: while state.nextSlot < state.slots.count {
                let slot = state.slots[state.nextSlot]
                let scheduled = max(start.addingTimeInterval(TimeInterval(slot.offset)), state.earliestNext)
                guard scheduled < deadline, now() < deadline else { break }
                if now() < scheduled {
                    event(.waiting(cycle: cycle, counts: state.counts, slot: slot, until: scheduled))
                    try await wait(until: scheduled)
                }
                try checkDeadline(nil, now: now())
                // Claim before starting a round. An interrupted or unconfirmed send must never
                // repeat when this account is visited again.
                state.nextSlot += 1
                var succeeded: Round?
                var reason = ""
                for attempt in 0...retryDelays.count {
                    try checkDeadline(nil, now: now())
                    guard now() < deadline else { break slots }
                    event(.starting(cycle: cycle, counts: state.counts, slot: slot, deadline: deadline))
                    do {
                        let limit = min(deadline, ThreadsRunContext.deadline ?? deadline)
                        let result = try await round(true, cycle, state.counts.total + 1, slot.kind, limit)
                        if result.submitted { succeeded = result; break }
                        reason = result.message
                        if !result.retryable { break }
                    } catch is WindowEnded {
                        try checkDeadline(nil, now: now())
                        break slots
                    } catch let error as ThreadsLoopStop {
                        throw error
                    } catch {
                        try Task.checkCancellation()
                        reason = error.localizedDescription
                    }
                    guard attempt < retryDelays.count else { break }
                    let retryAt = now().addingTimeInterval(TimeInterval(retryDelays[attempt]))
                    guard retryAt < deadline else { break slots }
                    await recover(reason)
                    event(.retrying(cycle: cycle, counts: state.counts, attempt: attempt + 1, of: retryDelays.count, reason: reason, until: retryAt))
                    try await wait(until: retryAt)
                }
                guard succeeded != nil else {
                    state.failedSlots += 1
                    if state.failedSlots >= failedSlotsBeforeRest {
                        event(.windowAbandoned(cycle: cycle, counts: state.counts, reason: reason))
                        break slots
                    }
                    event(.skipped(cycle: cycle, counts: state.counts, reason: reason))
                    try? await closeThreads()
                    state.earliestNext = now().addingTimeInterval(TimeInterval(max(180, cooldown())))
                    continue
                }
                state.failedSlots = 0
                state.counts.record(slot.kind)
                event(.submitted(cycle: cycle, counts: state.counts))
                let finished = now()
                let graceEnd = finished.addingTimeInterval(60)
                state.graceEnd = graceEnd
                state.earliestNext = finished.addingTimeInterval(TimeInterval(max(180, cooldown())))
                event(.keepingOpen(cycle: cycle, counts: state.counts, until: graceEnd))
                try await wait(until: graceEnd)
                try? await closeThreads()
                state.graceEnd = nil
            }
            try? await closeThreads()
            if now() < deadline {
                event(.finishingWindow(cycle: cycle, counts: state.counts, until: deadline))
                try await wait(until: deadline)
            }
            state.restUntil = now().addingTimeInterval(TimeInterval(cycleRestSeconds))
        }
    }
}
