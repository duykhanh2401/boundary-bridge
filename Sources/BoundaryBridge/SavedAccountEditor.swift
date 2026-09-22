import SwiftUI
import BridgeCore

struct SavedAccountEditor: View {
    @State var account: SavedAccount
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var otpSetup = ""
    @State private var removeOTP = false
    @State private var error: String?
    private var exists: Bool { store.configuration.accounts.contains { $0.id == account.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(exists ? "Sửa tài khoản" : "Thêm tài khoản").font(.title2.weight(.semibold))
            Form {
                TextField("Tên gợi nhớ", text: $account.name, prompt: Text("Ví dụ: Nick công việc"))
                TextField("Tên đăng nhập", text: $account.username)
                SecureField("Mật khẩu", text: $password, prompt: Text(exists ? "Để trống để giữ mật khẩu cũ" : "Mật khẩu đăng nhập"))
                SecureField("Khóa thiết lập OTP", text: $otpSetup, prompt: Text(account.hasOTP ? "Để trống để giữ khóa cũ" : "Secret Base32 hoặc otpauth://totp/…"))
                    .disabled(removeOTP)
                if account.hasOTP { Toggle("Xóa khóa OTP đã lưu", isOn: $removeOTP) }
                Text("Nhập khóa thiết lập từ Authenticator, không phải mã 6 số đang hiển thị. App tự tạo mã mới mỗi lần đăng nhập.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Kiểu đăng nhập", selection: $account.authType) {
                    Text("OIDC · tài khoản + mật khẩu + ô OTP riêng").tag("oidc")
                    Text("Boundary password").tag("password")
                    Text("LDAP").tag("ldap")
                }
                TextField("Auth Method ID", text: $account.authMethodID)
                if account.authType != "oidc" {
                    Toggle("Ghép OTP sau mật khẩu (chỉ khi máy chủ yêu cầu)", isOn: $account.appendOTPToPassword)
                }
            }.textFieldStyle(.roundedBorder)
            Label("Mật khẩu và khóa OTP được lưu trong macOS Keychain.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
            Text(account.controller).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu tài khoản") {
                    do {
                        account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        account.username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
                        try store.saveAccount(account, password: password, otpSetup: otpSetup, removeOTP: removeOTP)
                        password = ""; otpSetup = ""; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 570)
    }
}
