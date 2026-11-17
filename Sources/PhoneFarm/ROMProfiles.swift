import Foundation

struct ROMProfile: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let userId: Int
    let name: String
    let proxy: ROMProxyStatus?
    var state: String? = nil
    var userID: Int { userId }
    var isDeleting: Bool { state == "deleting" }
    var canRotate: Bool { userID >= 0 && (state == nil || state == "ready") && proxy?.enforced == true }
}

struct ROMProxyStatus: Decodable, Equatable, Sendable {
    let type: String
    let host: String?
    let port: Int?
    let routing: String?
    let transport: String?
    let authenticated: Bool?
    var address: String? { host.flatMap { host in port.map { "\(host):\($0)" } } }
    var enforced: Bool { type == "http" && routing == "enforced" && transport == "device" }
}

struct ROMNetworkGuard: Decodable, Equatable, Sendable {
    let required: Bool?
    let engineRunning: Bool?
    let ipv4Guard: Bool?
    let ipv6Guard: Bool?
    let tcpDnsRedirect: Bool?
    let protectedUserId: Int?
    let inactiveUserApps: String?
    func protects(_ user: Int) -> Bool {
        required == true && engineRunning == true && ipv4Guard == true && ipv6Guard == true
            && tcpDnsRedirect == true && protectedUserId == user && inactiveUserApps == "blocked"
    }
}

struct ROMProfileList: Decodable, Sendable {
    let activeUser: Int
    let profiles: [ROMProfile]
    let maxProfiles: Int
    let networkGuard: ROMNetworkGuard?
    var capabilities: [String]? = nil
    var active: ROMProfile? { profiles.first { $0.userId == activeUser } }
}

/// Secrets travel only over stdin to the phone's root API; never persist this request on the Mac.
struct ROMProxyConfiguration: Encodable, Sendable {
    let type = "http"
    let host: String
    let port: Int
    let username: String
    let password: String
    let exclusions: [String] = []
    let transport = "device"
    let routing = "enforced"

    init(line: String) throws {
        guard let proxy = ProxyProfile(line: line) else { throw ROMError.invalidProxy }
        try self.init(host: proxy.endpoint.host, port: String(proxy.endpoint.port),
                      username: proxy.login?.username ?? "", password: proxy.login?.password ?? "")
    }

    init(host: String, port: String, username: String, password: String) throws {
        guard let proxy = ProxyProfile(host: host, port: port, username: username, password: password),
              username.utf16.count <= 256, password.utf16.count <= 1024 else {
            throw ROMError.invalidProxy
        }
        self.host = proxy.endpoint.host; self.port = proxy.endpoint.port
        self.username = username; self.password = password
    }
}

enum ROMError: LocalizedError, Equatable {
    case unavailable, busy, resultUnknown, invalidResponse, invalidProxy, proxyRequired, proxyTestFailed, duplicateProxy, proxyAuthentication, failed, wrongProfile, notProtected
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Chưa kết nối được ROM Profiles API v1. Kiểm tra root và engine trên điện thoại."
        case .busy: return "Điện thoại đang xử lý tác vụ khác. Chờ hoàn tất rồi làm mới."
        case .resultUnknown: return "Chưa xác định được kết quả trên điện thoại. Bấm Làm mới để đối chiếu trước khi thử lại; app không tự tạo hoặc chuyển thêm profile."
        case .invalidResponse: return "Engine trả về dữ liệu không hợp lệ hoặc phiên bản API chưa được hỗ trợ."
        case .invalidProxy: return "Dán proxy HTTP dạng host:port:username:password hoặc host:port, với cổng 1–65535."
        case .proxyRequired: return "Profile mới bắt buộc có proxy HTTP riêng. Dán proxy và kiểm tra trước khi tạo."
        case .proxyTestFailed: return "Không gọi được HTTPS để đọc IP qua proxy. Đã dừng trước khi lưu proxy hoặc tạo profile; kiểm tra proxy, mạng hoặc thử lại."
        case .duplicateProxy: return "Host:cổng proxy này đã thuộc profile khác. Hãy dùng một proxy riêng cho profile này."
        case .proxyAuthentication: return "Proxy từ chối xác thực (HTTP 407). Kiểm tra lại username/mật khẩu hoặc thay proxy cho profile này."
        case .failed: return "Engine không hoàn tất thao tác. Kiểm tra trạng thái trên điện thoại rồi làm mới."
        case .wrongProfile: return "Profile trên điện thoại đã thay đổi. Tác vụ đã dừng để tránh dùng nhầm tài khoản."
        case .notProtected: return "Chưa xác minh được proxy và chặn mạng giữa các profile. Thao tác Threads đang khóa."
        }
    }
}

struct ROMRequest: Encodable, Sendable {
    let apiVersion = 1
    let operation: String
    var userId: Int? = nil
    var backupCurrent: Bool? = nil
    var proxy: ROMProxyConfiguration? = nil
    var expectedProfileId: String? = nil
    var confirmDeletion: Bool? = nil
    var name: String? = nil
}

struct ROMReply: Sendable {
    let data: Data
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data) }
    var passed: Bool { (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["passed"] as? Bool == true }
    var egressIP: String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = object["report"] as? [String: Any], report["httpStatus"] as? Int == 200 else { return nil }
        return (report["egress"] as? [String: Any])?["ip"] as? String
    }
}

struct ROMProfilesClient: Sendable {
    typealias Transport = @Sendable (Data, TimeInterval) async throws -> CommandResult
    private let transport: Transport
    init(transport: @escaping Transport) { self.transport = transport }
    init(adb: URL, serial: String) {
        transport = { data, timeout in
            let command = try RunningCommand(adb, arguments: ["-s", serial, "shell", "su", "-c",
                "'CLASSPATH=/data/adb/romprofiles/manager.apk /system/bin/app_process / vn.romprofiles.Backend rpc 0'"], input: data)
            return await command.result(timeout: timeout, outputLimit: 2_000_000)
        }
    }
    func call(_ request: ROMRequest, timeout: TimeInterval = 240, busyRetries: Int = 3) async throws -> ROMReply {
        let data = try JSONEncoder().encode(request)
        for attempt in 0...busyRetries {
            try Task.checkCancellation()
            let result: CommandResult
            do { result = try await transport(data, timeout) }
            catch { throw ROMError.resultUnknown }
            // A transport failure can happen after a mutation committed. Never retry it.
            struct Envelope: Decodable { let apiVersion: Int; let ok: Bool; let errorCode: String?; let error: String? }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: result.data) else {
                throw result.status == 0 ? ROMError.invalidResponse : ROMError.resultUnknown
            }
            guard envelope.apiVersion == 1 else { throw ROMError.invalidResponse }
            if envelope.ok {
                guard result.status == 0 else { throw ROMError.resultUnknown }
                return ROMReply(data: result.data)
            }
            if envelope.errorCode == "BUSY" {
                guard attempt < busyRetries else { throw ROMError.busy }
                try await Task.sleep(for: .seconds(1))
                continue
            }
            if envelope.errorCode == "RESULT_UNKNOWN" { throw ROMError.resultUnknown }
            if envelope.error?.contains("Profile UUID changed") == true || envelope.error?.contains("Android user generation changed") == true { throw ROMError.wrongProfile }
            // Map known errors to fixed messages; never echo potentially sensitive backend text.
            if envelope.error?.contains("CONNECT status 407") == true { throw ROMError.proxyAuthentication }
            if envelope.errorCode == "PROXY_REQUIRED" { throw ROMError.proxyRequired }
            if envelope.errorCode == "PROXY_TEST_FAILED" { throw ROMError.proxyTestFailed }
            if envelope.errorCode == "DUPLICATE_PROXY" { throw ROMError.duplicateProxy }
            throw ROMError.failed
        }
        throw ROMError.busy
    }
    func list() async throws -> ROMProfileList {
        let list = try await call(ROMRequest(operation: "profile.list"), timeout: 20).decode(ROMProfileList.self)
        guard list.active != nil, !list.profiles.isEmpty, list.profiles.allSatisfy({ $0.userID >= 0 && UUID(uuidString: $0.id) != nil }),
              Set(list.profiles.map(\.id)).count == list.profiles.count,
              Set(list.profiles.map(\.userID)).count == list.profiles.count else { throw ROMError.invalidResponse }
        return list
    }
}

struct ROMSession: Equatable, Sendable {
    let profileID: String
    let userID: Int
    var mediaRoot: String { "/storage/emulated/\(userID)/Pictures/" }
}

/// Task-local bindings pin a whole automation to its original account. The registry fences manual
/// actions too, and is locked before any engine mutation, including across async suspension points.
enum ROMTaskContext { @TaskLocal static var session: ROMSession? }
final class ROMRuntime: @unchecked Sendable {
    static let shared = ROMRuntime()
    private let lock = NSLock()
    private var managed: Set<String> = []
    private var sessions: [String: ROMSession] = [:]
    func set(_ serial: String, managed: Bool, session: ROMSession?) {
        lock.lock(); defer { lock.unlock() }
        if managed { self.managed.insert(serial) } else { self.managed.remove(serial) }
        sessions[serial] = session
    }
    func session(_ serial: String) throws -> ROMSession? {
        lock.lock(); defer { lock.unlock() }
        if managed.contains(serial) && sessions[serial] == nil { throw ROMError.busy }
        if let expected = ROMTaskContext.session, expected != sessions[serial] { throw ROMError.wrongProfile }
        return ROMTaskContext.session ?? sessions[serial]
    }
    func namespace(_ serial: String) throws -> String {
        let session = try self.session(serial)
        return session.map { serial + ".rom." + $0.profileID } ?? serial
    }
    static func checkForeground(_ session: ROMSession?, adb: URL, serial: String) async throws {
        guard let session else { return }
        let result = await (try RunningCommand(adb, arguments: ["-s", serial, "shell", "am", "get-current-user"])).result(timeout: 8)
        guard result.status == 0, Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) == session.userID else { throw ROMError.wrongProfile }
    }
}
