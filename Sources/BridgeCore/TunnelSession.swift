import Foundation
import Combine

public enum TunnelState: Equatable {
    case stopped, starting, connected, retrying(Int), failed(String)
    public var title: String {
        switch self {
        case .stopped: return "Đã ngắt"
        case .starting: return "Đang kết nối"
        case .connected: return "Đã kết nối"
        case .retrying(let seconds): return "Thử lại sau \(seconds)s"
        case .failed: return "Lỗi kết nối"
        }
    }
}

public final class TunnelSession: ObservableObject, Identifiable {
    public let id: UUID
    public let profile: TunnelProfile
    @Published public private(set) var state: TunnelState = .stopped
    @Published public private(set) var upstreamPort: UInt16?
    @Published public private(set) var connectionCount = 0
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var wanted = false
    private var settings: BoundarySettings
    private var forwarder: TCPForwarder?
    private var command: CommandProcess?
    private var retry: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var generation = UUID()
    private var attempt = 0
    private var lastError = ""
    private var connectedAt: Date?

    public init(profile: TunnelProfile, settings: BoundarySettings) {
        self.id = profile.id
        self.profile = profile
        self.settings = settings
    }

    public func start() {
        guard !wanted else { return }
        do {
            try profile.validate(others: [])
            if profile.mode == .managed { try settings.validate() }
            wanted = true
            state = .starting
            attempt = 0
            let forwarder = TCPForwarder()
            self.forwarder = forwarder
            forwarder.onConnectionCount = { [weak self] count in self?.connectionCount = count }
            forwarder.onFailure = { [weak self] error in self?.fail(error) }
            forwarder.onReady = { [weak self] in
                guard let self, self.wanted else { return }
                if self.profile.mode == .existing {
                    self.activate(port: UInt16(self.profile.existingPort))
                } else { self.launchBoundary() }
            }
            try forwarder.start(port: UInt16(profile.localPort))
            log("Đã yêu cầu mở 127.0.0.1:\(profile.localPort).")
        } catch { fail(error.localizedDescription) }
    }

    public func stop() {
        wanted = false
        generation = UUID()
        retry?.cancel(); retry = nil
        timeout?.cancel(); timeout = nil
        command?.stop(); command = nil
        forwarder?.stop(); forwarder = nil
        upstreamPort = nil
        connectedAt = nil
        state = .stopped
        log("Đã ngắt kết nối và giải phóng port.")
    }

    private func launchBoundary() {
        guard wanted else { return }
        state = .starting
        lastError = ""
        let generation = UUID()
        self.generation = generation
        let command = CommandProcess()
        self.command = command
        do {
            try command.start(executable: settings.resolvedExecutable, arguments: settings.connectArguments(for: profile),
                              environment: settings.environment, onLine: { [weak self] line, isError in
                guard let self, self.generation == generation, self.wanted else { return }
                if isError {
                    let clean = LogSanitizer.clean(line)
                    if !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastError = clean
                        self.log(clean)
                    }
                    return
                }
                do {
                    switch try BoundaryEvent.parse(line) {
                    case .listening(let port, _):
                        guard port != self.profile.localPort else {
                            self.fail("Port Boundary trùng với port cố định."); return
                        }
                        self.activate(port: port)
                    case .terminated(let reason):
                        self.lastError = LogSanitizer.clean(reason)
                        self.log("Boundary: \(self.lastError)")
                        self.forwarder?.route(to: nil)
                        self.upstreamPort = nil
                    case .ignored: break
                    }
                } catch { self.fail(error.localizedDescription) }
            }, onExit: { [weak self] code in
                guard let self, self.generation == generation, self.wanted else { return }
                self.timeout?.cancel()
                self.command = nil
                self.forwarder?.route(to: nil)
                self.upstreamPort = nil
                if let since = self.connectedAt, Date().timeIntervalSince(since) >= 30 { self.attempt = 0 }
                self.connectedAt = nil
                let message = self.lastError.isEmpty ? "Boundary đã dừng (mã \(code))." : self.lastError
                self.scheduleRetry(message)
            })
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation, self.upstreamPort == nil else { return }
                self.lastError = "Boundary chưa cấp port sau 45 giây. Kiểm tra VPN và đăng nhập."
                self.log(self.lastError)
                self.command?.stop()
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
            log("Đang yêu cầu tunnel cho \(profile.targetID)…")
        } catch { fail(error.localizedDescription) }
    }

    private func activate(port: UInt16) {
        timeout?.cancel(); timeout = nil
        upstreamPort = port
        forwarder?.route(to: port)
        connectedAt = Date()
        state = .connected
        log("127.0.0.1:\(profile.localPort) → 127.0.0.1:\(port)")
    }

    private func scheduleRetry(_ message: String) {
        log(message)
        guard profile.reconnect, attempt < 6 else {
            fail("\(message) Kiểm tra đăng nhập/VPN rồi kết nối lại."); return
        }
        let delay = min(1 << (attempt + 1), 30)
        attempt += 1
        state = .retrying(delay)
        let retry = DispatchWorkItem { [weak self] in self?.launchBoundary() }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: retry)
    }

    private func fail(_ message: String) {
        stop()
        state = .failed(message)
        log(message)
    }

    private func log(_ text: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("\(time)  \(LogSanitizer.clean(text))")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
}
