import Foundation
import CryptoKit

public struct TOTP {
    public let digits: Int
    public let period: Int
    public let algorithm: String
    private let secret: Data

    public init(setup: String) throws {
        var encoded = setup.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = 6, period = 30, algorithm = "SHA1"
        if encoded.lowercased().hasPrefix("otpauth:") {
            guard let url = URLComponents(string: encoded), url.scheme?.lowercased() == "otpauth",
                  url.host?.lowercased() == "totp" else { throw Self.invalid }
            let items = url.queryItems ?? []
            for name in ["secret", "digits", "period", "algorithm"] {
                guard items.filter({ $0.name == name }).count <= 1 else { throw Self.invalid }
            }
            guard let value = items.first(where: { $0.name == "secret" })?.value else { throw Self.invalid }
            encoded = value
            if let value = items.first(where: { $0.name == "digits" })?.value { guard let n = Int(value) else { throw Self.invalid }; digits = n }
            if let value = items.first(where: { $0.name == "period" })?.value { guard let n = Int(value) else { throw Self.invalid }; period = n }
            if let value = items.first(where: { $0.name == "algorithm" })?.value { algorithm = value.uppercased() }
        }
        guard [6, 8].contains(digits), (1...300).contains(period), ["SHA1", "SHA256", "SHA512"].contains(algorithm) else { throw Self.invalid }
        self.digits = digits; self.period = period; self.algorithm = algorithm
        self.secret = try Self.decodeBase32(encoded)
    }

    public func code(at date: Date = Date()) throws -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else { throw Self.invalid }
        var counter = UInt64(floor(seconds / Double(period))).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let hash: [UInt8]
        switch algorithm {
        case "SHA256": hash = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": hash = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        }
        let offset = Int(hash.last! & 0x0f)
        let value = (UInt32(hash[offset] & 0x7f) << 24) | (UInt32(hash[offset + 1]) << 16) |
                    (UInt32(hash[offset + 2]) << 8) | UInt32(hash[offset + 3])
        return String(format: "%0*u", digits, value % (digits == 8 ? 100_000_000 : 1_000_000))
    }

    public func remaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period)))
    }

    private static var invalid: BridgeError { .message("Khóa OTP không hợp lệ. Nhập secret Base32 hoặc URI otpauth://totp/; không nhập mã OTP 6 số.") }
    private static func decodeBase32(_ input: String) throws -> Data {
        let characters = input.uppercased().filter { !$0.isWhitespace }
        let text = characters.prefix { $0 != "=" }
        guard characters.dropFirst(text.count).allSatisfy({ $0 == "=" }),
              [0, 2, 4, 5, 7].contains(text.count % 8) else { throw invalid }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0, bits = 0, bytes: [UInt8] = []
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { throw invalid }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 0xff)) }
            buffer &= (1 << bits) - 1
        }
        guard buffer == 0, bytes.count >= 10 else { throw invalid }
        return Data(bytes)
    }
}
