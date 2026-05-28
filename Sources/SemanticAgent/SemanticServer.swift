// MARK: - HTTP Server

private final class SemanticServer {
    private var listener: NWListener?
    private let port: UInt16
    private let auth: AgentAuthProvider
    private let nav: AgentNavigationProvider
    private var overlayWindow: OverlayWindow?
    private var cachedWalk: WalkResult?
    private var cachedWalkTime: Date?

    init(port: UInt16, auth: AgentAuthProvider, nav: AgentNavigationProvider) {
        self.port = port
        self.auth = auth
        self.nav = nav
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
                self.handleSemantic(conn, req: req)
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
            } else if req.hasPrefix("GET /viewdebug-log") {
                self.send(conn, status: "200 OK", type: "text/plain",
                          body: "activationLog:\n\(ViewDebugBridge.activationLog)\nlastLog:\n\(ViewDebugBridge.lastLog)")
            } else if req.hasPrefix("GET /viewdebug-activate") {
                ViewDebugBridge.activate()
                self.send(conn, status: "200 OK", type: "text/plain",
                          body: "activated. log:\n\(ViewDebugBridge.activationLog)")
            } else if req.hasPrefix("GET /health") {
                self.send(conn, status: "200 OK", type: "application/json",
                          body: "{\"status\":\"ok\",\"agent\":\"semantic-agent\",\"version\":\"5.0.0\"}")
            } else if req.hasPrefix("GET /version") {
                let hash = "95c522f"
                let buildTime = "2026-05-28T17:13:28Z"
                self.send(conn, status: "200 OK", type: "application/json",
                          body: "{\"git_hash\":\"\(hash)\",\"build_time\":\"\(buildTime)\"}")
            } else if req.hasPrefix("POST /auth/login") {
                self.handleAuthLogin(conn, req: req)
            } else if req.hasPrefix("POST /auth/logout") {
                self.handleAuthLogout(conn)
            } else if req.hasPrefix("GET /auth/state") {
                self.handleAuthState(conn)
            } else if req.hasPrefix("POST /state/reset") {
                self.handleStateReset(conn)
            } else if req.hasPrefix("GET /permissions") {
                self.handlePermissions(conn)
            } else if req.hasPrefix("POST /navigate/site/") {
                self.handleNavigateSite(conn, req: req)
            } else if req.hasPrefix("POST /navigate/user/") {
                self.handleNavigateUser(conn, req: req)
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
        cachedWalkTime = Date()
        return result
    }

    private func cachedOrFreshWalk() -> WalkResult {
        if let cached = cachedWalk, let time = cachedWalkTime,
           Date().timeIntervalSince(time) < 5.0 {
            return cached
        }
        return freshWalk()
    }

    // MARK: - /semantic

    private func handleSemantic(_ conn: NWConnection, req: String = "") {
        let scrollSteps = parseScrollSteps(req)

        DispatchQueue.main.async {
            if scrollSteps > 0 {
                let walker = SemanticWalker()
                walker.walkWithScroll(steps: scrollSteps) { result in
                    self.cachedWalk = result
                    self.cachedWalkTime = Date()
                    let yaml = SemanticYAMLEmitter.emit(
                        elements: result.elements, screen: result.screenName, device: result.deviceName,
                        scrollMeta: result.scrollMeta)
                    self.send(conn, status: "200 OK", type: "text/yaml", body: yaml)
                }
            } else {
                let result = self.freshWalk()
                let yaml = SemanticYAMLEmitter.emit(
                    elements: result.elements, screen: result.screenName, device: result.deviceName)
                self.send(conn, status: "200 OK", type: "text/yaml", body: yaml)
            }
        }
    }

    private func parseScrollSteps(_ req: String) -> Int {
        guard let queryStart = req.range(of: "?") else { return 0 }
        let query = String(req[queryStart.upperBound...].prefix(while: { $0 != " " && $0 != "\r" }))
        for param in query.components(separatedBy: "&") {
            let kv = param.components(separatedBy: "=")
            guard kv.count == 2, kv[0] == "scroll" else { continue }
            return Int(kv[1]) ?? 0
        }
        return 0
    }

    // MARK: - /overlay

    private func handleOverlay(_ conn: NWConnection, req: String) {
        let mode = parseOverlayMode(req)

        DispatchQueue.main.async {
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil

            let result = self.cachedOrFreshWalk()

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
            self.cachedWalkTime = nil
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

    // MARK: - /auth/login

    private func handleAuthLogin(_ conn: NWConnection, req: String) {
        let body = extractBody(req)
        guard let email = extractJSONString(body, key: "email"),
              let password = extractJSONString(body, key: "password") else {
            send(conn, status: "400 Bad Request", type: "application/json",
                 body: "{\"error\":\"missing email or password\"}")
            return
        }
        Task { @MainActor in
            let result = await self.auth.login(email: email, password: password)
            if result.success {
                self.send(conn, status: "200 OK", type: "application/json", body: "{\"logged_in\":true}")
            } else {
                let err = self.escJSON(result.error ?? "unknown")
                self.send(conn, status: "401 Unauthorized", type: "application/json",
                          body: "{\"logged_in\":false,\"error\":\"\(err)\"}")
            }
        }
    }

    // MARK: - /auth/logout

    private func handleAuthLogout(_ conn: NWConnection) {
        Task { @MainActor in
            self.auth.logout()
            self.send(conn, status: "200 OK", type: "application/json", body: "{\"logged_in\":false}")
        }
    }

    // MARK: - /auth/state

    private func handleAuthState(_ conn: NWConnection) {
        Task { @MainActor in
            let loggedIn = self.auth.isAuthenticated
            let userId = self.auth.userId
            self.send(conn, status: "200 OK", type: "application/json",
                      body: "{\"logged_in\":\(loggedIn),\"user_id\":\"\(userId)\"}")
        }
    }

    // MARK: - /state/reset

    private func handleStateReset(_ conn: NWConnection) {
        Task { @MainActor in
            self.auth.resetState()
            self.send(conn, status: "200 OK", type: "application/json", body: "{\"reset\":true}")
        }
    }

    // MARK: - /permissions

    private func handlePermissions(_ conn: NWConnection) {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        var perms: [(String, Bool)] = []
        if let infoPlist = Bundle.main.infoDictionary {
            let permKeys = infoPlist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
            for key in permKeys {
                perms.append((key, true))
            }
        }
        let items = perms.map { "{\"permission\":\"\($0.0)\",\"granted\":\($0.1)}" }.joined(separator: ",")
        send(conn, status: "200 OK", type: "application/json",
             body: "{\"package\":\"\(bundleId)\",\"permissions\":[\(items)]}")
    }

    // MARK: - /navigate/site/{id}

    private func handleNavigateSite(_ conn: NWConnection, req: String) {
        guard let line = req.components(separatedBy: "\r\n").first,
              let path = line.components(separatedBy: " ").dropFirst().first,
              let idStr = path.components(separatedBy: "/").last,
              let siteId = Int(idStr) else {
            send(conn, status: "400 Bad Request", type: "application/json",
                 body: "{\"error\":\"invalid site id\"}")
            return
        }
        Task { @MainActor in
            guard let site = await self.nav.loadSite(id: String(siteId)) else {
                self.send(conn, status: "404 Not Found", type: "application/json",
                          body: "{\"error\":\"site \(siteId) not found\"}")
                return
            }
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
                self.send(conn, status: "500 Internal Server Error", type: "application/json",
                          body: "{\"error\":\"no root view controller\"}")
                return
            }
            let hostingVC = self.nav.createSiteViewController(site: site)
            if let navVC = rootVC as? UINavigationController {
                navVC.pushViewController(hostingVC, animated: false)
            } else if let navVC = rootVC.children.compactMap({ $0 as? UINavigationController }).first {
                navVC.pushViewController(hostingVC, animated: false)
            } else {
                rootVC.present(hostingVC, animated: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.send(conn, status: "200 OK", type: "application/json",
                          body: "{\"navigated\":\"site\",\"id\":\(siteId)}")
            }
        }
    }

    // MARK: - /navigate/user/{id}

    private func handleNavigateUser(_ conn: NWConnection, req: String) {
        guard let line = req.components(separatedBy: "\r\n").first,
              let path = line.components(separatedBy: " ").dropFirst().first,
              let idStr = path.components(separatedBy: "/").last,
              let userId = Int(idStr) else {
            send(conn, status: "400 Bad Request", type: "application/json",
                 body: "{\"error\":\"invalid user id\"}")
            return
        }
        Task { @MainActor in
            guard let user = await self.nav.loadUser(id: String(userId)) else {
                self.send(conn, status: "404 Not Found", type: "application/json",
                          body: "{\"error\":\"user \(userId) not found\"}")
                return
            }
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
                self.send(conn, status: "500 Internal Server Error", type: "application/json",
                          body: "{\"error\":\"no root view controller\"}")
                return
            }
            let hostingVC = self.nav.createUserViewController(user: user)
            if let navVC = rootVC as? UINavigationController {
                navVC.pushViewController(hostingVC, animated: false)
            } else if let navVC = rootVC.children.compactMap({ $0 as? UINavigationController }).first {
                navVC.pushViewController(hostingVC, animated: false)
            } else {
                rootVC.present(hostingVC, animated: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.send(conn, status: "200 OK", type: "application/json",
                          body: "{\"navigated\":\"user\",\"id\":\(userId)}")
            }
        }
    }

    // MARK: - Helpers

    private func extractBody(_ req: String) -> String {
        guard let range = req.range(of: "\r\n\r\n") else { return "" }
        return String(req[range.upperBound...])
    }

    private func extractJSONString(_ json: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return String(json[range])
    }

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
