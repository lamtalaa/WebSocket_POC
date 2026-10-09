// A WebSocket client built on URLSessionWebSocketTask.
//
// URLSession performs the HTTP upgrade and masks outgoing frames for you.
// This type is the part an app can actually see: connect, text, binary,
// ping, and close. server/server.py prints the handshake and the mask key
// that URLSession does not hand back.

import Combine
import Foundation

@MainActor
final class WebSocketClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case open
        case closing
        case closed
        case failed

        var label: String {
            switch self {
            case .idle: "Idle"
            case .connecting: "Connecting"
            case .open: "Open"
            case .closing: "Closing"
            case .closed: "Closed"
            case .failed: "Failed"
            }
        }
    }

    struct Event: Identifiable, Equatable {
        enum Kind: Equatable {
            case status
            case sent
            case received
            case ping
            case pong
            case close
            case error

            var tag: String {
                switch self {
                case .status: "NOTE"
                case .sent: "SENT"
                case .received: "RECV"
                case .ping: "PING"
                case .pong: "PONG"
                case .close: "CLOSE"
                case .error: "FAIL"
                }
            }
        }

        let id = UUID()
        let date = Date()
        let kind: Kind
        let title: String
        let detail: String
    }

    /// Four bytes the Binary button sends, so the log has a stable payload to compare.
    static let sampleBinary = Data([0xDE, 0xAD, 0xBE, 0xEF])

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var events: [Event] = []

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var socketDelegate: SocketDelegate?
    private var listenTask: Task<Void, Never>?
    private var generation = 0
    private var ended = false
    private var currentURL = ""

    func connect(urlString: String) {
        guard phase == .idle || phase == .closed || phase == .failed else { return }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = url.host,
              !host.isEmpty
        else {
            phase = .failed
            append(
                kind: .error,
                title: "Bad URL",
                detail: "Use a ws:// or wss:// URL with a host. The lab server is ws://127.0.0.1:8765."
            )
            return
        }

        teardownSocket()
        generation += 1
        ended = false
        currentURL = url.absoluteString
        phase = .connecting

        let port = url.port.map(String.init) ?? (scheme == "wss" ? "443" : "80")
        append(
            kind: .status,
            title: "Connecting",
            detail: "Opening TCP to \(host):\(port). Next, URLSession sends an HTTP GET with Upgrade: websocket and a random Sec-WebSocket-Key."
        )

        let generation = self.generation
        let delegate = SocketDelegate(generation: generation, owner: self)
        socketDelegate = delegate

        let config = URLSessionConfiguration.ephemeral
        // For a WebSocket, this is the longest quiet stretch allowed between frames.
        // A short value would drop the socket while you are reading the server log.
        config.timeoutIntervalForRequest = 60 * 30
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.task = socket
        socket.resume()
    }

    func disconnect() {
        guard phase == .open || phase == .connecting, let task else { return }
        phase = .closing
        append(
            kind: .close,
            title: "Closing",
            detail: "Sending a Close frame, code 1000 normalClosure, reason \"closed by the lab\". The server should answer with its own Close frame."
        )
        task.cancel(with: .normalClosure, reason: Data("closed by the lab".utf8))
    }

    func send(text: String) {
        guard phase == .open, let task else { return }
        let generation = generation
        let payload = text
        Task {
            do {
                try await task.send(.string(payload))
                guard self.generation == generation else { return }
                self.append(
                    kind: .sent,
                    title: "text frame · \(payload.utf8.count) bytes",
                    detail: payload
                )
            } catch {
                guard self.generation == generation else { return }
                self.recordFailure(error)
            }
        }
    }

    func sendSampleBinary() {
        guard phase == .open, let task else { return }
        let generation = generation
        let payload = Self.sampleBinary
        Task {
            do {
                try await task.send(.data(payload))
                guard self.generation == generation else { return }
                self.append(
                    kind: .sent,
                    title: "binary frame · \(payload.count) bytes",
                    detail: Self.hex(payload)
                )
            } catch {
                guard self.generation == generation else { return }
                self.recordFailure(error)
            }
        }
    }

    func sendPing() {
        guard phase == .open, let task else { return }
        append(
            kind: .ping,
            title: "ping frame",
            detail: "A control frame. URLSession chooses the payload, often a few zero bytes, and reports the matching pong here. The receive loop does not see it. The server terminal prints both frames."
        )
        let generation = generation
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if let error {
                    self.recordFailure(error)
                } else {
                    self.append(
                        kind: .pong,
                        title: "pong received",
                        detail: "The server echoed the ping. That round trip reused the open connection."
                    )
                }
            }
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    fileprivate func handleOpen(_ subprotocol: String?, generation: Int) {
        guard generation == self.generation, !ended, phase == .connecting else { return }
        phase = .open
        let negotiated = subprotocol ?? "none"
        append(
            kind: .status,
            title: "Handshake complete",
            detail: "The server answered 101 Switching Protocols. Subprotocol: \(negotiated). The same TCP connection now carries WebSocket frames in both directions."
        )
        // Messages that arrived with the 101 sit in URLSession's buffer until
        // the first receive(), so the welcome frame shows up after this line.
        if let task, phase == .open {
            listen(to: task, generation: generation)
        }
    }

    fileprivate func handleClose(
        _ code: URLSessionWebSocketTask.CloseCode,
        reason: Data?,
        generation: Int
    ) {
        guard generation == self.generation else { return }
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        var detail = "\(Self.describe(code))."
        if let reasonText, !reasonText.isEmpty {
            detail += " Reason: \(reasonText)."
        }
        detail += " The TCP connection is gone."
        finish(phase: .closed, kind: .close, title: "Closed", detail: detail)
    }

    fileprivate func handleComplete(_ error: Error?, generation: Int) {
        guard generation == self.generation, !ended else { return }
        guard let error else {
            finish(
                phase: .closed,
                kind: .close,
                title: "Closed",
                detail: "The socket task finished."
            )
            return
        }

        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            finish(
                phase: .closed,
                kind: .close,
                title: "Closed",
                detail: "The socket task ended."
            )
            return
        }
        fail(explain(error))
    }

    private func listen(to task: URLSessionWebSocketTask, generation: Int) {
        listenTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // One call returns one full message. URLSession joins fragments
                    // and strips the mask before this resume.
                    let message = try await task.receive()
                    await MainActor.run {
                        guard let self, self.generation == generation else { return }
                        self.record(message)
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard let self, self.generation == generation else { return }
                        self.recordFailure(error)
                    }
                    return
                }
            }
        }
    }

    private func record(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            append(
                kind: .received,
                title: "text frame · \(text.utf8.count) bytes",
                detail: text
            )
        case .data(let data):
            append(
                kind: .received,
                title: "binary frame · \(data.count) bytes",
                detail: Self.hex(data)
            )
        @unknown default:
            append(kind: .received, title: "frame", detail: "URLSession returned a message this app does not decode.")
        }
    }

    private func recordFailure(_ error: Error) {
        if error is CancellationError { return }
        if ended || phase == .closing || phase == .closed { return }
        fail(explain(error))
    }

    private func fail(_ message: String) {
        finish(phase: .failed, kind: .error, title: "Connection failed", detail: message)
    }

    private func finish(phase: Phase, kind: Event.Kind, title: String, detail: String) {
        guard !ended else { return }
        ended = true
        self.phase = phase
        append(kind: kind, title: title, detail: detail)
        teardownSocket()
    }

    private func teardownSocket() {
        listenTask?.cancel()
        listenTask = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        socketDelegate = nil
    }

    private func append(kind: Event.Kind, title: String, detail: String) {
        events.append(Event(kind: kind, title: title, detail: detail))
        if events.count > 300 {
            events.removeFirst(events.count - 300)
        }
    }

    private func explain(_ error: Error) -> String {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSPOSIXErrorDomain, 61):
            return "Nothing accepted a TCP connection to \(currentURL). From the project folder, run python3 server/server.py and connect again."
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSPOSIXErrorDomain, 54):
            return "The TCP connection dropped. Stopping the server with Ctrl-C looks like this: the socket ends without a Close frame."
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return "Timed out waiting for the server at \(currentURL)."
        case (NSURLErrorDomain, NSURLErrorAppTransportSecurityRequiresSecureConnection):
            return "App Transport Security blocked this cleartext ws:// URL. Info.plist allows local networking so the lab server can be reached."
        default:
            return ns.localizedDescription
        }
    }

    private static func describe(_ code: URLSessionWebSocketTask.CloseCode) -> String {
        switch code {
        case .invalid:
            return "0 invalid (no close status)"
        case .normalClosure:
            return "1000 normalClosure"
        case .goingAway:
            return "1001 goingAway"
        case .protocolError:
            return "1002 protocolError"
        case .unsupportedData:
            return "1003 unsupportedData"
        case .noStatusReceived:
            return "1005 noStatusReceived"
        case .abnormalClosure:
            return "1006 abnormalClosure"
        case .invalidFramePayloadData:
            return "1007 invalidFramePayloadData"
        case .policyViolation:
            return "1008 policyViolation"
        case .messageTooBig:
            return "1009 messageTooBig"
        case .mandatoryExtensionMissing:
            return "1010 mandatoryExtensionMissing"
        case .internalServerError:
            return "1011 internalServerError"
        case .tlsHandshakeFailure:
            return "1015 tlsHandshakeFailure"
        @unknown default:
            return "code \(code.rawValue)"
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// URLSession calls this off the main thread. The generation is fixed when the
/// socket is created, so a callback from an old session cannot update a newer one.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    let generation: Int
    weak var owner: WebSocketClient?

    init(generation: Int, owner: WebSocketClient) {
        self.generation = generation
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let subprotocol = `protocol`
        let generation = generation
        Task { @MainActor in
            self.owner?.handleOpen(subprotocol, generation: generation)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let generation = generation
        Task { @MainActor in
            self.owner?.handleClose(closeCode, reason: reason, generation: generation)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let generation = generation
        Task { @MainActor in
            self.owner?.handleComplete(error, generation: generation)
        }
    }
}
