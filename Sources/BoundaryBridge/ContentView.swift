import SwiftUI
import AppKit
import BridgeCore

private enum Page: String, CaseIterable {
    case connections = "Kết nối", targets = "Targets", account = "Boundary"
    var icon: String {
        switch self {
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .targets: return "server.rack"
        case .account: return "person.crop.circle"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: AppStore
    @State private var page: Page = .connections
    @State private var editing: TunnelProfile?
    @State private var deleting: TunnelProfile?
    @State private var hoveredPage: Page?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                switch page {
                case .connections: connections
                case .targets: TargetsView(store: store, client: store.client, onAdd: addTarget)
                case .account: AccountView(store: store, client: store.client)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(.teal)
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, store: store)
        }
        .sheet(item: $store.browserLogin) { login in
            BrowserLoginView(login: login) { store.cancelLogin() }
        }
        .alert("Không thể hoàn tất", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Đóng") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Xóa cấu hình kết nối?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Hủy", role: .cancel) { deleting = nil }
            Button("Xóa", role: .destructive) { if let deleting { store.remove(deleting) }; deleting = nil }
        } message: { Text("Kết nối đang chạy sẽ được ngắt. Target trên Boundary vẫn được giữ nguyên.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 25, weight: .semibold)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BOUNDARY").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    Text("Bridge").font(.system(size: 23, weight: .semibold))
                }
            }
            VStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon).frame(width: 20)
                            Text(item.rawValue).fontWeight(.medium)
                            Spacer()
                            if item == .connections { Text("\(store.configuration.profiles.count)").foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(page == item ? Color.teal.opacity(0.12) : hoveredPage == item ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(page == item ? Color.teal : Color.primary)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { hoveredPage = item }
                            else if hoveredPage == item { hoveredPage = nil }
                        }
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("\(store.activeCount) tunnel hoạt động", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(store.activeCount > 0 ? .teal : .secondary)
                Text("Port ổn định.\nKết nối liền mạch.")
                    .font(.system(size: 18, weight: .medium)).lineSpacing(4)
                Text("Đóng cửa sổ để tiếp tục chạy\ntrên thanh menu của macOS.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(.horizontal, 8)
        }
        .padding(22)
        .frame(width: 215)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(page == .connections ? "Không đổi port. Không đổi config." : page == .targets ? "Targets của bạn" : "Kết nối với Boundary")
                    .font(.system(size: 25, weight: .semibold))
                Text(page == .connections ? "Mỗi dịch vụ, một địa chỉ localhost cố định." : page == .targets ? "Chọn target và gán port sử dụng trên máy này." : "Đăng nhập và quản lý controller ngay tại đây.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if page == .connections {
                Button { editing = newProfile() } label: { Label("Thêm kết nối", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }

    @ViewBuilder private var connections: some View {
        if store.configuration.profiles.isEmpty {
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 52, weight: .light)).foregroundStyle(.teal)
                Text("Đưa dịch vụ về một port quen thuộc").font(.title2.weight(.semibold))
                Text("Đăng nhập Boundary, chọn target và đặt port một lần.\nỨng dụng của bạn luôn kết nối tới cùng địa chỉ localhost.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5)
                Text("localhost:15432  →  Boundary  →  Database")
                    .font(.system(.callout, design: .monospaced)).padding(16)
                    .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                Button("Thiết lập Boundary") { page = .account }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Tôi đã có Target ID") { editing = newProfile() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("ĐÃ LƯU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("Kết nối tất cả") { store.startAll() }.disabled(!store.canConnect)
                            Button("Ngắt tất cả") { store.stopAll() }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
                    }.padding(18)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.configuration.profiles) { profile in
                                if let session = store.sessions[profile.id] {
                                    ConnectionRow(session: session, selected: store.selectedID == profile.id)
                                        .onTapGesture { store.selectedID = profile.id }
                                }
                            }
                        }.padding(.horizontal, 12)
                    }
                }.frame(width: 270)
                Divider()
                if let id = store.selectedID, let session = store.sessions[id] {
                    SessionDetail(session: session, canConnect: store.canConnect, onConnect: { store.start(session) },
                                  onEdit: { editing = session.profile }, onDelete: { deleting = session.profile })
                } else { Text("Chọn một kết nối").frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary) }
            }
        }
    }

    private func newProfile() -> TunnelProfile {
        var profile = TunnelProfile()
        let used = Set(store.configuration.profiles.map(\.localPort))
        profile.localPort = (15432...65535).first { !used.contains($0) } ?? 15432
        return profile
    }

    private func addTarget(_ target: BoundaryResource) {
        var profile = newProfile()
        profile.name = target.title
        profile.targetID = target.id
        if let port = target.attributes?.defaultPort, (1024...55535).contains(port) {
            let candidate = port + 10000
            if !store.configuration.profiles.contains(where: { $0.localPort == candidate }) { profile.localPort = candidate }
        }
        editing = profile
    }
}

private struct ConnectionRow: View {
    @ObservedObject var session: TunnelSession
    var selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "server.rack").foregroundStyle(.teal)
                Text(session.profile.name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Circle().fill(session.state == .connected ? Color.teal : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            }
            Text("127.0.0.1:\(session.profile.localPort)").font(.system(.caption, design: .monospaced))
            Text(session.state.title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.teal.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.teal.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
    }
}

private struct SessionDetail: View {
    @ObservedObject var session: TunnelSession
    var canConnect: Bool
    var onConnect: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.profile.name).font(.title2.weight(.semibold))
                        Label(session.state.title, systemImage: session.state == .connected ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(session.state == .connected ? .teal : .secondary)
                    }
                    Spacer()
                    Button(session.wanted ? "Ngắt kết nối" : "Kết nối") {
                        session.wanted ? session.stop() : onConnect()
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!session.wanted && !canConnect)
                        .help(canConnect || session.wanted ? "" : "Đăng nhập Boundary trước khi kết nối tunnel.")
                }
                if !canConnect && !session.wanted {
                    Label("Đăng nhập tại mục Boundary để kết nối tunnel.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text("ĐỊA CHỈ DÙNG TRONG CONFIG").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text("127.0.0.1:\(session.profile.localPort)").font(.system(size: 23, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("127.0.0.1:\(session.profile.localPort)", forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }.help("Sao chép địa chỉ")
                    }
                    Divider()
                    HStack {
                        Label("Port Boundary", systemImage: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Spacer()
                        Text(session.upstreamPort.map { "127.0.0.1:\($0)" } ?? "Chưa kết nối").font(.system(.body, design: .monospaced))
                    }
                }.padding(20).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                if case .failed(let message) = session.state {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow { Text("Target").foregroundStyle(.secondary); Text(session.profile.targetID.isEmpty ? "Port thủ công" : session.profile.targetID).textSelection(.enabled) }
                    GridRow { Text("TCP đang mở").foregroundStyle(.secondary); Text("\(session.connectionCount)") }
                    GridRow { Text("Tự kết nối lại").foregroundStyle(.secondary); Text(session.profile.reconnect ? "Bật" : "Tắt") }
                }.font(.callout)
                HStack {
                    Button("Sửa cấu hình", action: onEdit).disabled(session.wanted)
                    Spacer()
                    Button("Xóa", role: .destructive, action: onDelete)
                }
                Divider()
                Text("NHẬT KÝ KẾT NỐI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(session.logs.isEmpty ? "Sẵn sàng kết nối." : session.logs.suffix(60).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(26)
        }
    }
}

private struct ProfileEditor: View {
    @State var profile: TunnelProfile
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cấu hình kết nối").font(.title2.weight(.semibold))
            Form {
                TextField("Tên hiển thị", text: $profile.name)
                Picker("Nguồn tunnel", selection: $profile.mode) {
                    ForEach(ConnectionMode.allCases) { Text($0.title).tag($0) }
                }
                if profile.mode == .managed {
                    TextField("Target ID", text: $profile.targetID, prompt: Text("ttcp_…"))
                    TextField("Host ID (tùy chọn)", text: $profile.hostID)
                } else {
                    TextField("Port Boundary", value: $profile.existingPort, format: .number.grouping(.never))
                    Text("Chế độ thủ công: cập nhật port này khi Boundary Desktop cấp port mới.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Port cố định", value: $profile.localPort, format: .number.grouping(.never))
                if profile.mode == .managed { Toggle("Tự kết nối lại khi phiên bị ngắt", isOn: $profile.reconnect) }
            }.textFieldStyle(.roundedBorder)
            Text("Ứng dụng của bạn sử dụng 127.0.0.1:\(profile.localPort). Port chỉ mở trên máy này.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu cấu hình") {
                    do { try store.saveProfile(profile); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 510)
    }
}

struct TargetsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var client: BoundaryClient
    var onAdd: (BoundaryResource) -> Void
    @State private var search = ""
    var filtered: [BoundaryResource] {
        client.targets.filter { search.isEmpty || "\($0.title) \($0.id) \($0.scopeID ?? "")".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                TextField("Tìm target theo tên, ID hoặc scope", text: $search).textFieldStyle(.roundedBorder)
                Button { client.loadTargets(settings: store.configuration.settings) } label: { Label("Tải targets", systemImage: "arrow.clockwise") }
                    .disabled(client.busy)
            }
            HStack {
                if client.busy { ProgressView().controlSize(.small) }
                Text(client.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(client.targets.isEmpty ? "Đăng nhập tại mục Boundary rồi tải danh sách target." : "Không tìm thấy target phù hợp.")
                        .foregroundStyle(.secondary)
                    Text("Bạn cũng có thể thêm kết nối trực tiếp bằng Target ID.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { target in
                            HStack(spacing: 16) {
                                Image(systemName: "server.rack").font(.title2).foregroundStyle(.teal)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(target.title).fontWeight(.semibold)
                                    Text("\(target.id) · \(target.scopeID ?? "")").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                    if let description = target.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text((target.type ?? "tcp").uppercased()).font(.caption).foregroundStyle(.secondary)
                                Button("Gán port") { onAdd(target) }.disabled(target.type != "tcp")
                                    .help(target.type == "tcp" ? "Tạo kết nối với port cố định" : "Phiên bản này hỗ trợ target TCP")
                            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }.padding(28)
    }
}

struct AccountView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var client: BoundaryClient
    @State private var draft = BoundarySettings()
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var editingAccount: SavedAccount?
    @State private var deletingAccount: SavedAccount?
    private var selectedSavedAccount: SavedAccount? {
        let matching = store.configuration.accounts.filter {
            $0.controller == draft.address && $0.authMethodID == draft.authMethodID && $0.authType == draft.authType
        }
        return matching.first { $0.tokenName == draft.tokenName } ?? (matching.count == 1 ? matching.first : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox("Tài khoản đã lưu") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Chọn tài khoản để tự đăng nhập và tải targets.").foregroundStyle(.secondary)
                            Spacer()
                            Button { withSavedSettings {
                                var account = SavedAccount()
                                account.controller = draft.address
                                account.authMethodID = draft.authMethodID
                                account.authType = draft.authType
                                editingAccount = account
                            } } label: { Label("Thêm tài khoản", systemImage: "plus") }
                                .disabled(client.busy || store.hasRunning)
                        }
                        if store.configuration.accounts.isEmpty {
                            Text("Lưu tài khoản, mật khẩu và khóa OTP một lần. Những lần sau chỉ cần chọn nick.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(store.configuration.accounts) { account in
                            HStack(spacing: 12) {
                                Button {
                                    withSavedSettings { store.login(account: account) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.teal)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(account.name).fontWeight(.semibold)
                                            Text(account.username).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if account.hasOTP { Label("OTP tự động", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary) }
                                        Image(systemName: "arrow.right.circle").foregroundStyle(.teal)
                                    }.padding(12).frame(maxWidth: .infinity)
                                        .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(client.busy || store.hasRunning)
                                Menu {
                                    Button("Sửa tài khoản") { editingAccount = account }
                                    Button("Xóa tài khoản", role: .destructive) { deletingAccount = account }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
                                    .disabled(client.busy)
                            }
                        }
                        Text("Mật khẩu và khóa OTP được lưu trong Keychain trên máy này.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("Controller") {
                    Form {
                        TextField("Controller URL", text: $draft.address, prompt: Text("https://boundary.example.com:9200"))
                        TextField("Scope ID", text: $draft.scopeID, prompt: Text("global hoặc o_…"))
                        TextField("CA certificate (tùy chọn)", text: $draft.caCertificate)
                    }.textFieldStyle(.roundedBorder).padding(12)
                }
                GroupBox("Đăng nhập") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Tải phương thức đăng nhập từ controller.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Tải phương thức") { withSavedSettings { client.loadAuthMethods(settings: draft) } }.disabled(client.busy)
                        }
                        if !client.authMethods.isEmpty {
                            Picker("Phương thức", selection: $draft.authMethodID) {
                                Text("Chọn phương thức").tag("")
                                ForEach(client.authMethods) { method in Text("\(method.title) (\(method.type ?? ""))").tag(method.id) }
                            }.onChange(of: draft.authMethodID) { id in
                                if let type = client.authMethods.first(where: { $0.id == id })?.type { draft.authType = type }
                            }
                        }
                        Form {
                            TextField("Auth Method ID", text: $draft.authMethodID, prompt: Text("amoidc_… / ampw_… / amldap_…"))
                            Picker("Kiểu đăng nhập", selection: $draft.authType) {
                                Text("SSO / OIDC").tag("oidc")
                                Text("Mật khẩu").tag("password")
                                Text("LDAP").tag("ldap")
                            }
                            if draft.authType != "oidc" {
                                TextField("Tên đăng nhập", text: $username)
                                SecureField("Mật khẩu", text: $password)
                            }
                        }.textFieldStyle(.roundedBorder)
                        HStack {
                            Button(selectedSavedAccount.map { "Đăng nhập · \($0.name)" } ?? (draft.authType == "oidc" ? "Đăng nhập bằng trình duyệt" : "Đăng nhập")) {
                                withSavedSettings {
                                    if let account = selectedSavedAccount {
                                        store.login(account: account)
                                    } else {
                                        client.login(settings: draft, username: username, password: password) {
                                            client.loadTargets(settings: store.configuration.settings)
                                        }
                                    }
                                    password = ""
                                }
                            }.buttonStyle(.borderedProminent).disabled(client.busy || store.hasRunning)
                            Button("Đăng xuất") {
                                store.stopAll()
                                client.logout(settings: store.configuration.settings)
                            }.disabled(client.busy)
                            if client.busy { ProgressView().controlSize(.small); Button("Hủy") { client.cancel() } }
                        }
                        Text("Token do Boundary CLI lưu trong macOS Keychain. App không lưu mật khẩu vào cấu hình.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("Cài đặt CLI") {
                    VStack(alignment: .leading, spacing: 12) {
                        Form {
                            TextField("Boundary CLI", text: $draft.executable)
                            TextField("Tên token trong Keychain", text: $draft.tokenName)
                        }.textFieldStyle(.roundedBorder)
                        Text("Dùng CLI độc lập hoặc CLI đi kèm Boundary Desktop. Không cần mở Boundary Desktop khi sử dụng app này.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Lưu cài đặt") { withSavedSettings {} }.disabled(client.busy || store.hasRunning)
                    }.padding(12)
                }
                if store.hasRunning { Text("Ngắt các tunnel trước khi thay đổi tài khoản/controller.").foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text(client.message).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(28)
        }.onAppear { draft = store.configuration.settings }
            .onChange(of: store.configuration.settings) { draft = $0 }
            .sheet(item: $editingAccount) { account in SavedAccountEditor(account: account, store: store) }
            .alert("Xóa tài khoản đã lưu?", isPresented: Binding(get: { deletingAccount != nil }, set: { if !$0 { deletingAccount = nil } })) {
                Button("Hủy", role: .cancel) { deletingAccount = nil }
                Button("Xóa", role: .destructive) {
                    do { if let account = deletingAccount { try store.deleteAccount(account) } }
                    catch { self.error = error.localizedDescription }
                    deletingAccount = nil
                }
            } message: { Text("Mật khẩu và khóa OTP của tài khoản này sẽ được xóa khỏi Keychain.") }
    }

    private func withSavedSettings(_ action: () -> Void) {
        do {
            draft.address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.scopeID.isEmpty { draft.scopeID = "global" }
            try draft.validate()
            if draft != store.configuration.settings { try store.saveSettings(draft) }
            error = nil
            action()
        } catch { self.error = error.localizedDescription }
    }
}
