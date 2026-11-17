import Foundation

/// Two three-hour windows share one phone; an inactive account's four-hour rest
/// keeps running. Short pauses within a window do not trigger expensive user switches.
@MainActor
enum ROMProfileAlternation {
    struct SelectionError: LocalizedError {
        var errorDescription: String? { "Chế độ theo ca nghỉ cần đúng hai profile có proxy riêng." }
    }

    static func run(
        profiles: [ROMProfile], startingAt id: String?,
        prepare: @escaping @MainActor (ROMProfile) async throws -> Void,
        runWindow: @escaping @MainActor (ROMProfile, ThreadsLoop.State) async throws -> Void,
        stopSession: @escaping @MainActor @Sendable (ROMProfile) async -> Bool,
        event: @escaping @MainActor (ROMProfileRotation.Status) -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleepUntil: @escaping @MainActor (Date) async throws -> Void = { until in
            while Date() < until {
                try await Task.sleep(for: .seconds(min(60, max(0, until.timeIntervalSinceNow))))
            }
            try Task.checkCancellation()
        }
    ) async throws {
        guard profiles.count == 2 else { throw SelectionError() }
        let targets = try ROMProfileRotation.ordered(profiles, startingAt: id)
        let states = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, ThreadsLoop.State()) })
        var currentID = id
        var preparation: TimeInterval = 180 // Conservative initial estimate, then measured + 30s margin.
        var lastFinished: String?
        func ready(_ profile: ROMProfile) -> Date { states[profile.id]!.restUntil ?? .distantPast }
        func close(_ profile: ROMProfile) async throws {
            let closed = await Task.detached { @MainActor in await stopSession(profile) }.value
            guard closed else { throw ROMProfileRotation.RotationError.couldNotStop }
        }
        while true {
            try Task.checkCancellation()
            // Prefer the other account after a window; if both are resting, select the
            // earliest ready one and leave the physical phone alone until preparation is due.
            let eligible = targets.filter { ready($0) <= now() }
            let target = eligible.first(where: { $0.id != lastFinished }) ?? eligible.first
                ?? targets.min(by: { ready($0) < ready($1) })!
            let next = targets.first { $0.id != target.id }!
            let changesUser = currentID != target.id
            let prepareAt = ready(target).addingTimeInterval(-(changesUser ? preparation : 0))
            if now() < prepareAt {
                let current = targets.first { $0.id == currentID } ?? target
                event(.init(profile: current, next: target, switchAt: nil, mode: .restWindows,
                            wakeAt: prepareAt, preparationSeconds: preparation))
                try await sleepUntil(prepareAt)
                continue // Recalculate after sleep/wake or a clock correction.
            }
            event(.init(profile: target, next: next, switchAt: nil, mode: .restWindows,
                        preparationSeconds: preparation))
            let began = uptime()
            try await prepare(target)
            if changesUser { preparation = max(preparation, max(0, uptime() - began) + 30) }
            currentID = target.id
            try Task.checkCancellation()
            // Switching may finish early. This account still cannot post before its own rest ends.
            if now() < ready(target) {
                event(.init(profile: target, next: target, switchAt: nil, mode: .restWindows,
                            wakeAt: ready(target), preparationSeconds: preparation))
                try await sleepUntil(ready(target))
                try Task.checkCancellation()
            }
            let state = states[target.id]!
            event(.init(profile: target, next: next,
                        switchAt: now().addingTimeInterval(TimeInterval(ThreadsLoop.activeSeconds)),
                        mode: .restWindows, preparationSeconds: preparation))
            do {
                try await runWindow(target, state)
                throw ROMProfileRotation.RotationError.workerStopped
            } catch let rest as ThreadsLoop.CycleRest {
                guard state.restUntil == rest.until, rest.until > now() else {
                    try await close(target)
                    throw ROMProfileRotation.RotationError.workerStopped
                }
                try await close(target)
                lastFinished = target.id
            } catch {
                try? await close(target)
                throw error
            }
        }
    }
}
