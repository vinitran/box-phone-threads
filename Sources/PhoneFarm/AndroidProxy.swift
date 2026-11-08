import Foundation

struct ProxyLogin: Codable, Equatable {
    let username: String
    let password: String
}

struct ProxyProfile {
    let endpoint: ProxyEndpoint
    let login: ProxyLogin?

    init?(host: String, port: String, username: String = "", password: String = "") {
        guard let endpoint = ProxyEndpoint(host: host, port: port),
              !username.contains(where: { $0.isNewline || $0 == ":" }),
              !password.contains(where: \.isNewline),
              !username.isEmpty || password.isEmpty else { return nil }
        self.endpoint = endpoint
        login = username.isEmpty ? nil : ProxyLogin(username: username, password: password)
    }

    /// host:port or host:port:user:pass, the format of the Proxy window and the phone's file.
    var line: String {
        guard let login else { return endpoint.address }
        return endpoint.address + ":" + login.username + ":" + login.password
    }

    init?(line: String) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 4 else { return nil }
        self.init(host: parts[0], port: parts[1],
                  username: parts.count == 4 ? parts[2] : "",
                  password: parts.count == 4 ? parts[3] : "")
    }
}

struct ProxyEndpoint: Equatable {
    let host: String
    let port: Int

    var address: String { "\(host):\(port)" }

    init?(host: String, port: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253,
              labels.allSatisfy(Self.isHostnameLabel),
              let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else { return nil }
        self.host = host
        self.port = port
    }

    private static func isHostnameLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy {
                switch $0 {
                case 45, 48...57, 65...90, 97...122: return true
                default: return false
                }
            }
    }
}

enum ProxyConfiguration: Equatable {
    case off
    case direct(ProxyEndpoint)
    case unsupported

    var address: String? {
        switch self {
        case .off: return ":0"
        case .direct(let endpoint): return endpoint.address
        case .unsupported: return nil
        }
    }
}

struct AndroidProxy {
    let adb: URL
    let serial: String

    private struct CheckRequest: Encodable {
        let host: String
        let port: Int
    }

    private struct CheckResult: Decodable {
        let status: String
        let ip: String?
    }

    func validate(_ endpoint: ProxyEndpoint) async throws -> String {
        let payload = try JSONEncoder().encode(CheckRequest(host: endpoint.host, port: endpoint.port))
        let output = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .proxyCheck,
                                                          timeout: 30, payload: payload)
        guard output.status == 0, let line = output.output.split(whereSeparator: \.isNewline).last,
              let result = try? JSONDecoder().decode(CheckResult.self, from: Data(line.utf8)) else {
            throw ProxyError.unreachable
        }
        if result.status == "authentication_failed" { throw ProxyError.authentication }
        guard result.status == "ok", let ip = result.ip else { throw ProxyError.unreachable }
        return ip
    }

    func configuration() async throws -> ProxyConfiguration {
        try await readSettings().configuration
    }

    func apply(_ target: ProxyConfiguration, replacing previous: ProxyConfiguration) async throws {
        let before = try await readSettings()
        guard let address = target.address, let previousAddress = previous.address,
              before.configuration == previous else { throw ProxyError.changed }
        guard target != previous else { return }

        // Android observes this setting and writes the applied host and port separately.
        try await write(address)
        var current = try await readSettings()
        for _ in 0..<8 where current.configuration != target {
            try await Task.sleep(for: .milliseconds(200))
            current = try await readSettings()
        }
        if current.configuration == target { return }

        if current.requested == address, current.configuration == previous {
            try await write(previousAddress)
        }
        throw ProxyError.unverified
    }

    private func readSettings() async throws -> (configuration: ProxyConfiguration, requested: String) {
        let keys = ["global_http_proxy_host", "global_http_proxy_port", "global_http_proxy_pac",
                    "global_http_proxy_exclusion_list", "http_proxy"]
        let script = keys.map { "settings get global \($0)" }.joined(separator: " && ")
        let output = try await run(["shell", script])
        let lines = output.components(separatedBy: "\n")
        guard lines.count == keys.count + 1, lines.last == "" else { throw ProxyError.unverified }
        let values = lines.dropLast().map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == "null" ? "" : value
        }
        let host = values[0], port = values[1], pac = values[2], exclusions = values[3]
        let configuration: ProxyConfiguration
        if !pac.isEmpty || !exclusions.isEmpty {
            configuration = .unsupported
        } else if host.isEmpty && (port.isEmpty || port == "0") {
            configuration = .off
        } else if let endpoint = ProxyEndpoint(host: host, port: port) {
            configuration = .direct(endpoint)
        } else {
            configuration = .unsupported
        }
        return (configuration, values[4])
    }

    private func write(_ address: String) async throws {
        _ = try await run(["shell", "settings", "put", "global", "http_proxy", address])
    }

    private func run(_ arguments: [String]) async throws -> String {
        let command = try RunningCommand(adb, arguments: ["-s", serial] + arguments)
        let result = await command.result(timeout: 8)
        guard result.status == 0 else { throw ProxyError.adb(result.diagnostics) }
        return result.output
    }
}

enum ProxyError: LocalizedError {
    case noADB
    case adb(String)
    case changed
    case unverified
    case authentication
    case unreachable

    var errorDescription: String? {
        switch self {
        case .noADB: return "Không tìm thấy ADB."
        case .adb(let details):
            return details.isEmpty ? "ADB không thực hiện được thao tác trên thiết bị." : details
        case .changed:
            return "Cấu hình trên điện thoại vừa thay đổi. Hãy bấm Áp dụng lại."
        case .unverified:
            return "Không xác minh được cấu hình proxy trên Android. Hãy bấm Áp dụng lại."
        case .authentication:
            return "Proxy từ chối đăng nhập. Kiểm tra tài khoản và mật khẩu."
        case .unreachable:
            return "Không kết nối được Internet qua proxy. Kiểm tra địa chỉ, cổng và thông tin đăng nhập."
        }
    }
}
