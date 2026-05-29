#if DEBUG
import UIKit

// MARK: - Idle Resource Protocol

protocol IdleResource {
    var name: String { get }
    func isIdle() -> Bool
}

// MARK: - Built-in Resources

struct RunLoopIdleResource: IdleResource {
    let name = "runloop"
    func isIdle() -> Bool {
        let mode = RunLoop.main.currentMode
        return mode == nil || mode == .default
    }
}

struct NavigationIdleResource: IdleResource {
    let name = "navigation"
    func isIdle() -> Bool {
        guard let window = keyWindow() else { return true }
        var vc: UIViewController? = window.rootViewController
        while let current = vc {
            if let nav = current as? UINavigationController,
               nav.transitionCoordinator != nil { return false }
            if current.transitionCoordinator != nil { return false }
            if current.isBeingPresented || current.isBeingDismissed { return false }
            vc = current.presentedViewController
        }
        return true
    }
}

struct AnimationIdleResource: IdleResource {
    let name = "animation"
    func isIdle() -> Bool {
        guard let window = keyWindow() else { return true }
        return !viewHasAnimations(window)
    }

    private func viewHasAnimations(_ view: UIView) -> Bool {
        if let keys = view.layer.animationKeys(), !keys.isEmpty { return true }
        for sub in view.subviews {
            if viewHasAnimations(sub) { return true }
        }
        return false
    }
}

struct SpinnerIdleResource: IdleResource {
    let name = "spinner"
    func isIdle() -> Bool {
        guard let window = keyWindow() else { return true }
        return !findSpinner(window)
    }

    private func findSpinner(_ view: UIView) -> Bool {
        if let spinner = view as? UIActivityIndicatorView {
            if spinner.isAnimating && !spinner.isHidden && spinner.alpha > 0.01 { return true }
        }
        let typeName = String(describing: type(of: view))
        if typeName.contains("ActivityIndicator") && !view.isHidden && view.alpha > 0.01 {
            return true
        }
        for sub in view.subviews {
            if findSpinner(sub) { return true }
        }
        return false
    }
}

final class NetworkIdleResource: IdleResource {
    let name = "network"
    static let shared = NetworkIdleResource()
    private var lastActivityTime: Date = Date()
    private let lock = NSLock()
    private let settleInterval: TimeInterval = 1.5

    func isIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivityTime) > settleInterval
    }

    func noteActivity() {
        lock.lock()
        lastActivityTime = Date()
        lock.unlock()
    }

    func installHook() {
        URLProtocol.registerClass(NetworkIdleURLProtocol.self)
    }
}

final class NetworkIdleURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        NetworkIdleResource.shared.noteActivity()
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

final class PresentationIdleResource: IdleResource {
    let name = "presentation"
    static let shared = PresentationIdleResource()
    private var lastPresentationChange: Date = .distantPast
    private let lock = NSLock()
    private let settleInterval: TimeInterval = 0.5

    func isIdle() -> Bool {
        let windowCount = activeWindowCount()
        let hasPresentation = hasPendingPresentation()

        if windowCount > 1 || hasPresentation {
            noteChange()
            return true
        }

        lock.lock()
        let settled = Date().timeIntervalSince(lastPresentationChange) > settleInterval
        lock.unlock()
        return settled
    }

    func noteChange() {
        lock.lock()
        lastPresentationChange = Date()
        lock.unlock()
    }

    private func activeWindowCount() -> Int {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .count
    }

    private func hasPendingPresentation() -> Bool {
        guard let window = keyWindow(),
              var vc = window.rootViewController else { return false }
        while let presented = vc.presentedViewController {
            if presented.isBeingPresented || presented.isBeingDismissed { return true }
            if presented is UIAlertController { return false }
            vc = presented
        }
        return false
    }
}

struct LayoutIdleResource: IdleResource {
    let name = "layout"
    func isIdle() -> Bool {
        guard let window = keyWindow() else { return true }
        return !viewNeedsLayout(window)
    }

    private func viewNeedsLayout(_ view: UIView) -> Bool {
        if view.layer.needsLayout() { return true }
        for sub in view.subviews.prefix(50) {
            if viewNeedsLayout(sub) { return true }
        }
        return false
    }
}

// MARK: - Registry

final class IdleResourceRegistry {
    static let shared = IdleResourceRegistry()

    private(set) var resources: [IdleResource] = [
        NavigationIdleResource(),
        AnimationIdleResource(),
        SpinnerIdleResource(),
        LayoutIdleResource(),
        NetworkIdleResource.shared,
        PresentationIdleResource.shared,
    ]

    func installHooks() {
        NetworkIdleResource.shared.installHook()
    }

    func isAllIdle() -> Bool {
        resources.allSatisfy { $0.isIdle() }
    }

    func isAllIdle(named: [String]) -> Bool {
        let filtered = named.isEmpty ? resources : resources.filter { named.contains($0.name) }
        return filtered.allSatisfy { $0.isIdle() }
    }

    func status() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for r in resources { result[r.name] = r.isIdle() }
        return result
    }

    func status(named: [String]) -> [String: Bool] {
        let filtered = named.isEmpty ? resources : resources.filter { named.contains($0.name) }
        var result: [String: Bool] = [:]
        for r in filtered { result[r.name] = r.isIdle() }
        return result
    }

    func waitForIdle(named: [String] = [], timeout: TimeInterval = 5, callback: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if isAllIdle(named: named) {
                callback(true)
            } else if Date() >= deadline {
                callback(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
            }
        }
        DispatchQueue.main.async { check() }
    }
}

// MARK: - Legacy API (backward-compatible)

enum IdleDetector {
    static func isIdle() -> Bool {
        IdleResourceRegistry.shared.isAllIdle()
    }
}

// MARK: - Helpers

private func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)
}
#endif
