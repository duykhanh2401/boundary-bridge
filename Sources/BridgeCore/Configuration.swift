import Foundation

public enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    case managed, existing
    public var id: String { rawValue }
    public var title: String { self == .managed ? "Boundary CLI (tự động)" : "Port từ Boundary Desktop" }
}

public struct TunnelProfile: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name = "Kết nối mới"
    public var mode: ConnectionMode = .managed
    public var targetID = ""
    public var hostID = ""
    public var localPort = 15432
    public var existingPort = 50000
    public var reconnect = true
    public init() {}

    public func validate(others: [TunnelProfile]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.message("Hãy đặt tên cho kết nối.")
        }
        guard (1024...65535).contains(localPort) else {
            throw BridgeError.message("Port cố định phải từ 1024 đến 65535.")
        }
        guard !others.contains(where: { $0.id != id && $0.localPort == localPort }) else {
            throw BridgeError.message("Port \(localPort) đã được cấu hình cho kết nối khác.")
        }
        if mode == .managed && targetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BridgeError.message("Hãy nhập Target ID của Boundary.")
        }
        if mode == .existing && (!(1...65535).contains(existingPort) || existingPort == localPort) {
            throw BridgeError.message("Port Boundary phải hợp lệ và khác port cố định.")
        }
    }
}

public struct BoundarySettings: Codable, Equatable {
    public var executable = BoundarySettings.detectExecutable()
    public var address = ""
    public var authMethodID = ""
    public var tokenName = "BoundaryBridge"
    public var scopeID = "global"
    public var authType = "oidc"
    public var caCertificate = ""
    public init() {}

    public static func detectExecutable() -> String {
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cli/boundary").path,
         "/opt/homebrew/bin/boundary", "/usr/local/bin/boundary",
         "/Applications/Boundary.app/Contents/Resources/cli/boundary"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/opt/homebrew/bin/boundary"
    }

    public func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: resolvedExecutable) else {
            throw BridgeError.message("Không tìm thấy Boundary CLI. Chọn đường dẫn trong Cài đặt.")
        }
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil else {
            throw BridgeError.message("Controller URL phải có dạng https://boundary.example.com:9200.")
        }
        if !caCertificate.isEmpty && !FileManager.default.isReadableFile(atPath: caCertificate) {
            throw BridgeError.message("Không đọc được file CA certificate.")
        }
    }

    public var resolvedExecutable: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cli/boundary").path
        if executable.hasSuffix("/Boundary Bridge.app/Contents/Resources/cli/boundary"),
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return executable
    }

    public var commonArguments: [String] {
        var args = ["-addr=\(address)"]
        if !tokenName.isEmpty { args.append("-token-name=\(tokenName)") }
        if !caCertificate.isEmpty { args.append("-ca-cert=\(caCertificate)") }
        return args
    }

    public func connectArguments(for profile: TunnelProfile) -> [String] {
        var args = ["connect"] + commonArguments + [
            "-target-id=\(profile.targetID)", "-listen-addr=127.0.0.1", "-listen-port=0",
            "-format=json", "-inactive-timeout=-1"
        ]
        if !profile.hostID.isEmpty { args.append("-host-id=\(profile.hostID)") }
        return args
    }

    // Finder does not inherit terminal exports. Pass explicit settings, and prevent
    // inherited CLI flags from overriding routing or invoking a connect helper.
    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("BOUNDARY_") }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

public struct AppConfiguration: Codable {
    public var version = 1
    public var settings = BoundarySettings()
    public var profiles: [TunnelProfile] = []
    public var accounts: [SavedAccount] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, settings, profiles, accounts }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        settings = try values.decode(BoundarySettings.self, forKey: .settings)
        profiles = try values.decode([TunnelProfile].self, forKey: .profiles)
        accounts = try values.decodeIfPresent([SavedAccount].self, forKey: .accounts) ?? []
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoundaryBridge/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard config.version == 1 else { throw BridgeError.message("Phiên bản cấu hình chưa được hỗ trợ.") }
        guard Set(config.profiles.map(\.id)).count == config.profiles.count else {
            throw BridgeError.message("Cấu hình có ID kết nối trùng nhau.")
        }
        for profile in config.profiles { try profile.validate(others: config.profiles) }
        guard Set(config.accounts.map(\.id)).count == config.accounts.count else {
            throw BridgeError.message("Cấu hình có ID tài khoản trùng nhau.")
        }
        for account in config.accounts { try account.validate() }
        return config
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
