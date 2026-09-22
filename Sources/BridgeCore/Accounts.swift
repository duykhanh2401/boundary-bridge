import Foundation
import Security

public struct SavedAccount: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name = ""
    public var username = ""
    public var controller = ""
    public var authMethodID = ""
    public var authType = "oidc"
    public var appendOTPToPassword = false
    public var hasOTP = false
    public var tokenName: String { "BoundaryBridge-\(id.uuidString)" }
    public init() {}

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.message("Nhập tên tài khoản và tên đăng nhập.")
        }
        guard ["oidc", "password", "ldap"].contains(authType), !authMethodID.isEmpty else {
            throw BridgeError.message("Chọn phương thức đăng nhập Boundary trước khi thêm tài khoản.")
        }
        guard let url = URL(string: controller), url.host != nil,
              ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil else {
            throw BridgeError.message("Controller URL không hợp lệ.")
        }
    }
}

public struct AccountSecrets: Codable {
    public var password: String
    public var otpSetup: String
    public init(password: String, otpSetup: String = "") { self.password = password; self.otpSetup = otpSetup }
}

public struct AccountKeychain {
    private let service: String
    public init(service: String = "local.boundary.bridge.saved-accounts") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    public func save(_ secrets: AccountSecrets, for id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "Boundary Bridge · Saved login"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public func load(for id: UUID) throws -> AccountSecrets {
        var item = query(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(item as CFDictionary, &result))
        guard let data = result as? Data else { throw BridgeError.message("Không đọc được thông tin tài khoản từ Keychain.") }
        return try JSONDecoder().decode(AccountSecrets.self, from: data)
    }
    public func remove(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "mã \(status)"
            throw BridgeError.message("Keychain: \(detail)")
        }
    }
}
