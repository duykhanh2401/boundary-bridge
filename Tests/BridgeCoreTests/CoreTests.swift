import Foundation
import Combine
import Darwin
import BridgeCore

final class CoreTests: CheckSuite {
    func testFragmentedJSONAndUTF8() throws {
        var decoder = LineDecoder()
        let input = Data("{\"address\":\"127.0.0.1\",\"port\":54321,\"protocol\":\"tcp\",\"session_id\":\"s_test\"}\n{\"termination_reason\":\"Đã hết hạn\"}\n".utf8)
        var lines: [String] = []
        for byte in input { lines += try decoder.append(Data([byte])) }
        checkEqual(lines.count, 2)
        checkEqual(try BoundaryEvent.parse(lines[0]), .listening(port: 54321, sessionID: "s_test"))
        checkEqual(try BoundaryEvent.parse(lines[1]), .terminated("Đã hết hạn"))
        checkNil(decoder.finish())
    }

    func testUntrustedEndpointAndOversizedOutput() throws {
        checkThrows(try BoundaryEvent.parse(#"{"address":"0.0.0.0","port":40000,"protocol":"tcp"}"#))
        checkThrows(try BoundaryEvent.parse(#"{"address":"127.0.0.1","port":70000,"protocol":"tcp"}"#))
        checkThrows(try BoundaryEvent.parse(#"{"address":"127.0.0.1","port":1234,"protocol":"udp"}"#))
        checkEqual(try BoundaryEvent.parse(#"{"credentials":[{"secret":"do-not-log"}]}"#), .ignored)
        var decoder = LineDecoder()
        checkThrows(try decoder.append(Data(repeating: 65, count: 1_048_577)))
    }

    func testConfigurationValidationAndRoundTrip() throws {
        var profile = TunnelProfile()
        profile.targetID = "ttcp_test"
        var duplicate = profile
        duplicate.id = UUID()
        checkThrows(try duplicate.validate(others: [profile]))
        duplicate.localPort = 80
        checkThrows(try duplicate.validate(others: []))
        duplicate.mode = .existing
        duplicate.localPort = 5432
        duplicate.existingPort = 5432
        checkThrows(try duplicate.validate(others: []))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var configuration = AppConfiguration()
        configuration.profiles = [profile]
        try configuration.save(to: file)
        checkEqual(try AppConfiguration.load(from: file).profiles, [profile])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        checkEqual(permissions, 0o600)
        let data = try Data(contentsOf: file)
        checkFalse(String(decoding: data, as: UTF8.self).contains("password"))
    }

    func testCLIArgumentsPreserveLiteralInputAndForceLoopback() {
        var settings = BoundarySettings()
        settings.address = "https://boundary.example.com"
        var profile = TunnelProfile()
        profile.targetID = "ttcp_$(touch /tmp/never-run)"
        let arguments = settings.connectArguments(for: profile)
        checkTrue(arguments.contains("-target-id=\(profile.targetID)"))
        checkTrue(arguments.contains("-listen-addr=127.0.0.1"))
        checkTrue(arguments.contains("-listen-port=0"))
        checkTrue(arguments.contains("-format=json"))
        checkNil(settings.environment["BOUNDARY_CONNECT_EXEC"])
    }

    func testSanitizeSecrets() {
        let output = LogSanitizer.clean("token=at_ABC_secret password=hunter2 Authorization: Bearer secret-value")
        checkFalse(output.contains("hunter2"))
        checkFalse(output.contains("at_ABC_secret"))
        checkFalse(output.contains("secret-value"))
    }

    func testResourceListDecoding() throws {
        let data = Data(#"{"items":[{"id":"ttcp_1","type":"tcp","name":"Postgres","scope_id":"p_1","attributes":{"default_port":5432}}]}"#.utf8)
        let list = try JSONDecoder().decode(BoundaryResourceList.self, from: data)
        checkEqual(list.items?.first?.title, "Postgres")
        checkEqual(list.items?.first?.attributes?.defaultPort, 5432)
    }
}

final class TunnelIntegrationTests: CheckSuite {
    private var subscriptions: Set<AnyCancellable> = []

    override func tearDown() { subscriptions.removeAll(); super.tearDown() }

    func testClientLoginDiscoveryAndLogout() throws {
        let client = BoundaryClient()
        defer { client.cancel() }
        var settings = BoundarySettings()
        settings.address = "http://127.0.0.1:9200"
        settings.authMethodID = "ampw_fixture"
        settings.authType = "password"
        settings.executable = Bundle.module.url(forResource: "fake-boundary", withExtension: "py", subdirectory: "Fixtures")!.path
        let methods = expectation(description: "Auth methods loaded")
        client.$authMethods.filter { !$0.isEmpty }.prefix(1).sink { _ in methods.fulfill() }.store(in: &subscriptions)
        client.loadAuthMethods(settings: settings)
        try wait(for: [methods], timeout: 5)
        checkEqual(client.authMethods.first?.id, "ampw_fixture")
        let login = expectation(description: "Password login completed")
        client.login(settings: settings, username: "test-user", password: "test-password-only") { login.fulfill() }
        try wait(for: [login], timeout: 5)
        checkTrue(client.authenticated)
        checkFalse(client.message.contains("at_sensitive_fixture_secret"))
        let targets = expectation(description: "Targets loaded")
        client.$targets.filter { !$0.isEmpty }.prefix(1).sink { _ in targets.fulfill() }.store(in: &subscriptions)
        client.loadTargets(settings: settings)
        try wait(for: [targets], timeout: 5)
        checkEqual(client.targets.first?.id, "ttcp_fixture")
        let logout = expectation(description: "Logged out")
        client.$busy.dropFirst().filter { !$0 }.prefix(1).sink { _ in logout.fulfill() }.store(in: &subscriptions)
        client.logout(settings: settings)
        checkFalse(client.authenticated)
        try wait(for: [logout], timeout: 5)
        checkTrue(client.targets.isEmpty)
    }

    func testIndependentTargets() throws {
        let first = try makeSession(), second = try makeSession()
        defer { first.stop(); second.stop() }
        let readyA = expectation(description: "First target ready"), readyB = expectation(description: "Second target ready")
        first.$state.filter { $0 == .connected }.prefix(1).sink { _ in readyA.fulfill() }.store(in: &subscriptions)
        second.$state.filter { $0 == .connected }.prefix(1).sink { _ in readyB.fulfill() }.store(in: &subscriptions)
        first.start(); second.start()
        try wait(for: [readyA, readyB], timeout: 10)
        checkNotEqual(first.upstreamPort, second.upstreamPort)
        first.stop()
        let transfer = expectation(description: "Second target stays connected")
        DispatchQueue.global().async {
            let data = Data("independent target".utf8)
            do { checkEqual(try exchange(port: UInt16(second.profile.localPort), payload: data), data) }
            catch { checkFail("\(error)") }
            transfer.fulfill()
        }
        try wait(for: [transfer], timeout: 5)
        checkEqual(second.state, .connected)
    }

    func testRealTCPBytesHalfCloseConcurrentClientsAndStop() throws {
        let session = try makeSession()
        defer { session.stop() }
        let ready = expectation(description: "Boundary endpoint parsed and fixed port ready")
        session.$state.filter { $0 == .connected }.prefix(1).sink { _ in ready.fulfill() }.store(in: &subscriptions)
        session.start()
        try wait(for: [ready], timeout: 15)
        checkNotEqual(Int(session.upstreamPort ?? 0), session.profile.localPort)
        checkTrue(session.wanted)

        let data = Data((0..<1_200_000).map { UInt8($0 % 251) })
        let clients = (0..<4).map { expectation(description: "TCP client \($0) full response after FIN") }
        for complete in clients {
            DispatchQueue.global().async {
                do {
                    let response = try exchange(port: UInt16(session.profile.localPort), payload: data)
                    if response != data { print("  payload mismatch: received \(response.count), expected \(data.count); first mismatch \(zip(response, data).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)") }
                    checkEqual(response, data)
                }
                catch { checkFail("TCP transfer failed: \(error)") }
                complete.fulfill()
            }
        }
        try wait(for: clients, timeout: 20)
        session.stop()
        checkEqual(session.state, .stopped)
        checkNil(session.upstreamPort)
        let released = expectation(description: "Port released")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                let fd = try boundSocket(port: UInt16(session.profile.localPort))
                Darwin.close(fd)
            } catch { checkFail("Fixed port was not released: \(error)") }
            released.fulfill()
        }
        try wait(for: [released], timeout: 3)
    }

    func testReconnectUsesNewUpstreamAndSameFixedPort() throws {
        let session = try makeSession()
        defer { session.stop() }
        let first = expectation(description: "First connection")
        session.$state.filter { $0 == .connected }.prefix(1).sink { _ in first.fulfill() }.store(in: &subscriptions)
        session.start()
        try wait(for: [first], timeout: 15)
        let oldPort = session.upstreamPort
        let second = expectation(description: "Reconnected")
        session.$state.dropFirst().filter { $0 == .connected }.prefix(1).sink { _ in second.fulfill() }.store(in: &subscriptions)
        DispatchQueue.global().async { _ = try? exchange(port: UInt16(session.profile.localPort), payload: Data("__DROP__".utf8)) }
        try wait(for: [second], timeout: 15)
        checkNotNil(session.upstreamPort)
        checkNotEqual(oldPort, session.upstreamPort)
        let transfer = expectation(description: "Same fixed port works after reconnect")
        DispatchQueue.global().async {
            let data = Data("after reconnect".utf8)
            do { checkEqual(try exchange(port: UInt16(session.profile.localPort), payload: data), data) }
            catch { checkFail("\(error)") }
            transfer.fulfill()
        }
        try wait(for: [transfer], timeout: 5)
    }

    func testOccupiedPortFailsWithoutStartingTunnel() throws {
        let occupied = try boundSocket(port: 0)
        defer { Darwin.close(occupied) }
        checkEqual(Darwin.listen(occupied, 8), 0)
        let session = try makeSession(port: socketPort(occupied))
        defer { session.stop() }
        let failed = expectation(description: "Conflict reported")
        session.$state.sink { if case .failed = $0 { failed.fulfill() } }.store(in: &subscriptions)
        session.start()
        try wait(for: [failed], timeout: 8)
        checkFalse(session.wanted)
        checkNil(session.upstreamPort)
    }

    func testStopDuringRetryDoesNotRestart() throws {
        let session = try makeSession()
        defer { session.stop() }
        let ready = expectation(description: "Connected")
        session.$state.filter { $0 == .connected }.prefix(1).sink { _ in ready.fulfill() }.store(in: &subscriptions)
        session.start()
        try wait(for: [ready], timeout: 15)
        let retrying = expectation(description: "Retry scheduled")
        session.$state.sink { if case .retrying = $0 { retrying.fulfill() } }.store(in: &subscriptions)
        DispatchQueue.global().async { _ = try? exchange(port: UInt16(session.profile.localPort), payload: Data("__DROP__".utf8)) }
        try wait(for: [retrying], timeout: 8)
        session.stop()
        let settled = expectation(description: "Cancelled retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            checkEqual(session.state, .stopped)
            checkNil(session.upstreamPort)
            checkFalse(session.wanted)
            settled.fulfill()
        }
        try wait(for: [settled], timeout: 5)
    }

    private func makeSession(port: UInt16? = nil) throws -> TunnelSession {
        var profile = TunnelProfile()
        profile.targetID = "ttcp_integration"
        if let port { profile.localPort = Int(port) }
        else {
            let fd = try boundSocket(port: 0)
            profile.localPort = Int(try socketPort(fd))
            Darwin.close(fd)
        }
        var settings = BoundarySettings()
        settings.address = "http://127.0.0.1:9200"
        settings.executable = Bundle.module.url(forResource: "fake-boundary", withExtension: "py", subdirectory: "Fixtures")!.path
        let session = TunnelSession(profile: profile, settings: settings)
        session.$logs.sink { if let line = $0.last { print("  tunnel: \(line)") } }.store(in: &subscriptions)
        return session
    }
}

private func boundSocket(port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { let code = errno; Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    return fd
}

private func socketPort(_ fd: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    return UInt16(bigEndian: address.sin_port)
}

private func exchange(port: UInt16, payload: Data) throws -> Data {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try payload.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            guard sent > 0 else { throw POSIXError(.EIO) }
            offset += sent
        }
    }
    shutdown(fd, SHUT_WR)
    var output = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if count == 0 { return output }
        output.append(contentsOf: buffer.prefix(count))
    }
}
