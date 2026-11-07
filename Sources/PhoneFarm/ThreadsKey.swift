import Darwin
import Foundation

/// The AI key ships encrypted in the app bundle (`ai-key.enc.json`, from `Resources/`).
/// Opening the app requires the password; the decrypted key stays in memory only.
@MainActor
enum ThreadsKey {
    static let fileName = "ai-key.enc"
    static let repositoryPath = "Resources/ai-key.enc.json"

    private static var unlocked: String?

    private static var environmentKey: String? {
        let key = ProcessInfo.processInfo.environment["PHONE_FARM_AI_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static var encryptedFile: URL? { Bundle.main.url(forResource: fileName, withExtension: "json") }

    /// True when the app must ask for the password before showing anything.
    static var needsUnlock: Bool { environmentKey == nil && unlocked == nil && encryptedFile != nil }

    static func load() -> String? { environmentKey ?? unlocked }

    static func unlock(password: String) async throws {
        guard let url = encryptedFile else { throw EncryptedKey.Failure.invalidFile }
        let data = try Data(contentsOf: url)
        let key = try await Task.detached(priority: .userInitiated) {
            try EncryptedKey.decrypt(data, password: password)
        }.value
        unlocked = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `PhoneFarm --encrypt-threads-key [output]`: encrypts the key with a new password.
    /// Uses the plaintext key left in SQLite by older builds, then deletes it.
    static func encryptFromTerminal(output: String?) -> Int32 {
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return 1
        }
        let store = try? PhoneFarmStore.shared.get()
        var secret = (try? store?.legacyAIKey()) ?? nil
        if secret != nil {
            print("Dùng khóa AI đang lưu dạng chưa mã hóa trong SQLite.")
        } else {
            secret = prompt("Khóa AI: ")?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let secret, !secret.isEmpty else { return fail("Chưa có khóa AI.") }
        guard let password = prompt("Mật khẩu mở app (tối thiểu 8 ký tự): "), password.count >= 8 else {
            return fail("Mật khẩu cần tối thiểu 8 ký tự.")
        }
        guard prompt("Nhập lại mật khẩu: ") == password else { return fail("Hai mật khẩu không khớp.") }
        let url = URL(fileURLWithPath: output ?? repositoryPath)
        do {
            let data = try EncryptedKey.encrypt(secret, password: password)
            guard try EncryptedKey.decrypt(data, password: password) == secret else { return fail("Kiểm tra giải mã thất bại.") }
            try data.write(to: url, options: .atomic)
            try store?.deleteLegacyAIKey()
        } catch {
            return fail("Chưa mã hóa được khóa: \(error.localizedDescription)")
        }
        print("Đã lưu khóa mã hóa vào \(url.path). Chạy lại ./scripts/build-app.sh để đóng gói vào app.")
        return 0
    }

    private static func prompt(_ text: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        defer { buffer.withUnsafeMutableBufferPointer { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard readpassphrase(text, &buffer, buffer.count, 0) != nil else { return nil }
        return String(cString: buffer)
    }
}
