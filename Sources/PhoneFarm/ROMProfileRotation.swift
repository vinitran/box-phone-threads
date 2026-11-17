import Foundation

@MainActor
enum ROMProfileRotation {
    nonisolated static let secondsPerProfile: TimeInterval = 300

    enum Mode: String, CaseIterable, Identifiable {
        case restWindows, fiveMinutes
        var id: Self { self }
        var title: String { self == .restWindows ? "Hai profile · theo ca nghỉ" : "Đổi mỗi 5 phút" }
    }

    struct Status {
        let profile: ROMProfile
        let next: ROMProfile
        let switchAt: Date?
        var mode: Mode = .fiveMinutes
        var wakeAt: Date? = nil
        var preparationSeconds: TimeInterval? = nil
    }

    enum RotationError: LocalizedError {
        case invalidSelection, workerStopped, couldNotStop
        var errorDescription: String? {
            switch self {
            case .invalidSelection: return "Chọn ít nhất hai profile khác nhau, mỗi profile có proxy ép tuyến riêng."
            case .workerStopped: return "Luồng Threads kết thúc trước hạn; đã dừng đổi profile để kiểm tra."
            case .couldNotStop: return "Chưa xác nhận đã dừng Threads và tiến trình điều khiển cũ; chưa chuyển profile."
            }
        }
    }

    static func ordered(_ profiles: [ROMProfile], startingAt id: String?) throws -> [ROMProfile] {
        guard profiles.count >= 2, Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.userID)).count == profiles.count,
              profiles.allSatisfy({ $0.canRotate }),
              Set(profiles.compactMap { $0.proxy?.address?.lowercased() }).count == profiles.count else {
            throw RotationError.invalidSelection
        }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return profiles }
        return Array(profiles[index...]) + Array(profiles[..<index])
    }

    /// The next activation cannot start until the old worker has unwound AND a final
    /// force-stop succeeded. Stop remains effective while a non-cancellable RPC finishes.
    static func run(
        profiles: [ROMProfile], startingAt id: String?,
        prepare: @escaping @MainActor @Sendable (ROMProfile) async throws -> Void,
        runSession: @escaping @MainActor @Sendable (ROMProfile, Date) async throws -> Void,
        stopSession: @escaping @MainActor @Sendable (ROMProfile) async -> Bool,
        event: @escaping @MainActor (Status) -> Void,
        duration: TimeInterval = secondsPerProfile,
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        sleepUntil: @escaping @MainActor @Sendable (Date) async throws -> Void = { until in
            // One monotonic sleep keeps a wall-clock correction from extending a visit.
            try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            try Task.checkCancellation()
        }
    ) async throws {
        let targets = try ordered(profiles, startingAt: id)
        var index = 0
        while true {
            try Task.checkCancellation()
            let target = targets[index], next = targets[(index + 1) % targets.count]
            event(Status(profile: target, next: next, switchAt: nil))
            try await prepare(target)
            try Task.checkCancellation()
            let until = now().addingTimeInterval(duration)
            event(Status(profile: target, next: next, switchAt: until))
            try await visit(target, until: until, run: runSession, stop: stopSession, sleepUntil: sleepUntil)
            index = (index + 1) % targets.count
        }
    }

    private enum Outcome: Sendable { case expired, finished }

    private static func visit(
        _ target: ROMProfile, until: Date,
        run: @escaping @MainActor @Sendable (ROMProfile, Date) async throws -> Void,
        stop: @escaping @MainActor @Sendable (ROMProfile) async -> Bool,
        sleepUntil: @escaping @MainActor @Sendable (Date) async throws -> Void
    ) async throws {
        func stopUncancelled() async -> Bool {
            await Task.detached { @MainActor in await stop(target) }.value
        }
        do {
            let result = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { @MainActor in
                    do {
                        try await ThreadsRunContext.$deadline.withValue(until) { try await run(target, until) }
                        return .finished
                    } catch is ThreadsLoop.SliceEnded { return .expired }
                }
                group.addTask { @MainActor in try await sleepUntil(until); return .expired }
                do {
                    let first = try await group.next()!
                    group.cancelAll()
                    _ = await stopUncancelled()
                    return first
                } catch {
                    group.cancelAll()
                    _ = await stopUncancelled()
                    throw error
                }
                // The task-group scope waits for both children before returning.
            }
            guard await stopUncancelled() else { throw RotationError.couldNotStop }
            try Task.checkCancellation()
            if result == .finished { throw RotationError.workerStopped }
        } catch {
            _ = await stopUncancelled()
            throw error
        }
    }
}
