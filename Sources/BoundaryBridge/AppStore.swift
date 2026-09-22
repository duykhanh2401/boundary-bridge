import AppKit
import BridgeCore
import Combine

final class AppStore: ObservableObject {
    @Published var configuration = AppConfiguration()
    @Published var sessions: [UUID: TunnelSession] = [:]
    @Published var error: String?
    @Published var selectedID: UUID?
    @Published var browserLogin: BrowserLogin?
    @Published private(set) var canConnect = false
    let client = BoundaryClient()
    private let keychain = AccountKeychain()
    private var clientObservation: AnyCancellable?
    private var authenticationObservation: AnyCancellable?
    private var canSave = true
    private var observations: [UUID: AnyCancellable] = [:]

    init() {
        do { configuration = try AppConfiguration.load() }
        catch {
            canSave = false
            self.error = "Không đọc được cấu hình: \(error.localizedDescription)\nFile được giữ nguyên tại \(AppConfiguration.defaultURL.path)."
        }
        for profile in configuration.profiles { makeSession(profile) }
        selectedID = configuration.profiles.first?.id
        clientObservation = client.$busy.dropFirst().sink { [weak self] busy in
            if !busy { self?.browserLogin?.stop(); self?.browserLogin = nil }
        }
        authenticationObservation = client.$authenticated.sink { [weak self] authenticated in
            self?.canConnect = authenticated
        }
    }

    var activeCount: Int { sessions.values.filter { $0.state == .connected }.count }
    var hasRunning: Bool { sessions.values.contains { $0.wanted } }

    func saveProfile(_ profile: TunnelProfile) throws {
        try profile.validate(others: configuration.profiles)
        guard sessions[profile.id]?.wanted != true else { throw BridgeError.message("Ngắt kết nối trước khi sửa cấu hình.") }
        var updated = configuration
        if let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) { updated.profiles[index] = profile }
        else { updated.profiles.append(profile) }
        try persist(updated)
        makeSession(profile)
        selectedID = profile.id
    }

    func saveSettings(_ settings: BoundarySettings) throws {
        guard !hasRunning else { throw BridgeError.message("Ngắt các kết nối trước khi đổi cài đặt Boundary.") }
        var updated = configuration
        updated.settings = settings
        try persist(updated)
        client.reset()
        for profile in configuration.profiles { makeSession(profile) }
    }

    func remove(_ profile: TunnelProfile) {
        do {
            var updated = configuration
            updated.profiles.removeAll { $0.id == profile.id }
            try persist(updated)
            sessions[profile.id]?.stop()
            sessions.removeValue(forKey: profile.id)
            observations.removeValue(forKey: profile.id)
            selectedID = configuration.profiles.first?.id
        } catch { self.error = error.localizedDescription }
    }

    func stopAll() { sessions.values.forEach { if $0.wanted { $0.stop() } } }
    func start(_ session: TunnelSession) {
        guard canConnect else { return }
        session.start()
    }
    func startAll() {
        guard canConnect else { return }
        sessions.values.forEach { start($0) }
    }
    func shutdown() { stopAll(); cancelLogin() }

    func cancelLogin() { browserLogin?.stop(); browserLogin = nil; client.cancel() }

    func saveAccount(_ account: SavedAccount, password: String, otpSetup: String, removeOTP: Bool) throws {
        try account.validate()
        let exists = configuration.accounts.contains { $0.id == account.id }
        let old = exists ? try keychain.load(for: account.id) : nil
        let secrets = AccountSecrets(password: password.isEmpty ? (old?.password ?? "") : password,
                                     otpSetup: removeOTP ? "" : otpSetup.isEmpty ? (old?.otpSetup ?? "") : otpSetup)
        guard !secrets.password.isEmpty else { throw BridgeError.message("Nhập mật khẩu cho tài khoản.") }
        if !secrets.otpSetup.isEmpty { _ = try TOTP(setup: secrets.otpSetup) }
        if account.authType != "oidc", !secrets.otpSetup.isEmpty, !account.appendOTPToPassword {
            throw BridgeError.message("Boundary password/LDAP không có ô OTP riêng. Chọn OIDC cho màn hình OTP riêng, hoặc bật ghép OTP nếu máy chủ LDAP yêu cầu.")
        }
        var account = account
        account.hasOTP = !secrets.otpSetup.isEmpty
        var updated = configuration
        if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) { updated.accounts[index] = account }
        else { updated.accounts.append(account) }
        try keychain.save(secrets, for: account.id)
        do { try persist(updated) } catch {
            if let old { try? keychain.save(old, for: account.id) } else { try? keychain.remove(for: account.id) }
            throw error
        }
    }

    func deleteAccount(_ account: SavedAccount) throws {
        let old = try keychain.load(for: account.id)
        var updated = configuration
        updated.accounts.removeAll { $0.id == account.id }
        try keychain.remove(for: account.id)
        do { try persist(updated) } catch { try? keychain.save(old, for: account.id); throw error }
    }

    func login(account: SavedAccount) {
        do {
            guard !client.busy else { return }
            guard !hasRunning else { throw BridgeError.message("Ngắt các tunnel trước khi đổi tài khoản.") }
            guard account.controller == configuration.settings.address else {
                throw BridgeError.message("Tài khoản này thuộc controller khác. Chọn đúng Controller URL trước khi đăng nhập.")
            }
            let secrets = try keychain.load(for: account.id)
            var settings = configuration.settings
            settings.authMethodID = account.authMethodID
            settings.authType = account.authType
            settings.tokenName = account.tokenName
            try settings.validate()
            try saveSettings(settings)
            var password = secrets.password
            if account.authType != "oidc", account.appendOTPToPassword {
                password += try TOTP(setup: secrets.otpSetup).code()
            }
            let onURL: ((URL) -> Void)? = account.authType == "oidc" ? { [weak self] url in
                guard let self else { return }
                do { self.browserLogin = try BrowserLogin(account: account, secrets: secrets, url: url) }
                catch { self.cancelLogin(); self.error = error.localizedDescription }
            } : nil
            client.login(settings: settings, username: account.username, password: password, onAuthorizationURL: onURL) { [weak self] in
                guard let self else { return }
                self.browserLogin?.stop(); self.browserLogin = nil
                self.client.loadTargets(settings: self.configuration.settings)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func persist(_ updated: AppConfiguration) throws {
        guard canSave else { throw BridgeError.message("Cấu hình hiện tại bị lỗi. Sửa hoặc đổi tên file config.json trước khi mở lại app.") }
        try updated.save()
        configuration = updated
    }

    private func makeSession(_ profile: TunnelProfile) {
        let session = TunnelSession(profile: profile, settings: configuration.settings)
        sessions[profile.id] = session
        observations[profile.id] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
