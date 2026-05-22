#if DEBUG
import UIKit
import Network

// MARK: - Public API

final class SemanticAgent {
    static let shared = SemanticAgent()
    private var server: SemanticServer?

    func start(port: UInt16 = 9877) {
        guard server == nil else { return }
        server = SemanticServer(port: port)
        server?.start()
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

// MARK: - HTTP Server

private final class SemanticServer {
    private var listener: NWListener?
    private let port: UInt16
    private var overlayWindow: OverlayWindow?
    private var cachedWalk: WalkResult?

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

    // MARK: - Routing

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data, error == nil else { conn.cancel(); return }
            let req = String(data: data, encoding: .utf8) ?? ""

            if req.hasPrefix("GET /semantic") {
                self.handleSemantic(conn)
            } else if req.hasPrefix("GET /overlay") {
                self.handleOverlay(conn, req: req)
            } else if req.hasPrefix("DELETE /overlay") {
                self.handleOverlayClear(conn)
            } else if req.hasPrefix("GET /idle") {
                self.handleIdle(conn)
            } else if req.hasPrefix("POST /animations") {
                self.handleAnimations(conn, req: req)
            } else if req.hasPrefix("GET /debug-log") {
                self.handleDebugLog(conn)
            } else if req.hasPrefix("GET /health") {
                self.send(conn, status: "200 OK", type: "text/plain", body: "ok")
            } else {
                self.send(conn, status: "404 Not Found", type: "text/plain", body: "not found")
            }
        }
    }

    // MARK: - Walk + Cache

    private func freshWalk() -> WalkResult {
        let walker = SemanticWalker()
        let result = walker.walk()
        cachedWalk = result
        return result
    }

    private func cachedOrFreshWalk() -> WalkResult {
        if let cached = cachedWalk { return cached }
        return freshWalk()
    }

    // MARK: - /semantic

    private func handleSemantic(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let result = self.freshWalk()
            let yaml = SemanticYAMLEmitter.emit(
                elements: result.elements, screen: result.screenName, device: result.deviceName)
            self.send(conn, status: "200 OK", type: "text/yaml", body: yaml)
        }
    }

    // MARK: - /overlay

    private func handleOverlay(_ conn: NWConnection, req: String) {
        let mode = parseOverlayMode(req)

        DispatchQueue.main.async {
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil

            let result = self.freshWalk()

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
                self.send(conn, status: "500 Internal Server Error", type: "application/json",
                          body: "{\"error\":\"no window scene\"}")
                return
            }

            let (window, colorMap) = SemanticOverlay.draw(
                elements: result.elements, mode: mode, scene: scene)
            self.overlayWindow = window

            let modeStr = mode == .stroke ? "stroke" : "fill"
            let elementsJSON = colorMap.map { el in
                "{\"id\":\"\(self.escJSON(el.id))\",\"z\":\(el.z),\"color\":[\(el.r),\(el.g),\(el.b)]}"
            }.joined(separator: ",")
            let json = "{\"status\":\"\(modeStr)\",\"elements\":[\(elementsJSON)]}"
            self.send(conn, status: "200 OK", type: "application/json", body: json)
        }
    }

    private func parseOverlayMode(_ req: String) -> OverlayMode {
        guard let queryStart = req.range(of: "?") else { return .stroke }
        let query = String(req[queryStart.upperBound...].prefix(while: { $0 != " " && $0 != "\r" }))
        for param in query.components(separatedBy: "&") {
            let kv = param.components(separatedBy: "=")
            guard kv.count == 2, kv[0] == "mode" else { continue }
            if kv[1] == "fill" || kv[1] == "validate-fill" { return .fill }
        }
        return .stroke
    }

    // MARK: - DELETE /overlay

    private func handleOverlayClear(_ conn: NWConnection) {
        DispatchQueue.main.async {
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
            self.cachedWalk = nil
            self.send(conn, status: "200 OK", type: "application/json",
                      body: "{\"status\":\"disabled\"}")
        }
    }

    // MARK: - /idle

    private func handleIdle(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let idle = IdleDetector.isIdle()
            self.send(conn, status: "200 OK", type: "application/json",
                      body: "{\"idle\":\(idle)}")
        }
    }

    // MARK: - /animations

    private func handleAnimations(_ conn: NWConnection, req: String) {
        let enabled = req.contains("enabled=true")
        DispatchQueue.main.async {
            UIView.setAnimationsEnabled(enabled)
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) {
                window.layer.speed = enabled ? 1.0 : 100.0
            }
            self.send(conn, status: "200 OK", type: "application/json",
                      body: "{\"animations\":\(enabled)}")
        }
    }

    // MARK: - /debug-log

    private func handleDebugLog(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let result = self.cachedWalk ?? self.freshWalk()
            self.send(conn, status: "200 OK", type: "text/plain", body: result.log)
        }
    }

    // MARK: - HTTP Response

    private func send(_ conn: NWConnection, status: String, type: String, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: (header.data(using: .utf8) ?? Data()) + bodyData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func escJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
#endif
