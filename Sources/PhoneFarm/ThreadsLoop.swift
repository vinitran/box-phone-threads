import Foundation

@MainActor
enum ThreadsLoop {
    nonisolated static let batchSize = 10
    nonisolated static let restSeconds = (20 * 60)...(30 * 60)
    /// After the 10th comment of a cycle, Threads is closed and the phone rests this long.
    nonisolated static let cycleRestSeconds = 3 * 60 * 60

    struct Round {
        let submitted: Bool
        let readyForNext: Bool
        let message: String
    }

    enum Event {
        case starting(cycle: Int, submitted: Int)
        case submitted(cycle: Int, count: Int)
        case keepingOpen(cycle: Int, submitted: Int, until: Date)
        case resting(cycle: Int, submitted: Int, until: Date)
        case cycleResting(cycle: Int, until: Date)
    }

    struct LoopError: LocalizedError {
        let errorDescription: String?
    }

    static func run(
        round: (Bool, Int, Int) async throws -> Round,
        closeThreads: () async throws -> Void,
        event: (Event) -> Void,
        restRange: ClosedRange<Int> = restSeconds,
        cycleRest: Int = cycleRestSeconds,
        rest: (() -> Int)? = nil,
        now: () -> Date = Date.init,
        sleep: (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws {
        var cycle = 1
        while true {
            var count = 0
            while count < batchSize {
                try Task.checkCancellation()
                event(.starting(cycle: cycle, submitted: count))
                // Each previous post is followed by a long rest with Threads in
                // the background. Reopen and prepare a fresh feed every round.
                let result = try await round(true, cycle, count + 1)
                if result.submitted {
                    count += 1
                    event(.submitted(cycle: cycle, count: count))
                }
                guard result.submitted else {
                    throw LoopError(errorDescription: "Đã bấm Đăng \(count)/\(batchSize) · " + result.message)
                }
                try Task.checkCancellation()
                event(.keepingOpen(cycle: cycle, submitted: count, until: now().addingTimeInterval(60)))
                try await sleep(60)
                try Task.checkCancellation()
                try await closeThreads()
                let seconds: Int
                if count == batchSize {
                    seconds = cycleRest
                    event(.cycleResting(cycle: cycle, until: now().addingTimeInterval(TimeInterval(seconds))))
                } else {
                    seconds = rest?() ?? Int.random(in: restRange)
                    guard restRange.contains(seconds) else {
                        throw LoopError(errorDescription: "Khoảng nghỉ không đúng chế độ đã chọn.")
                    }
                    event(.resting(cycle: cycle, submitted: count, until: now().addingTimeInterval(TimeInterval(seconds))))
                }
                try await sleep(seconds)
                try Task.checkCancellation()
            }
            cycle += 1
        }
    }
}
