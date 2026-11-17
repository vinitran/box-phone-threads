import XCTest
@testable import PhoneFarm

/// Opt in on an authorized connected phone. Uses two existing users, creates only disposable
/// photos/marker files, and restores the original user even if an assertion or API operation fails.
final class ROMProfilesLiveTests: XCTestCase {
    @MainActor
    func testExistingProfilesAndMediaSurviveRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let serial = env["PHONE_FARM_ROM_QA_SERIAL"],
              let other = env["PHONE_FARM_ROM_QA_SWITCH_USER"].flatMap(Int.init) else {
            throw XCTSkip("Set PHONE_FARM_ROM_QA_SERIAL and PHONE_FARM_ROM_QA_SWITCH_USER to opt in")
        }
        let adb = try XCTUnwrap(ToolPaths.adb())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dex = root.appendingPathComponent(".build/Phone Farm.app/Contents/Resources/KeyboardReader.dex")
        let images = ["hoan-xu-05.png", "app_store.png", "hoan-xu-11.png"].map {
            root.appendingPathComponent("Resources/ThreadsDefaults/images/" + $0)
        }
        let client = ROMProfilesClient(adb: adb, serial: serial)
        let baseline = try await client.list()
        let original = try XCTUnwrap(baseline.active)
        let alternate = try XCTUnwrap(baseline.profiles.first { $0.userID == other && $0.userID != original.userID })
        XCTAssertNotEqual(original.proxy?.address, alternate.proxy?.address)
        let blockedUser = env["PHONE_FARM_ROM_QA_EXPECT_BLOCKED_USER"].flatMap(Int.init)
        let markerName = "pf-qa-" + UUID().uuidString
        var photos: [Int: ThreadsAttachments.Batch] = [:]
        func bind(_ profile: ROMProfile) {
            ROMRuntime.shared.set(serial, managed: true, session: ROMSession(profileID: profile.id, userID: profile.userID))
        }
        func shell(_ script: String) async throws -> CommandResult {
            let quote = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "su", "-c", quote])).result(timeout: 30)
        }
        func markerPath(_ profile: ROMProfile) -> String {
            "/data/user/\(profile.userID)/vn.romprofiles.probe/\(markerName)"
        }
        func network(_ profile: ROMProfile) async throws -> String? {
            var lastError: Error = ROMError.notProtected
            for attempt in 0..<3 {
                do {
                    let verified = try await client.call(ROMRequest(operation: "network.verify", userId: profile.userID), timeout: 90)
                    try verified.data.write(to: root.appendingPathComponent(".build/rom-integration-qa/live-network-\(profile.userID).json"))
                    if profile.userID == blockedUser {
                        XCTAssertFalse(verified.passed, "Expected the invalid proxy to stay blocked")
                        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: verified.data) as? [String: Any])
                        let guardData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["networkGuard"]))
                        XCTAssertTrue(try JSONDecoder().decode(ROMNetworkGuard.self, from: guardData).protects(profile.userID))
                        return nil
                    }
                    guard verified.passed else { throw ROMError.notProtected }
                    let egress = try await client.call(ROMRequest(operation: "proxy.egress", userId: profile.userID), timeout: 60)
                    return try XCTUnwrap(egress.egressIP)
                } catch { lastError = error }
                if attempt < 2 { try await Task.sleep(for: .seconds(3)) }
            }
            throw lastError
        }
        func cleanup() async throws {
            let state = try await client.list()
            if let current = state.active { _ = try await shell("rm -f \(markerPath(current))") }
            if let current = state.active, let batch = photos[current.userID] {
                bind(current)
                let removed = await ThreadsAttachments.remove(batch, adb: adb, serial: serial)
                XCTAssertTrue(removed)
                photos.removeValue(forKey: current.userID)
            }
            if state.activeUser != original.userID {
                _ = try await client.call(ROMRequest(operation: "profile.activate", userId: original.userID, backupCurrent: true), timeout: 600)
            }
            bind(original)
            if let batch = photos[original.userID] {
                let removed = await ThreadsAttachments.remove(batch, adb: adb, serial: serial)
                XCTAssertTrue(removed)
            }
            _ = try await shell("rm -f \(markerPath(original)) \(markerPath(alternate))")
            ROMRuntime.shared.set(serial, managed: false, session: nil)
        }
        do {
            bind(original)
            let ipA = try await network(original)
            let createdA = try await shell("printf original > \(markerPath(original)) && test \"$(cat \(markerPath(original)))\" = original")
            XCTAssertEqual(createdA.status, 0)
            photos[original.userID] = try await ThreadsAttachments.prepare(adb: adb, serial: serial, images: images) { _ in }
            let batchA = try XCTUnwrap(photos[original.userID])
            XCTAssertTrue(batchA.paths.allSatisfy { $0.hasPrefix("/storage/emulated/\(original.userID)/Pictures/") })
            _ = try await client.call(ROMRequest(operation: "profile.activate", userId: alternate.userID, backupCurrent: true), timeout: 600)
            let switched = try await client.list()
            XCTAssertEqual(switched.active?.id, alternate.id)
            XCTAssertEqual(switched.profiles.count, baseline.profiles.count)
            bind(alternate)
            let ipB = try await network(alternate)
            if alternate.userID == blockedUser { XCTAssertNil(ipB) } else { XCTAssertNotEqual(ipA, ipB) }
            let wrongUserRemoval = await ThreadsAttachments.remove(batchA, adb: adb, serial: serial)
            XCTAssertFalse(wrongUserRemoval, "Cannot delete A's photos from B")
            let absent = try await shell("content query --user \(alternate.userID) --uri content://media/external/images/media --projection _id --where \"relative_path='Pictures/\(batchA.album)/'\"")
            XCTAssertFalse(absent.output.contains("_id="))
            let createdB = try await shell("printf alternate > \(markerPath(alternate)) && test \"$(cat \(markerPath(alternate)))\" = alternate")
            XCTAssertEqual(createdB.status, 0)
            photos[alternate.userID] = try await ThreadsAttachments.prepare(adb: adb, serial: serial, images: images) { _ in }
            let batchB = try XCTUnwrap(photos[alternate.userID])
            let removedB = await ThreadsAttachments.remove(batchB, adb: adb, serial: serial)
            XCTAssertTrue(removedB)
            photos.removeValue(forKey: alternate.userID)
            _ = try await shell("rm -f \(markerPath(alternate))")
            _ = try await client.call(ROMRequest(operation: "profile.activate", userId: original.userID, backupCurrent: true), timeout: 600)
            bind(original)
            let restored = try await client.list()
            XCTAssertEqual(restored.active?.id, original.id)
            XCTAssertEqual(restored.profiles.map(\.id), baseline.profiles.map(\.id))
            try await ThreadsAttachments.verify(batchA, adb: adb, serial: serial)
            let restoredIP = try await network(original)
            XCTAssertEqual(restoredIP, ipA)
            let markers = try await shell("test \"$(cat \(markerPath(original)))\" = original")
            XCTAssertEqual(markers.status, 0)
            let read = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .keyboard, readerURL: dex)
            XCTAssertEqual(read.status, 0, "Read-only UiAutomation works in the secondary user")
            let fencePath = "/data/local/tmp/pf-qa-fence-" + UUID().uuidString + ".dex"
            let push = await (try RunningCommand(adb, arguments: ["-s", serial, "push", dex.path, fencePath])).result(timeout: 10)
            XCTAssertEqual(push.status, 0)
            let fenced = await (try RunningCommand(adb, arguments: ["-s", serial, "shell",
                "chmod 444 \(fencePath) && CLASSPATH=\(fencePath) PF_EXPECTED_USER=999 app_process /system/bin KeyboardReader"])).result(timeout: 10)
            XCTAssertNotEqual(fenced.status, 0)
            XCTAssertTrue(fenced.output.contains("profile_changed"))
            _ = try await shell("rm -f \(fencePath)")
        } catch {
            try await cleanup()
            throw error
        }
        try await cleanup()
        let final = try await client.list()
        XCTAssertEqual(final.activeUser, baseline.activeUser)
        XCTAssertEqual(final.profiles.count, baseline.profiles.count)
    }
}
