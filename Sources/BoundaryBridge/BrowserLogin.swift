import SwiftUI
import WebKit
import BridgeCore

typealias BrowserLogin = EmbeddedLogin

private struct LoginWebView: NSViewRepresentable {
    let login: BrowserLogin
    func makeNSView(context: Context) -> WKWebView { login.start(); return login.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserLoginView: View {
    @ObservedObject var login: BrowserLogin
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Đăng nhập · \(login.name)").font(.title3.weight(.semibold))
                    Text(login.status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Hủy", action: cancel).keyboardShortcut(.cancelAction)
            }
            LoginWebView(login: login)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Label(login.url.host ?? "", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Tiếp tục bằng trình duyệt ngoài") { login.stop(); NSWorkspace.shared.open(login.url) }
            }
        }.padding(20).frame(width: 790, height: 680).interactiveDismissDisabled()
    }
}
