#if DEBUG
import UIKit
import CoreText
import QuartzCore

struct SemanticUIElement {
    let id: String
    let platformId: String
    let semanticType: String
    let content: String?
    let font: SemanticFontInfo?
    let color: String?
    let backgroundColor: String?
    let bounds: CGRect
    let clickable: Bool
    let cornerRadius: CGFloat
    let padding: UIEdgeInsets?
    let iconName: String?
    let clipShape: String?
    var children: [SemanticUIElement]?
}

struct SemanticFontInfo {
    let family: String
    let weight: String
    let size: CGFloat
}

final class SemanticViewWalker {

    private var seen = Set<String>()
    private var keyWindow: UIView?

    func walk() -> (elements: [SemanticUIElement], screenName: String, deviceName: String) {
        var elements: [SemanticUIElement] = []
        seen.removeAll()

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            return (elements, "unknown", UIDevice.current.name)
        }

        keyWindow = window
        walkView(window, into: &elements)
        keyWindow = nil
        return (elements, topScreenName(window), UIDevice.current.name)
    }

    // MARK: - Recursive walk (accessibility tree + view tree hybrid)

    private func walkView(_ view: UIView, into elements: inout [SemanticUIElement]) {
        guard !view.isHidden, view.alpha > 0.01 else { return }

        let frame = view.convert(view.bounds, to: nil)
        let screen = UIScreen.main.bounds

        guard frame.width > 0, frame.height > 0 else { return }
        guard frame.maxY > 0, frame.minY < screen.height + 100 else { return }
        guard frame.height > 1 else { return }

        // If this view is an accessibility element itself, extract it
        if view.isAccessibilityElement {
            if var el = extractAccessible(view, frame: frame) {
                if isComposite(el.content, bounds: el.bounds) {
                    el.children = decomposeComposite(content: el.content!, bounds: el.bounds, searchIn: view)
                }
                addDeduped(el, into: &elements)
            }
        }

        // Also check standard UIKit types (UILabel, UIButton etc.) even if not accessibility elements
        if let el = extractUIKit(view, frame: frame) {
            addDeduped(el, into: &elements)
        }

        // Walk accessibility children (SwiftUI exposes elements here, not as UIView subviews)
        walkAccessibilityChildren(of: view, into: &elements)

        // Walk UIView subviews
        for sub in view.subviews {
            walkView(sub, into: &elements)
        }
    }

    private func walkAccessibilityChildren(of view: UIView, into elements: inout [SemanticUIElement]) {
        let screen = UIScreen.main.bounds
        // Method 1: explicit accessibilityElements array
        if let axElements = view.accessibilityElements {
            for child in axElements {
                if let childView = child as? UIView {
                    walkView(childView, into: &elements)
                } else if let axElement = child as? UIAccessibilityElement {
                    let axFrame = axElement.accessibilityFrame
                    if let el = extractAXElement(axElement, frame: axFrame, parentView: view) {
                        addDeduped(el, into: &elements)
                    }
                } else if let nsObj = child as? NSObject {
                    if var el = extractNSObjectChild(nsObj, screen: screen) {
                        if isComposite(el.content, bounds: el.bounds) {
                            el.children = decomposeComposite(content: el.content!, bounds: el.bounds, searchIn: view)
                        }
                        addDeduped(el, into: &elements)
                    }
                }
            }
        }

        // Method 2: accessibilityElementCount / accessibilityElement(at:) — SwiftUI's primary path
        let count = view.accessibilityElementCount()
        if count != NSNotFound && count > 0 {
            for i in 0..<count {
                guard let child = view.accessibilityElement(at: i) else { continue }
                if let childView = child as? UIView {
                    // Only walk if not already walked as subview
                    if !view.subviews.contains(childView) {
                        walkView(childView, into: &elements)
                    }
                } else if let axElement = child as? UIAccessibilityElement {
                    let axFrame = axElement.accessibilityFrame
                    if let el = extractAXElement(axElement, frame: axFrame, parentView: view) {
                        addDeduped(el, into: &elements)
                    }
                } else if let nsObj = child as? NSObject {
                    if var el = extractNSObjectChild(nsObj, screen: screen) {
                        if isComposite(el.content, bounds: el.bounds) {
                            el.children = decomposeComposite(content: el.content!, bounds: el.bounds, searchIn: view)
                        }
                        addDeduped(el, into: &elements)
                    }
                }
            }
        }
    }

    private func extractNSObjectChild(_ nsObj: NSObject, screen: CGRect) -> SemanticUIElement? {
        let label = nsObj.accessibilityLabel
        let traits = nsObj.accessibilityTraits
        let frame = nsObj.accessibilityFrame
        guard label != nil && !label!.isEmpty else { return nil }
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard frame.maxY > 0, frame.minY < screen.height + 100 else { return nil }

        let semType: String
        if traits.contains(.button) || traits.contains(.link) { semType = "button" }
        else if traits.contains(.image) { semType = "image" }
        else if traits.contains(.header) { semType = "text" }
        else { semType = "text" }

        let content = label
        let identifier = (nsObj as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
        let platformId = !identifier.isEmpty ? identifier : (label ?? "")
        let id = !content!.isEmpty ? slugify(content!) : slugify(platformId)

        var correctedFrame = frame
        if semType == "image" && frame.height > frame.width * 1.5 {
            correctedFrame = CGRect(x: frame.minX, y: frame.maxY - frame.width, width: frame.width, height: frame.width)
        }

        return SemanticUIElement(
            id: id, platformId: platformId, semanticType: semType, content: content,
            font: nil, color: nil, backgroundColor: nil, bounds: correctedFrame,
            clickable: traits.contains(.button), cornerRadius: 0, padding: nil,
            iconName: semType == "image" ? (identifier.isEmpty ? label : identifier) : nil,
            clipShape: semType == "image" && frame.height > frame.width * 1.5 ? "circle" : nil,
            children: nil
        )
    }

    private func addDeduped(_ el: SemanticUIElement, into elements: inout [SemanticUIElement]) {
        let key = "\(el.id)|\(Int(el.bounds.minX)),\(Int(el.bounds.minY)),\(Int(el.bounds.width)),\(Int(el.bounds.height))"
        if el.id.isEmpty || !seen.contains(key) {
            if !el.id.isEmpty { seen.insert(key) }
            elements.append(el)
        }
    }

    // MARK: - UIKit-specific extraction (UILabel, UIButton, etc.)

    private func extractUIKit(_ view: UIView, frame: CGRect) -> SemanticUIElement? {
        let semType: String
        var content: String?
        var font: SemanticFontInfo?
        var textColor: String?
        var iconName: String?

        switch view {
        case let label as UILabel:
            guard let text = label.text, !text.isEmpty else { return nil }
            semType = "text"
            content = text
            font = fontInfo(label.font)
            textColor = hex(label.textColor)

        case let button as UIButton:
            let title = button.title(for: .normal) ?? button.titleLabel?.text
            guard title != nil && !title!.isEmpty else { return nil }
            semType = "button"
            content = title
            if let tl = button.titleLabel {
                font = fontInfo(tl.font)
                textColor = hex(button.titleColor(for: .normal) ?? tl.textColor)
            }

        case let tf as UITextField:
            semType = "input"
            content = (tf.text?.isEmpty == false) ? tf.text : tf.placeholder
            if let f = tf.font { font = fontInfo(f) }
            textColor = hex(tf.textColor)

        case let tv as UITextView:
            guard let text = tv.text, !text.isEmpty else { return nil }
            semType = "text"
            content = text
            if let f = tv.font { font = fontInfo(f) }
            textColor = hex(tv.textColor)

        case let iv as UIImageView:
            guard iv.image != nil else { return nil }
            semType = "image"
            iconName = iv.accessibilityIdentifier ?? iv.image?.accessibilityIdentifier
            if iconName == nil || iconName!.isEmpty {
                let size = min(frame.width, frame.height)
                if size >= 40 && size <= 300 {
                    let clip = isClipped(iv)
                    iconName = clip ? "avatar_\(Int(frame.width))x\(Int(frame.height))" : "image_\(Int(frame.width))x\(Int(frame.height))"
                } else {
                    return nil
                }
            }

        case let sw as UISwitch:
            semType = "toggle"
            content = sw.isOn ? "on" : "off"

        case let sl as UISlider:
            semType = "slider"
            content = String(format: "%.1f", sl.value)

        default:
            return nil
        }

        let accessId = view.accessibilityIdentifier ?? ""
        let accessLabel = view.accessibilityLabel ?? ""
        let platformId = !accessId.isEmpty ? accessId : accessLabel

        let id: String
        if let c = content, !c.isEmpty {
            id = slugify(c)
        } else if !platformId.isEmpty {
            id = slugify(platformId)
        } else {
            id = ""
        }

        let bgColor = bgHex(view)
        let radius = view.layer.cornerRadius
        let clip = radius > 0 ? (radius >= min(frame.width, frame.height) / 2 - 1 ? "circle" : "rounded") : nil

        let margins = view.layoutMargins
        let defaultMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let padding: UIEdgeInsets? = (margins != defaultMargins && (margins.top + margins.left + margins.bottom + margins.right) > 0) ? margins : nil

        let clickable = view is UIControl || (view.gestureRecognizers?.isEmpty == false)

        return SemanticUIElement(
            id: id,
            platformId: platformId,
            semanticType: semType,
            content: content,
            font: font,
            color: textColor,
            backgroundColor: bgColor,
            bounds: frame,
            clickable: clickable,
            cornerRadius: radius,
            padding: padding,
            iconName: iconName,
            clipShape: clip,
            children: nil
        )
    }

    // MARK: - Accessibility-based extraction (SwiftUI elements)

    private func extractAccessible(_ view: UIView, frame: CGRect) -> SemanticUIElement? {
        let traits = view.accessibilityTraits
        let label = view.accessibilityLabel
        let value = view.accessibilityValue
        let identifier = view.accessibilityIdentifier

        guard label != nil || identifier != nil || value != nil else { return nil }

        let semType: String
        var content: String?
        var font: SemanticFontInfo?
        var textColor: String?
        var iconName: String?

        if traits.contains(.image) {
            semType = "image"
            iconName = identifier ?? label
            guard iconName != nil && !iconName!.isEmpty else { return nil }
        } else if traits.contains(.button) || traits.contains(.link) {
            semType = "button"
            content = label ?? value
            font = extractSwiftUIFont(view)
            textColor = extractSwiftUITextColor(view)
        } else if traits.contains(.staticText) || traits.contains(.header) {
            semType = "text"
            content = label ?? value
            font = extractSwiftUIFont(view)
            textColor = extractSwiftUITextColor(view)
        } else if traits.contains(.adjustable) {
            semType = "slider"
            content = value
        } else if traits.contains(.tabBar) {
            semType = "tab_bar"
        } else if label != nil && !label!.isEmpty {
            semType = "text"
            content = label
            font = extractSwiftUIFont(view)
            textColor = extractSwiftUITextColor(view)
        } else if identifier != nil {
            semType = "view"
        } else {
            return nil
        }

        return buildElement(semType: semType, content: content, font: font, textColor: textColor, iconName: iconName,
                           view: view, frame: frame)
    }

    private func extractAXElement(_ ax: UIAccessibilityElement, frame: CGRect, parentView: UIView) -> SemanticUIElement? {
        let traits = ax.accessibilityTraits
        let label = ax.accessibilityLabel
        let value = ax.accessibilityValue
        let identifier = ax.accessibilityIdentifier

        guard label != nil || identifier != nil else { return nil }

        let semType: String
        var content: String?
        var iconName: String?

        if traits.contains(.image) {
            semType = "image"
            iconName = identifier ?? label
            guard iconName != nil && !iconName!.isEmpty else { return nil }
        } else if traits.contains(.button) || traits.contains(.link) {
            semType = "button"
            content = label ?? value
        } else if traits.contains(.staticText) || traits.contains(.header) {
            semType = "text"
            content = label ?? value
        } else if label != nil && !label!.isEmpty {
            semType = "text"
            content = label
        } else {
            semType = "view"
        }

        let accessId = identifier ?? ""
        let accessLabel = label ?? ""
        let platformId = !accessId.isEmpty ? accessId : accessLabel

        let id: String
        if let c = content, !c.isEmpty {
            id = slugify(c)
        } else if !platformId.isEmpty {
            id = slugify(platformId)
        } else {
            id = ""
        }

        let clickable = traits.contains(.button) || traits.contains(.link)

        return SemanticUIElement(
            id: id, platformId: platformId, semanticType: semType, content: content,
            font: nil, color: nil, backgroundColor: nil, bounds: frame,
            clickable: clickable, cornerRadius: 0, padding: nil, iconName: iconName, clipShape: nil,
            children: nil
        )
    }

    private func buildElement(semType: String, content: String?, font: SemanticFontInfo?, textColor: String?,
                              iconName: String?, view: UIView, frame: CGRect) -> SemanticUIElement {
        let accessId = view.accessibilityIdentifier ?? ""
        let accessLabel = view.accessibilityLabel ?? ""
        let platformId = !accessId.isEmpty ? accessId : accessLabel

        let id: String
        if let c = content, !c.isEmpty {
            id = slugify(c)
        } else if !platformId.isEmpty {
            id = slugify(platformId)
        } else {
            id = ""
        }

        let bgColor = bgHex(view)
        let radius = view.layer.cornerRadius
        let clip = radius > 0 ? (radius >= min(frame.width, frame.height) / 2 - 1 ? "circle" : "rounded") : nil
        let margins = view.layoutMargins
        let defaultMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let padding: UIEdgeInsets? = (margins != defaultMargins && (margins.top + margins.left + margins.bottom + margins.right) > 0) ? margins : nil
        let clickable = view is UIControl || (view.gestureRecognizers?.isEmpty == false) ||
                        view.accessibilityTraits.contains(.button)

        return SemanticUIElement(
            id: id, platformId: platformId, semanticType: semType, content: content,
            font: font, color: textColor, backgroundColor: bgColor, bounds: frame,
            clickable: clickable, cornerRadius: radius, padding: padding, iconName: iconName, clipShape: clip,
            children: nil
        )
    }

    // MARK: - Composite Decomposition

    private func isComposite(_ content: String?, bounds: CGRect) -> Bool {
        guard let content = content else { return false }
        return content.contains(", ") && bounds.width > 100 && bounds.height > 40
    }

    private func decomposeComposite(content: String, bounds: CGRect, searchIn root: UIView?) -> [SemanticUIElement]? {
        if let root = root ?? keyWindow, let hostView = findViewByBounds(near: bounds, in: root) {
            let children = collectTextChildren(in: hostView)
            if children.count >= 2 { return children }
        }
        let parsed = parseCompositeContent(content, bounds: bounds)
        return parsed.count >= 2 ? parsed : nil
    }

    private func findViewByBounds(near target: CGRect, in view: UIView) -> UIView? {
        let frame = view.convert(view.bounds, to: nil)
        let t: CGFloat = 5
        if abs(frame.minX - target.minX) < t && abs(frame.minY - target.minY) < t
            && abs(frame.width - target.width) < t && abs(frame.height - target.height) < t {
            return view
        }
        for sub in view.subviews {
            let subFrame = sub.convert(sub.bounds, to: nil)
            guard subFrame.intersects(target) else { continue }
            if let found = findViewByBounds(near: target, in: sub) { return found }
        }
        return nil
    }

    private func collectTextChildren(in view: UIView) -> [SemanticUIElement] {
        var results: [SemanticUIElement] = []
        var seenText = Set<String>()

        for desc in allDescendants(view) {
            if let label = desc as? UILabel, let text = label.text, !text.isEmpty {
                guard !seenText.contains(text) else { continue }
                seenText.insert(text)
                let frame = desc.convert(desc.bounds, to: nil)
                guard frame.width > 0, frame.height > 0 else { continue }
                results.append(SemanticUIElement(
                    id: slugify(text), platformId: text, semanticType: "text",
                    content: text, font: fontInfo(label.font), color: hex(label.textColor),
                    backgroundColor: nil, bounds: frame, clickable: false,
                    cornerRadius: 0, padding: nil, iconName: nil, clipShape: nil, children: nil
                ))
            }
        }

        collectTextFromLayers(view.layer, into: &results, seenText: &seenText)
        return results
    }

    private func collectTextFromLayers(_ layer: CALayer, into elements: inout [SemanticUIElement], seenText: inout Set<String>) {
        if let textLayer = layer as? CATextLayer {
            let text: String?
            if let s = textLayer.string as? String { text = s }
            else if let a = textLayer.string as? NSAttributedString { text = a.string }
            else { text = nil }

            if let text = text, !text.isEmpty, !seenText.contains(text) {
                seenText.insert(text)
                guard let rootLayer = keyWindow?.layer else { return }
                let screenBounds = layer.convert(layer.bounds, to: rootLayer)
                guard screenBounds.width > 0, screenBounds.height > 0 else { return }

                var font: SemanticFontInfo?
                if let ctFont = textLayer.font {
                    if let uiFont = ctFont as? UIFont {
                        font = fontInfo(uiFont)
                    } else if CFGetTypeID(ctFont as CFTypeRef) == CTFontGetTypeID() {
                        let f = ctFont as! CTFont
                        let desc = CTFontCopyFontDescriptor(f)
                        let traits = CTFontDescriptorCopyAttribute(desc, kCTFontTraitsAttribute) as? [String: Any]
                        let w = (traits?[kCTFontWeightTrait as String] as? CGFloat) ?? 0
                        font = SemanticFontInfo(
                            family: (CTFontCopyFamilyName(f) as String).lowercased(),
                            weight: weightName(w), size: CTFontGetSize(f)
                        )
                    }
                }
                if font == nil {
                    font = SemanticFontInfo(family: "system", weight: "regular", size: textLayer.fontSize)
                }

                let color = textLayer.foregroundColor.map { hex(UIColor(cgColor: $0)) } ?? nil

                elements.append(SemanticUIElement(
                    id: slugify(text), platformId: text, semanticType: "text",
                    content: text, font: font, color: color, backgroundColor: nil,
                    bounds: screenBounds, clickable: false, cornerRadius: 0,
                    padding: nil, iconName: nil, clipShape: nil, children: nil
                ))
            }
        }

        for sub in layer.sublayers ?? [] {
            collectTextFromLayers(sub, into: &elements, seenText: &seenText)
        }
    }

    private func parseCompositeContent(_ content: String, bounds: CGRect) -> [SemanticUIElement] {
        let parts = content.components(separatedBy: ", ")
        guard parts.count >= 2 else { return [] }

        let lineHeight = min(bounds.height / CGFloat(parts.count), 20)
        let startY = bounds.minY + (bounds.height - lineHeight * CGFloat(parts.count)) / 2

        return parts.enumerated().map { i, part in
            SemanticUIElement(
                id: slugify(part), platformId: part, semanticType: "text",
                content: part, font: nil, color: nil, backgroundColor: nil,
                bounds: CGRect(x: bounds.minX + 8, y: startY + CGFloat(i) * lineHeight,
                               width: bounds.width - 16, height: lineHeight),
                clickable: false, cornerRadius: 0, padding: nil, iconName: nil,
                clipShape: nil, children: nil
            )
        }
    }

    // MARK: - Helpers

    private func isClipped(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let current = v {
            if current.clipsToBounds || current.layer.masksToBounds {
                let r = current.layer.cornerRadius
                let size = min(current.bounds.width, current.bounds.height)
                if r >= size / 2 - 1 && size > 0 { return true }
            }
            if current.layer.mask != nil { return true }
            v = current.superview
        }
        return false
    }

    private func fontInfo(_ f: UIFont) -> SemanticFontInfo {
        let family = f.familyName.lowercased()
        let traits = f.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let w = (traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue
        let weight: String
        switch w {
        case ..<(-0.3): weight = "thin"
        case -0.3..<(-0.1): weight = "light"
        case -0.1..<0.1: weight = "regular"
        case 0.1..<0.3: weight = "medium"
        case 0.3..<0.5: weight = "semibold"
        case 0.5..<0.7: weight = "bold"
        default: weight = "heavy"
        }
        return SemanticFontInfo(family: family, weight: weight, size: f.pointSize)
    }

    // MARK: - SwiftUI backing view extraction

    private func extractSwiftUIFont(_ view: UIView) -> SemanticFontInfo? {
        // Walk subviews looking for a CATextLayer or a UILabel hidden inside SwiftUI
        for sub in allDescendants(view) {
            if let label = sub as? UILabel {
                return fontInfo(label.font)
            }
            // CATextLayer stores font as CTFont
            if let textLayer = sub.layer as? CATextLayer,
               let ctFont = textLayer.font {
                if let uiFont = ctFont as? UIFont {
                    return fontInfo(uiFont)
                }
                if CFGetTypeID(ctFont as CFTypeRef) == CTFontGetTypeID() {
                    let font = ctFont as! CTFont
                    let size = CTFontGetSize(font)
                    let desc = CTFontCopyFontDescriptor(font)
                    let traits = CTFontDescriptorCopyAttribute(desc, kCTFontTraitsAttribute) as? [String: Any]
                    let weightVal = (traits?[kCTFontWeightTrait as String] as? CGFloat) ?? 0
                    let family = CTFontCopyFamilyName(font) as String
                    return SemanticFontInfo(family: family.lowercased(), weight: weightName(weightVal), size: size)
                }
            }
        }
        return nil
    }

    private func extractSwiftUITextColor(_ view: UIView) -> String? {
        for sub in allDescendants(view) {
            if let label = sub as? UILabel {
                return hex(label.textColor)
            }
            if let textLayer = sub.layer as? CATextLayer {
                if let cgColor = textLayer.foregroundColor {
                    return hex(UIColor(cgColor: cgColor))
                }
            }
        }
        return nil
    }

    private func allDescendants(_ view: UIView) -> [UIView] {
        var result: [UIView] = []
        for sub in view.subviews {
            result.append(sub)
            result.append(contentsOf: allDescendants(sub))
        }
        return result
    }

    private func weightName(_ w: CGFloat) -> String {
        switch w {
        case ..<(-0.3): return "thin"
        case -0.3..<(-0.1): return "light"
        case -0.1..<0.1: return "regular"
        case 0.1..<0.3: return "medium"
        case 0.3..<0.5: return "semibold"
        case 0.5..<0.7: return "bold"
        default: return "heavy"
        }
    }

    private func hex(_ color: UIColor?) -> String? {
        guard let c = color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func bgHex(_ view: UIView) -> String? {
        guard let bg = view.backgroundColor, bg != .clear else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.getRed(&r, green: &g, blue: &b, alpha: &a)
        guard a > 0.01 else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func topScreenName(_ window: UIWindow) -> String {
        var vc = window.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        if let nav = vc as? UINavigationController { vc = nav.topViewController }
        if let tab = vc as? UITabBarController {
            if let sel = tab.selectedViewController {
                vc = (sel as? UINavigationController)?.topViewController ?? sel
            }
        }
        return String(describing: type(of: vc!))
    }

    private func slugify(_ s: String) -> String {
        let low = s.lowercased()
        var result = ""
        var lastUnderscore = false
        for ch in low {
            if ch.isLetter || ch.isNumber {
                result.append(ch)
                lastUnderscore = false
            } else if !lastUnderscore && !result.isEmpty {
                result.append("_")
                lastUnderscore = true
            }
        }
        if result.hasSuffix("_") { result.removeLast() }
        return result
    }
}
#endif
