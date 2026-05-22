#if DEBUG
import UIKit

enum IdleDetector {

    static func isIdle() -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return true }

        // Check navigation transitions
        if hasActiveNavTransition(window) { return false }

        // Check CALayer animations
        if hasActiveAnimations(window) { return false }

        // Check activity indicators (loading spinners)
        if hasActiveSpinners(window) { return false }

        // Check modal presentations in progress
        if hasActivePresentation(window) { return false }

        return true
    }

    private static func hasActiveNavTransition(_ window: UIWindow) -> Bool {
        var vc: UIViewController? = window.rootViewController
        while let current = vc {
            if let nav = current as? UINavigationController {
                if nav.transitionCoordinator != nil { return true }
            }
            if current.transitionCoordinator != nil { return true }
            vc = current.presentedViewController
        }
        return false
    }

    private static func hasActiveAnimations(_ window: UIWindow) -> Bool {
        return viewHasAnimations(window)
    }

    private static func viewHasAnimations(_ view: UIView) -> Bool {
        if let keys = view.layer.animationKeys(), !keys.isEmpty { return true }
        for sub in view.subviews {
            if viewHasAnimations(sub) { return true }
        }
        return false
    }

    private static func hasActiveSpinners(_ window: UIWindow) -> Bool {
        return findSpinner(window)
    }

    private static func findSpinner(_ view: UIView) -> Bool {
        if let spinner = view as? UIActivityIndicatorView {
            if spinner.isAnimating && !spinner.isHidden && spinner.alpha > 0.01 { return true }
        }
        // SwiftUI ProgressView renders as _UIActivityIndicatorView
        let typeName = String(describing: type(of: view))
        if typeName.contains("ActivityIndicator") && !view.isHidden && view.alpha > 0.01 {
            return true
        }
        for sub in view.subviews {
            if findSpinner(sub) { return true }
        }
        return false
    }

    private static func hasActivePresentation(_ window: UIWindow) -> Bool {
        var vc: UIViewController? = window.rootViewController
        while let current = vc {
            if current.isBeingPresented || current.isBeingDismissed { return true }
            vc = current.presentedViewController
        }
        return false
    }
}
#endif
