#if DEBUG
import UIKit
import MapKit
import WebKit

struct SemanticUIElement {
    let id: String
    let platformId: String
    let semanticType: String
    let content: String?
    let bounds: CGRect
    let zIndex: Int
    let clickable: Bool
    let enabled: Bool
    let render: String?
    let accessible: Bool
    let a11yLabel: String?
    let a11yId: String?
}

final class SemanticViewWalker {

    private var elements: [SemanticUIElement] = []
    private var globalZ = 0
    private(set) var walkLog: String = ""

    func walk() -> (elements: [SemanticUIElement], screenName: String, deviceName: String) {
        elements.removeAll()
        globalZ = 0
        walkLog = ""

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            walkLog += "SKIP: no key window found\n"
            return ([], "unknown", UIDevice.current.name)
        }

        let screenName = topViewControllerName(window)

        walkView(window, depth: 0, parentExternal: false)

        let beforeGhost = elements.count
        let filtered = filterGhostTouchTargets(elements)
        let removed = beforeGhost - filtered.count
        if removed > 0 {
            walkLog += "POST-FILTER: ghost touch removed \(removed) elements (\(beforeGhost) → \(filtered.count))\n"
        }

        return (filtered, screenName, UIDevice.current.name)
    }

    // MARK: - Recursive Walk

    private func walkView(_ view: UIView, depth: Int, parentExternal: Bool) {
        let indent = String(repeating: "  ", count: depth)
        let cls = String(describing: type(of: view))
        let frame = view.convert(view.bounds, to: nil)
        let screenBounds = UIScreen.main.bounds

        if view.isHidden && view.subviews.isEmpty {
            walkLog += "\(indent)SKIP \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) hidden=true leaf\n"
            return
        }
        if view.alpha == 0 && view.subviews.isEmpty {
            walkLog += "\(indent)SKIP \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) alpha=0 leaf\n"
            return
        }

        guard frame.maxY > 0,
              frame.minY < screenBounds.height,
              frame.maxX > 0,
              frame.minX < screenBounds.width,
              frame.width > 0,
              frame.height > 0 else {
            walkLog += "\(indent)SKIP \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) offscreen\n"
            return
        }

        let isExternal = view is MKMapView || view is WKWebView

        let content = extractContent(view)
        let platformId = view.accessibilityIdentifier ?? ""
        let semanticType = classifyType(view, content: content)

        let id: String
        if let c = content, !c.isEmpty {
            id = slugify(c)
        } else if !platformId.isEmpty {
            id = slugify(platformId)
        } else {
            id = "\(shortenClass(cls))_\(Int(frame.minX))_\(Int(frame.minY))"
        }

        let clickable = view.isUserInteractionEnabled && (
            view is UIControl ||
            view.accessibilityTraits.contains(.button) ||
            view.accessibilityTraits.contains(.link) ||
            (view.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) == true)
        )

        let axLabel = view.accessibilityLabel
        let axId = view.accessibilityIdentifier
        let isAccessible = view.isAccessibilityElement

        let element = SemanticUIElement(
            id: id,
            platformId: platformId,
            semanticType: semanticType,
            content: content,
            bounds: frame,
            zIndex: globalZ,
            clickable: clickable,
            enabled: view.isUserInteractionEnabled,
            render: (isExternal || parentExternal) ? "external" : nil,
            accessible: isAccessible,
            a11yLabel: axLabel,
            a11yId: axId
        )
        elements.append(element)

        var logLine = "\(indent)EMIT z=\(globalZ) \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
        logLine += " hidden=\(view.isHidden) alpha=\(view.alpha) axEl=\(isAccessible)"
        if let al = axLabel, !al.isEmpty { logLine += " axLabel=\"\(al)\"" }
        if let ai = axId, !ai.isEmpty { logLine += " axId=\"\(ai)\"" }
        if let c = content, !c.isEmpty { logLine += " content=\"\(c.prefix(40))\"" }
        logLine += " type=\(semanticType) id=\(id)"
        if isExternal { logLine += " EXTERNAL(skip children)" }
        walkLog += logLine + "\n"

        globalZ += 1

        if isExternal { return }

        for subview in view.subviews {
            walkView(subview, depth: depth + 1, parentExternal: isExternal || parentExternal)
        }

        synthesizeAccessibilityChildren(view, depth: depth)
    }

    // MARK: - Accessibility Element Synthesis

    private func synthesizeAccessibilityChildren(_ view: UIView, depth: Int) {
        let indent = String(repeating: "  ", count: depth + 1)

        guard let axElements = view.accessibilityElements, !axElements.isEmpty else { return }

        let hasOpaqueBitmaps = view.subviews.contains { sub in
            let scls = String(describing: type(of: sub))
            return scls.contains("CGDrawingView") || scls.contains("GraphicsView")
        }
        guard hasOpaqueBitmaps else { return }

        for axEl in axElements {
            guard let axEl = axEl as? NSObject else { continue }
            let label = axEl.accessibilityLabel ?? ""
            guard !label.isEmpty else { continue }

            let axFrame: CGRect
            if let axView = axEl as? UIView {
                axFrame = axView.convert(axView.bounds, to: nil)
            } else if let container = (axEl as? UIAccessibilityElement)?.accessibilityContainer as? UIView {
                axFrame = UIAccessibility.convertToScreenCoordinates(axEl.accessibilityFrame, in: container)
            } else {
                axFrame = axEl.accessibilityFrame
            }

            guard axFrame.width > 0, axFrame.height > 0 else { continue }

            let synId = slugify(label)
            let traits = axEl.accessibilityTraits
            let synType: String
            if traits.contains(.button) { synType = "button" }
            else if traits.contains(.image) { synType = "image" }
            else if traits.contains(.staticText) { synType = "text" }
            else { synType = "text" }

            let synElement = SemanticUIElement(
                id: synId,
                platformId: "",
                semanticType: synType,
                content: label,
                bounds: axFrame,
                zIndex: globalZ,
                clickable: traits.contains(.button) || traits.contains(.link),
                enabled: true,
                render: nil,
                accessible: true,
                a11yLabel: label,
                a11yId: (axEl as? UIAccessibilityIdentification)?.accessibilityIdentifier
            )
            elements.append(synElement)
            walkLog += "\(indent)SYNTH z=\(globalZ) axElement label=\"\(label)\" (\(Int(axFrame.minX)),\(Int(axFrame.minY)),\(Int(axFrame.width)),\(Int(axFrame.height))) type=\(synType)\n"
            globalZ += 1
        }
    }

    // MARK: - Content Extraction

    private func extractContent(_ view: UIView) -> String? {
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            return text
        }
        if let textField = view as? UITextField, let text = textField.text, !text.isEmpty {
            return text
        }
        if let textView = view as? UITextView, let text = textView.text, !text.isEmpty {
            return text
        }
        if let btn = view as? UIButton, let title = btn.currentTitle, !title.isEmpty {
            return title
        }
        if let seg = view as? UISegmentedControl {
            let idx = seg.selectedSegmentIndex
            if idx >= 0, let title = seg.titleForSegment(at: idx) {
                return title
            }
        }
        if let sw = view as? UISwitch {
            return sw.isOn ? "on" : "off"
        }
        if let axLabel = view.accessibilityLabel, !axLabel.isEmpty {
            return axLabel
        }
        return nil
    }

    // MARK: - Type Classification

    private func classifyType(_ view: UIView, content: String?) -> String {
        if view is UILabel || view.accessibilityTraits.contains(.staticText) { return "text" }
        if view is UIButton || view.accessibilityTraits.contains(.button) { return "button" }
        if view is UIImageView { return "image" }
        if view is UITextField || view is UITextView { return "input" }
        if view is UISwitch || view is UISlider { return "toggle" }
        if view is UISegmentedControl { return "toggle" }

        let cls = String(describing: type(of: view))
        if cls.contains("Image") || cls.contains("Drawing") || cls.contains("Graphics") {
            if view.layer.contents != nil { return "image" }
        }

        if view is MKMapView || view is WKWebView { return "container" }

        return "container"
    }

    // MARK: - Ghost Touch Target Filter

    private func filterGhostTouchTargets(_ elements: [SemanticUIElement]) -> [SemanticUIElement] {
        var result = elements
        var toRemove = Set<Int>()

        for (i, a) in elements.enumerated() {
            guard a.clickable,
                  a.content == nil || a.content?.isEmpty == true,
                  a.semanticType == "container" else { continue }

            let hasNoBg = !viewHasBackground(at: i)

            guard hasNoBg else { continue }

            for (j, b) in elements.enumerated() where j != i {
                if boundsMatch(a.bounds, b.bounds) && b.content != nil && !b.content!.isEmpty {
                    toRemove.insert(i)
                    break
                }
            }
        }

        for i in toRemove.sorted(by: >) {
            result.remove(at: i)
        }
        return result
    }

    private func viewHasBackground(at index: Int) -> Bool {
        false
    }

    private func boundsMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 &&
        abs(a.minY - b.minY) < 2 &&
        abs(a.width - b.width) < 2 &&
        abs(a.height - b.height) < 2
    }

    // MARK: - Helpers

    private func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var slug = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
            } else if ch == " " || ch == "-" || ch == "_" || ch == "." {
                if !slug.hasSuffix("_") { slug.append("_") }
            }
        }
        if slug.hasSuffix("_") { slug.removeLast() }
        if slug.count > 60 { slug = String(slug.prefix(60)) }
        return slug.isEmpty ? "unnamed" : slug
    }

    private func shortenClass(_ cls: String) -> String {
        let name = cls
            .replacingOccurrences(of: "UIKit.", with: "")
            .replacingOccurrences(of: "_UI", with: "")
            .replacingOccurrences(of: "XCUIElementType", with: "")
        let lower = name.lowercased()
        if lower.count > 20 { return String(lower.prefix(20)) }
        return lower
    }

    private func topViewControllerName(_ window: UIWindow) -> String {
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        if let nav = vc as? UINavigationController { vc = nav.visibleViewController }
        if let tab = vc as? UITabBarController { vc = tab.selectedViewController }
        if let nav = vc as? UINavigationController { vc = nav.visibleViewController }
        let name = String(describing: type(of: vc ?? window.rootViewController as Any))
        return name.replacingOccurrences(of: "ViewController", with: "")
            .replacingOccurrences(of: "Controller", with: "")
    }
}
#endif
