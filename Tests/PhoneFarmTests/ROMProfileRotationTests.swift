import XCTest
@testable import PhoneFarm

@MainActor
final class ROMProfileRotationTests: XCTestCase {
    private enum Stop: ThreadsLoopStop { case done }
    private final class Harness {
        var clock = Date(timeIntervalSince1970: 0)
        var trace: [String] = []
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var stopCounts: [Int: Int] = [:]
        var cancelledWorker = false
    }
    private func profile(_ user: Int, host: String? = nil) -> ROMProfile {
        ROMProfile(id: UUID().uuidString, userId: user, name: "User \(user)",
                   proxy: ROMProxyStatus(type: "http", host: host ?? "proxy\(user).example", port: 8080,
                                         routing: "enforced", transport: "device", authenticated: true))
    }

    func testFiveMinuteDeadlineWrapsOnlyAfterWorkerUnwindsAndFinalClose() async throws {
        let a = profile(10), b = profile(11), h = Harness()
        var visits: [Int] = []
        do {
            try await ROMProfileRotation.run(profiles: [a, b], startingAt: b.id, prepare: { target in
                if visits.count == 2 {
                    XCTAssertEqual(target.id, b.id)
                    throw Stop.done
                }
                if let previous = visits.last {
                    XCTAssertTrue(h.trace.contains("exit-\(previous)"))
                    XCTAssertGreaterThanOrEqual(h.stopCounts[previous, default: 0], 2)
                }
                h.started = false
                visits.append(target.userID)
            }, runSession: { target, deadline in
                XCTAssertEqual(deadline.timeIntervalSince(h.clock), 300)
                XCTAssertEqual(ThreadsRunContext.deadline, deadline)
                h.started = true
                await withCheckedContinuation { h.release = $0 }
                h.cancelledWorker = Task.isCancelled
                h.trace.append("exit-\(target.userID)")
                try Task.checkCancellation()
            }, stopSession: { target in
                h.stopCounts[target.userID, default: 0] += 1
                h.release?.resume(); h.release = nil
                return true
            }, event: { status in
                if let until = status.switchAt { XCTAssertEqual(until.timeIntervalSince(h.clock), 300) }
            }, now: { h.clock }, sleepUntil: { deadline in
                while !h.started { await Task.yield() }
                h.clock = deadline
            })
        } catch Stop.done {}
        XCTAssertEqual(visits, [11, 10])
        XCTAssertEqual(h.clock.timeIntervalSince1970, 600)
        XCTAssertTrue(h.cancelledWorker)
    }

    func testStopDuringVisitNeverPreparesAnotherProfile() async throws {
        let h = Harness(), a = profile(10), b = profile(11)
        var visits = 0
        let task = Task {
            try await ROMProfileRotation.run(profiles: [a, b], startingAt: nil, prepare: { _ in visits += 1 },
                runSession: { _, _ in
                    h.started = true
                    await withCheckedContinuation { h.release = $0 }
                    h.cancelledWorker = Task.isCancelled
                    try Task.checkCancellation()
                }, stopSession: { target in
                    h.stopCounts[target.userID, default: 0] += 1
                    h.release?.resume(); h.release = nil
                    return true
                }, event: { _ in }, sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        }
        while !h.started { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("Must cancel") } catch is CancellationError {}
        XCTAssertEqual(visits, 1)
        XCTAssertTrue(h.cancelledWorker)
        XCTAssertGreaterThanOrEqual(h.stopCounts[10, default: 0], 2)
    }

    func testStopWhileActivationSettlesCannotStartWorker() async throws {
        let h = Harness(), a = profile(10), b = profile(11)
        let task = Task {
            try await ROMProfileRotation.run(profiles: [a, b], startingAt: nil, prepare: { _ in
                h.started = true
                await withCheckedContinuation { h.release = $0 }
            }, runSession: { _, _ in XCTFail("Stop was pressed while activation was settling") },
                stopSession: { _ in true }, event: { _ in })
        }
        while !h.started { await Task.yield() }
        task.cancel(); h.release?.resume(); h.release = nil
        do { try await task.value; XCTFail("Must cancel") } catch is CancellationError {}
    }

    func testFailedFinalStopBlocksNextActivation() async throws {
        let h = Harness(), a = profile(10), b = profile(11)
        var visits = 0
        do {
            try await ROMProfileRotation.run(profiles: [a, b], startingAt: nil, prepare: { _ in visits += 1 },
                runSession: { _, _ in
                    h.started = true
                    await withCheckedContinuation { h.release = $0 }
                    try Task.checkCancellation()
                }, stopSession: { _ in h.release?.resume(); h.release = nil; return false }, event: { _ in },
                now: { h.clock }, sleepUntil: { until in
                    while !h.started { await Task.yield() }
                    h.clock = until
                })
            XCTFail("Must stop when close cannot be verified")
        } catch ROMProfileRotation.RotationError.couldNotStop {}
        XCTAssertEqual(visits, 1)
    }

    func testPreparationFailureOrEarlyWorkerExitStopsInsteadOfSpinning() async throws {
        let a = profile(10), b = profile(11)
        var visits = 0
        do {
            try await ROMProfileRotation.run(profiles: [a, b], startingAt: nil, prepare: { _ in visits += 1; throw ROMError.notProtected },
                runSession: { _, _ in XCTFail("Unverified proxy must not run") }, stopSession: { _ in true }, event: { _ in })
            XCTFail("Must fail")
        } catch ROMError.notProtected {}
        XCTAssertEqual(visits, 1)
        visits = 0
        do {
            try await ROMProfileRotation.run(profiles: [a, b], startingAt: nil, prepare: { _ in visits += 1 },
                runSession: { _, _ in }, stopSession: { _ in true }, event: { _ in },
                sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
            XCTFail("An unexpected return must stop")
        } catch ROMProfileRotation.RotationError.workerStopped {}
        XCTAssertEqual(visits, 1)
    }

    func testSelectionAllowsProtectedOwnerWithProxyButRejectsPendingDeletionAndSharedProxy() throws {
        let a = profile(10), b = profile(11)
        XCTAssertThrowsError(try ROMProfileRotation.ordered([a], startingAt: nil))
        XCTAssertThrowsError(try ROMProfileRotation.ordered([a, a], startingAt: nil))
        XCTAssertEqual(try ROMProfileRotation.ordered([profile(0), b], startingAt: nil).map(\.userID), [0, 11])
        XCTAssertThrowsError(try ROMProfileRotation.ordered([profile(10, host: "same.example"), profile(11, host: "same.example")], startingAt: nil))
        var pending = b; pending.state = "deleting"
        XCTAssertThrowsError(try ROMProfileRotation.ordered([a, pending], startingAt: nil))
    }

    func testPerProfileScheduleAndCountsSurviveFiveMinuteVisits() async throws {
        let state = ThreadsLoop.State(), h = Harness()
        var plans = 0, sent: [ThreadsCommentKind] = []
        func visit(at start: TimeInterval) async throws {
            h.clock = Date(timeIntervalSince1970: start)
            let end = h.clock.addingTimeInterval(300)
            do {
                try await ThreadsRunContext.$deadline.withValue(end) {
                    try await ThreadsLoop.run(state: state, round: { _, _, _, kind, deadline in
                        XCTAssertLessThan(h.clock, end)
                        XCTAssertEqual(deadline, end)
                        sent.append(kind); h.clock.addTimeInterval(30)
                        return .init(submitted: true, readyForNext: true, message: "fixture")
                    }, closeThreads: {}, event: { _ in }, plan: {
                        plans += 1; return ThreadsLoop.makePlan { $0.lowerBound }
                    }, cooldown: { 180 }, now: { h.clock }, sleep: { h.clock.addTimeInterval(TimeInterval($0)) })
                }
                XCTFail("Visit must expire")
            } catch is ThreadsLoop.SliceEnded {}
        }
        try await visit(at: 0)
        try await visit(at: 600)
        try await visit(at: 1080)
        XCTAssertEqual(plans, 1)
        XCTAssertEqual(sent, [.promotion, .ordinary])
        XCTAssertEqual(state.counts.total, 2)
        XCTAssertEqual(state.cycle, 1)
    }

    func testInterruptedRoundIsClaimedBeforePostingAndNotRepeatedOnReturn() async throws {
        let state = ThreadsLoop.State(), h = Harness()
        do {
            try await ThreadsRunContext.$deadline.withValue(Date(timeIntervalSince1970: 300)) {
                try await ThreadsLoop.run(state: state, round: { _, _, _, _, _ in
                    h.clock = Date(timeIntervalSince1970: 300)
                    throw ThreadsLoop.SliceEnded()
                }, closeThreads: {}, event: { _ in }, plan: { ThreadsLoop.makePlan { $0.lowerBound } },
                    now: { h.clock }, sleep: { h.clock.addTimeInterval(TimeInterval($0)) })
            }
        } catch is ThreadsLoop.SliceEnded {}
        h.clock = Date(timeIntervalSince1970: 1080)
        do {
            try await ThreadsLoop.run(state: state, round: { _, _, _, kind, _ in
                XCTAssertEqual(kind, .ordinary)
                throw Stop.done
            }, closeThreads: {}, event: { _ in }, plan: { XCTFail("Must keep original plan"); return [] },
                now: { h.clock }, sleep: { h.clock.addTimeInterval(TimeInterval($0)) })
        } catch Stop.done {}
    }

    func testFourHourRestIsNotResetByChangingProfiles() async throws {
        let state = ThreadsLoop.State(), h = Harness()
        var plans = 0
        func visit(start: TimeInterval, end: TimeInterval) async throws {
            h.clock = Date(timeIntervalSince1970: start)
            do {
                try await ThreadsRunContext.$deadline.withValue(Date(timeIntervalSince1970: end)) {
                    try await ThreadsLoop.run(state: state, round: { _, _, _, _, _ in
                        h.clock.addTimeInterval(10)
                        return .init(submitted: true, readyForNext: true, message: "fixture")
                    }, closeThreads: {}, event: { _ in }, plan: {
                        plans += 1; return ThreadsLoop.makePlan { $0.lowerBound }
                    }, cooldown: { 180 }, now: { h.clock }, sleep: { h.clock.addTimeInterval(TimeInterval($0)) })
                }
            } catch is ThreadsLoop.SliceEnded {}
        }
        try await visit(start: 0, end: 10860)
        XCTAssertEqual(state.restUntil, Date(timeIntervalSince1970: 25200))
        XCTAssertEqual(state.counts.promotions, 5)
        try await visit(start: 20000, end: 20300)
        XCTAssertEqual(state.restUntil, Date(timeIntervalSince1970: 25200))
        XCTAssertEqual(plans, 1)
        try await visit(start: 25200, end: 25500)
        XCTAssertEqual(state.cycle, 2)
        XCTAssertEqual(plans, 2)
        XCTAssertEqual(state.counts.promotions, 1)
    }

    func testSliceBoundaryBlocksActionsEvenWithoutAWindowDeadline() throws {
        let end = Date(timeIntervalSince1970: 300)
        try ThreadsRunContext.$deadline.withValue(end) {
            XCTAssertNoThrow(try ThreadsLoop.checkDeadline(nil, now: end.addingTimeInterval(-1)))
            XCTAssertThrowsError(try ThreadsLoop.checkDeadline(nil, now: end)) { XCTAssertTrue($0 is ThreadsLoop.SliceEnded) }
        }
    }
}
