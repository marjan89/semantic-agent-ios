import UIKit
import Network
import Foundation

// MARK: - Protocols (app implements these)

public protocol AgentAuthProvider: AnyObject {
    var isAuthenticated: Bool { get }
    var userId: String { get }
    func login(email: String, password: String) async -> (success: Bool, error: String?)
    func logout()
    func resetState()
}

public protocol AgentNavigationProvider: AnyObject {
    func navigateToSite(id: Int) async -> UIViewController?
    func navigateToUser(id: Int) async -> UIViewController?
}

// MARK: - Public API

@MainActor
public final class SemanticAgentEngine {
    public static let shared = SemanticAgentEngine()
    private var server: SemanticServer?

    public func start(
        port: UInt16 = UInt16(ProcessInfo.processInfo.environment["IDB_AGENT_PORT"] ?? "9877") ?? 9877,
        auth: AgentAuthProvider,
        nav: AgentNavigationProvider
    ) {
        guard server == nil else { return }
        server = SemanticServer(port: port, auth: auth, nav: nav)
        server?.start()
    }

    public func stop() {
        server?.stop()
        server = nil
    }
}
