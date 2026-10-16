#if os(macOS)
import Foundation

/// Connects to the local `fluxd` over its Unix socket and speaks the same
/// JSON-lines IPC protocol that `flux-cli` and the desktop hosts use.
///
/// `fluxd` owns device state, so this client only reads it (`state`) and
/// sends commands (`ring`, `clipboard.send`, ...). Every method is
/// non-blocking and thread-safe: the work runs on a private serial queue and
/// the callbacks are delivered on that queue.
public final class DaemonClient: @unchecked Sendable {
    /// An error answer from `fluxd`, or a transport error.
    public struct CallError: Error, LocalizedError {
        public let code: String
        public let message: String
        public var errorDescription: String? { message }
    }

    /// An event from `fluxd`: its name and its data.
    public var onEvent: ((_ event: String, _ data: JSONValue) -> Void)?
    /// The socket connected.
    public var onOpen: (() -> Void)?
    /// The socket closed. The client keeps retrying until `stop()`.
    public var onClose: (() -> Void)?

    private let queue = DispatchQueue(label: "org.omarchy.flux.daemon")
    private let retryDelay: TimeInterval

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var retry: DispatchSourceTimer?
    private var path: String?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: (Result<JSONValue, Error>) -> Void] = [:]
    private var started = false
    private var isOpen = false

    public init(retryDelay: TimeInterval = 2) {
        self.retryDelay = retryDelay
    }

    /// The socket of the local daemon: `$FLUX_SOCKET`, else
    /// `$XDG_RUNTIME_DIR/flux/fluxd.sock`, else `$HOME/.fluxr/flux/fluxd.sock`
    /// on macOS, else `/run/user/<uid>/flux/fluxd.sock`.
    public static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["FLUX_SOCKET"], !p.isEmpty { return p }
        if let d = env["XDG_RUNTIME_DIR"], !d.isEmpty { return d + "/flux/fluxd.sock" }
        let mac = NSHomeDirectory() + "/.fluxr/flux/fluxd.sock"
        if FileManager.default.fileExists(atPath: mac) { return mac }
        return "/run/user/\(getuid())/flux/fluxd.sock"
    }

    /// Starts connecting to `path` and keeps retrying until `stop()`.
    public func start(path: String? = nil) {
        queue.async {
            self.path = path ?? Self.defaultSocketPath()
            self.started = true
            self.connect()
        }
    }

    /// Stops retrying and closes the socket.
    public func stop() {
        queue.async {
            self.started = false
            self.teardown(retry: false)
        }
    }

    /// Sends 1 request. `done` runs on the client queue.
    public func call(_ method: String, _ params: JSONValue? = nil, _ done: ((Result<JSONValue, Error>) -> Void)? = nil) {
        queue.async {
            guard self.isOpen else {
                done?(.failure(CallError(code: "offline", message: "fluxd is not reachable")))
                return
            }
            self.nextID += 1
            let id = self.nextID
            var msg: [String: JSONValue] = ["id": .int(Int64(id)), "method": .string(method)]
            if let params { msg["params"] = params }
            if let done { self.pending[id] = done }
            self.write(.object(msg))
        }
    }

    /// Subscribes to the state and other events.
    public func subscribe() { call("subscribe") { _ in } }

    // MARK: - Queue-private

    private func connect() {
        guard started, !isOpen, let path else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            scheduleRetry()
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            scheduleRetry()
            return
        }

        cancelRetry()
        self.fd = fd
        self.isOpen = true
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.read() }
        source = src
        src.resume()
        onOpen?()
        subscribe()
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let n = buf.withUnsafeMutableBytes { raw in
            Foundation.read(fd, raw.baseAddress, raw.count)
        }
        if n > 0 {
            buffer.append(contentsOf: buf[0..<n])
            while let idx = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                if line.isEmpty { continue }
                handle(line)
            }
            // A line that never ends cannot grow the buffer without a limit.
            if buffer.count > 32 << 20 { teardown(retry: true) }
        } else if n == 0 {
            teardown(retry: true)
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            teardown(retry: true)
        }
    }

    private func handle(_ line: Data) {
        guard let value = JSONValue.parse(line) else { return }
        if let event = value["event"]?.string {
            onEvent?(event, value["data"] ?? .null)
            return
        }
        guard let id = value["id"]?.int else { return }
        let done = pending.removeValue(forKey: id)
        if let err = value["error"] {
            let code = err["code"]?.string ?? "error"
            let message = err["message"]?.string ?? "fluxd error"
            done?(.failure(CallError(code: code, message: message)))
        } else {
            done?(.success(value["result"] ?? .null))
        }
    }

    private func write(_ value: JSONValue) {
        guard fd >= 0 else { return }
        var line = value.serialized()
        line.append(0x0a)
        line.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Foundation.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n > 0 {
                    off += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else {
                    teardown(retry: true)
                    return
                }
            }
        }
    }

    private func teardown(retry later: Bool) {
        if let source {
            source.cancel()
            self.source = nil
        }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        let wasOpen = isOpen
        isOpen = false
        buffer.removeAll()
        for (_, done) in pending {
            done(.failure(CallError(code: "closed", message: "fluxd closed the connection")))
        }
        pending.removeAll()
        if wasOpen { onClose?() }
        if later && started { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard retry == nil, started else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + retryDelay, repeating: retryDelay)
        t.setEventHandler { [weak self] in self?.connect() }
        retry = t
        t.resume()
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }
}
#endif
