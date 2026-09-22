import Foundation

public enum BridgeResources {
    public static func url(_ name: String) -> URL {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BridgeResources/\(name)"),
           FileManager.default.fileExists(atPath: url.path) { return url }
        return Bundle.module.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent(name)
    }
}

public enum LoginOrigin {
    /// Compare scheme, host and effective port. Never match by string prefix.
    public static func httpsOrigin(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return "https://\(host):\(url.port ?? 443)"
    }
}
