#if DEBUG
import UIKit
import Network

// MARK: - Public API

final class SemanticAgent {
    static let shared = SemanticAgent()
    private var server: SemanticHTTPServer?

    func start(port: UInt16 = 9877) {
        guard server == nil else { return }
        server = SemanticHTTPServer(port: port)
        server?.start()
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

// MARK: - HTTP Server

private final class SemanticHTTPServer {
    private var listener: NWListener?
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try? NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                print("[SemanticAgent] listening on :\(nwPort)")
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private var streamConnections: [ObjectIdentifier: NWConnection] = [:]

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data, error == nil else { conn.cancel(); return }
            let req = String(data: data, encoding: .utf8) ?? ""
            if req.hasPrefix("GET /stream") {
                self.handleStream(conn)
            } else if req.hasPrefix("GET /semantic") {
                self.handleSemantic(conn)
            } else if req.hasPrefix("GET /idle") {
                self.handleIdle(conn)
            } else if req.hasPrefix("GET /health") {
                self.send(conn, status: "200 OK", type: "text/plain", body: "ok")
            } else {
                self.send(conn, status: "404 Not Found", type: "text/plain", body: "not found")
            }
        }
    }

    private func handleIdle(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let idle = IdleDetector.isIdle()
            let json = "{\"idle\": \(idle)}"
            self.send(conn, status: "200 OK", type: "application/json", body: json)
        }
    }

    private func handleSemantic(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let walker = SemanticViewWalker()
            let (elements, screen, device) = walker.walk()
            let yaml = SemanticYAMLEmitter.emit(elements: elements, screen: screen, device: device)
            self.send(conn, status: "200 OK", type: "text/yaml", body: yaml)
        }
    }

    // MARK: - SSE Stream

    private var previousSnapshot: [String: ElementSnapshot] = [:]
    private var streamTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?

    private struct ElementSnapshot: Equatable {
        let id: String
        let type: String
        let content: String?
        let x: Int, y: Int, w: Int, h: Int
    }

    private func handleStream(_ conn: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: header.data(using: .utf8), completion: .contentProcessed { error in
            guard error == nil else { conn.cancel(); return }
        })

        let key = ObjectIdentifier(conn)
        streamConnections[key] = conn

        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.streamConnections.removeValue(forKey: key)
                if self?.streamConnections.isEmpty == true {
                    self?.stopStreamPolling()
                }
            }
        }

        if streamTimer == nil {
            startStreamPolling()
        }
    }

    private func startStreamPolling() {
        DispatchQueue.main.async {
            let walker = SemanticViewWalker()
            let (elements, _, _) = walker.walk()
            self.previousSnapshot = self.snapshot(from: elements)

            self.streamTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.pollForChanges()
            }
        }
    }

    private func stopStreamPolling() {
        streamTimer?.invalidate()
        streamTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        previousSnapshot.removeAll()
    }

    private func pollForChanges() {
        let walker = SemanticViewWalker()
        let (elements, _, _) = walker.walk()
        let current = snapshot(from: elements)

        var events: [String] = []
        for (id, el) in current {
            if let prev = previousSnapshot[id] {
                if prev != el {
                    events.append("{\"event\":\"change\",\"id\":\"\(escJSON(id))\",\"type\":\"\(el.type)\"}")
                }
            } else {
                events.append("{\"event\":\"add\",\"id\":\"\(escJSON(id))\",\"type\":\"\(el.type)\",\"content\":\(el.content.map { "\"\(escJSON($0))\"" } ?? "null")}")
            }
        }
        for id in previousSnapshot.keys where current[id] == nil {
            events.append("{\"event\":\"remove\",\"id\":\"\(escJSON(id))\"}")
        }

        previousSnapshot = current

        guard !events.isEmpty else { return }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            for event in events {
                let sseData = "data: \(event)\n\n".data(using: .utf8) ?? Data()
                for (_, conn) in self.streamConnections {
                    conn.send(content: sseData, completion: .contentProcessed { _ in })
                }
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func snapshot(from elements: [SemanticUIElement]) -> [String: ElementSnapshot] {
        var map: [String: ElementSnapshot] = [:]
        for el in elements where !el.id.isEmpty {
            map[el.id] = ElementSnapshot(
                id: el.id, type: el.semanticType, content: el.content,
                x: Int(el.bounds.minX), y: Int(el.bounds.minY),
                w: Int(el.bounds.width), h: Int(el.bounds.height)
            )
        }
        return map
    }

    private func escJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: (header.data(using: .utf8) ?? Data()) + bodyData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

@_cdecl("_semantic_agent_autostart")
func _semanticAgentAutostart() {
    SemanticAgent.shared.start()
}
#endif
