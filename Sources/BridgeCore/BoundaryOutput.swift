import Foundation

public enum BoundaryEvent: Equatable {
    case listening(port: UInt16, sessionID: String?)
    case terminated(String)
    case ignored

    public static func parse(_ line: String) throws -> BoundaryEvent {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        if let reason = object["termination_reason"] as? String { return .terminated(reason) }
        if let port = object["port"] as? Int {
            guard object["address"] as? String == "127.0.0.1", (1...65535).contains(port),
                  object["protocol"] as? String == "tcp" else {
                throw BridgeError.message("Boundary trả về endpoint không hợp lệ; chỉ hỗ trợ TCP trên 127.0.0.1.")
            }
            return .listening(port: UInt16(port), sessionID: object["session_id"] as? String)
        }
        // Session JSON may contain credentials. Never log the raw JSON.
        return .ignored
    }
}

public struct LineDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= 1_048_576 else {
                throw BridgeError.message("Dòng dữ liệu Boundary vượt giới hạn 1 MB.")
            }
            lines.append(String(decoding: buffer[..<end], as: UTF8.self))
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= 1_048_576 else { throw BridgeError.message("Dữ liệu Boundary vượt giới hạn 1 MB.") }
        return lines
    }
    public mutating func finish() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

public enum LogSanitizer {
    public static func clean(_ text: String) -> String {
        var result = text
        for pattern in [
            #"(?i)Bearer\s+\S+"#,
            #"(?i)(token|password|secret|authorization|credential)([\"\s:=]+)[^\s,}]+"#,
            #"\bat_[A-Za-z0-9_]+\b"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(result.prefix(1200))
    }
}
