import Foundation

@MainActor
enum GboardSetup {
    private static var configured: Set<String> = []

    static func ensure(adb: URL, serial: String, progress: @escaping @MainActor @Sendable (String) -> Void) async throws {
        let session = try ROMRuntime.shared.session(serial)
        let user = try await currentUser(adb: adb, serial: serial)
        if let session, session.userID != user { throw ROMError.wrongProfile }
        let package = AppBundles.gboard.package
        var installed = try await command(["pm", "list", "packages", "--user", String(user), package], adb: adb, serial: serial)
        if !installed.output.contains("package:" + package) {
            progress("Đang bật Gboard cho profile hiện tại…")
            try await check(user, adb: adb, serial: serial)
            _ = try await command(["cmd", "package", "install-existing", "--user", String(user), package], adb: adb, serial: serial)
            installed = try await command(["pm", "list", "packages", "--user", String(user), package], adb: adb, serial: serial)
            if !installed.output.contains("package:" + package) {
                let prepared = try await AppBundles.prepare(selectedApps: [AppBundles.gboard], progress: progress)
                try await check(user, adb: adb, serial: serial)
                _ = try await AppBundles.install(prepared, on: serial, adb: adb, progress: progress)
            }
        }
        progress("Đang chọn Gboard cho profile hiện tại…")
        try await check(user, adb: adb, serial: serial)
        let enabled = try await command(["pm", "enable", "--user", String(user), package], adb: adb, serial: serial)
        guard enabled.status == 0 else { throw TypingError.wrongKeyboard }
        try await selectDefault(package, adb: adb, serial: serial, user: user)
        let key = serial + "." + (session?.profileID ?? String(user))
        guard !configured.contains(key) else { return }
        progress("Đang tự cấu hình Tiếng Việt Telex trong Gboard…")
        try await check(user, adb: adb, serial: serial)
        _ = try await command(["input", "keyevent", "KEYCODE_WAKEUP"], adb: adb, serial: serial)
        try await check(user, adb: adb, serial: serial)
        // Android's secondary user can be RUNNING_UNLOCKED while a non-secure swipe
        // keyguard still covers its UI. The system refuses this for secure credentials.
        _ = try await command(["wm", "dismiss-keyguard"], adb: adb, serial: serial)
        let launched = try await command(["am", "start", "--user", String(user), "-n",
            package + "/com.google.android.apps.inputmethod.latin.preference.SettingsActivity"], adb: adb, serial: serial)
        guard launched.status == 0, !launched.output.contains("Error") else { throw TypingError.wrongKeyboard }
        let result = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .gboardSetup, timeout: 75, expectedUser: user)
        struct Response: Decodable { let keyboardStatus: String }
        guard result.status == 0, let line = result.output.split(whereSeparator: \.isNewline).last,
              let response = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)),
              response.keyboardStatus == "telex_configured" else {
            throw AppBundles.BundleError("Đã chọn Gboard nhưng chưa tự cấu hình được Tiếng Việt Telex. Kiểm tra mục Ngôn ngữ của Gboard rồi thử lại.")
        }
        try await check(user, adb: adb, serial: serial)
        // The settings activity took the foreground. Return to Threads before opening any editor.
        let packageName = "com.instagram.barcelona"
        let resolved = try await command(["cmd", "package", "resolve-activity", "--brief", "--user", String(user),
            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-p", packageName], adb: adb, serial: serial)
        guard let component = resolved.output.split(whereSeparator: \.isNewline).map(String.init).first(where: {
            $0.hasPrefix(packageName + "/") && $0.range(of: #"^[A-Za-z0-9_./]+$"#, options: .regularExpression) != nil
        }) else { throw TypingError.keyboardHidden }
        try await check(user, adb: adb, serial: serial)
        let opened = try await command(["am", "start", "--user", String(user), "-n", component], adb: adb, serial: serial)
        guard opened.status == 0, !opened.output.contains("Error") else { throw TypingError.keyboardHidden }
        configured.insert(key)
    }

    static func selectVietnamese(adb: URL, serial: String) async throws {
        let user = try await currentUser(adb: adb, serial: serial)
        let selected = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .gboardSelect, timeout: 15, expectedUser: user)
        guard selected.status == 0, selected.output.contains("\"telex_selected\"") else { throw TypingError.wrongKeyboard }
    }

    static func selectDefault(_ package: String, adb: URL, serial: String, user: Int? = nil) async throws {
        let target: Int
        if let user { target = user } else { target = try await currentUser(adb: adb, serial: serial) }
        if let session = try ROMRuntime.shared.session(serial), session.userID != target { throw ROMError.wrongProfile }
        for _ in 0..<10 {
            try Task.checkCancellation()
            try await check(target, adb: adb, serial: serial)
            let list = try await command(["ime", "list", "--user", String(target), "-a", "-s"], adb: adb, serial: serial)
            if let id = list.output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix(package + "/") && $0.range(of: #"^[A-Za-z0-9_./]+$"#, options: .regularExpression) != nil }) {
                let current = try await command(["settings", "--user", String(target), "get", "secure", "default_input_method"], adb: adb, serial: serial)
                if current.status == 0, current.output.trimmingCharacters(in: .whitespacesAndNewlines) == id { return }
                for operation in ["enable", "set"] {
                    try await check(target, adb: adb, serial: serial)
                    let result = try await command(["ime", operation, "--user", String(target), id], adb: adb, serial: serial)
                    guard result.status == 0 else { throw TypingError.wrongKeyboard }
                }
                let observed = try await command(["settings", "--user", String(target), "get", "secure", "default_input_method"], adb: adb, serial: serial)
                if observed.output.trimmingCharacters(in: .whitespacesAndNewlines) == id { return }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TypingError.wrongKeyboard
    }

    private static func currentUser(adb: URL, serial: String) async throws -> Int {
        let result = try await command(["am", "get-current-user"], adb: adb, serial: serial)
        guard result.status == 0, let user = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)), user >= 0 else { throw ROMError.wrongProfile }
        return user
    }
    private static func check(_ user: Int, adb: URL, serial: String) async throws {
        try Task.checkCancellation()
        guard try await currentUser(adb: adb, serial: serial) == user else { throw ROMError.wrongProfile }
    }
    private static func command(_ args: [String], adb: URL, serial: String) async throws -> CommandResult {
        try Task.checkCancellation()
        return await (try RunningCommand(adb, arguments: ["-s", serial, "shell"] + args)).result(timeout: 30)
    }
}
