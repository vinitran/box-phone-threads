import XCTest
@testable import PhoneFarm

@MainActor
final class ProfileBioWorkflowTests: XCTestCase {
    private enum Failure: Error { case fixture }

    func testBioIsTypedBeforeSavingAndUsesTheSamePreparedTextAtEveryStep() async throws {
        var stages: [String] = [], values: [String] = []
        let status = try await ProfileBioWorkflow.run(bio: "Trân trọng 3 điều giản dị!", prepare: {
            stages.append("prepare"); values.append($0)
        }, type: {
            XCTAssertEqual(stages, ["prepare"])
            XCTAssertNoThrow(try Telex.keys(for: $0))
            stages.append("type"); values.append($0)
        }, save: {
            XCTAssertEqual(stages, ["prepare", "type"])
            stages.append("save"); values.append($0); return "bio_saved"
        })
        XCTAssertEqual(status, "bio_saved")
        XCTAssertEqual(stages, ["prepare", "type", "save"])
        XCTAssertEqual(Set(values), ["Trân trọng ba điều giản dị."])
    }

    func testInvalidBioDoesNotTouchThePhone() async throws {
        for bio in ["", "😀", "hai\ndòng", String(repeating: "a", count: 151)] {
            do {
                _ = try await ProfileBioWorkflow.run(bio: bio, prepare: { _ in XCTFail() }, type: { _ in XCTFail() }, save: { _ in XCTFail(); return "" })
                XCTFail("Must reject before opening editor")
            } catch { XCTAssertTrue(error is ProfileAutomation.ProfileError) }
        }
    }

    func testPreparationOrTypingFailureCannotSavePartiallyTypedBio() async throws {
        for failPreparation in [true, false] {
            var typed = false
            do {
                _ = try await ProfileBioWorkflow.run(bio: "Bình an mỗi ngày", prepare: { _ in
                    if failPreparation { throw Failure.fixture }
                }, type: { _ in typed = true; throw Failure.fixture }, save: { _ in XCTFail("Must not save"); return "" })
                XCTFail("Must throw")
            } catch Failure.fixture {}
            XCTAssertEqual(typed, !failPreparation)
        }
    }

    func testStopAfterTypingCannotTapSave() async throws {
        let task = Task {
            try await ProfileBioWorkflow.run(bio: "Bình an mỗi ngày", prepare: { _ in }, type: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }, save: { _ in XCTFail("Stop must prevent save"); return "" })
        }
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError {}
    }
}
