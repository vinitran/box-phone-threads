import XCTest
@testable import PhoneFarm

@MainActor
final class ROMProfileAlternationTests: XCTestCase {
    private enum Stop: ThreadsLoopStop { case done }
    private final class Clock {
        var date = Date(timeIntervalSince1970: 0)
        var uptime: TimeInterval { date.timeIntervalSince1970 }
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    }
    private func profile(_ user: Int) -> ROMProfile {
        .init(id: UUID().uuidString, userId: user, name: "P\(user)",
              proxy: .init(type: "http", host: "proxy\(user).example", port: 8080,
                           routing: "enforced", transport: "device", authenticated: true))
    }

    func testRealLoopSharesFourWindowsWithoutInterruptingRoundsOrShortWaits() async throws {
        let a = profile(0), b = profile(10), clock = Clock()
        var current = a.id, prepared: [(String, Date)] = [], sent: [(String, Int, ThreadsCommentKind, Date)] = []
        var rests: [String: Date] = [:], planCalls = 0, completed = 0
        var closes: [String: Int] = [:], instance: [String: ObjectIdentifier] = [:]
        var waits: [(Date, Date)] = []
        do {
            try await ROMProfileAlternation.run(profiles: [a, b], startingAt: a.id, prepare: { target in
                if completed == 4 { throw Stop.done }
                if let prior = prepared.last { XCTAssertGreaterThan(closes[prior.0, default: 0], 0) }
                prepared.append((target.id, clock.date))
                if current != target.id { clock.advance(180); current = target.id }
            }, runWindow: { target, state in
                if let prior = instance[target.id] { XCTAssertEqual(ObjectIdentifier(state), prior) }
                instance[target.id] = ObjectIdentifier(state)
                if let ready = rests[target.id] { XCTAssertGreaterThanOrEqual(clock.date, ready) }
                do {
                    try await ThreadsLoop.run(state: state, yieldAtCycleRest: true, round: { _, cycle, _, kind, deadline in
                        XCTAssertNil(ThreadsRunContext.deadline, "A long window has no five-minute interruption")
                        XCTAssertLessThan(clock.date, deadline)
                        sent.append((target.id, cycle, kind, clock.date))
                        clock.advance(420) // A complete comment can take longer than five minutes.
                        return .init(submitted: true, readyForNext: true, message: "fixture")
                    }, closeThreads: {}, event: { _ in }, plan: {
                        planCalls += 1
                        return ThreadsLoop.makePlan { planCalls % 2 == 1 ? $0.lowerBound : $0.upperBound }
                    }, cooldown: { 180 }, now: { clock.date }, sleep: { clock.advance(TimeInterval($0)) })
                } catch let rest as ThreadsLoop.CycleRest {
                    XCTAssertEqual(rest.until.timeIntervalSince(clock.date), 14400)
                    XCTAssertNil(state.graceEnd)
                    XCTAssertEqual(state.counts.promotions, 5)
                    rests[target.id] = rest.until; completed += 1
                    throw rest
                }
            }, stopSession: { target in closes[target.id, default: 0] += 1; return true }, event: { _ in },
                now: { clock.date }, uptime: { clock.uptime }, sleepUntil: { until in
                    waits.append((clock.date, until)); clock.date = until
                })
        } catch Stop.done {}
        XCTAssertEqual(prepared.map(\.0), [a.id, b.id, a.id, b.id])
        XCTAssertEqual(planCalls, 4)
        XCTAssertEqual(sent.filter { $0.2 == .promotion }.count, 20)
        XCTAssertEqual(sent.filter { $0.2 == .ordinary }.count, 30)
        XCTAssertEqual(prepared[1].1.timeIntervalSince1970, 10800)
        XCTAssertEqual(prepared[2].1.timeIntervalSince1970, 25200 - 210, "Preparation uses the measured 180 seconds plus margin")
        XCTAssertEqual(sent.first { $0.0 == a.id && $0.1 == 2 }?.3.timeIntervalSince1970, 25200)
        XCTAssertTrue(waits.contains { $0.1.timeIntervalSince($0.0) > 3000 }, "Both accounts rest without repeatedly switching")
    }

    func testSlowSwitchMeasuredAndNeverShortensRestOrWorkWindow() async throws {
        let a = profile(10), b = profile(11), clock = Clock()
        var starts: [(String, Date)] = [], prepared: [(String, Date)] = [], ready: [String: Date] = [:]
        var physical = a.id, closed: String?
        do {
            try await ROMProfileAlternation.run(profiles: [a, b], startingAt: a.id, prepare: { target in
                if starts.count == 3 { throw Stop.done }
                if !starts.isEmpty { XCTAssertNotNil(closed) }
                prepared.append((target.id, clock.date))
                if physical != target.id { clock.advance(600); physical = target.id }
            }, runWindow: { target, state in
                if let required = ready[target.id] { XCTAssertGreaterThanOrEqual(clock.date, required) }
                starts.append((target.id, clock.date)); closed = nil
                clock.advance(10800)
                state.restUntil = clock.date.addingTimeInterval(14400); ready[target.id] = state.restUntil
                throw ThreadsLoop.CycleRest(until: state.restUntil!)
            }, stopSession: { target in closed = target.id; return true }, event: { _ in },
                now: { clock.date }, uptime: { clock.uptime }, sleepUntil: { clock.date = $0 })
        } catch Stop.done {}
        XCTAssertEqual(starts.map(\.0), [a.id, b.id, a.id])
        XCTAssertEqual(starts[1].1.timeIntervalSince1970, 11400)
        XCTAssertEqual(prepared[2].1.timeIntervalSince1970, 25200 - 630)
        XCTAssertEqual(starts[2].1.timeIntervalSince1970, 25200)
    }

    func testFailedFinalCloseBlocksEveryFurtherPreparation() async throws {
        let a = profile(10), b = profile(11), clock = Clock()
        var prepares = 0
        do {
            try await ROMProfileAlternation.run(profiles: [a, b], startingAt: a.id, prepare: { _ in prepares += 1 },
                runWindow: { _, state in
                    clock.advance(10800); state.restUntil = clock.date.addingTimeInterval(14400)
                    throw ThreadsLoop.CycleRest(until: state.restUntil!)
                }, stopSession: { _ in false }, event: { _ in }, now: { clock.date })
            XCTFail("Must stop")
        } catch ROMProfileRotation.RotationError.couldNotStop {}
        XCTAssertEqual(prepares, 1)
    }

    func testUnexpectedWorkerReturnOrErrorStopsWithoutSwitching() async throws {
        for returnsNormally in [true, false] {
            let a = profile(10), b = profile(11)
            var prepares = 0, closes = 0
            do {
                try await ROMProfileAlternation.run(profiles: [a, b], startingAt: a.id, prepare: { _ in prepares += 1 },
                    runWindow: { _, _ in if !returnsNormally { throw ROMError.notProtected } },
                    stopSession: { _ in closes += 1; return true }, event: { _ in })
                XCTFail("Must stop")
            } catch {
                if returnsNormally { XCTAssertTrue(error is ROMProfileRotation.RotationError) }
                else { XCTAssertEqual(error as? ROMError, .notProtected) }
            }
            XCTAssertEqual(prepares, 1); XCTAssertEqual(closes, 1)
        }
    }

    func testStopDuringSharedRestDoesNotSwitchOrStartAnotherWindow() async throws {
        let a = profile(10), b = profile(11), clock = Clock()
        var prepares = 0, sleeping = false
        let task = Task {
            try await ROMProfileAlternation.run(profiles: [a, b], startingAt: a.id, prepare: { _ in prepares += 1 },
                runWindow: { _, state in
                    clock.advance(10800); state.restUntil = clock.date.addingTimeInterval(14400)
                    throw ThreadsLoop.CycleRest(until: state.restUntil!)
                }, stopSession: { _ in true }, event: { _ in }, now: { clock.date }, sleepUntil: { _ in
                    sleeping = true; try await Task.sleep(for: .seconds(3600))
                })
        }
        while !sleeping { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("Must cancel") } catch is CancellationError {}
        XCTAssertEqual(prepares, 2)
    }

    func testStopWhilePreparationSettlesCannotStartAWindow() async throws {
        let a = profile(10), b = profile(11)
        var began = false, release: CheckedContinuation<Void, Never>?
        let task = Task {
            try await ROMProfileAlternation.run(profiles: [a, b], startingAt: a.id, prepare: { _ in
                began = true; await withCheckedContinuation { release = $0 }
            }, runWindow: { _, _ in XCTFail("Cannot start after Stop") }, stopSession: { _ in true }, event: { _ in })
        }
        while !began { await Task.yield() }
        task.cancel(); release?.resume()
        do { try await task.value; XCTFail("Must cancel") } catch is CancellationError {}
    }

    func testBadSelectionOrProxyFailsBeforePreparation() async throws {
        let a = profile(10), b = profile(11)
        var missing = b; missing = ROMProfile(id: b.id, userId: b.userID, name: b.name, proxy: nil)
        for selection in [[a], [a, b, profile(12)], [a, a], [a, missing]] {
            do {
                try await ROMProfileAlternation.run(profiles: selection, startingAt: nil,
                    prepare: { _ in XCTFail("Invalid targets cannot activate") }, runWindow: { _, _ in XCTFail() },
                    stopSession: { _ in true }, event: { _ in })
                XCTFail("Must fail")
            } catch {}
        }
    }

    func testYieldOccursAfterGraceAndCloseAndDoesNotRegeneratePlan() async throws {
        let clock = Clock(), state = ThreadsLoop.State()
        var lastSent: Date?, lastClose: Date?, plans = 0
        for _ in 0..<2 {
            do {
                try await ThreadsLoop.run(state: state, yieldAtCycleRest: true, round: { _, _, _, _, _ in
                    lastSent = clock.date; return .init(submitted: true, readyForNext: true, message: "fixture")
                }, closeThreads: { lastClose = clock.date }, event: { _ in }, plan: {
                    plans += 1; return ThreadsLoop.makePlan { $0.lowerBound }
                }, now: { clock.date }, sleep: { clock.advance(TimeInterval($0)) })
                XCTFail("Must yield on rest")
            } catch let rest as ThreadsLoop.CycleRest { XCTAssertEqual(rest.until, state.restUntil) }
        }
        XCTAssertEqual(plans, 1); XCTAssertEqual(state.counts.promotions, 5)
        XCTAssertGreaterThanOrEqual(lastClose!.timeIntervalSince(lastSent!), 60)
        XCTAssertEqual(clock.date.timeIntervalSince1970, 10800)
    }
}
