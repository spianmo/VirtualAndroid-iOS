import Foundation

/// Minimal QMP client over a connected socket (one end of a socketpair; the
/// other end is handed to the in-process QEMU as `-chardev socket,fd=N`).
final class QMPClient {
    enum QMPError: LocalizedError {
        case remote(String)
        case closed
        var errorDescription: String? {
            switch self {
            case .remote(let s): return "QMP: \(s)"
            case .closed: return "QMP connection closed"
            }
        }
    }

    typealias Completion = (Result<Any?, Error>) -> Void

    /// Called on the QMP queue with (event name, data).
    var onEvent: ((String, [String: Any]) -> Void)?

    private let fd: Int32
    private let queue = DispatchQueue(label: "va.qmp")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var ready = false
    private var nextID = 1
    private var pendingSend: [(Data, Int, Completion?)] = []
    private var waiting: [Int: Completion] = [:]
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in _ = Darwin.close(fd) }
        src.resume()
        source = src
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            source?.cancel()
            for (_, c) in waiting { c(.failure(QMPError.closed)) }
            waiting.removeAll()
            for (_, _, c) in pendingSend { c?(.failure(QMPError.closed)) }
            pendingSend.removeAll()
        }
    }

    func execute(_ command: String, arguments: [String: Any]? = nil, completion: Completion? = nil) {
        queue.async { [self] in
            guard !closed else { completion?(.failure(QMPError.closed)); return }
            let id = nextID
            nextID += 1
            var msg: [String: Any] = ["execute": command, "id": id]
            if let arguments { msg["arguments"] = arguments }
            guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
            data.append(0x0A)
            if ready {
                send(data, id: id, completion: completion)
            } else {
                pendingSend.append((data, id, completion))
            }
        }
    }

    /// Runs commands one after another; stops at the first error.
    /// Completion on the QMP queue.
    func run(_ commands: [SnapshotProtocol.Command], completion: @escaping (Error?) -> Void) {
        guard let first = commands.first else { completion(nil); return }
        execute(first.execute, arguments: first.jsonArguments) { [weak self] result in
            switch result {
            case .failure(let e):
                completion(QMPError.remote("\(first.execute): \(e.localizedDescription)"))
            case .success:
                guard let self else { completion(QMPError.closed); return }
                self.run(Array(commands.dropFirst()), completion: completion)
            }
        }
    }

    /// Polls until the migration finished. Outgoing: `query-migrate` status
    /// "completed" (runstate postmigrate). Incoming: "completed", or the
    /// runstate left "inmigrate". Completion on the QMP queue.
    func pollMigration(incoming: Bool, interval: TimeInterval = 0.02, timeout: TimeInterval,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func again() {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval) { poll() }
        }
        func poll() {
            execute("query-migrate") { [weak self] result in
                guard let self else { completion(.failure(QMPError.closed)); return }
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let reply):
                    switch SnapshotProtocol.status(fromQueryMigrate: reply as? [String: Any]) {
                    case .completed:
                        completion(.success(()))
                    case .failed(let why):
                        completion(.failure(QMPError.remote("migration failed: \(why)")))
                    case .inProgress(let status):
                        if Date() > deadline {
                            completion(.failure(QMPError.remote("migration timed out (\(status))")))
                        } else if incoming && status == "none" {
                            self.execute("query-status") { r in
                                if case .success(let st) = r, let run = (st as? [String: Any])?["status"] as? String,
                                   run != "inmigrate" && run != "prelaunch" {
                                    completion(.success(()))
                                } else {
                                    again()
                                }
                            }
                        } else {
                            again()
                        }
                    }
                }
            }
        }
        poll()
    }

    /// Convenience for HMP-only commands (savevm/loadvm/info ...).
    func human(_ commandLine: String, completion: Completion? = nil) {
        execute("human-monitor-command", arguments: ["command-line": commandLine], completion: completion)
    }

    private func send(_ data: Data, id: Int, completion: Completion?) {
        if let completion { waiting[id] = completion }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 {
                    if errno == EAGAIN { usleep(1000); continue }
                    break
                }
                off += n
            }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                close()
                return
            } else {
                break
            }
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(Data(line))
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if obj["QMP"] != nil {
            // Greeting: negotiate, then flush queued commands.
            var negotiate = (try? JSONSerialization.data(withJSONObject: ["execute": "qmp_capabilities", "id": 0])) ?? Data()
            negotiate.append(0x0A)
            send(negotiate, id: 0, completion: { [weak self] _ in
                guard let self else { return }
                self.ready = true
                let queued = self.pendingSend
                self.pendingSend.removeAll()
                for (d, id, c) in queued { self.send(d, id: id, completion: c) }
            })
            return
        }
        if let event = obj["event"] as? String {
            onEvent?(event, obj["data"] as? [String: Any] ?? [:])
            return
        }
        guard let id = obj["id"] as? Int, let completion = waiting.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            completion(.failure(QMPError.remote(err["desc"] as? String ?? "error")))
        } else {
            completion(.success(obj["return"]))
        }
    }
}
