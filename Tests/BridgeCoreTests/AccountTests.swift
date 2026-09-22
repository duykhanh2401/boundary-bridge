import Foundation
import Combine
import BridgeCore

final class AccountTests: CheckSuite {
    func testAuthenticationStateLifecycle() throws {
        let client = BoundaryClient()
        defer { client.cancel() }
        checkFalse(client.authenticated)
        var settings = BoundarySettings()
        settings.address = "https://boundary.example.test"
        settings.authMethodID = "ampw_fixture"
        settings.authType = "password"
        settings.executable = Bundle.module.url(forResource: "fake-boundary", withExtension: "py", subdirectory: "Fixtures")!.path
        let success = expectation(description: "Login completed")
        client.login(settings: settings, username: "user", password: "test-password-only") { success.fulfill() }
        checkFalse(client.authenticated)
        try wait(for: [success], timeout: 5)
        checkTrue(client.authenticated)

        settings.authMethodID = "ampw_fail"
        let failure = expectation(description: "Failed login completed")
        let observation = client.$busy.dropFirst().filter { !$0 }.prefix(1).sink { _ in failure.fulfill() }
        defer { observation.cancel() }
        client.login(settings: settings, username: "user", password: "test-password-only") { checkFail("Rejected credentials marked authenticated") }
        checkFalse(client.authenticated)
        try wait(for: [failure], timeout: 5)
        checkFalse(client.authenticated)

        settings.authMethodID = "ampw_fixture"
        client.login(settings: settings, username: "user", password: "test-password-only") { checkFail("Cancelled login completed") }
        client.cancel()
        checkFalse(client.authenticated)
        let settled = expectation(description: "Cancelled process settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        try wait(for: [settled], timeout: 2)
        checkFalse(client.authenticated)
    }
    func testTOTPVectors() throws {
        // RFC 6238 Appendix B. Public test keys, never real account secrets.
        let keys = [
            "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA",
            "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA"
        ]
        let times: [TimeInterval] = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000]
        let expected = [
            ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"],
            ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"],
            ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"]
        ]
        for (index, algorithm) in ["SHA1", "SHA256", "SHA512"].enumerated() {
            let generator = try TOTP(setup: "otpauth://totp/Test?secret=\(keys[index])&digits=8&algorithm=\(algorithm)")
            for (timeIndex, time) in times.enumerated() {
                checkEqual(try generator.code(at: Date(timeIntervalSince1970: time)), expected[index][timeIndex])
            }
        }
        let standard = try TOTP(setup: keys[0].lowercased())
        checkEqual(try standard.code(at: Date(timeIntervalSince1970: 59)), "287082")
        checkEqual(standard.remaining(at: Date(timeIntervalSince1970: 59)), 1)
        checkEqual(standard.remaining(at: Date(timeIntervalSince1970: 60)), 30)
    }

    func testInvalidOTPAndOrigins() throws {
        for value in ["123456", "not a valid secret!!!", "otpauth://hotp/Test?secret=GEZDGNBVGY3TQOJQ",
                      "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQ&period=0",
                      "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQ&algorithm=MD5",
                      "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQ&secret=OTHER"] {
            checkThrows(try TOTP(setup: value))
        }
        checkEqual(LoginOrigin.httpsOrigin(URL(string: "https://LOGIN.example:443/form")!), "https://login.example:443")
        checkNotEqual(LoginOrigin.httpsOrigin(URL(string: "https://login.example.evil.test/")!), "https://login.example:443")
        checkNil(LoginOrigin.httpsOrigin(URL(string: "http://login.example/")!))
        checkNil(LoginOrigin.httpsOrigin(URL(string: "https://user:secret@login.example/")!))
    }

    func testLegacyConfigurationAndSecretSeparation() throws {
        let encoder = JSONEncoder()
        let oldConfig = AppConfiguration()
        var old = try JSONSerialization.jsonObject(with: encoder.encode(oldConfig)) as! [String: Any]
        old.removeValue(forKey: "accounts")
        let migrated = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        checkTrue(migrated.accounts.isEmpty)
        var config = migrated
        var account = SavedAccount()
        account.name = "Work"; account.username = "fixture-user"
        account.controller = "https://boundary.example.test"; account.authMethodID = "amoidc_fixture"
        account.hasOTP = true
        config.accounts = [account]
        let data = try encoder.encode(config)
        let text = String(decoding: data, as: UTF8.self)
        checkFalse(text.contains("otpSetup"))
        checkFalse(text.contains("\"password\""))
        checkEqual(try JSONDecoder().decode(AppConfiguration.self, from: data).accounts, [account])
        checkNotEqual(account.tokenName, SavedAccount().tokenName)
    }

    func testEmbeddedOIDCProcess() throws {
        let client = BoundaryClient()
        defer { client.cancel() }
        var settings = BoundarySettings()
        settings.address = "https://boundary.example.test"
        settings.authMethodID = "amoidc_fixture"
        settings.executable = Bundle.module.url(forResource: "fake-boundary", withExtension: "py", subdirectory: "Fixtures")!.path
        let url = expectation(description: "Embedded browser received authorization URL")
        let loggedIn = expectation(description: "OIDC completed")
        client.login(settings: settings, username: "fixture-user", password: "unused-for-oidc", onAuthorizationURL: { value in
            checkEqual(value.host, "login.example.test")
            url.fulfill()
        }) { loggedIn.fulfill() }
        try wait(for: [url, loggedIn], timeout: 5)
        checkTrue(client.authenticated)
        checkFalse(client.message.contains("at_sensitive_fixture_secret"))
        checkFalse(client.message.contains("state=fixture"))
    }

    func testTemporaryKeychainRoundTrip() throws {
        let keychain = AccountKeychain(service: "local.boundary.bridge.checks.\(UUID().uuidString)")
        let id = UUID()
        defer { try? keychain.remove(for: id) }
        try keychain.save(AccountSecrets(password: "synthetic-test-password", otpSetup: "GEZDGNBVGY3TQOJQ"), for: id)
        checkEqual(try keychain.load(for: id).password, "synthetic-test-password")
        try keychain.save(AccountSecrets(password: "updated-test-password"), for: id)
        checkEqual(try keychain.load(for: id).password, "updated-test-password")
        checkEqual(try keychain.load(for: id).otpSetup, "")
        try keychain.remove(for: id)
        checkThrows(try keychain.load(for: id))
    }
}
