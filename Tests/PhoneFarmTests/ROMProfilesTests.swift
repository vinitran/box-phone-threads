import XCTest
@testable import PhoneFarm

final class ROMProfilesTests: XCTestCase {
    func testProxyPasteSupportsAuthenticationAndColonInPassword() throws {
        let proxy = try ROMProxyConfiguration(line: "  proxy.example:11419:fixture-user:fixture:password\n")
        XCTAssertEqual(proxy.host, "proxy.example")
        XCTAssertEqual(proxy.port, 11419)
        XCTAssertEqual(proxy.username, "fixture-user")
        XCTAssertEqual(proxy.password, "fixture:password")
        XCTAssertEqual(try ROMProxyConfiguration(line: "proxy.example:8080").username, "")
        for invalid in ["", "proxy.example", "proxy.example:8080:user", "proxy.example:0:u:p", "proxy.example:8080::password", "proxy..example:8080", "proxy.example:8080:u:p\nsecond-line"] {
            XCTAssertThrowsError(try ROMProxyConfiguration(line: invalid))
        }
        XCTAssertThrowsError(try ROMProxyConfiguration(line: "proxy.example:8080:" + String(repeating: "a", count: 257) + ":p"))
        XCTAssertThrowsError(try ROMProxyConfiguration(line: "proxy.example:8080:u:" + String(repeating: "a", count: 1025)))
    }

    func testCreationProxyErrorsAreActionableAndDoNotEchoSecrets() async throws {
        for (code, expected) in [("PROXY_REQUIRED", ROMError.proxyRequired), ("PROXY_TEST_FAILED", .proxyTestFailed), ("DUPLICATE_PROXY", .duplicateProxy)] {
            let client = ROMProfilesClient { _, _ in
                CommandResult(status: 1, data: Data("{\"apiVersion\":1,\"ok\":false,\"errorCode\":\"\(code)\",\"error\":\"fixture-secret\"}".utf8))
            }
            do {
                _ = try await client.call(ROMRequest(operation: "profile.create"))
                XCTFail("Must reject")
            } catch {
                XCTAssertEqual(error as? ROMError, expected)
                XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
            }
        }
    }

    func testDeletionBindsConfirmationToExactUUIDAndUnknownResultNeverRetries() async throws {
        let id = UUID().uuidString
        let client = ROMProfilesClient { data, _ in
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(object["operation"] as? String, "profile.delete")
            XCTAssertEqual(object["userId"] as? Int, 14)
            XCTAssertEqual(object["expectedProfileId"] as? String, id)
            XCTAssertEqual(object["confirmDeletion"] as? Bool, true)
            return CommandResult(status: 1, data: Data(#"{"apiVersion":1,"ok":false,"errorCode":"RESULT_UNKNOWN"}"#.utf8))
        }
        // A separate counting transport proves that an explicit uncertain response is not retried.
        let counted = Responses([CommandResult(status: 1, data: Data(#"{"apiVersion":1,"ok":false,"errorCode":"RESULT_UNKNOWN"}"#.utf8))])
        for candidate in [client, ROMProfilesClient { data, _ in await counted.next(data) }] {
            do {
                _ = try await candidate.call(ROMRequest(operation: "profile.delete", userId: 14, expectedProfileId: id, confirmDeletion: true))
                XCTFail("Must reconcile")
            } catch { XCTAssertEqual(error as? ROMError, .resultUnknown) }
        }
        let count = await counted.calls
        XCTAssertEqual(count, 1)
    }

    func testOldEngineRosterStillDecodesAndPendingProfilesCannotRotate() throws {
        let id = UUID().uuidString
        let old = Data("{\"activeUser\":15,\"maxProfiles\":16,\"profiles\":[{\"id\":\"\(id)\",\"userId\":15,\"name\":\"QA\",\"proxy\":{\"type\":\"http\",\"host\":\"proxy.example\",\"port\":8080,\"routing\":\"enforced\",\"transport\":\"device\"}}]}".utf8)
        let list = try JSONDecoder().decode(ROMProfileList.self, from: old)
        XCTAssertNil(list.capabilities)
        XCTAssertTrue(try XCTUnwrap(list.active).canRotate)
        var pending = try XCTUnwrap(list.active); pending.state = "deleting"
        XCTAssertFalse(pending.canRotate)
        pending.state = "initializing"; XCTAssertFalse(pending.canRotate)
    }
    private actor Responses {
        var calls = 0
        var requests: [Data] = []
        let responses: [CommandResult]
        init(_ responses: [CommandResult]) { self.responses = responses }
        func next(_ request: Data) -> CommandResult {
            requests.append(request)
            defer { calls += 1 }
            return responses[min(calls, responses.count - 1)]
        }
    }
    private func result(_ json: String, status: Int32 = 0) -> CommandResult {
        CommandResult(status: status, data: Data(json.utf8))
    }

    func testOnlyBusyRetriesEvenWhenBackendExitsOne() async throws {
        let responses = Responses([
            result(#"{"ok":false,"apiVersion":1,"errorCode":"BUSY"}"#, status: 1),
            result(#"{"ok":true,"apiVersion":1}"#)
        ])
        let client = ROMProfilesClient { data, _ in await responses.next(data) }
        _ = try await client.call(ROMRequest(operation: "profile.activate", userId: 12, backupCurrent: true))
        let calls = await responses.calls
        XCTAssertEqual(calls, 2)
        let requests = await responses.requests
        XCTAssertEqual(requests.first, requests.last)
    }

    func testUnknownMutationIsNeverRetried() async throws {
        for response in [result("", status: 15), result("not-json"), result(#"{"ok":true,"apiVersion":2}"#)] {
            let responses = Responses([response])
            let client = ROMProfilesClient { data, _ in await responses.next(data) }
            do {
                _ = try await client.call(ROMRequest(operation: "profile.create"))
                XCTFail("Should reject an unknown result")
            } catch { XCTAssertTrue(error is ROMError) }
            let calls = await responses.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testProxyCredentialsStayInJSONAndErrorsAreRedacted() async throws {
        let proxy = try ROMProxyConfiguration(host: "proxy.example.com", port: "3128", username: "username-sentinel", password: "secret-sentinel'$(test)")
        let responses = Responses([result(#"{"ok":false,"apiVersion":1,"errorCode":"DEVICE_ERROR","error":"secret-sentinel"}"#, status: 1)])
        let client = ROMProfilesClient { data, _ in await responses.next(data) }
        do {
            _ = try await client.call(ROMRequest(operation: "proxy.set", userId: 10, proxy: proxy))
            XCTFail("Should fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("secret-sentinel")) }
        let requests = await responses.requests
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0]) as? [String: Any])
        let encoded = try XCTUnwrap(object["proxy"] as? [String: Any])
        XCTAssertEqual(encoded["password"] as? String, proxy.password)
        XCTAssertEqual(encoded["routing"] as? String, "enforced")
        XCTAssertEqual(encoded["transport"] as? String, "device")
        XCTAssertThrowsError(try ROMProxyConfiguration(host: "$(bad)", port: "3128", username: "", password: ""))
        XCTAssertThrowsError(try ROMProxyConfiguration(host: "proxy.example", port: "65536", username: "", password: ""))
        XCTAssertThrowsError(try ROMProxyConfiguration(host: "proxy.example", port: "3128", username: "u:p", password: ""))
    }

    func testNetworkRequiresPassedAndNestedEgressHTTP200() throws {
        let failed = ROMReply(data: Data(#"{"ok":true,"passed":false}"#.utf8))
        XCTAssertFalse(failed.passed)
        let egress = ROMReply(data: Data(#"{"report":{"httpStatus":200,"egress":{"ip":"203.0.113.10"}}}"#.utf8))
        XCTAssertEqual(egress.egressIP, "203.0.113.10")
        let error = ROMReply(data: Data(#"{"report":{"httpStatus":407,"egress":{"ip":"203.0.113.10"}}}"#.utf8))
        XCTAssertNil(error.egressIP)
        let guardData = Data(#"{"required":true,"engineRunning":true,"ipv4Guard":true,"ipv6Guard":true,"tcpDnsRedirect":true,"protectedUserId":12,"inactiveUserApps":"blocked"}"#.utf8)
        let network = try JSONDecoder().decode(ROMNetworkGuard.self, from: guardData)
        XCTAssertTrue(network.protects(12))
        XCTAssertFalse(network.protects(13))
    }

    func testProxyAuthenticationFailureHasActionableRedactedMessage() async throws {
        let client = ROMProfilesClient { _, _ in
            CommandResult(status: 1, data: Data(#"{"ok":false,"apiVersion":1,"errorCode":"DEVICE_ERROR","error":"Upstream proxy CONNECT status 407 secret-sentinel"}"#.utf8))
        }
        do {
            _ = try await client.call(ROMRequest(operation: "proxy.test"))
            XCTFail("Must fail")
        } catch {
            XCTAssertEqual(error as? ROMError, .proxyAuthentication)
            XCTAssertFalse(error.localizedDescription.contains("secret-sentinel"))
        }
    }

    func testPhotoVerificationRefusesAnotherProfileBeforeCallingADB() async throws {
        let serial = UUID().uuidString
        defer { ROMRuntime.shared.set(serial, managed: false, session: nil) }
        let current = ROMSession(profileID: UUID().uuidString, userID: 11)
        ROMRuntime.shared.set(serial, managed: true, session: current)
        let batch = ThreadsAttachments.Batch(album: "PF-" + String(repeating: "a", count: 32), ids: [1, 2, 3], paths: [], profileID: UUID().uuidString, userID: 10)
        do {
            try await ThreadsAttachments.verify(batch, adb: URL(fileURLWithPath: "/bin/false"), serial: serial)
            XCTFail("Must reject foreign photos")
        } catch { XCTAssertEqual(error as? ROMError, .wrongProfile) }
    }

    func testTaskRemainsPinnedAfterRegistryChangesAndDuringSwitch() async throws {
        let runtime = ROMRuntime.shared
        let serial = "test-" + UUID().uuidString
        defer { runtime.set(serial, managed: false, session: nil) }
        let first = ROMSession(profileID: UUID().uuidString, userID: 10)
        let second = ROMSession(profileID: UUID().uuidString, userID: 11)
        runtime.set(serial, managed: true, session: first)
        try ROMTaskContext.$session.withValue(first) {
            XCTAssertEqual(try runtime.session(serial), first)
            runtime.set(serial, managed: true, session: second)
            XCTAssertThrowsError(try runtime.session(serial))
            XCTAssertThrowsError(try runtime.namespace(serial))
        }
        runtime.set(serial, managed: true, session: nil)
        XCTAssertThrowsError(try runtime.session(serial))
        XCTAssertThrowsError(try runtime.namespace(serial))
    }

    @MainActor
    func testReplyReservationsAndPhotoQueuesAreSeparateAndPersistWhenSwitchingBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try PhoneFarmStore(databaseURL: folder.appendingPathComponent("test.sqlite3"))
        let serial = "test-" + UUID().uuidString
        let runtime = ROMRuntime.shared
        defer { runtime.set(serial, managed: false, session: nil) }
        try store.remember([AndroidDevice(serial: serial, name: "QA", status: "device")])
        let first = ROMSession(profileID: UUID().uuidString, userID: 10)
        let second = ROMSession(profileID: UUID().uuidString, userID: 11)
        runtime.set(serial, managed: true, session: first)
        XCTAssertTrue(try store.reserveReply(serial: serial, postID: "same-post"))
        XCTAssertFalse(try store.reserveReply(serial: serial, postID: "same-post"))
        let batch = ThreadsAttachments.Batch(album: "PF-" + String(repeating: "a", count: 32), ids: [1, 2, 3], paths: [], profileID: first.profileID, userID: 10)
        try store.queueSubmittedPhotos(batch, serial: serial)
        let cache = ThreadsAttachments.ImageCache(album: "PF-CACHE-" + String(repeating: "b", count: 32))
        try store.saveImageCache(cache, serial: serial)
        runtime.set(serial, managed: true, session: second)
        XCTAssertTrue(try store.attemptedReplies(serial: serial).isEmpty)
        XCTAssertTrue(try store.submittedPhotos(serial: serial).isEmpty)
        XCTAssertNil(try store.imageCache(serial: serial))
        XCTAssertTrue(try store.reserveReply(serial: serial, postID: "same-post"))
        runtime.set(serial, managed: true, session: first)
        XCTAssertEqual(try store.attemptedReplies(serial: serial), ["same-post"])
        XCTAssertEqual(try store.submittedPhotos(serial: serial).count, 1)
        XCTAssertEqual(try store.imageCache(serial: serial)?.album, cache.album)
    }

    func testRunningCommandWritesJSONToStdinThenClosesIt() async throws {
        let payload = Data(#"{"password":"secret'$(printf test)","operation":"profile.list"}"#.utf8)
        let command = try RunningCommand(URL(fileURLWithPath: "/bin/cat"), arguments: [], input: payload)
        let result = await command.result(timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.data, payload)
    }

    func testPackageQueryResolvesCurrentToNumericAndroidUser() async throws {
        let adb = FileManager.default.temporaryDirectory.appendingPathComponent("fake-adb-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: adb) }
        let script = """
        #!/bin/sh
        if [ "$4" = am ]; then
            printf '12\\n'
        elif [ "$4" = pm ] && [ "$8" = 12 ]; then
            printf 'package:com.google.android.inputmethod.latin\\npackage:com.instagram.barcelona\\n'
        fi
        """
        XCTAssertTrue(FileManager.default.createFile(atPath: adb.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]))
        let packages = await AppBundles.installedPackages(adb: adb, serial: "test-device")
        XCTAssertEqual(packages, ["com.google.android.inputmethod.latin", "com.instagram.barcelona"])
    }
}
