// A small Foundation-only harness: Command Line Tools do not ship XCTest.
// Run with `swift run BridgeChecks`; no Xcode app or third-party packages needed.
import Foundation
import Darwin

private let results = CheckResults()
private final class CheckResults {
    private let lock = NSLock()
    private var failures = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return failures }
    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        failures += 1
        fputs("  FAIL: \(message)\n", stderr)
    }
}

final class CheckExpectation {
    let description: String
    private let lock = NSLock()
    private var done = false
    init(_ description: String) { self.description = description }
    var fulfilled: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func fulfill() { lock.lock(); done = true; lock.unlock() }
}

class CheckSuite {
    func tearDown() {}
    func expectation(description: String) -> CheckExpectation { CheckExpectation(description) }
    func wait(for expectations: [CheckExpectation], timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while expectations.contains(where: { !$0.fulfilled }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let pending = expectations.filter { !$0.fulfilled }
        if !pending.isEmpty { throw CheckTimeout(message: "Timeout: \(pending.map(\.description).joined(separator: ", "))") }
    }
}

private struct CheckTimeout: Error, CustomStringConvertible { let message: String; var description: String { message } }

func checkFail(_ message: String, file: StaticString = #fileID, line: UInt = #line) { results.fail("\(file):\(line): \(message)") }
func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
    if a != b { checkFail("Expected equal values", file: file, line: line) }
}
func checkNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
    if a == b { checkFail("Expected different values", file: file, line: line) }
}
func checkTrue(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) { if !value { checkFail("Expected true", file: file, line: line) } }
func checkFalse(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) { checkTrue(!value, file: file, line: line) }
func checkNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) { checkTrue(value == nil, file: file, line: line) }
func checkNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) { checkTrue(value != nil, file: file, line: line) }
func checkThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line) {
    do { _ = try expression(); checkFail("Expected error", file: file, line: line) } catch {}
}

@main
struct CheckRunner {
    static func main() {
        let core = CoreTests(), network = TunnelIntegrationTests(), accounts = AccountTests()
        var checks: [(String, () throws -> Void)] = [
            ("Authentication gate: pending, successful, failed and cancelled login", accounts.testAuthenticationStateLifecycle),
            ("TOTP: RFC 6238 vectors SHA1 / SHA256 / SHA512", accounts.testTOTPVectors),
            ("Reject invalid OTP and untrusted login origins", accounts.testInvalidOTPAndOrigins),
            ("Legacy config migration and secret separation", accounts.testLegacyConfigurationAndSecretSeparation),
            ("Embedded OIDC URL delivery and browser helper", accounts.testEmbeddedOIDCProcess),
            ("Fragmented JSON and UTF-8", core.testFragmentedJSONAndUTF8),
            ("Reject invalid endpoints and oversized output", core.testUntrustedEndpointAndOversizedOutput),
            ("Config validation, persistence and permissions", core.testConfigurationValidationAndRoundTrip),
            ("Literal CLI arguments and loopback binding", core.testCLIArgumentsPreserveLiteralInputAndForceLoopback),
            ("Secret redaction", core.testSanitizeSecrets),
            ("Target discovery JSON", core.testResourceListDecoding),
            ("Client auth discovery, password process, targets and logout", network.testClientLoginDiscoveryAndLogout),
            ("Multiple targets stay independent", network.testIndependentTargets),
            ("Concurrent TCP streams, 4.8 MB, half-close and port release", network.testRealTCPBytesHalfCloseConcurrentClientsAndStop),
            ("Reconnect changes upstream and preserves fixed port", network.testReconnectUsesNewUpstreamAndSameFixedPort),
            ("Occupied port rejected", network.testOccupiedPortFailsWithoutStartingTunnel),
            ("Stop cancels pending reconnect", network.testStopDuringRetryDoesNotRestart)
        ]
        if CommandLine.arguments.contains("--keychain") {
            checks.append(("Temporary Keychain save, update and delete", accounts.testTemporaryKeychainRoundTrip))
        }
        for (name, check) in checks {
            let before = results.count
            do { try check() } catch { checkFail(String(describing: error)) }
            core.tearDown(); network.tearDown()
            print("\(results.count == before ? "PASS" : "FAIL")  \(name)")
        }
        print("\(checks.count) checks; \(results.count) failures")
        exit(results.count == 0 ? 0 : 1)
    }
}
