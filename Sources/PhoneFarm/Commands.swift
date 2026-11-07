import Foundation

enum ToolPaths {
    static func adb() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sdkDirectories: [String?] = [
            environment["ANDROID_HOME"],
            environment["ANDROID_SDK_ROOT"],
            home.appendingPathComponent("Library/Android/sdk").path
        ]
        let sdkPaths = sdkDirectories.compactMap { $0 }.map { $0 + "/platform-tools/adb" }
        return find("adb", override: "ADB", extraPaths: sdkPaths)
    }

    static func scrcpy() -> URL? {
        find("scrcpy", override: "SCRCPY")
    }

    static func gnirehtet() -> URL? {
        find("gnirehtet", override: "GNIREHTET")
    }

    private static func find(_ name: String, override: String, extraPaths: [String] = []) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let shellDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = shellDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let candidates = [environment[override]].compactMap { $0 }
            + directories.map { $0 + "/" + name } + extraPaths
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

struct CommandResult: Sendable {
    let status: Int32
    let data: Data

    var output: String { String(decoding: data, as: UTF8.self) }

    var diagnostics: String {
        output.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
    }
}

struct DeviceProgress: Sendable {
    let message: String
    var completed: Int? = nil
    var total: Int? = nil

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum AndroidAccessibility {
    struct Progress: Decodable, Sendable {
        let event: String
        let stage: String
        let completed: Int?
        let total: Int?

        var deviceProgress: DeviceProgress {
            let count = completed ?? 0
            let target = total ?? 0
            let message: String
            switch stage {
            case "opening_home": message = "Đang bấm Trang chủ"
            case "initial_swipe": message = "Đang vuốt lên một lần để bắt đầu đọc"
            case "returning_top": message = "Đang trở về đầu feed"
            case "refreshing": message = "Đang kéo làm mới feed"
            case "waiting_feed": message = "Đang đợi Threads tải feed mới"
            case "pausing_feed": message = "Đang chờ nhịp đọc trước khi vuốt"
            case "reading": message = "Đang đọc \(count)/\(target) bài"
            case "swiping": message = "Đang lướt · đã đọc \(count)/\(target) bài"
            case "locating_like": message = "Đang tìm bài để thả tim · \(count) lần vuốt"
            case "locating_reply": message = "Đang tìm bài để bình luận · \(count) lần vuốt"
            case "liking": message = "Đang thả tim"
            case "opening_composer": message = "Đang mở ô bình luận"
            case "opening_photos": message = "Đang mở thư viện ảnh"
            case "selecting_photos": message = "Đang chọn \(count)/3 ảnh · app_store.png ở giữa"
            case "photos_ready": message = "Đã kiểm tra đủ 3 ảnh đúng thứ tự"
            case "sending_reply": message = "Đang gửi bình luận"
            default: message = "Đang thao tác Threads"
            }
            return DeviceProgress(message: message, completed: completed, total: total)
        }
    }

    enum Entry: String {
        case keyboard = "KeyboardReader"
        case keyboardType = "KeyboardReader type"
        case threads = "ThreadsReader"
        case threadsAutoFeed = "ThreadsReader auto_feed"
        case threadsRefresh = "ThreadsReader refresh"
        case threadsHomeAfterPost = "ThreadsReader home_after_post"
        case threadsScroll = "ThreadsReader scroll"
        case threadsAction = "ThreadsReader action"
        case threadsProfile = "ThreadsReader profile"
        case proxyCheck = "ProxyCheck"
    }

    static func read(adb: URL, serial: String, entry: Entry, timeout: Int = 8, payload: Data? = nil,
                     onProgress: (@Sendable (Progress) async -> Void)? = nil) async throws -> CommandResult {
        guard let reader = Bundle.main.url(forResource: "KeyboardReader", withExtension: "dex") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let remotePath = "/data/local/tmp/phone-farm-\(UUID().uuidString).dex"
        let device = ["-s", serial]
        defer {
            if let cleanup = try? RunningCommand(adb, arguments: device + ["shell", "rm", "-f", remotePath, remotePath + ".json"]) {
                Task { _ = await cleanup.result(timeout: 8) }
            }
        }
        let push = try RunningCommand(adb, arguments: device + ["push", reader.path, remotePath])
        let uploaded = await push.result(timeout: 8)
        if uploaded.status != 0 { return uploaded }
        try Task.checkCancellation()
        let argument: String
        if entry == .keyboardType, let payload {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: file) }
            FileManager.default.createFile(atPath: file.path, contents: payload, attributes: [.posixPermissions: 0o600])
            let upload = try RunningCommand(adb, arguments: device + ["push", file.path, remotePath + ".json"])
            let result = await upload.result(timeout: 8)
            guard result.status == 0 else { return result }
            argument = " " + remotePath + ".json"
        } else {
            argument = payload.map { " " + $0.base64EncodedString() } ?? ""
        }
        let script = "chmod 444 \(remotePath) && CLASSPATH=\(remotePath) timeout \(timeout) app_process /system/bin \(entry.rawValue)\(argument)"
        try Task.checkCancellation()
        let command = try RunningCommand(adb, arguments: device + ["shell", script])
        let read = { @Sendable in await command.result(timeout: TimeInterval(timeout + 2), outputLimit: 256_000) { line in
            guard let onProgress,
                  let update = try? JSONDecoder().decode(Progress.self, from: Data(line.utf8)),
                  update.event == "progress" else { return }
            await onProgress(update)
        } }
        return await withTaskCancellationHandler(operation: read, onCancel: {
            if let cancel = try? RunningCommand(adb, arguments: device + ["shell", "rm", "-f", remotePath]) {
                Task { _ = await cancel.result(timeout: 8) }
            }
            if entry != .keyboardType { command.stop() }
        })
    }
}

final class RunningCommand: Sendable {
    private let process: Process
    private let output = Pipe()
    private let exited = DispatchGroup()

    init(_ executable: URL, arguments: [String], environment: [String: String]? = nil) throws {
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        exited.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }
    }

    func stop() {
        if process.isRunning { process.interrupt() }
    }

    func result(timeout: TimeInterval? = nil, outputLimit: Int? = nil,
                onLine: (@Sendable (String) async -> Void)? = nil) async -> CommandResult {
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
            }
        }
        let (lines, lineContinuation) = AsyncStream<String>.makeStream()
        let updates = Task {
            for await line in lines { await onLine?(line) }
        }
        let result: CommandResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let reader = self.output.fileHandleForReading
                var bytes = Data()
                var pendingLine = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                    if onLine != nil {
                        pendingLine.append(chunk)
                        while let newline = pendingLine.firstIndex(of: 10) {
                            lineContinuation.yield(String(decoding: pendingLine[..<newline], as: UTF8.self))
                            pendingLine.removeSubrange(...newline)
                        }
                    }
                    if let outputLimit, bytes.count > outputLimit {
                        bytes.removeFirst(bytes.count - outputLimit)
                    }
                }
                if !pendingLine.isEmpty { lineContinuation.yield(String(decoding: pendingLine, as: UTF8.self)) }
                self.exited.notify(queue: .global()) { [bytes] in
                    lineContinuation.finish()
                    continuation.resume(returning: CommandResult(
                        status: self.process.terminationStatus,
                        data: bytes
                    ))
                }
            }
        }
        await updates.value
        return result
    }
}
