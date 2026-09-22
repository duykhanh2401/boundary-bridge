import Foundation
import Combine
import WebKit

public final class EmbeddedLogin: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    public let id = UUID()
    public let name: String
    public let url: URL
    public let webView: WKWebView
    @Published public private(set) var status = "Đang mở màn hình đăng nhập…"
    private let origin: String
    private var username: String
    private var password: String
    private var otp: TOTP?
    private var timer: Timer?
    private var evaluating = false
    private var evaluationID = UUID()
    private var completed: Set<String> = []
    private var navigating = false
    private var stopped = false
    private let script: String

    public init(account: SavedAccount, secrets: AccountSecrets, url: URL) throws {
        guard let origin = LoginOrigin.httpsOrigin(url) else { throw BridgeError.message("Trang đăng nhập phải dùng HTTPS.") }
        self.name = account.name; self.url = url; self.origin = origin
        username = account.username; password = secrets.password
        otp = secrets.otpSetup.isEmpty ? nil : try TOTP(setup: secrets.otpSetup)
        script = try String(contentsOf: BridgeResources.url("autofill.js"), encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        // No shared cookies: selecting a different account cannot silently reuse
        // the previous person's IdP session.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    public func start() {
        guard timer == nil, !stopped else { return }
        webView.load(URLRequest(url: url))
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.fill() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func stop() {
        stopped = true
        evaluationID = UUID()
        timer?.invalidate(); timer = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        username = ""; password = ""; otp = nil
    }

    private func fill() {
        guard !stopped, !evaluating, !navigating, let current = webView.url,
              LoginOrigin.httpsOrigin(current) == origin else { return }
        if let otp, otp.remaining() <= min(3, otp.period / 5) {
            status = "Đang chờ mã OTP mới…"; return
        }
        guard let code = try? otp?.code() ?? "" else { status = "Không tạo được OTP. Kiểm tra khóa đã lưu."; return }
        evaluating = true
        let evaluationID = UUID()
        self.evaluationID = evaluationID
        var arguments: [String: Any] = [
            "expectedOrigin": origin, "username": username, "password": password,
            "otpCode": code, "completedSteps": Array(completed), "actionMode": "inspect", "expectedSteps": [String]()
        ]
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self, !self.stopped, self.evaluationID == evaluationID else { return }
            self.evaluating = false
            guard case .success(let value) = result, let output = value as? [String: Any],
                  let status = output["status"] as? String else {
                self.status = "Chưa đọc được màn hình đăng nhập. Bạn có thể thao tác bên dưới."
                return
            }
            switch status {
            case "ready":
                let steps = output["steps"] as? [String] ?? []
                guard !steps.isEmpty else { return }
                // Commit the attempt BEFORE navigation can destroy the JS context.
                // A failed password must never trigger an automatic retry loop.
                self.completed.formUnion(steps)
                arguments["actionMode"] = "submit"
                arguments["expectedSteps"] = steps
                self.evaluating = true
                self.status = steps.contains("otp") ? "Đang gửi OTP…" : "Đang gửi thông tin đăng nhập…"
                self.webView.callAsyncJavaScript(self.script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                    guard let self, !self.stopped, self.evaluationID == evaluationID else { return }
                    self.evaluating = false
                    if case .success(let value) = result, let response = value as? [String: Any],
                       let status = response["status"] as? String {
                        if status == "filled" { self.status = "Đã điền OTP. Bấm xác nhận trong trang để tiếp tục." }
                        else if status == "submitted" {
                            self.status = steps.contains("otp") ? "Đã gửi OTP. Đang chờ Boundary…" : "Đã gửi thông tin đăng nhập. Đang chờ bước tiếp theo…"
                        } else if status != "already-submitted" {
                            // No field was submitted: allow inspection of the updated form.
                            self.completed.subtract(steps)
                        }
                    }
                }
            case "submitted":
                let steps = output["steps"] as? [String] ?? []
                self.completed.formUnion(steps)
                self.status = steps.contains("otp") ? "Đã gửi OTP. Đang chờ Boundary…" : "Đã gửi thông tin đăng nhập. Đang chờ bước tiếp theo…"
            case "needs-otp": self.status = "Nhập OTP trong màn hình bên dưới, hoặc thêm khóa OTP vào tài khoản."
            case "manual": self.status = "Màn hình này cần thao tác trực tiếp. Bạn có thể tiếp tục bên dưới."
            case "already-submitted": self.status = "Đã gửi bước này. Nếu có lỗi, kiểm tra thông tin và thao tác tiếp bên dưới."
            default: break
            }
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigating = true
        // An evaluation from the old document must not block the next OTP page.
        evaluationID = UUID()
        evaluating = false
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigating = false
        if let url = webView.url, LoginOrigin.httpsOrigin(url) != origin {
            status = "Đã chuyển sang trang khác. App đang chờ Boundary xác nhận; thông tin không được tự điền ở miền khác."
        }
        fill()
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigating = false
        status = "Không tải được trang đăng nhập. Kiểm tra VPN hoặc dùng trình duyệt ngoài."
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigating = false
        status = "Trang đăng nhập bị gián đoạn. Bạn có thể hủy và thử lại."
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "about" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    deinit { timer?.invalidate() }
}
