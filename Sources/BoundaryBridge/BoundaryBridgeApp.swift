import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.shutdown()
        // Let SIGINT and the bounded process cleanup finish before exiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct BoundaryBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        Window("Boundary Bridge", id: "main") {
            ContentView(store: store)
                .onAppear { delegate.store = store }
                .frame(minWidth: 1020, minHeight: 680)
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Label("\(store.activeCount)", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Boundary Bridge · \(store.activeCount) kết nối")
        Button("Mở cửa sổ") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        ForEach(store.configuration.profiles) { profile in
            if let session = store.sessions[profile.id] {
                Button("\(session.wanted ? "Ngắt" : "Kết nối") \(profile.name) · :\(profile.localPort)") {
                    session.wanted ? session.stop() : store.start(session)
                }
                .disabled(!session.wanted && !store.canConnect)
            }
        }
        Divider()
        Button("Ngắt tất cả") { store.stopAll() }
        Button("Thoát") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
