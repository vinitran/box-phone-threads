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
