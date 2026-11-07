import Foundation

struct AndroidProxyRelay {
    struct Handle {
        let directory: String
        let endpoint: ProxyEndpoint
    }

    private struct Request: Encodable {
        let host: String
        let port: Int
        let login: ProxyLogin
    }

    private struct State: Decodable {
        let pid: Int
        let port: Int
    }

    private struct RelayError: LocalizedError {
        let errorDescription: String?
    }

    let adb: URL
    let serial: String

    func start(_ profile: ProxyProfile) async throws -> Handle {
        guard let login = profile.login,
              let reader = Bundle.main.url(forResource: "KeyboardReader", withExtension: "dex") else {
            throw RelayError(errorDescription: "Chưa có bộ xử lý proxy có xác thực trong app.")
        }
        let directory = "/data/local/tmp/phone-farm-proxy-" + UUID().uuidString.lowercased()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: local) }
        let data = try JSONEncoder().encode(Request(host: profile.endpoint.host, port: profile.endpoint.port, login: login))
        try data.write(to: local, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        do {
            _ = try await run(["shell", "mkdir -m 700 \(directory)"])
            _ = try await run(["push", reader.path, directory + "/relay.dex"])
            _ = try await run(["push", local.path, directory + "/config.json"])
            _ = try await run(["shell", "chmod 444 \(directory)/relay.dex && chmod 600 \(directory)/config.json"])
            _ = try await run(["shell", """
                trap '' HUP
                CLASSPATH=\(directory)/relay.dex \
                app_process /system/bin --nice-name=\(URL(fileURLWithPath: directory).lastPathComponent) ProxyRelay \(directory) \
                </dev/null >\(directory)/relay.log 2>&1 &
                exit 0
                """])
            for _ in 0..<20 {
                let result = try await run(["shell", "if [ -f \(directory)/state.json ]; then cat \(directory)/state.json; fi"])
                if let state = try? JSONDecoder().decode(State.self, from: result.data),
                   state.pid > 1, let endpoint = ProxyEndpoint(host: "127.0.0.1", port: String(state.port)) {
                    return Handle(directory: directory, endpoint: endpoint)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw RelayError(errorDescription: "Android chưa khởi động được cầu nối proxy. Hãy thử Áp dụng lại.")
        } catch {
            // Stop by its unique directory before removing a partially started relay.
            try? await stop(directory: directory)
            throw error
        }
    }

    func stop(directory: String) async throws {
        guard Self.valid(directory) else { return }
        _ = try await run(["shell", """
            if [ -f \(directory)/state.json ]; then \
            CLASSPATH=\(directory)/relay.dex timeout 8 app_process /system/bin ProxyRelay stop \(directory); fi
            """])
        _ = try await run(["shell", "rm -rf \(directory)"])
    }

    private static func valid(_ directory: String) -> Bool {
        let prefix = "/data/local/tmp/phone-farm-proxy-"
        guard directory.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(directory.dropFirst(prefix.count))) != nil
    }

    private func run(_ arguments: [String]) async throws -> CommandResult {
        let command = try RunningCommand(adb, arguments: ["-s", serial] + arguments)
        let result = await command.result(timeout: 12, outputLimit: 4_096)
        guard result.status == 0 else {
            let step = arguments.first == "push" ? "chép bộ cầu nối" : "chạy lệnh trên Android"
            throw RelayError(errorDescription: "ADB chưa hoàn tất bước \(step) (mã \(result.status)). " + result.diagnostics)
        }
        return result
    }
}
