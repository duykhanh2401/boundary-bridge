import Foundation
import Darwin

/// Launches an executable directly, without shell interpolation. Call on main queue.
public final class CommandProcess {
    private let process = Process()
    private var stopRequested = false
    public var isRunning: Bool { process.isRunning }

    public init() {}

    public func start(executable: String, arguments: [String], environment: [String: String],
                      onLine: @escaping (String, Bool) -> Void,
                      onExit: @escaping (Int32) -> Void) throws {
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let readers = DispatchGroup()
        // Enter before launch so an immediate process exit still waits for both streams.
        readers.enter(); readers.enter()
        process.terminationHandler = { process in
            readers.notify(queue: .main) { onExit(process.terminationStatus) }
        }
        do { try process.run() } catch {
            process.terminationHandler = nil
            readers.leave(); readers.leave()
            throw error
        }
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            DispatchQueue.global(qos: .utility).async {
                defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                var decoder = LineDecoder()
                do {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    while true {
                        // FileHandle.read(upToCount:) can wait to fill its requested
                        // length on a pipe. POSIX read returns as soon as output is
                        // available, even while the long-lived tunnel stays open.
                        let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        let data = Data(bytes.prefix(count))
                        for line in try decoder.append(data) {
                            DispatchQueue.main.async { onLine(line, isError) }
                        }
                    }
                    if let line = decoder.finish() { DispatchQueue.main.async { onLine(line, isError) } }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        onLine("Không đọc được dữ liệu CLI: \(error.localizedDescription)", true)
                        self?.stop()
                    }
                }
            }
        }
    }

    public func stop() {
        guard !stopRequested else { return }
        stopRequested = true
        guard process.isRunning else { return }
        process.interrupt()
        let process = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit { if !stopRequested && process.isRunning { process.terminate() } }
}
