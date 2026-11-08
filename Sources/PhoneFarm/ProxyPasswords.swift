import Foundation
import Security

enum ProxyPasswords {
    private static func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.phonefarm.mac.proxy",
         kSecAttrAccount as String: reference]
    }

    private struct PasswordError: LocalizedError {
        let errorDescription: String? = "Không đọc hoặc lưu được mật khẩu proxy trong Keychain. Hãy nhập lại thông tin đăng nhập."
    }

    static func save(_ login: ProxyLogin) throws -> String {
        let reference = UUID().uuidString
        var item = query(reference)
        item[kSecValueData as String] = try JSONEncoder().encode(login)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PasswordError() }
        return reference
    }

    /// `interactive` lets macOS ask for the Mac's password when the item was saved by another build
    /// of Phone Farm (release builds are signed ad hoc, so each one is a different app to the Keychain).
    static func load(_ reference: String, interactive: Bool = false) throws -> ProxyLogin {
        var item = query(reference)
        item[kSecReturnData as String] = true
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else { throw PasswordError() }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        var value: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { throw PasswordError() }
        return try JSONDecoder().decode(ProxyLogin.self, from: data)
    }

    static func remove(_ reference: String) {
        SecItemDelete(query(reference) as CFDictionary)
    }
}
