import Foundation
import Combine

public struct BoundaryResource: Decodable, Identifiable {
    public let id: String
    public let name: String?
    public let type: String?
    public let description: String?
    public let scopeID: String?
    public let attributes: Attributes?
    public struct Attributes: Decodable {
        public let defaultPort: Int?
        enum CodingKeys: String, CodingKey { case defaultPort = "default_port" }
    }
    enum CodingKeys: String, CodingKey {
        case id, name, type, description, attributes
        case scopeID = "scope_id"
    }
    public var title: String { name?.isEmpty == false ? name! : id }
}

public struct BoundaryResourceList: Decodable {
    public let items: [BoundaryResource]?
}

public final class BoundaryClient: ObservableObject {
    @Published public private(set) var busy = false
    @Published public private(set) var message = "Nhập Controller URL để bắt đầu."
    @Published public private(set) var authMethods: [BoundaryResource] = []
    @Published public private(set) var targets: [BoundaryResource] = []
    @Published public private(set) var authenticated = false
    private var command: CommandProcess?
    private var generation = UUID()
    private var deadline: DispatchWorkItem?

    public init() {}

    public func loadAuthMethods(settings: BoundarySettings) {
        request(settings: settings, arguments: ["auth-methods", "list"] + settings.commonArguments +
                ["-scope-id=\(settings.scopeID)", "-recursive", "-format=json"], capture: true) { [weak self] result in
            self?.receiveList(result) { self?.authMethods = $0 }
        }
    }

    public func loadTargets(settings: BoundarySettings) {
        request(settings: settings, arguments: ["targets", "list"] + settings.commonArguments +
                ["-scope-id=\(settings.scopeID)", "-recursive", "-format=json"], capture: true) { [weak self] result in
            self?.receiveList(result) { self?.targets = $0 }
        }
    }

    public func login(settings: BoundarySettings, username: String, password: String,
                      onAuthorizationURL: ((URL) -> Void)? = nil,
                      completion: @escaping () -> Void) {
        guard !busy else { return }
        authenticated = false
        guard !settings.authMethodID.isEmpty else { message = "Chọn hoặc nhập Auth Method ID."; return }
        guard ["oidc", "password", "ldap"].contains(settings.authType) else { return }
        if settings.authType != "oidc" && (username.isEmpty || password.isEmpty) {
            message = "Nhập tên đăng nhập và mật khẩu."; return
        }
        var args = ["authenticate", settings.authType] + settings.commonArguments +
            ["-auth-method-id=\(settings.authMethodID)", "-format=table"]
        var environment = settings.environment
        if settings.authType == "oidc", onAuthorizationURL != nil {
            let helper = BridgeResources.url("browser-helper/open")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                message = "Thiếu helper đăng nhập. Hãy build lại app."; return
            }
            environment["PATH"] = helper.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
        }
        if settings.authType != "oidc" {
            args += ["-login-name=\(username)", "-password=env://BRIDGE_LOGIN_PASSWORD"]
            environment["BRIDGE_LOGIN_PASSWORD"] = password
        }
        // Table mode lets Boundary save its token to macOS Keychain. Discard
        // stdout because authenticate output contains the token itself.
        var deliveredURL = false
        request(settings: settings, arguments: args, environment: environment, capture: false,
                timeout: 180, onOutput: { line in
            guard settings.authType == "oidc", let onAuthorizationURL, !deliveredURL,
                  let url = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  LoginOrigin.httpsOrigin(url) != nil else { return }
            deliveredURL = true
            onAuthorizationURL(url)
        }) { [weak self] result in
            switch result {
            case .success:
                self?.authenticated = true
                self?.message = "Đăng nhập thành công. Token được Boundary quản lý trong Keychain."
                completion()
            case .failure(let error): self?.message = error.localizedDescription
            }
        }
        if busy { message = settings.authType == "oidc" ? "Hoàn tất đăng nhập trong trình duyệt…" : "Đang đăng nhập…" }
    }

    public func cancel() {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        command?.stop(); command = nil
        busy = false
        message = "Đã hủy thao tác."
    }

    public func logout(settings: BoundarySettings) {
        guard !busy else { return }
        authenticated = false
        targets = []
        var args = ["logout"]
        if !settings.tokenName.isEmpty { args.append("-token-name=\(settings.tokenName)") }
        request(settings: settings, arguments: args, capture: false) { [weak self] result in
            switch result {
            case .success:
                self?.authenticated = false
                self?.targets = []
                self?.message = "Đã đăng xuất và xóa token khỏi Keychain."
            case .failure(let error): self?.message = error.localizedDescription
            }
        }
    }

    public func reset() {
        cancel()
        targets = []; authMethods = []; authenticated = false
        message = "Đã đổi cấu hình. Tải lại phương thức đăng nhập hoặc target."
    }

    private func receiveList(_ result: Result<String, Error>, apply: ([BoundaryResource]) -> Void) {
        do {
            let output = try result.get()
            let list = try JSONDecoder().decode(BoundaryResourceList.self, from: Data(output.utf8))
            let items = (list.items ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            apply(items)
            message = items.isEmpty ? "Không có kết quả trong scope này. Kiểm tra scope và quyền truy cập." : "Đã tải \(items.count) mục."
        } catch { message = error.localizedDescription }
    }

    private func request(settings: BoundarySettings, arguments: [String], environment: [String: String]? = nil,
                         capture: Bool, timeout: TimeInterval = 45,
                         onOutput: ((String) -> Void)? = nil,
                         completion: @escaping (Result<String, Error>) -> Void) {
        guard !busy else { return }
        do { try settings.validate() } catch { message = error.localizedDescription; return }
        busy = true
        message = "Đang tải dữ liệu từ Boundary…"
        let generation = UUID()
        self.generation = generation
        let command = CommandProcess()
        self.command = command
        var output = "", errors = ""
        var exceeded = false
        do {
            try command.start(executable: settings.resolvedExecutable, arguments: arguments,
                              environment: environment ?? settings.environment, onLine: { [weak self] line, isError in
                guard self?.generation == generation else { return }
                if isError {
                    if errors.utf8.count < 8192 { errors += LogSanitizer.clean(line) + "\n" }
                } else {
                    onOutput?(line)
                    if capture {
                        if output.utf8.count + line.utf8.count < 8_388_608 { output += line + "\n" }
                        else { exceeded = true; command.stop() }
                    }
                }
            }, onExit: { [weak self] code in
                guard let self, self.generation == generation else { return }
                self.deadline?.cancel(); self.deadline = nil
                self.busy = false
                self.command = nil
                if exceeded { completion(.failure(BridgeError.message("Danh sách quá lớn. Chọn scope hẹp hơn."))) }
                else if code == 0 { completion(.success(output)) }
                else { completion(.failure(BridgeError.message(errors.isEmpty ? "Boundary thất bại (mã \(code)). Kiểm tra đăng nhập và VPN." : errors))) }
            })
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation else { return }
                self.cancel()
                self.message = "Boundary không phản hồi kịp. Kiểm tra VPN/Controller URL rồi thử lại."
            }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        } catch {
            busy = false
            self.command = nil
            completion(.failure(error))
        }
    }
}
