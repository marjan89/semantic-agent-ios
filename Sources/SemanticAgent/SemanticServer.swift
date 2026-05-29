#if DEBUG
import UIKit
import Network
import SwiftUI
import Resolver

// MARK: - Public API

protocol AgentAuthProvider {
    var isAuthenticated: Bool { get }
    var userId: String { get }
    func login(email: String, password: String) async -> (success: Bool, error: String?)
    func logout()
    func resetState()
}

protocol AgentNavigationProvider {
    func loadSite(id: String) async -> Site?
    func loadUser(id: String) async -> RegularUser?
    func createSiteViewController(site: Site) -> UIViewController
    func createUserViewController(user: RegularUser) -> UIViewController
}

@MainActor
final class SemanticAgent {
    static let shared = SemanticAgent()
    private var server: SemanticServer?

    func start(port: UInt16 = UInt16(ProcessInfo.processInfo.environment["IDB_AGENT_PORT"] ?? "9877") ?? 9877) {
        guard server == nil else { return }
        IdleResourceRegistry.shared.installHooks()
        let auth = NKAgentAuthProvider()
        let nav = NKAgentNavigationProvider()
        server = SemanticServer(port: port, auth: auth, nav: nav)
        server?.start()
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

// MARK: - Concrete Providers

@MainActor
private final class NKAgentAuthProvider: AgentAuthProvider {
    nonisolated var isAuthenticated: Bool {
        MainActor.assumeIsolated { AuthService().isAuthenticated }
    }
    nonisolated var userId: String {
        MainActor.assumeIsolated { AuthService().userModel?.user.id ?? "-1" }
    }
    func login(email: String, password: String) async -> (success: Bool, error: String?) {
        let svc = AuthService()
        await svc.login(authMethod: .password(email: email, password: password))
        return (svc.isAuthenticated, svc.loginError)
    }
    nonisolated func logout() {
        MainActor.assumeIsolated { AuthService().logout() }
    }
    nonisolated func resetState() {
        MainActor.assumeIsolated {
            AuthService().logout()
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        }
    }
}

@MainActor
private final class NKAgentNavigationProvider: AgentNavigationProvider {
    func loadSite(id: String) async -> Site? {
        let repo: SitesRepository = Resolver.resolve()
        return await repo.loadSite(siteId: id, relationships: [.images])
    }
    func loadUser(id: String) async -> RegularUser? {
        let api: API = Resolver.resolve()
        guard let apiUser = try? await api.JSONAPIRequest(with: Endpoints.Public.user(id: id)).valueOrThrow() else { return nil }
        return RegularUser(user: apiUser)
    }
    nonisolated func createSiteViewController(site: Site) -> UIViewController {
        MainActor.assumeIsolated {
            UIHostingController(rootView: SiteDetailScreen(site: site).environmentObject(AuthService()))
        }
    }
    nonisolated func createUserViewController(user: RegularUser) -> UIViewController {
        MainActor.assumeIsolated {
            UIHostingController(rootView: UserScreen(userViewModel: UserModel(user: user)).environmentObject(AuthService()))
        }
    }
}

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

            let reqStart = Date()
            if req.hasPrefix("GET /semantic") {
                self.agentLog("GET", "/semantic", durationMs: 0)
                self.handleSemantic(conn, req: req)
            } else if req.hasPrefix("GET /overlay") {
                self.handleOverlay(conn, req: req)
            } else if req.hasPrefix("DELETE /overlay") {
                self.handleOverlayClear(conn)
            } else if req.hasPrefix("GET /idle-resources") {
                let status = IdleResourceRegistry.shared.status()
                let entries = status.map { "\"\(self.escJSON($0.key))\":\($0.value ? "\"idle\"" : "\"busy\"")" }.joined(separator: ",")
                self.agentLog("GET", "/idle-resources", durationMs: Int(Date().timeIntervalSince(reqStart) * 1000))
                self.send(conn, status: "200 OK", type: "application/json", body: "{\(entries)}")
            } else if req.hasPrefix("GET /idle") {
                self.handleIdle(conn)
                self.agentLog("GET", "/idle", durationMs: Int(Date().timeIntervalSince(reqStart) * 1000))
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
                let buildTime = "2026-05-29T19:16:47Z"
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
            } else if req.hasPrefix("POST /query-when-idle") {
                self.agentLog("POST", "/query-when-idle", durationMs: 0)
                self.handleQueryWhenIdle(conn, req: req)
            } else if req.hasPrefix("POST /scroll-search") {
                self.agentLog("POST", "/scroll-search", durationMs: 0)
                self.handleScrollSearch(conn, req: req)
            } else if req.hasPrefix("POST /navigate/site/") {
                self.agentLog("POST", "/navigate/site", durationMs: 0)
                self.handleNavigateSite(conn, req: req)
            } else if req.hasPrefix("POST /navigate/user/") {
                self.agentLog("POST", "/navigate/user", durationMs: 0)
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
        let entries = logBuffer.joined(separator: ",")
        send(conn, status: "200 OK", type: "application/json", body: "[\(entries)]")
    }

    // MARK: - Debug Log Buffer

    private var logBuffer: [String] = []
    private let logBufferLimit = 100

    private func agentLog(_ method: String, _ path: String, durationMs: Int) {
        let entry = "{\"ts\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"method\":\"\(method)\",\"path\":\"\(path)\",\"duration_ms\":\(durationMs)}"
        if logBuffer.count >= logBufferLimit { logBuffer.removeFirst() }
        logBuffer.append(entry)
    }

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

    // MARK: - /query-when-idle

    private func handleQueryWhenIdle(_ conn: NWConnection, req: String) {
        let body = extractBody(req)
        let timeout = extractJSONDouble(body, key: "timeout") ?? 5.0
        let matchFuzzy = extractJSONString(body, key: "content_fuzzy")
        let matchText = extractJSONString(body, key: "text")
        let matchId = extractJSONString(body, key: "id")

        var resourceNames: [String] = []
        if let raw = extractJSONArray(body, key: "idle_resources") {
            resourceNames = raw
        }

        let registry = IdleResourceRegistry.shared
        let startTime = Date()

        registry.waitForIdle(named: resourceNames, timeout: timeout) {  [weak self] idle in
            guard let self = self else { return }
            let waitMs = Int(Date().timeIntervalSince(startTime) * 1000)

            if !idle {
                let status = registry.status(named: resourceNames)
                let statusJSON = status.map { "\"\(self.escJSON($0.key))\":\($0.value)" }.joined(separator: ",")
                self.send(conn, status: "200 OK", type: "application/json",
                          body: "{\"found\":false,\"timeout\":true,\"idle_wait_ms\":\(waitMs),\"idle_resources_status\":{\(statusJSON)}}")
                return
            }

            DispatchQueue.main.async {
                let result = self.freshWalk()
                let elements = result.elements

                var found: SemanticElement?
                for el in elements {
                    if let mid = matchId, el.a11yId == mid {
                        found = el; break
                    }
                    if let mt = matchText, el.content == mt {
                        found = el; break
                    }
                    if let mf = matchFuzzy, let c = el.content, c.lowercased().contains(mf.lowercased()) {
                        found = el; break
                    }
                }

                if let el = found {
                    let cx = el.bounds.midX
                    let cy = el.bounds.midY
                    let contentStr = self.escJSON(el.content ?? "")
                    self.send(conn, status: "200 OK", type: "application/json",
                              body: "{\"found\":true,\"element\":{\"x\":\(Int(cx)),\"y\":\(Int(cy)),\"w\":\(Int(el.bounds.width)),\"h\":\(Int(el.bounds.height)),\"content\":\"\(contentStr)\",\"type\":\"\(el.semanticType)\"},\"idle_wait_ms\":\(waitMs),\"source\":\"view_tree\"}")
                } else {
                    let status = registry.status(named: resourceNames)
                    let statusJSON = status.map { "\"\(self.escJSON($0.key))\":\($0.value)" }.joined(separator: ",")
                    self.send(conn, status: "200 OK", type: "application/json",
                              body: "{\"found\":false,\"timeout\":false,\"idle_wait_ms\":\(waitMs),\"idle_resources_status\":{\(statusJSON)}}")
                }
            }
        }
    }

    // MARK: - /scroll-search

    private func handleScrollSearch(_ conn: NWConnection, req: String) {
        let body = extractBody(req)
        let matchFuzzy = extractJSONString(body, key: "content_fuzzy")
        let matchText = extractJSONString(body, key: "text")
        let matchId = extractJSONString(body, key: "id")
        let maxScroll = Int(extractJSONDouble(body, key: "max_scroll") ?? 15)
        let restoreScroll = extractJSONBool(body, key: "restore_scroll") ?? false

        var resourceNames: [String] = []
        if let raw = extractJSONArray(body, key: "idle_resources") {
            resourceNames = raw
        }

        let registry = IdleResourceRegistry.shared
        let startTime = Date()

        registry.waitForIdle(named: resourceNames, timeout: 3) { [weak self] _ in
            guard let self = self else { return }

            DispatchQueue.main.async {
                let result = self.freshWalk()
                var found: SemanticElement?
                for el in result.elements {
                    if let mid = matchId, el.a11yId == mid { found = el; break }
                    if let mt = matchText, el.content == mt { found = el; break }
                    if let mf = matchFuzzy, let c = el.content, c.lowercased().contains(mf.lowercased()) { found = el; break }
                }

                if let el = found {
                    let waitMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    let contentStr = self.escJSON(el.content ?? "")
                    self.send(conn, status: "200 OK", type: "application/json",
                              body: "{\"found\":true,\"element\":{\"x\":\(Int(el.bounds.midX)),\"y\":\(Int(el.bounds.midY)),\"w\":\(Int(el.bounds.width)),\"h\":\(Int(el.bounds.height)),\"content\":\"\(contentStr)\",\"type\":\"\(el.semanticType)\"},\"scrolls\":0,\"scroll_restored\":true,\"idle_wait_ms\":\(waitMs)}")
                    return
                }

                let walker = SemanticWalker()
                walker.walkWithScroll(steps: maxScroll) { scrollResult in
                    var scrollFound: SemanticElement?
                    for el in scrollResult.elements {
                        if let mid = matchId, el.a11yId == mid { scrollFound = el; break }
                        if let mt = matchText, el.content == mt { scrollFound = el; break }
                        if let mf = matchFuzzy, let c = el.content, c.lowercased().contains(mf.lowercased()) { scrollFound = el; break }
                    }
                    let waitMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    if let el = scrollFound {
                        let contentStr = self.escJSON(el.content ?? "")
                        self.send(conn, status: "200 OK", type: "application/json",
                                  body: "{\"found\":true,\"element\":{\"x\":\(Int(el.bounds.midX)),\"y\":\(Int(el.bounds.midY)),\"w\":\(Int(el.bounds.width)),\"h\":\(Int(el.bounds.height)),\"content\":\"\(contentStr)\",\"type\":\"\(el.semanticType)\"},\"scrolls\":\(maxScroll),\"scroll_restored\":\(restoreScroll),\"idle_wait_ms\":\(waitMs)}")
                    } else {
                        self.send(conn, status: "200 OK", type: "application/json",
                                  body: "{\"found\":false,\"scrolls\":\(maxScroll),\"timeout\":false,\"idle_wait_ms\":\(waitMs)}")
                    }
                }
            }
        }
    }

    private func extractJSONBool(_ json: String, key: String) -> Bool? {
        let pattern = "\"\(key)\"\\s*:\\s*(true|false)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return json[range] == "true"
    }

    private func extractJSONDouble(_ json: String, key: String) -> Double? {
        let pattern = "\"\(key)\"\\s*:\\s*([0-9.]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return Double(json[range])
    }

    private func extractJSONArray(_ json: String, key: String) -> [String]? {
        let pattern = "\"\(key)\"\\s*:\\s*\\[([^\\]]*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        let inner = String(json[range])
        return inner.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
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
