import Foundation
import Darwin

/// Nonblocking BSD sockets driven by DispatchSource. All mutable state is on main.
/// Each direction buffers at most 64 KiB and preserves TCP half-close.
public final class TCPForwarder {
    private var listener: DispatchSourceRead?
    private var upstreamPort: UInt16?
    private var pairs: [UUID: StreamPair] = [:]
    public var onReady: (() -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onConnectionCount: ((Int) -> Void)?
    public init() {}

    public func start(port: UInt16) throws {
        let fd = try makeSocket()
        do {
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            let result = withAddress(port: port) { Darwin.bind(fd, $0, $1) }
            guard result == 0, Darwin.listen(fd, 128) == 0 else { throw socketError() }
        } catch {
            Darwin.close(fd)
            throw BridgeError.message("Không mở được port \(port): \(error.localizedDescription)")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        listener = source
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, self.listener != nil else { return }
            // Bound work per event so UI and other streams keep making progress.
            for _ in 0..<32 {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    if errno == EINTR { continue }
                    self.onFailure?(socketError().localizedDescription)
                    return
                }
                guard let upstream = self.upstreamPort, self.pairs.count < 512 else { Darwin.close(client); continue }
                do {
                    try configureSocket(client)
                    let id = UUID()
                    let pair = try StreamPair(client: client, port: upstream) { [weak self] in
                        self?.pairs.removeValue(forKey: id)
                        self?.onConnectionCount?(self?.pairs.count ?? 0)
                    }
                    self.pairs[id] = pair
                    self.onConnectionCount?(self.pairs.count)
                    pair.start()
                } catch { Darwin.close(client) }
            }
        }
        source.resume()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.listener != nil else { return }
            self.onReady?()
        }
    }

    public func route(to port: UInt16?) {
        upstreamPort = port
        Array(pairs.values).forEach { $0.stop() }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        route(to: nil)
    }
    deinit { listener?.cancel() }
}

private final class SocketChannel {
    let fd: Int32
    let readSource: DispatchSourceRead
    let writeSource: DispatchSourceWrite
    private var readPaused = true
    private var writePaused = true
    private var cancelled = false
    var buffer = Data()
    var readEnded = false
    var finishWrite = false
    var writeEnded = false

    init(fd: Int32) {
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        // Close only after BOTH sources have drained their queued callbacks.
        // The closure owns this counter independently of the channel lifetime.
        var sourcesLeft = 2
        let release = { sourcesLeft -= 1; if sourcesLeft == 0 { Darwin.close(fd) } }
        readSource.setCancelHandler(handler: release)
        writeSource.setCancelHandler(handler: release)
    }
    func readEnabled(_ enabled: Bool) {
        guard !cancelled else { return }
        if enabled && readPaused { readPaused = false; readSource.resume() }
        if !enabled && !readPaused { readPaused = true; readSource.suspend() }
    }
    func writeEnabled(_ enabled: Bool) {
        guard !cancelled else { return }
        if enabled && writePaused { writePaused = false; writeSource.resume() }
        if !enabled && !writePaused { writePaused = true; writeSource.suspend() }
    }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        readSource.cancel(); writeSource.cancel()
        if readPaused { readSource.resume() }
        if writePaused { writeSource.resume() }
    }
    deinit { cancel() }
}

private final class StreamPair {
    private let client: SocketChannel
    private let upstream: SocketChannel
    private let onClose: () -> Void
    private var connecting: Bool
    private var closed = false
    private var deadline: DispatchWorkItem?

    init(client: Int32, port: UInt16, onClose: @escaping () -> Void) throws {
        let fd = try makeSocket()
        let result = withAddress(port: port) { Darwin.connect(fd, $0, $1) }
        if result != 0 && errno != EINPROGRESS {
            let error = socketError(); Darwin.close(fd); throw error
        }
        self.connecting = result != 0
        self.client = SocketChannel(fd: client)
        self.upstream = SocketChannel(fd: fd)
        self.onClose = onClose
    }

    func start() {
        client.readSource.setEventHandler { [weak self] in
            guard let self else { return }; self.read(from: self.client, to: self.upstream)
        }
        upstream.readSource.setEventHandler { [weak self] in
            guard let self else { return }; self.read(from: self.upstream, to: self.client)
        }
        client.writeSource.setEventHandler { [weak self] in
            guard let self else { return }; self.flush(self.client, source: self.upstream)
        }
        upstream.writeSource.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if self.connecting {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: error))
                guard getsockopt(self.upstream.fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { self.stop(); return }
                self.connecting = false
                self.deadline?.cancel(); self.deadline = nil
                self.upstream.writeEnabled(false)
                self.client.readEnabled(true)
                self.upstream.readEnabled(true)
            } else { self.flush(self.upstream, source: self.client) }
        }
        if connecting {
            let deadline = DispatchWorkItem { [weak self] in self?.stop() }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
            upstream.writeEnabled(true)
        } else { client.readEnabled(true); upstream.readEnabled(true) }
    }

    private func read(from source: SocketChannel, to destination: SocketChannel) {
        guard !closed, !connecting, !source.readEnded else { return }
        guard destination.buffer.isEmpty else { source.readEnabled(false); return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.recv(source.fd, &bytes, bytes.count, 0)
        if count > 0 {
            destination.buffer = Data(bytes.prefix(count))
            source.readEnabled(false)
            flush(destination, source: source)
        } else if count == 0 {
            source.readEnded = true
            source.readEnabled(false)
            destination.finishWrite = true
            flush(destination, source: source)
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { stop() }
    }

    private func flush(_ destination: SocketChannel, source: SocketChannel) {
        guard !closed, !connecting else { return }
        if !destination.buffer.isEmpty {
            let count = destination.buffer.withUnsafeBytes { Darwin.send(destination.fd, $0.baseAddress, $0.count, 0) }
            if count > 0 { destination.buffer.removeFirst(count) }
            else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { stop(); return }
        }
        if destination.buffer.isEmpty {
            destination.writeEnabled(false)
            if destination.finishWrite && !destination.writeEnded {
                Darwin.shutdown(destination.fd, SHUT_WR)
                destination.writeEnded = true
            }
            if !source.readEnded { source.readEnabled(true) }
        } else { destination.writeEnabled(true) }
        if client.readEnded && upstream.readEnded && client.buffer.isEmpty && upstream.buffer.isEmpty { stop() }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        deadline?.cancel(); deadline = nil
        client.cancel(); upstream.cancel()
        onClose()
    }
}

private func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
private func configureSocket(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw socketError() }
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw socketError() }
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { throw socketError() }
}
private func makeSocket() throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw socketError() }
    do { try configureSocket(fd); return fd } catch { Darwin.close(fd); throw error }
}
private func withAddress<T>(port: UInt16, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}
