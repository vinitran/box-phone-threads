import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Password-protected secret: PBKDF2-HMAC-SHA256 derives an AES-256-GCM key from the password.
/// The file holds only the salt, iteration count and sealed box, so it can be committed to git.
enum EncryptedKey {
    struct File: Codable {
        var version = 1
        var kdf = "pbkdf2-sha256"
        var cipher = "aes-256-gcm"
        let iterations: Int
        let salt: Data
        let sealed: Data
    }

    enum Failure: LocalizedError {
        case wrongPassword, invalidFile, randomUnavailable

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "Mật khẩu không đúng."
            case .invalidFile: return "File khóa mã hóa không hợp lệ."
            case .randomUnavailable: return "Không tạo được dữ liệu ngẫu nhiên để mã hóa."
            }
        }
    }

    static let defaultIterations = 600_000

    static func encrypt(_ secret: String, password: String, iterations: Int = defaultIterations) throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.randomUnavailable }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        guard let sealed = try AES.GCM.seal(Data(secret.utf8), using: key).combined else { throw Failure.invalidFile }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(iterations: iterations, salt: salt, sealed: sealed))
    }

    static func decrypt(_ data: Data, password: String) throws -> String {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1, file.kdf == "pbkdf2-sha256", file.cipher == "aes-256-gcm",
              (100_000...10_000_000).contains(file.iterations), file.salt.count >= 16 else { throw Failure.invalidFile }
        let key = try deriveKey(password: password, salt: file.salt, iterations: file.iterations)
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: file.sealed), using: key)
        } catch {
            throw Failure.wrongPassword
        }
        guard let secret = String(data: plain, encoding: .utf8) else { throw Failure.invalidFile }
        return secret
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        guard !passwordBytes.isEmpty else { throw Failure.wrongPassword }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passwordBytes.count) { passwordPointer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, passwordBytes.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.invalidFile }
        return SymmetricKey(data: derived)
    }
}
