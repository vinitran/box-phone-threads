import XCTest
@testable import PhoneFarm

final class DeviceProfileTests: XCTestCase {
    private let snapshot = """
    [ro.product.model]: [SM-G960N]
    [ro.product.manufacturer]: [samsung]
    [ro.product.brand]: [samsung]
    [ro.product.device]: [starlteks]
    [ro.product.name]: [starlteks]
    [ro.build.version.sdk]: [29]
    [ro.build.version.release]: [10]
    [ro.build.fingerprint]: [samsung/test/test:10/TEST/123:user/release-keys]
    [persist.sys.locale]: [vi-VN]
    [persist.sys.timezone]: [Asia/Ho_Chi_Minh]
    [ril.serialnumber]: [should-not-be-copied]
    """

    func testSavedProfileCanBeSelectedAgainWithoutRegeneratingValues() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DeviceProfileRepository(directory: folder)
        let baseline = try DeviceTestProfile.capture(snapshot)
        let first = try baseline.randomized(name: "Profile 1")
        let second = try baseline.randomized(name: "Profile 2")
        var library = DeviceProfileLibrary(serial: "phone-a", selectedID: second.id, profiles: [baseline, first, second])
        try repository.save(library)
        library = try repository.load(serial: "phone-a")
        library.selectedID = first.id
        try repository.save(library)

        let reopened = try DeviceProfileRepository(directory: folder).load(serial: "phone-a")
        let restored = try XCTUnwrap(reopened.profiles.first { $0.id == reopened.selectedID })
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(restored.seed, first.seed)
        XCTAssertEqual(restored.properties, first.properties)
        XCTAssertEqual(restored.locale, first.locale)
        XCTAssertEqual(restored.timezone, first.timezone)
        XCTAssertEqual(try repository.load(serial: "phone-b").profiles.count, 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.url(serial: "phone-a").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRandomProfilesPreserveOSAndSeparateTestIdentities() throws {
        let baseline = try DeviceTestProfile.capture(snapshot)
        var seeds = Set<UUID>()
        var fingerprints = Set<String>()
        for _ in 0..<100 {
            let profile = try baseline.randomized(name: "QA")
            try profile.validate()
            XCTAssertEqual(profile.properties["ro.build.version.release"], "10")
            XCTAssertEqual(profile.properties["ro.build.version.sdk"], "29")
            XCTAssertNil(profile.properties["ril.serialnumber"])
            XCTAssertEqual(profile.properties["ro.build.tags"], "test-keys")
            let fingerprint = try XCTUnwrap(profile.properties["ro.build.fingerprint"])
            XCTAssertTrue(fingerprint.hasPrefix(profile.properties["ro.product.brand"]! + "/"))
            XCTAssertEqual(profile.properties["ro.build.id"], profile.properties["ro.build.display.id"])
            XCTAssertEqual(profile.generatorVersion, 2)
            XCTAssertTrue(profile.consistencyIssues.isEmpty)
            XCTAssertTrue(fingerprint.contains("/\(profile.properties["ro.product.device"]!):10/"))
            seeds.insert(profile.seed)
            fingerprints.insert(fingerprint)
        }
        XCTAssertEqual(seeds.count, 100)
        XCTAssertEqual(fingerprints.count, 100)
    }

    func testWrongDeviceVersionAndUnsupportedFieldsAreRejected() throws {
        let profile = try DeviceTestProfile.capture(snapshot)
        var library = DeviceProfileLibrary(serial: "phone-a", selectedID: profile.id, profiles: [profile])
        let data = try DeviceProfileRepository.encode(library)
        XCTAssertThrowsError(try DeviceProfileRepository.decode(data, serial: "phone-b"))
        library.schemaVersion = 2
        XCTAssertThrowsError(try DeviceProfileRepository.encode(library))
        library.schemaVersion = 1
        library.selectedID = UUID()
        XCTAssertThrowsError(try DeviceProfileRepository.encode(library))
        library.selectedID = profile.id
        library.profiles.append(profile)
        XCTAssertThrowsError(try DeviceProfileRepository.encode(library))
        let unsupported = DeviceTestProfile(id: UUID(), name: "Invalid", createdAt: Date(), kind: .randomized,
                                            seed: UUID(), properties: ["ro.product.model": "QA", "ro.build.version.sdk": "29", "imei": "123"],
                                            locale: "vi-VN", timezone: "Asia/Ho_Chi_Minh")
        XCTAssertThrowsError(try unsupported.validate())
    }

    func testCorruptLibraryIsPreservedAndNotReplacedByEmptyState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = DeviceProfileRepository(directory: folder)
        let corrupt = Data("{broken".utf8)
        let file = repository.url(serial: "phone-a")
        try corrupt.write(to: file)
        XCTAssertThrowsError(try repository.load(serial: "phone-a"))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertThrowsError(try DeviceTestProfile.capture("[ro.product.model]: [SM-G960N]"))
    }

    func testAndroidAPIReaderValidatesScopeAndKeepsActualValues() throws {
        let input: [String: Any] = [
            "schemaVersion": 1, "scope": "shell_process",
            "properties": ["ro.product.model": "SM-G955N", "ro.build.version.sdk": "29", "ro.build.version.release": "10"],
            "locale": "en-US", "timezone": "America/New_York"
        ]
        let profile = try DeviceTestProfile.decodeVisible(JSONSerialization.data(withJSONObject: input))
        XCTAssertEqual(profile.properties["ro.product.model"], "SM-G955N")
        XCTAssertEqual(profile.properties["ro.build.version.sdk"], "29")
        XCTAssertEqual(profile.kind, .captured)
        var wrong = input
        wrong["scope"] = "every_app"
        XCTAssertThrowsError(try DeviceTestProfile.decodeVisible(JSONSerialization.data(withJSONObject: wrong)))
        wrong = input
        wrong["properties"] = ["ro.product.model": "invalid\rvalue", "ro.build.version.sdk": "29"]
        XCTAssertThrowsError(try DeviceTestProfile.decodeVisible(JSONSerialization.data(withJSONObject: wrong)))
    }

    func testSeedReproducesAllGeneratedFieldsAndCoversEveryModelAndRegion() throws {
        let baseline = try DeviceTestProfile.capture(snapshot)
        var models: Set<String> = []
        var regions: Set<String> = []
        for number in 1...64 {
            let seed = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number)))
            let first = try baseline.randomized(name: "First", seed: seed)
            let repeated = try baseline.randomized(name: "Repeated", seed: seed)
            XCTAssertEqual(first.properties, repeated.properties)
            XCTAssertEqual(first.locale, repeated.locale)
            XCTAssertEqual(first.timezone, repeated.timezone)
            XCTAssertEqual(first.seed, seed)
            XCTAssertNotEqual(first.id, repeated.id)
            let fields = first.properties
            let fingerprint = try XCTUnwrap(fields["ro.build.fingerprint"])
            let slash = fingerprint.components(separatedBy: "/")
            XCTAssertEqual(slash.count, 6)
            XCTAssertEqual(slash[0], fields["ro.product.brand"])
            XCTAssertEqual(slash[1], fields["ro.product.name"])
            XCTAssertEqual(slash[2], "\(fields["ro.product.device"]!):\(fields["ro.build.version.release"]!)")
            XCTAssertEqual(slash[3], fields["ro.build.id"])
            XCTAssertEqual(slash[4], "\(fields["ro.build.version.incremental"]!):\(fields["ro.build.type"]!)")
            XCTAssertEqual(slash[5], fields["ro.build.tags"])
            XCTAssertNotNil(fields["ro.build.version.incremental"]?.range(of: #"^[0-9]{10}$"#, options: .regularExpression))
            models.insert(try XCTUnwrap(fields["ro.product.model"]))
            regions.insert(first.locale + "/" + first.timezone)
        }
        XCTAssertEqual(models, ["SM-G960N", "SM-G960F", "Pixel 3a", "Pixel 4"])
        XCTAssertEqual(regions.count, 4)
    }

    func testLegacyRepairKeepsProfileIdentityAndBacksUpExactOriginalBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DeviceProfileRepository(directory: folder)
        let baseline = try DeviceTestProfile.capture(snapshot)
        var values = baseline.properties
        values["ro.product.brand"] = "google"
        values["ro.product.manufacturer"] = "Google"
        values["ro.product.model"] = "Pixel 4"
        values["ro.product.name"] = "flame"
        values["ro.product.device"] = "flame"
        values["ro.build.id"] = "PFTEST"
        values["ro.build.display.id"] = "PhoneFarm-Test-old"
        values["ro.build.version.incremental"] = String(repeating: "a", count: 32)
        values["ro.build.type"] = "userdebug"
        values["ro.build.tags"] = "test-keys"
        values["ro.build.fingerprint"] = "phonefarm/flame/flame:10/PFTEST/old:userdebug/test-keys"
        let old = DeviceTestProfile(id: UUID(), name: "Profile 001", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    kind: .randomized, seed: UUID(), properties: values,
                                    locale: "en-GB", timezone: "Europe/London")
        var library = DeviceProfileLibrary(serial: "physical-adb-serial", selectedID: old.id, profiles: [old])
        try repository.save(library)
        let originalBytes = try Data(contentsOf: repository.url(serial: library.serial))
        let loaded = try repository.load(serial: library.serial)
        XCTAssertTrue(loaded.profiles[0].needsConsistencyRepair)
        XCTAssertFalse(loaded.profiles[0].consistencyIssues.isEmpty)
        let repaired = try loaded.profiles[0].normalizedQA()
        XCTAssertEqual(repaired.id, old.id)
        XCTAssertEqual(repaired.seed, old.seed)
        XCTAssertEqual(repaired.createdAt, old.createdAt)
        XCTAssertEqual(repaired.name, old.name)
        XCTAssertEqual(repaired.locale, old.locale)
        XCTAssertEqual(repaired.timezone, old.timezone)
        for key in ["ro.product.brand", "ro.product.name", "ro.product.device", "ro.product.model", "ro.build.version.release", "ro.build.version.sdk"] {
            XCTAssertEqual(repaired.properties[key], old.properties[key])
        }
        XCTAssertTrue(repaired.consistencyIssues.isEmpty)
        XCTAssertFalse(repaired.needsConsistencyRepair)
        XCTAssertEqual(try repaired.normalizedQA(), repaired)
        library.profiles[0] = repaired
        let backup = try XCTUnwrap(repository.save(library, backupExisting: true))
        XCTAssertEqual(try Data(contentsOf: backup), originalBytes)
        XCTAssertEqual(try repository.load(serial: library.serial).profiles[0], repaired)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
    }

    func testFailedBackupDoesNotReplaceSavedProfile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DeviceProfileRepository(directory: folder)
        let profile = try DeviceTestProfile.capture(snapshot).randomized(name: "QA")
        let library = DeviceProfileLibrary(serial: "phone", selectedID: profile.id, profiles: [profile])
        try repository.save(library)
        let original = try Data(contentsOf: repository.url(serial: library.serial))
        try Data("not a directory".utf8).write(to: folder.appendingPathComponent("backups"))
        var changed = library
        changed.profiles[0].name = "Changed"
        XCTAssertThrowsError(try repository.save(changed, backupExisting: true))
        XCTAssertEqual(try Data(contentsOf: repository.url(serial: library.serial)), original)
    }

    func testCapturedBuildFieldsArePreservedAndNeverNormalizedAsQA() throws {
        let input = snapshot + "\n[ro.build.id]: [OEM-ID]\n[ro.build.display.id]: [OEM-ID.vendor-display]\n[ro.build.version.incremental]: [abcdef0123456789abcdef0123456789]\n"
        let captured = try DeviceTestProfile.capture(input)
        try captured.validate()
        XCTAssertEqual(captured.properties["ro.build.display.id"], "OEM-ID.vendor-display")
        XCTAssertEqual(captured.properties["ro.build.version.incremental"], "abcdef0123456789abcdef0123456789")
        XCTAssertThrowsError(try captured.normalizedQA())
        XCTAssertNil(captured.generatorVersion)
    }

    func testNewQARejectsInconsistentFingerprintAndPreservesOtherBaselineOS() throws {
        let profile = try DeviceTestProfile.capture(snapshot).randomized(name: "QA")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: DeviceProfileRepository.encode(
            DeviceProfileLibrary(serial: "phone", profiles: [profile]))) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        var properties = try XCTUnwrap(profiles[0]["properties"] as? [String: String])
        properties["ro.product.brand"] = "mismatched"
        profiles[0]["properties"] = properties
        object["profiles"] = profiles
        XCTAssertThrowsError(try DeviceProfileRepository.decode(JSONSerialization.data(withJSONObject: object), serial: "phone"))

        let otherOS = snapshot.replacingOccurrences(of: "[29]", with: "[34]").replacingOccurrences(of: "[10]", with: "[14]")
        let baseline = try DeviceTestProfile.capture(otherOS)
        let generated = try baseline.randomized(name: "Other OS")
        for key in ["ro.product.model", "ro.product.brand", "ro.product.name", "ro.product.device", "ro.build.version.sdk", "ro.build.version.release"] {
            XCTAssertEqual(generated.properties[key], baseline.properties[key])
        }
    }
}
