import Foundation

/// Explicit, one-time CLI launch of the same runner as the two-profile button.
/// The app password is accepted only on stdin, never in arguments or saved preferences.
struct AutomaticLaunchRequest: Equatable {
    let serial: String
    let users: [Int]
    struct Invalid: LocalizedError {
        var errorDescription: String? { "Dùng --run-two-profiles SERIAL USER_A USER_B; mật khẩu mở app gửi riêng qua stdin." }
    }
    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.first == "--run-two-profiles" else { return nil }
        guard arguments.count == 4,
              arguments[1].range(of: #"^[A-Za-z0-9_.:-]{1,128}$"#, options: .regularExpression) != nil,
              let a = Int(arguments[2]), let b = Int(arguments[3]), a >= 0, b >= 0, a != b else { throw Invalid() }
        return .init(serial: arguments[1], users: [a, b])
    }
}

@MainActor
enum AutomaticLaunch {
    static var request: AutomaticLaunchRequest?
    static var statusURL: URL {
        PhoneFarmStore.databaseURL.deletingLastPathComponent().appendingPathComponent("automatic-run-status.json")
    }
    private static func status(_ phase: String, request: AutomaticLaunchRequest, manager: DeviceManager) {
        let device = manager.devices.first { $0.serial == request.serial }
        let object: [String: Any] = [
            "phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "serial": request.serial, "users": request.users, "mode": "restWindows",
            "activeUser": device.flatMap { manager.romProfiles[$0.id]?.activeUser } ?? -1,
            "running": device.map { manager.runningThreads.contains($0.id) } ?? false,
            "progress": device.flatMap { manager.activities[$0.id]?.progress.message } ?? "",
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: statusURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
        } catch { /* A diagnostic write must not interrupt the account runner. */ }
    }
    static func run(_ request: AutomaticLaunchRequest, manager: DeviceManager) async {
        status("preparing", request: request, manager: manager)
        do {
            var started = false
            for _ in 0..<60 {
                try Task.checkCancellation()
                await manager.refresh()
                if let device = manager.devices.first(where: { $0.serial == request.serial && $0.isReady }),
                   manager.romCanMutate(device) {
                    await manager.refreshROMProfiles(device)
                    if let list = manager.romProfiles[device.id], manager.romVerified.contains(device.id),
                       manager.romErrors[device.id] == nil, !manager.romNeedsReconcile.contains(device.id) {
                        let targets = list.profiles.filter { request.users.contains($0.userID) }
                        guard targets.count == 2 else { throw AutomaticLaunchRequest.Invalid() }
                        _ = try ROMProfileRotation.ordered(targets, startingAt: list.active?.id)
                        manager.runRotatingThreads(device, profileIDs: Set(targets.map(\.id)), mode: .restWindows)
                        started = manager.runningThreads.contains(device.id)
                        break
                    }
                }
                status("preparing", request: request, manager: manager)
                try await Task.sleep(for: .seconds(2))
            }
            guard started else { status("failed", request: request, manager: manager); return }
            // Remain observable and keep device polling alive even while the Mac's screen is locked.
            while let device = manager.devices.first(where: { $0.serial == request.serial }), manager.runningThreads.contains(device.id) {
                status("running", request: request, manager: manager)
                try await Task.sleep(for: .seconds(5))
                await manager.refresh()
            }
            status("stopped", request: request, manager: manager)
        } catch {
            status(Task.isCancelled ? "stopped" : "failed", request: request, manager: manager)
        }
    }
}
