import AppKit
import WebKit
import BridgeCore

struct CheckError: Error, CustomStringConvertible { let description: String }
final class BrowserHarness: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var loaded = false
    private let script: String
    init(scriptURL: URL) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        script = try String(contentsOf: scriptURL, encoding: .utf8)
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func load(_ fields: String, method: String = "post", action: String = "/login", form: Bool = true) throws {
        loaded = false
        let markup = form ? "<form method='\(method)' action='\(action)' onsubmit='event.preventDefault(); window.submissions++'>\(fields)<button type='submit'>Verify</button></form>" : fields
        web.loadHTMLString("<html><head><script>window.submissions=0</script></head><body>\(markup)</body></html>", baseURL: URL(string: "https://login.example.test/"))
        try wait { self.loaded }
    }
    func call(_ body: String, arguments: [String: Any] = [:], on view: WKWebView? = nil) throws -> Any {
        var answer: Result<Any, Error>?
        (view ?? web).callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { answer = $0 }
        try wait { answer != nil }
        return try answer!.get()
    }
    func autofill(completed: [String] = [], mode: String = "submit", code: String = "123456") throws -> [String: Any] {
        let result = try call(script, arguments: ["expectedOrigin": "https://login.example.test:443",
            "username": "synthetic-user", "password": "synthetic-password", "otpCode": code,
            "completedSteps": completed, "actionMode": mode, "expectedSteps": [String]()])
        guard let object = result as? [String: Any] else { throw CheckError(description: "Invalid JS result") }
        return object
    }
    func require(_ value: Bool, _ message: String) throws { if !value { throw CheckError(description: message) } }
    private func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !condition() { throw CheckError(description: "WebKit callback timeout") }
    }
    func run() throws {
        let previous = "<input name='username' value='keep-user'><input name='password' type='password' value='keep-password'>"
        try load(previous + "<input name='otp' autocomplete='one-time-code'>")
        let response = try autofill(completed: ["username", "password"])
        try require(response["status"] as? String == "submitted", "OTP blocked by credentials retained in DOM")
        try require(try call("return document.querySelector('[name=otp]').value") as? String == "123456", "OTP was not filled")
        try require(try call("return document.querySelector('[name=password]').value") as? String == "keep-password", "Password resubmitted on OTP step")
        print("PASS WebKit: OTP after credentials retained in the DOM")

        try load("<label for='challenge'>Authenticator verification code</label><input id='challenge' name='userToken' type='password'>")
        try require(try autofill(completed: ["username", "password"])["status"] as? String == "submitted", "Label-based masked OTP not detected")
        try require(try call("return document.querySelector('#challenge').value") as? String == "123456", "Masked OTP not filled")
        print("PASS WebKit: OTP identified by label, including masked fields")

        let digits = (0..<6).map { "<input name='otp-\($0)' maxlength='1' inputmode='numeric'>" }.joined()
        try load(digits)
        try require(try autofill(completed: ["username", "password"])["status"] as? String == "submitted", "Split OTP not submitted")
        try require(try call("return Array.from(document.querySelectorAll('input')).map(i=>i.value).join('')") as? String == "123456", "Split OTP digits incorrect")
        print("PASS WebKit: six separate OTP fields")

        try load("<input name='otp'>", form: false)
        try require(try autofill(completed: ["username", "password"])["status"] as? String == "filled", "Formless OTP was not filled")
        print("PASS WebKit: fills OTP even without a recognized submit form")

        try load("<input name='otp'>", action: "https://other.example.test/collect")
        try require(try autofill()["status"] as? String == "manual", "Cross-origin form accepted")
        try require(try call("return document.querySelector('input').value") as? String == "", "OTP leaked to cross-origin form")
        print("PASS WebKit: cross-origin form remains untouched")

        try load("<input name='username'><input type='password' name='password'>")
        try require(try autofill()["status"] as? String == "submitted", "Credentials were not submitted")
        try require(try autofill()["status"] as? String == "already-submitted", "Repeated submit in same page")
        try load("<input name='username'><input type='password' name='password'>")
        try require(try autofill(completed: ["username", "password"])["status"] as? String == "already-submitted", "Repeated submit after navigation")
        print("PASS WebKit: no repeat submission within/across documents")
        try runCoordinatorChecks()
    }

    private func runCoordinatorChecks() throws {
        var account = SavedAccount()
        account.name = "Synthetic"; account.username = "synthetic-user"
        let secrets = AccountSecrets(password: "synthetic-password", otpSetup: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let base = URL(string: "https://login.example.test/")!
        let flow = try EmbeddedLogin(account: account, secrets: secrets, url: base)
        defer { flow.stop() }
        flow.start()
        let credentials = "<form method='post' action='/login' onsubmit='event.preventDefault(); window.credentialsSent=true'><input name='username'><input type='password'><button type='submit'>Sign in</button></form>"
        flow.webView.loadHTMLString(credentials, baseURL: base)
        try awaitJS("return window.credentialsSent === true", on: flow.webView)
        // Real document replacement exercises WKNavigationDelegate and pending JS callbacks.
        let otpPage = "<form method='post' action='/otp' onsubmit='event.preventDefault(); window.receivedOTP=document.querySelector(\"#otp\").value'><input id='otp'><button type='submit'>Verify</button></form>"
        flow.webView.loadHTMLString(otpPage, baseURL: base)
        try awaitJS("return /^\\d{6}$/.test(window.receivedOTP || '')", on: flow.webView)
        print("PASS WebKit coordinator: password document → OTP document, no manual input")

        let spa = try EmbeddedLogin(account: account, secrets: secrets, url: base)
        defer { spa.stop() }
        spa.start()
        let markup = """
        <script>
        function nextStep(event) {
          event.preventDefault();
          document.querySelector('#credentials').style.display='none';
          document.querySelector('#challenge').style.display='block';
        }
        </script>
        <form id='credentials' method='post' action='/login' onsubmit='nextStep(event)'>
          <input name='username'><input type='password'><button type='submit'>Sign in</button>
        </form>
        <form id='challenge' style='display:none' method='post' action='/otp'
          onsubmit='event.preventDefault(); window.receivedOTP=document.querySelector("#user-code").value'>
          <label for='user-code'>Authenticator code</label><input id='user-code' name='userOtp'>
          <button type='submit'>Verify</button>
        </form>
        """
        spa.webView.loadHTMLString(markup, baseURL: base)
        try awaitJS("return /^\\d{6}$/.test(window.receivedOTP || '')", on: spa.webView)
        print("PASS WebKit coordinator: password → dynamic OTP without navigation")
    }

    private func awaitJS(_ body: String, on view: WKWebView) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if (try? call(body, on: view)) as? Bool == true { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        throw CheckError(description: "Automatic login did not advance to expected stage")
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
do {
    let harness = try BrowserHarness(scriptURL: BridgeResources.url("autofill.js"))
    try harness.run()
    print("8 native WebKit checks; 0 failures")
} catch {
    fputs("FAIL native WebKit: \(error)\n", stderr)
    exit(1)
}
