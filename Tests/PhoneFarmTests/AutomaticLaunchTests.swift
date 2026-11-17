import XCTest
@testable import PhoneFarm

final class AutomaticLaunchTests: XCTestCase {
    func testLaunchRequiresExplicitFlagAndTwoDistinctNumericUsers() throws {
        XCTAssertNil(try AutomaticLaunchRequest.parse([]))
        XCTAssertNil(try AutomaticLaunchRequest.parse(["ordinary-launch"]))
        XCTAssertEqual(try AutomaticLaunchRequest.parse(["--run-two-profiles", "test-device", "16", "17"]),
                       AutomaticLaunchRequest(serial: "test-device", users: [16, 17]))
        for args in [
            ["--run-two-profiles", "test-device", "16", "16"],
            ["--run-two-profiles", "test-device", "-1", "17"],
            ["--run-two-profiles", "bad;command", "16", "17"],
            ["--run-two-profiles", "test-device", "16", "17", "password-must-not-be-an-argument"],
            ["--run-two-profiles", "test-device", "16"]
        ] { XCTAssertThrowsError(try AutomaticLaunchRequest.parse(args)) }
    }
}
