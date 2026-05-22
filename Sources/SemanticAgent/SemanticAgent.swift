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

    private var cachedWalkResult: (elements: [SemanticUIElement], screenName: String, deviceName: String)?
    private var lastWalkLog: String = ""

    private func walkAndCache() -> (elements: [SemanticUIElement], screenName: String, deviceName: String) {
        let walker = SemanticViewWalker()
        let result = walker.walk()
        cachedWalkResult = result
        lastWalkLog = walker.walkLog
        return result
    }

    private func cachedOrWalk() -> (elements: [SemanticUIElement], screenName: String, deviceName: String) {
        if let cached = cachedWalkResult { return cached }
        return walkAndCache()
    }

    private var streamConnections: [ObjectIdentifier: NWConnection] = [:]

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data, error == nil else { conn.cancel(); return }
            let req = String(data: data, encoding: .utf8) ?? ""
            if req.hasPrefix("GET /stream") {
                self.handleStream(conn)
            } else if req.hasPrefix("GET /overlay") {
                self.handleOverlayEnable(conn, req: req)
            } else if req.hasPrefix("DELETE /overlay") {
                self.handleOverlayDisable(conn)
            } else if req.hasPrefix("GET /semantic") {
                self.handleSemantic(conn)
            } else if req.hasPrefix("GET /idle") {
                self.handleIdle(conn)
            } else if req.hasPrefix("POST /animations") {
                self.handleAnimations(conn, req: req)
            } else if req.hasPrefix("GET /debug-tabbar") {
                self.handleDebugTabBar(conn)
            } else if req.hasPrefix("GET /debug-log") {
                self.handleDebugLog(conn)
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
            let (elements, screen, device) = self.walkAndCache()
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

    // MARK: - Debug Log

    private func handleDebugLog(_ conn: NWConnection) {
        DispatchQueue.main.async {
            if self.lastWalkLog.isEmpty {
                _ = self.walkAndCache()
            }
            self.send(conn, status: "200 OK", type: "text/plain", body: self.lastWalkLog)
        }
    }

    // MARK: - Debug Tab Bar

    private func handleDebugTabBar(_ conn: NWConnection) {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else {
                self.send(conn, status: "200 OK", type: "text/plain", body: "no window")
                return
            }

            var log = ""
            func dump(_ view: UIView, depth: Int) {
                let indent = String(repeating: "  ", count: depth)
                let cls = String(describing: type(of: view))
                let frame = view.convert(view.bounds, to: nil)
                let hidden = view.isHidden
                let alpha = view.alpha
                let axElement = view.isAccessibilityElement
                let axLabel = view.accessibilityLabel ?? ""
                let axId = view.accessibilityIdentifier ?? ""
                let traits = view.accessibilityTraits
                let childCount = view.subviews.count
                var text = ""
                if let l = view as? UILabel { text = l.text ?? "" }
                if let b = view as? UIButton { text = b.currentTitle ?? "" }

                var traitNames: [String] = []
                if traits.contains(.button) { traitNames.append("button") }
                if traits.contains(.staticText) { traitNames.append("staticText") }
                if traits.contains(.image) { traitNames.append("image") }
                if traits.contains(.tabBar) { traitNames.append("tabBar") }
                if traits.contains(.selected) { traitNames.append("selected") }
                if traits.contains(.link) { traitNames.append("link") }

                log += "\(indent)\(cls) frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
                log += " hidden=\(hidden) alpha=\(alpha) axElement=\(axElement)"
                if !axLabel.isEmpty { log += " axLabel=\"\(axLabel)\"" }
                if !axId.isEmpty { log += " axId=\"\(axId)\"" }
                if !text.isEmpty { log += " text=\"\(text)\"" }
                if !traitNames.isEmpty { log += " traits=[\(traitNames.joined(separator: ","))]" }
                log += " children=\(childCount)\n"

                for sub in view.subviews {
                    dump(sub, depth: depth + 1)
                }
            }

            for sub in window.subviews {
                for child in sub.subviews {
                    let cls = String(describing: type(of: child))
                    if cls.contains("TabBar") || cls.contains("tabBar") || child is UITabBar {
                        log += "=== TAB BAR SUBTREE ===\n"
                        dump(child, depth: 0)
                    }
                }
            }

            if log.isEmpty {
                func findTabBar(_ view: UIView) {
                    let cls = String(describing: type(of: view))
                    if cls.contains("TabBar") || view is UITabBar {
                        log += "=== FOUND TAB BAR AT DEPTH ===\n"
                        dump(view, depth: 0)
                        return
                    }
                    for sub in view.subviews { findTabBar(sub) }
                }
                findTabBar(window)
            }

            if log.isEmpty { log = "no tab bar found in view tree" }
            self.send(conn, status: "200 OK", type: "text/plain", body: log)
        }
    }

    // MARK: - Bounds Overlay

    private var overlayWindow: UIWindow?

    private func handleOverlayEnable(_ conn: NWConnection, req: String) {
        var color = UIColor.red
        var alpha: CGFloat = 0.25
        var strokeOnly = false
        var validateMode = false
        var validateFillMode = false

        if let queryStart = req.range(of: "?") {
            let query = String(req[queryStart.upperBound...].prefix(while: { $0 != " " && $0 != "\r" }))
            let params = query.components(separatedBy: "&")
            for param in params {
                let kv = param.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                if kv[0] == "color", kv[1].count == 6, let hex = UInt32(kv[1], radix: 16) {
                    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
                    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
                    let b = CGFloat(hex & 0xFF) / 255.0
                    color = UIColor(red: r, green: g, blue: b, alpha: 1.0)
                } else if kv[0] == "alpha", let a = Int(kv[1]) {
                    alpha = CGFloat(min(max(a, 0), 255)) / 255.0
                } else if kv[0] == "mode", kv[1] == "stroke" {
                    strokeOnly = true
                } else if kv[0] == "mode", kv[1] == "validate" {
                    validateMode = true
                } else if kv[0] == "mode", kv[1] == "validate-fill" || kv[1] == "fill" {
                    validateFillMode = true
                }
            }
        }

        if validateFillMode {
            handleOverlayValidateFill(conn)
            return
        }
        if validateMode {
            handleOverlayValidate(conn)
            return
        }

        DispatchQueue.main.async {
            let (elements, _, _) = self.cachedOrWalk()

            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
                self.send(conn, status: "500 Internal Server Error", type: "application/json",
                          body: "{\"error\":\"no window scene\"}")
                return
            }

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .statusBar + 100
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            let vc = UIViewController()
            vc.view.backgroundColor = .clear
            window.rootViewController = vc

            for el in elements {
                let rect = el.bounds
                guard rect.width > 0 && rect.height > 0 else { continue }
                let layer = CALayer()
                layer.frame = rect
                if strokeOnly {
                    layer.backgroundColor = UIColor.clear.cgColor
                } else {
                    layer.backgroundColor = color.withAlphaComponent(alpha).cgColor
                }
                layer.borderColor = color.withAlphaComponent(min(alpha * 3, 1.0)).cgColor
                layer.borderWidth = strokeOnly ? 2.0 : 1.0
                window.layer.addSublayer(layer)
            }

            window.makeKeyAndVisible()
            self.overlayWindow = window

            let json = "{\"status\":\"enabled\",\"elements\":\(elements.count)}"
            self.send(conn, status: "200 OK", type: "application/json", body: json)
        }
    }

    // MARK: - Validate Overlay (v2)

    private func handleOverlayValidate(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let (elements, _, _) = self.cachedOrWalk()

            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil

            let sorted = elements
                .filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
                .sorted { $0.zIndex < $1.zIndex }

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
                self.send(conn, status: "500 Internal Server Error", type: "application/json",
                          body: "{\"error\":\"no window scene\"}")
                return
            }

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .statusBar + 100
            window.isUserInteractionEnabled = false
            let vc = UIViewController()
            vc.view.isHidden = true
            window.rootViewController = vc
            window.layer.backgroundColor = UIColor.white.cgColor

            let scale = scene.screen.scale
            let strokePt = 4.0 / scale

            var colorAssignments: [(id: String, z: Int, r: Int, g: Int, b: Int)] = []

            for el in sorted {
                let (r, g, b) = Self.deviceColorFromID(el.id)
                let uiColor = UIColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)

                let intRect = CGRect(
                    x: CGFloat(Int(el.bounds.origin.x)),
                    y: CGFloat(Int(el.bounds.origin.y)),
                    width: CGFloat(Int(el.bounds.width)),
                    height: CGFloat(Int(el.bounds.height))
                )

                let whiteFill = CALayer()
                whiteFill.frame = intRect
                whiteFill.backgroundColor = UIColor.white.cgColor
                window.layer.addSublayer(whiteFill)

                let strokeLayer = CALayer()
                strokeLayer.frame = intRect
                strokeLayer.backgroundColor = UIColor.clear.cgColor
                strokeLayer.borderColor = uiColor.cgColor
                strokeLayer.borderWidth = strokePt
                window.layer.addSublayer(strokeLayer)

                colorAssignments.append((id: el.id, z: el.zIndex, r: r, g: g, b: b))
            }

            window.makeKeyAndVisible()
            self.overlayWindow = window

            let elementsJSON = colorAssignments.map { el in
                "{\"id\":\"\(self.escJSON(el.id))\",\"z\":\(el.z),\"color\":[\(el.r),\(el.g),\(el.b)]}"
            }.joined(separator: ",")
            let json = "{\"status\":\"validate\",\"elements\":[\(elementsJSON)]}"
            self.send(conn, status: "200 OK", type: "application/json", body: json)
        }
    }

    private func handleOverlayValidateFill(_ conn: NWConnection) {
        DispatchQueue.main.async {
            let (elements, _, _) = self.cachedOrWalk()

            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
                self.send(conn, status: "500 Internal Server Error", type: "application/json",
                          body: "{\"error\":\"no window scene\"}")
                return
            }

            let screenBounds = scene.screen.bounds
            let wThresh = screenBounds.width * 0.95
            let hThresh = screenBounds.height * 0.95

            let sorted = elements
                .filter { $0.bounds.width > 0 && $0.bounds.height > 0 && $0.render != "external" }
                .filter { $0.bounds.width < wThresh || $0.bounds.height < hThresh }
                .sorted { $0.zIndex < $1.zIndex }

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .statusBar + 100
            window.isUserInteractionEnabled = false
            let vc = UIViewController()
            vc.view.isHidden = true
            window.rootViewController = vc
            window.layer.backgroundColor = UIColor.white.cgColor

            var colorAssignments: [(id: String, z: Int, r: Int, g: Int, b: Int)] = []

            for el in sorted {
                let (r, g, b) = Self.deviceColorFromID(el.id)
                let uiColor = UIColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)

                let intRect = CGRect(
                    x: CGFloat(Int(el.bounds.origin.x)),
                    y: CGFloat(Int(el.bounds.origin.y)),
                    width: CGFloat(Int(el.bounds.width)),
                    height: CGFloat(Int(el.bounds.height))
                )
                let layer = CALayer()
                layer.frame = intRect
                layer.backgroundColor = uiColor.cgColor
                window.layer.addSublayer(layer)

                colorAssignments.append((id: el.id, z: el.zIndex, r: r, g: g, b: b))
            }

            window.makeKeyAndVisible()
            self.overlayWindow = window

            let elementsJSON = colorAssignments.map { el in
                "{\"id\":\"\(self.escJSON(el.id))\",\"z\":\(el.z),\"color\":[\(el.r),\(el.g),\(el.b)]}"
            }.joined(separator: ",")
            let json = "{\"status\":\"validate-fill\",\"elements\":[\(elementsJSON)]}"
            self.send(conn, status: "200 OK", type: "application/json", body: json)
        }
    }

    private static func deviceColorFromID(_ id: String) -> (r: Int, g: Int, b: Int) {
        let hue = Double(djb2(id) % 360)
        return hslToRGB(h: hue, s: 1.0, l: 0.5)
    }

    private static func djb2(_ s: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in s.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return hash
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Int, g: Int, b: Int) {
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let hp = h / 60.0
        let x = c * (1.0 - abs(hp.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0

        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }

        return (
            r: Int(((r1 + m) * 255.0).rounded()),
            g: Int(((g1 + m) * 255.0).rounded()),
            b: Int(((b1 + m) * 255.0).rounded())
        )
    }

    private func handleOverlayDisable(_ conn: NWConnection) {
        DispatchQueue.main.async {
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
            self.cachedWalkResult = nil
            self.send(conn, status: "200 OK", type: "application/json",
                      body: "{\"status\":\"disabled\"}")
        }
    }

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

    private func send(_ conn: NWConnection, status: String, type: String, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: (header.data(using: .utf8) ?? Data()) + bodyData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
#endif
