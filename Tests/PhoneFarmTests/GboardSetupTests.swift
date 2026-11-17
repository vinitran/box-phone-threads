import XCTest
@testable import PhoneFarm

@MainActor
final class GboardSetupTests: XCTestCase {
    private let component = "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"

    private func fixture(alreadySelected: Bool = false, changesUser: Bool = false, failsEnable: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gboard-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if alreadySelected { FileManager.default.createFile(atPath: folder.appendingPathComponent("selected").path, contents: Data()) }
        let script = """
        #!/bin/sh
        qa_dir='\(folder.path)'
        printf '%s\\n' "$*" >> "$qa_dir/log"
        if [ "$4" = am ]; then
          qa_count=0
          if [ -f "$qa_dir/count" ]; then qa_count=$(cat "$qa_dir/count"); fi
          qa_count=$((qa_count + 1))
          printf '%s' "$qa_count" > "$qa_dir/count"
          if [ '\(changesUser)' = true ] && [ "$qa_count" -ge 3 ]; then printf '18\\n'; else printf '17\\n'; fi
        elif [ "$4" = ime ] && [ "$5" = list ]; then
          printf '\(component)\\n'
        elif [ "$4" = settings ]; then
          if [ -f "$qa_dir/selected" ]; then printf '\(component)\\n'; else printf 'com.android.inputmethod.latin/.LatinIME\\n'; fi
        elif [ "$4" = ime ] && [ "$5" = enable ]; then
          if [ '\(failsEnable)' = true ]; then exit 1; fi
        elif [ "$4" = ime ] && [ "$5" = set ]; then
          touch "$qa_dir/selected"
        fi
        """
        let adb = folder.appendingPathComponent("adb")
        XCTAssertTrue(FileManager.default.createFile(atPath: adb.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]))
        return adb
    }
    private func log(_ adb: URL) throws -> String { try String(contentsOf: adb.deletingLastPathComponent().appendingPathComponent("log")) }

    func testAOSPIsAutomaticallyReplacedOnlyForTheNumericCurrentUser() async throws {
        let adb = try fixture(); defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        try await GboardSetup.selectDefault(AppBundles.gboard.package, adb: adb, serial: "fixture")
        let calls = try log(adb)
        XCTAssertTrue(calls.contains("ime enable --user 17 " + component))
        XCTAssertTrue(calls.contains("ime set --user 17 " + component))
        XCTAssertFalse(calls.contains("--user current"))
        XCTAssertFalse(calls.contains("--user 0"))
    }
    func testAlreadySelectedKeyboardDoesNotToggleItAgain() async throws {
        let adb = try fixture(alreadySelected: true); defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        try await GboardSetup.selectDefault(AppBundles.gboard.package, adb: adb, serial: "fixture")
        XCTAssertFalse(try log(adb).contains("ime set"))
    }
    func testForegroundUserChangeStopsBeforeAnyKeyboardMutation() async throws {
        let adb = try fixture(changesUser: true); defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        do {
            try await GboardSetup.selectDefault(AppBundles.gboard.package, adb: adb, serial: "fixture")
            XCTFail("Must stop")
        } catch { XCTAssertEqual(error as? ROMError, .wrongProfile) }
        let calls = try log(adb)
        XCTAssertFalse(calls.contains("ime enable")); XCTAssertFalse(calls.contains("ime set"))
    }
    func testFailedEnableDoesNotProceedToSelectKeyboard() async throws {
        let adb = try fixture(failsEnable: true); defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        do {
            try await GboardSetup.selectDefault(AppBundles.gboard.package, adb: adb, serial: "fixture")
            XCTFail("Must fail")
        } catch { XCTAssertTrue(error is TypingError) }
        XCTAssertFalse(try log(adb).contains("ime set"))
    }
    func testPinnedROMAccountMismatchCannotEnableAnotherUsersKeyboard() async throws {
        let serial = UUID().uuidString, adb = try fixture()
        defer {
            ROMRuntime.shared.set(serial, managed: false, session: nil)
            try? FileManager.default.removeItem(at: adb.deletingLastPathComponent())
        }
        ROMRuntime.shared.set(serial, managed: true, session: ROMSession(profileID: UUID().uuidString, userID: 10))
        do {
            try await GboardSetup.selectDefault(AppBundles.gboard.package, adb: adb, serial: serial)
            XCTFail("Must fail")
        } catch { XCTAssertEqual(error as? ROMError, .wrongProfile) }
        XCTAssertFalse(try log(adb).contains("ime enable"))
    }
}
