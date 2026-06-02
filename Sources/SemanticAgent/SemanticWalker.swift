#if DEBUG
import UIKit
import MapKit
import WebKit

struct WalkResult {
    let elements: [SemanticElement]
    let screenName: String
    let deviceName: String
    let log: String
}

final class SemanticWalker {

    private var elements: [SemanticElement] = []
    private var globalZ = 0
    private var log = ""

    func walk() -> WalkResult {
        elements.removeAll()
        globalZ = 0
        log = ""

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow && !($0 is OverlayWindow) }) else {
            log += "SKIP: no key window found\n"
            return WalkResult(elements: [], screenName: "unknown",
                              deviceName: UIDevice.current.name, log: log)
        }

        let screenName = resolveScreenName(window)
        walkView(window, depth: 0, parentExternal: false)

        let beforeGhost = elements.count
        let filtered = filterGhostTouchTargets(elements)
        let removed = beforeGhost - filtered.count
        if removed > 0 {
            log += "POST-FILTER: ghost touch removed \(removed) elements (\(beforeGhost) → \(filtered.count))\n"
        }

        return WalkResult(elements: filtered, screenName: screenName,
                          deviceName: UIDevice.current.name, log: log)
    }

    // MARK: - Recursive Walk

    private func walkView(_ view: UIView, depth: Int, parentExternal: Bool) {
        let indent = String(repeating: "  ", count: depth)
        let cls = String(describing: type(of: view))
        let frame = view.convert(view.bounds, to: nil)
        let screenBounds = UIScreen.main.bounds

        if view.isHidden {
            log += "\(indent)SKIP \(cls) hidden (subtree pruned)\n"
            return
        }
        if view.alpha == 0 {
            log += "\(indent)SKIP \(cls) alpha=0 (subtree pruned)\n"
            return
        }

        guard frame.maxY > 0, frame.minY < screenBounds.height,
              frame.maxX > 0, frame.minX < screenBounds.width,
              frame.width > 0, frame.height > 0 else {
            log += "\(indent)SKIP \(cls) offscreen\n"
            return
        }

        let clipped = frame.minX < 0 || frame.minY < 0

        if clipped {
            log += "\(indent)CLIP \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) viewport-clipped\n"
        } else {
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
                (view.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer || $0 is UILongPressGestureRecognizer }) == true)
            )

            let element = SemanticElement(
                id: id,
                platformId: platformId,
                semanticType: semanticType,
                content: content,
                bounds: frame,
                zIndex: globalZ,
                clickable: clickable,
                enabled: view.isUserInteractionEnabled,
                render: (isExternal || parentExternal) ? "external" : nil,
                accessible: view.isAccessibilityElement,
                a11yLabel: view.accessibilityLabel,
                a11yId: view.accessibilityIdentifier
            )
            elements.append(element)

            var logLine = "\(indent)EMIT z=\(globalZ) \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
            logLine += " type=\(semanticType) id=\(id)"
            if let c = content, !c.isEmpty { logLine += " content=\"\(c.prefix(40))\"" }
            if isExternal { logLine += " EXTERNAL" }
            log += logLine + "\n"

            if isExternal {
                globalZ += 1
                return
            }
        }

        globalZ += 1

        if isExternal { return }

        for subview in view.subviews {
            walkView(subview, depth: depth + 1, parentExternal: isExternal || parentExternal)
        }

        synthesizeAccessibilityChildren(view, depth: depth)
    }

    // MARK: - Accessibility Synthesis

    private func synthesizeAccessibilityChildren(_ view: UIView, depth: Int) {
        guard let axElements = view.accessibilityElements, !axElements.isEmpty else { return }

        let hasOpaqueBitmaps = view.subviews.contains { sub in
            let scls = String(describing: type(of: sub))
            return scls.contains("CGDrawingView") || scls.contains("GraphicsView")
        }
        guard hasOpaqueBitmaps else { return }

        let indent = String(repeating: "  ", count: depth + 1)

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

            let traits = axEl.accessibilityTraits
            let synType: String
            if traits.contains(.button) { synType = "button" } else if traits.contains(.image) { synType = "image" } else if traits.contains(.staticText) { synType = "text" } else { synType = "text" }

            let synElement = SemanticElement(
                id: slugify(label),
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
            log += "\(indent)SYNTH z=\(globalZ) label=\"\(label)\" (\(Int(axFrame.minX)),\(Int(axFrame.minY)),\(Int(axFrame.width)),\(Int(axFrame.height))) type=\(synType)\n"
            globalZ += 1
        }
    }

    // MARK: - Content Extraction

    private func extractContent(_ view: UIView) -> String? {
        if let label = view as? UILabel, let text = label.text, !text.isEmpty { return text }
        if let tf = view as? UITextField, let text = tf.text, !text.isEmpty { return text }
        if let tv = view as? UITextView, let text = tv.text, !text.isEmpty { return text }
        if let btn = view as? UIButton, let title = btn.currentTitle, !title.isEmpty { return title }
        if let seg = view as? UISegmentedControl {
            let idx = seg.selectedSegmentIndex
            if idx >= 0, let title = seg.titleForSegment(at: idx) { return title }
        }
        if let sw = view as? UISwitch { return sw.isOn ? "on" : "off" }
        if let axLabel = view.accessibilityLabel, !axLabel.isEmpty { return axLabel }
        if view is UIControl {
            if let text = findLabelText(in: view) { return text }
        }
        if view.accessibilityTraits.contains(.button) || view is UIControl {
            let cls = String(describing: type(of: view))
            if cls.contains("TabBarButton") || cls.contains("BarButton") {
                for sub in view.subviews {
                    let subCls = String(describing: type(of: sub))
                    if subCls.contains("Label") || subCls.contains("Text") {
                        if sub.responds(to: NSSelectorFromString("attributedText")),
                           let attrText = sub.perform(NSSelectorFromString("attributedText"))?.takeUnretainedValue() as? NSAttributedString,
                           !attrText.string.isEmpty {
                            return attrText.string
                        }
                    }
                }
            }
        }
        return nil
    }

    private func findLabelText(in view: UIView) -> String? {
        for sub in view.subviews {
            if let label = sub as? UILabel, let text = label.text, !text.isEmpty { return text }
            if sub.responds(to: Selector(("text"))),
               let text = sub.perform(Selector(("text")))?.takeUnretainedValue() as? String,
               !text.isEmpty { return text }
            if let axLabel = sub.accessibilityLabel, !axLabel.isEmpty { return axLabel }
            if let text = findLabelText(in: sub) { return text }
        }
        if let axElements = view.accessibilityElements {
            for axEl in axElements {
                if let axEl = axEl as? NSObject,
                   let label = axEl.accessibilityLabel, !label.isEmpty { return label }
            }
        }
        return nil
    }

    // MARK: - Type Classification

    private func classifyType(_ view: UIView, content: String?) -> String {
        if view is UILabel || view.accessibilityTraits.contains(.staticText) { return "text" }
        if view is UIButton || view.accessibilityTraits.contains(.button) { return "button" }
        if view is UIImageView { return "image" }
        if view is UITextField || view is UITextView { return "input" }
        if view is UISwitch || view is UISlider || view is UISegmentedControl { return "toggle" }

        let cls = String(describing: type(of: view))
        if cls.contains("Image") || cls.contains("Drawing") || cls.contains("Graphics") {
            if view.layer.contents != nil { return "image" }
        }

        return "container"
    }

    // MARK: - Ghost Touch Target Filter

    private func filterGhostTouchTargets(_ elements: [SemanticElement]) -> [SemanticElement] {
        var toRemove = Set<Int>()

        for (i, a) in elements.enumerated() {
            guard a.clickable,
                  a.content == nil || a.content?.isEmpty == true,
                  a.semanticType != "image" else { continue }

            for (j, b) in elements.enumerated() where j != i {
                if boundsMatch(a.bounds, b.bounds) && b.content != nil && !b.content!.isEmpty {
                    toRemove.insert(i)
                    break
                }
            }
        }

        return elements.enumerated().compactMap { toRemove.contains($0.offset) ? nil : $0.element }
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
        let lower = name.lowercased()
        return lower.count > 20 ? String(lower.prefix(20)) : lower
    }

    private func resolveScreenName(_ window: UIWindow) -> String {
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
