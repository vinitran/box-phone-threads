// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneFarm",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "PhoneFarm", linkerSettings: [.linkedLibrary("sqlite3")])]
)
