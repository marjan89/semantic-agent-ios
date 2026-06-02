#if DEBUG
import UIKit
import MapKit
import WebKit

public struct ScrollStepMeta {
    let step: Int
    let offsetY: CGFloat
}

public struct ScrollCaptureMeta {
    let scrollViewFrame: CGRect
    let contentSize: CGSize
    let steps: [ScrollStepMeta]
}

public struct WalkResult {
    let elements: [SemanticElement]
    let screenName: String
    let deviceName: String
    let log: String
    let scrollMeta: ScrollCaptureMeta?
}

public final class SemanticWalker {

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
                              deviceName: UIDevice.current.name, log: log, scrollMeta: nil)
        }

        let screenName = resolveScreenName(window)
        walkView(window, depth: 0, parentExternal: false)

        let a11yFonts = harvestAccessibilityFonts(in: window)
        if !a11yFonts.isEmpty {
            mergeA11yFontData(a11yFonts)
            log += "A11Y-FONTS: \(a11yFonts.count) entries harvested\n"
        }

        let debugProps = ViewDebugBridge.extractProperties(from: window)
        log += "VIEWDEBUG: \(ViewDebugBridge.lastLog)"
        if !debugProps.isEmpty {
            log += "VIEWDEBUG: \(debugProps.count) properties extracted\n"
            mergeViewDebugProperties(debugProps)
        }

        let beforeGhost = elements.count
        let filtered = filterGhostTouchTargets(elements)
        let removed = beforeGhost - filtered.count
        if removed > 0 {
            log += "POST-FILTER: ghost touch removed \(removed) elements (\(beforeGhost) → \(filtered.count))\n"
        }

        return WalkResult(elements: filtered, screenName: screenName,
                          deviceName: UIDevice.current.name, log: log, scrollMeta: nil)
    }

    // MARK: - Scroll Capture

    func walkWithScroll(steps: Int, completion: @escaping (WalkResult) -> Void) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow && !($0 is OverlayWindow) }) else {
            completion(WalkResult(elements: [], screenName: "unknown",
                                  deviceName: UIDevice.current.name, log: "SKIP: no key window found\n",
                                  scrollMeta: nil))
            return
        }

        let screenName = resolveScreenName(window)
        guard let scrollView = findMainScrollView(in: window) else {
            log += "SCROLL: no UIScrollView found, falling back to single walk\n"
            walkView(window, depth: 0, parentExternal: false)
            let filtered = filterGhostTouchTargets(elements)
            completion(WalkResult(elements: filtered, screenName: screenName,
                                  deviceName: UIDevice.current.name, log: log, scrollMeta: nil))
            return
        }

        let originalOffset = scrollView.contentOffset
        let viewportHeight = scrollView.bounds.height
        let contentHeight = scrollView.contentSize.height
        let maxScrollY = max(0, contentHeight - viewportHeight)

        log += "SCROLL: found \(String(describing: type(of: scrollView))) contentSize=\(Int(contentHeight)) viewport=\(Int(viewportHeight)) maxScroll=\(Int(maxScrollY))\n"

        var allElements: [SemanticElement] = []
        var stickyIds = Set<String>()
        var stepMetas: [ScrollStepMeta] = []
        var step = 0
        let clampedSteps = min(steps, Int(ceil(maxScrollY / viewportHeight)) + 1)
        let scrollViewScreenFrame = scrollView.convert(scrollView.bounds, to: nil)

        func doStep() {
            guard step <= clampedSteps else {
                scrollView.setContentOffset(originalOffset, animated: false)
                log += "SCROLL: restored original offset (\(Int(originalOffset.y)))\n"

                let deduped = self.deduplicateScrollElements(allElements, stickyIds: stickyIds)
                log += "SCROLL: \(allElements.count) raw → \(deduped.count) deduped (sticky: \(stickyIds.count))\n"
                let filtered = self.filterGhostTouchTargets(deduped)
                let scrollMeta = ScrollCaptureMeta(
                    scrollViewFrame: scrollViewScreenFrame,
                    contentSize: scrollView.contentSize,
                    steps: stepMetas
                )
                completion(WalkResult(elements: filtered, screenName: screenName,
                                      deviceName: UIDevice.current.name, log: self.log,
                                      scrollMeta: scrollMeta))
                return
            }

            let targetY: CGFloat
            if step == 0 {
                targetY = 0
            } else {
                targetY = min(CGFloat(step) * viewportHeight * 0.85, maxScrollY)
            }

            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
            let actualOffset = scrollView.contentOffset.y
            stepMetas.append(ScrollStepMeta(step: step, offsetY: actualOffset))

            self.elements.removeAll()
            self.globalZ = 0
            self.walkView(window, depth: 0, parentExternal: false)
            self.synthesizeAccessibilityChildren(scrollView, depth: 0)

            self.log += "SCROLL step \(step): offset=\(Int(actualOffset)) elements=\(self.elements.count)\n"

            for var el in self.elements {
                let screenFrame = el.bounds
                let isInScrollView = scrollView.convert(scrollView.bounds, to: nil).contains(
                    CGPoint(x: screenFrame.midX, y: screenFrame.midY))

                if isInScrollView && step > 0 {
                    let adjustedY = screenFrame.minY + actualOffset
                    let adjustedBounds = CGRect(x: screenFrame.minX, y: adjustedY,
                                                 width: screenFrame.width, height: screenFrame.height)
                    el = SemanticElement(
                        id: el.id, platformId: el.platformId, semanticType: el.semanticType,
                        content: el.content, bounds: adjustedBounds, zIndex: el.zIndex,
                        clickable: el.clickable, enabled: el.enabled, render: el.render,
                        accessible: el.accessible, a11yLabel: el.a11yLabel, a11yId: el.a11yId,
                        fontFamily: el.fontFamily, fontSize: el.fontSize, fontWeight: el.fontWeight,
                        textColor: el.textColor, lineCount: el.lineCount, truncated: el.truncated,
                        background: el.background, foreground: el.foreground,
                        cornerRadius: el.cornerRadius, imageResource: el.imageResource, imagePath: el.imagePath,
                        borderWidth: el.borderWidth, borderColor: el.borderColor
                    )
                } else if !isInScrollView && step == 0 {
                    stickyIds.insert(el.id)
                }

                allElements.append(el)
            }

            step += 1

            if targetY >= maxScrollY && step > 1 {
                step = clampedSteps + 1
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                doStep()
            }
        }

        doStep()
    }

    private func findMainScrollView(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        var bestArea: CGFloat = 0

        func search(_ v: UIView) {
            if let sv = v as? UIScrollView,
               !(v is MKMapView), !(v is WKWebView),
               sv.contentSize.height > sv.bounds.height {
                let area = sv.bounds.width * sv.bounds.height
                if area > bestArea {
                    best = sv
                    bestArea = area
                }
            }
            for sub in v.subviews {
                search(sub)
            }
        }

        search(view)
        return best
    }

    private func deduplicateScrollElements(_ elements: [SemanticElement], stickyIds: Set<String>) -> [SemanticElement] {
        var seen: [String: Int] = [:]
        var result: [SemanticElement] = []

        for el in elements {
            if stickyIds.contains(el.id) {
                if seen[el.id] == nil {
                    seen[el.id] = result.count
                    result.append(el)
                }
                continue
            }

            let dedupeKey = "\(el.id)_\(Int(el.bounds.minX))_\(Int(el.bounds.minY))_\(Int(el.bounds.width))"
            if seen[dedupeKey] == nil {
                seen[dedupeKey] = result.count
                result.append(el)
            }
        }

        return result
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

        if frame.minX < 0 || frame.minY < 0 {
            log += "\(indent)CLIP \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) negative-origin\n"
            for subview in view.subviews {
                walkView(subview, depth: depth + 1, parentExternal: parentExternal)
            }
            synthesizeAccessibilityChildren(view, depth: depth)
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
            (view.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer || $0 is UILongPressGestureRecognizer }) == true)
        )

        let tp = (semanticType == "text" || semanticType == "button" || semanticType == "input") ? extractTextProps(view) : nil
        let colors = extractColors(view)
        let cr = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : nil
        let (imgRes, imgPath) = semanticType == "image" ? extractImageIdentity(view, id: id) : (nil, nil)
        let bw = view.layer.borderWidth
        let bc: String? = bw > 0 ? hexColor(view.layer.borderColor) : nil

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
            a11yId: view.accessibilityIdentifier,
            fontFamily: tp?.fontFamily,
            fontSize: tp?.fontSize,
            fontWeight: tp?.fontWeight,
            textColor: tp?.textColor,
            lineCount: tp?.lineCount,
            truncated: tp?.truncated,
            background: colors.background,
            foreground: colors.foreground,
            cornerRadius: cr,
            imageResource: imgRes,
            imagePath: imgPath,
            borderWidth: bw,
            borderColor: bc
        )
        elements.append(element)

        var logLine = "\(indent)EMIT z=\(globalZ) \(cls) (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
        logLine += " type=\(semanticType) id=\(id)"
        if let c = content, !c.isEmpty { logLine += " content=\"\(c.prefix(40))\"" }
        if isExternal { logLine += " EXTERNAL" }
        log += logLine + "\n"

        globalZ += 1

        if isExternal { return }

        for subview in view.subviews {
            walkView(subview, depth: depth + 1, parentExternal: isExternal || parentExternal)
        }

        synthesizeAccessibilityChildren(view, depth: depth)
    }

    // MARK: - Accessibility Synthesis

    private func synthesizeAccessibilityChildren(_ view: UIView, depth: Int) {
        var axElements: [Any] = view.accessibilityElements ?? []

        if axElements.isEmpty {
            let count = view.accessibilityElementCount()
            if count > 0 && count != NSNotFound {
                for i in 0..<count {
                    if let el = view.accessibilityElement(at: i) {
                        axElements.append(el)
                    }
                }
            }
        }

        guard !axElements.isEmpty else { return }

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

            var synTp: TextProps?
            var synBg: String?
            var synFg: String?
            var synCr: CGFloat?
            var synBw: CGFloat = 0
            var synBc: String?
            if let axView = axEl as? UIView {
                synTp = (synType == "text" || synType == "button") ? extractTextProps(axView) : nil
                if synTp == nil, synType == "text" || synType == "button" {
                    synTp = fontFromAttributedLabel(axView)
                }
                let c = extractColors(axView)
                synBg = c.background
                synFg = c.foreground
                synCr = axView.layer.cornerRadius > 0 ? axView.layer.cornerRadius : nil
                synBw = axView.layer.borderWidth
                synBc = synBw > 0 ? hexColor(axView.layer.borderColor) : nil
            } else {
                synTp = fontFromAttributedLabel(axEl)
                if synTp == nil {
                    if let container = (axEl as? UIAccessibilityElement)?.accessibilityContainer as? UIView {
                        synTp = findLabelProps(in: container, matching: label)
                        if synTp == nil {
                            synFg = findTextLayerColor(in: container)
                        }
                    }
                }
            }

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
                a11yId: (axEl as? UIAccessibilityIdentification)?.accessibilityIdentifier,
                fontFamily: synTp?.fontFamily,
                fontSize: synTp?.fontSize,
                fontWeight: synTp?.fontWeight,
                textColor: synTp?.textColor,
                lineCount: synTp?.lineCount,
                truncated: synTp?.truncated,
                background: synBg,
                foreground: synFg,
                cornerRadius: synCr,
                imageResource: nil,
                imagePath: nil,
                borderWidth: synBw,
                borderColor: synBc
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
        if let axValue = view.accessibilityValue, !axValue.isEmpty { return axValue }
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
        if cls.contains("Drawing") || cls.contains("Graphics") {
            if content != nil && !content!.isEmpty { return "text" }
            if view.layer.contents != nil { return "image" }
        }
        if cls.contains("Image") {
            if view.layer.contents != nil { return "image" }
        }

        return "container"
    }

    // MARK: - Text Property Extraction

    private struct TextProps {
        let fontFamily: String?
        let fontSize: CGFloat?
        let fontWeight: String?
        let textColor: String?
        let lineCount: Int?
        let truncated: Bool?
    }

    private func extractTextProps(_ view: UIView) -> TextProps? {
        let font: UIFont?
        let color: UIColor?
        let lines: Int?
        let isTruncated: Bool?

        if let label = view as? UILabel {
            font = label.font
            color = label.textColor
            lines = Int(label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines).height / (label.font.lineHeight))
            let fullSize = label.textRect(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude), limitedToNumberOfLines: 0)
            let limitedSize = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
            isTruncated = label.numberOfLines != 0 && fullSize.height > limitedSize.height + 1
        } else if let btn = view as? UIButton {
            font = btn.titleLabel?.font
            color = btn.titleColor(for: .normal)
            lines = btn.titleLabel.flatMap { Int($0.textRect(forBounds: $0.bounds, limitedToNumberOfLines: $0.numberOfLines).height / ($0.font.lineHeight)) }
            isTruncated = nil
        } else if let tf = view as? UITextField {
            font = tf.font
            color = tf.textColor
            lines = 1
            isTruncated = nil
        } else if let tv = view as? UITextView {
            font = tv.font
            color = tv.textColor
            if let lm = tv.layoutManager as? NSLayoutManager? {
                var count = 0
                var idx = 0
                let glyph = lm?.numberOfGlyphs ?? 0
                while idx < glyph {
                    var range = NSRange()
                    lm?.lineFragmentRect(forGlyphAt: idx, effectiveRange: &range)
                    count += 1
                    idx = NSMaxRange(range)
                }
                lines = count
            } else {
                lines = nil
            }
            isTruncated = nil
        } else if let found = findLabel(in: view) {
            font = found.font
            color = found.textColor
            lines = Int(found.textRect(forBounds: found.bounds, limitedToNumberOfLines: found.numberOfLines).height / found.font.lineHeight)
            let fullSize = found.textRect(forBounds: CGRect(x: 0, y: 0, width: found.bounds.width, height: .greatestFiniteMagnitude), limitedToNumberOfLines: 0)
            let limitedSize = found.textRect(forBounds: found.bounds, limitedToNumberOfLines: found.numberOfLines)
            isTruncated = found.numberOfLines != 0 && fullSize.height > limitedSize.height + 1
        } else if let tl = findTextLayer(in: view.layer) {
            if let ctFont = tl.font {
                if let name = ctFont as? String {
                    font = UIFont(name: name, size: tl.fontSize)
                } else {
                    font = UIFont.systemFont(ofSize: tl.fontSize)
                }
            } else {
                font = UIFont.systemFont(ofSize: tl.fontSize)
            }
            if let cgColor = tl.foregroundColor {
                color = UIColor(cgColor: cgColor)
            } else {
                color = nil
            }
            lines = nil
            isTruncated = nil
        } else {
            return nil
        }

        guard let f = font else { return nil }

        return TextProps(
            fontFamily: identifyFont(f),
            fontSize: f.pointSize,
            fontWeight: weightName(f),
            textColor: color.map { hexColor($0) },
            lineCount: lines,
            truncated: isTruncated
        )
    }

    private func weightName(_ font: UIFont) -> String {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let w = (traits?[.weight] as? NSNumber)?.floatValue ?? 0
        switch w {
        case ..<(-0.4): return "thin"
        case -0.4..<(-0.2): return "light"
        case -0.2..<0.1: return "regular"
        case 0.1..<0.3: return "medium"
        case 0.3..<0.5: return "semibold"
        case 0.5..<0.7: return "bold"
        case 0.7...: return "heavy"
        default: return "regular"
        }
    }

    private func findLabel(in view: UIView) -> UILabel? {
        for sub in view.subviews {
            if let label = sub as? UILabel { return label }
            if let found = findLabel(in: sub) { return found }
        }
        return nil
    }

    private func findTextLayer(in layer: CALayer) -> CATextLayer? {
        if let tl = layer as? CATextLayer { return tl }
        for sub in layer.sublayers ?? [] {
            if let found = findTextLayer(in: sub) { return found }
        }
        return nil
    }

    private func findLabelProps(in container: UIView, matching text: String) -> TextProps? {
        for sub in container.subviews {
            if let label = sub as? UILabel, label.text == text {
                return extractTextProps(label)
            }
            if let found = findLabelProps(in: sub, matching: text) { return found }
        }
        return nil
    }

    private func findTextLayerColor(in container: UIView) -> String? {
        if let tl = findTextLayer(in: container.layer), let fg = tl.foregroundColor {
            return hexColor(UIColor(cgColor: fg))
        }
        return nil
    }

    private struct A11yFontEntry {
        let label: String
        let fontFamily: String
        let fontName: String?
        let fontSize: CGFloat
        let foregroundColor: String?
    }

    private func harvestAccessibilityFonts(in view: UIView) -> [A11yFontEntry] {
        var results: [A11yFontEntry] = []
        harvestA11yFontsRecursive(view, into: &results)
        return results
    }

    private func harvestA11yFontsRecursive(_ view: UIView, into results: inout [A11yFontEntry]) {
        if let elements = view.accessibilityElements {
            for el in elements {
                guard !(el is UIView), let obj = el as? NSObject else { continue }
                guard let label = obj.accessibilityLabel, !label.isEmpty else { continue }
                guard let attrLabel = obj.accessibilityAttributedLabel, attrLabel.length > 0 else { continue }

                var family: String?
                var name: String?
                var size: CGFloat?
                var color: String?

                attrLabel.enumerateAttributes(in: NSRange(location: 0, length: attrLabel.length), options: []) { attrs, _, stop in
                    for (key, val) in attrs {
                        switch key.rawValue {
                        case "UIAccessibilityTokenFontFamily":
                            if let s = val as? String { family = s }
                        case "UIAccessibilityTokenFontName":
                            if let s = val as? String { name = s }
                        case "UIAccessibilityTokenFontSize":
                            if let n = val as? NSNumber { size = CGFloat(n.doubleValue) }
                        case "UIAccessibilityTokenForegroundColor":
                            if let s = val as? String { color = s }
                        default: break
                        }
                    }
                    if family != nil && color != nil { stop.pointee = true }
                }

                if let fam = family, let sz = size, fam != ".AppleSystemUIFont" {
                    results.append(A11yFontEntry(label: label, fontFamily: fam, fontName: name,
                                                  fontSize: sz, foregroundColor: color))
                }
            }
        }

        for sub in view.subviews {
            harvestA11yFontsRecursive(sub, into: &results)
        }
    }

    private func mergeA11yFontData(_ entries: [A11yFontEntry]) {
        var labelMap: [String: A11yFontEntry] = [:]
        for entry in entries {
            labelMap[entry.label] = entry
        }

        var merged = 0
        for i in elements.indices {
            let el = elements[i]
            guard el.semanticType == "text" || el.semanticType == "button" else { continue }
            let needsFont = el.fontFamily == nil || el.fontFamily == ".AppleSystemUIFont"
                || el.fontFamily == ".applesystemuifont"
            let needsColor = el.textColor == nil
            guard needsFont || needsColor else { continue }

            let matchLabel = el.content ?? el.a11yLabel ?? ""
            guard !matchLabel.isEmpty, let entry = labelMap[matchLabel] else { continue }

            let weight = needsFont ? extractWeightFromFontName(entry.fontName) : nil
            let resolvedColor = entry.foregroundColor.flatMap { parseNamedColor($0) }
            elements[i] = SemanticElement(
                id: el.id, platformId: el.platformId, semanticType: el.semanticType,
                content: el.content, bounds: el.bounds, zIndex: el.zIndex,
                clickable: el.clickable, enabled: el.enabled, render: el.render,
                accessible: el.accessible, a11yLabel: el.a11yLabel, a11yId: el.a11yId,
                fontFamily: needsFont ? entry.fontFamily : el.fontFamily,
                fontSize: needsFont ? entry.fontSize : el.fontSize,
                fontWeight: weight ?? el.fontWeight,
                textColor: resolvedColor ?? el.textColor, lineCount: el.lineCount, truncated: el.truncated,
                background: el.background, foreground: el.foreground,
                cornerRadius: el.cornerRadius, imageResource: el.imageResource,
                imagePath: el.imagePath, borderWidth: el.borderWidth, borderColor: el.borderColor
            )
            merged += 1
        }
        if merged > 0 {
            log += "A11Y-FONTS: merged \(merged) elements with token font data\n"
        }
    }

    private func parseNamedColor(_ name: String) -> String? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("#") { return lower }

        let known: [String: String] = [
            "black": "#000000", "white": "#FFFFFF",
            "red": "#FF0000", "green": "#00FF00", "blue": "#0000FF",
            "cyan": "#00FFFF", "magenta": "#FF00FF", "yellow": "#FFFF00",
            "orange": "#FF8000", "purple": "#800080", "brown": "#A52A2A",
            "gray": "#808080", "grey": "#808080",
            "light gray": "#C0C0C0", "light grey": "#C0C0C0",
            "dark gray": "#404040", "dark grey": "#404040",
            "dark cyan": "#008080", "dark blue": "#00008B",
            "dark green": "#006400", "dark red": "#8B0000"
        ]
        if let hex = known[lower] { return hex }

        if let color = UIColor(named: name) {
            return hexColor(color)
        }

        return nil
    }

    private func extractWeightFromFontName(_ name: String?) -> String? {
        guard let n = name?.lowercased() else { return nil }
        if n.contains("thin") { return "thin" }
        if n.contains("light") { return "light" }
        if n.contains("medium") { return "medium" }
        if n.contains("semibold") { return "semibold" }
        if n.contains("bold") { return "bold" }
        if n.contains("heavy") || n.contains("black") { return "heavy" }
        if n.contains("regular") { return "regular" }
        return nil
    }

    private static let tokenFontFamily = NSAttributedString.Key(rawValue: "UIAccessibilityTokenFontFamily")
    private static let tokenFontName = NSAttributedString.Key(rawValue: "UIAccessibilityTokenFontName")
    private static let tokenFontSize = NSAttributedString.Key(rawValue: "UIAccessibilityTokenFontSize")
    private static let tokenForegroundColor = NSAttributedString.Key(rawValue: "UIAccessibilityTokenForegroundColor")

    private func fontFromAttributedLabel(_ obj: NSObject) -> TextProps? {
        guard let attrLabel = obj.accessibilityAttributedLabel, attrLabel.length > 0 else { return nil }
        var font: UIFont?
        var color: UIColor?
        var tokenFamily: String?
        var tokenName: String?
        var tokenSize: CGFloat?
        var tokenColor: String?

        attrLabel.enumerateAttributes(in: NSRange(location: 0, length: attrLabel.length), options: []) { attrs, _, stop in
            if font == nil, let f = attrs[.font] as? UIFont { font = f }
            if color == nil, let c = attrs[.foregroundColor] as? UIColor { color = c }
            if tokenFamily == nil, let fam = attrs[Self.tokenFontFamily] as? String { tokenFamily = fam }
            if tokenName == nil, let name = attrs[Self.tokenFontName] as? String { tokenName = name }
            if tokenSize == nil, let sz = attrs[Self.tokenFontSize] as? NSNumber { tokenSize = CGFloat(sz.doubleValue) }
            if tokenColor == nil, let col = attrs[Self.tokenForegroundColor] as? String { tokenColor = col }
            if (font != nil || tokenFamily != nil) && (color != nil || tokenColor != nil) { stop.pointee = true }
        }

        if let f = font {
            return TextProps(fontFamily: identifyFont(f), fontSize: f.pointSize,
                             fontWeight: weightName(f), textColor: color.map { hexColor($0) },
                             lineCount: nil, truncated: nil)
        }

        if let family = tokenFamily ?? tokenName, let size = tokenSize {
            let weight = extractWeightFromFontName(tokenName)
            let hexCol = tokenColor.flatMap { parseNamedColor($0) }
            return TextProps(fontFamily: family, fontSize: size,
                             fontWeight: weight, textColor: hexCol,
                             lineCount: nil, truncated: nil)
        }

        return nil
    }

    // MARK: - Glyph Fingerprinting

    private static let glyphFingerprinter = GlyphFingerprinter()

    private func identifyFont(_ font: UIFont) -> String {
        let identified = Self.glyphFingerprinter.identify(font)
        return identified ?? font.familyName
    }

    private func extractColors(_ view: UIView) -> (background: String?, foreground: String?) {
        var bg: String?
        if let c = view.backgroundColor, c != .clear {
            var a: CGFloat = 0
            c.getRed(nil, green: nil, blue: nil, alpha: &a)
            if a > 0.01 { bg = hexColor(c) }
        }
        var fg: String?
        if let label = view as? UILabel {
            fg = hexColor(label.textColor)
        } else if let btn = view as? UIButton, let tc = btn.titleColor(for: .normal) {
            fg = hexColor(tc)
        } else if let iv = view as? UIImageView, let t = iv.tintColor {
            fg = hexColor(t)
        } else if let tf = view as? UITextField, let tc = tf.textColor {
            fg = hexColor(tc)
        }
        return (bg, fg)
    }

    private func hexColor(_ cgColor: CGColor?) -> String? {
        guard let cg = cgColor else { return nil }
        return hexColor(UIColor(cgColor: cg))
    }

    private func hexColor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        if a < 0.999 {
            return String(format: "#%02X%02X%02X%02X", Int(a * 255), Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    // MARK: - Image Identity

    private func extractImageIdentity(_ view: UIView, id: String) -> (String?, String?) {
        guard let iv = view as? UIImageView, let image = iv.image else { return (nil, nil) }
        let resource = image.accessibilityIdentifier
            ?? (view.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 })
        let dir = "/tmp/vdb-captures/images"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let filename = "\(id).png"
        let path = "\(dir)/\(filename)"
        if let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return (resource, "images/\(filename)")
    }

    // MARK: - ViewDebug Merge

    private func mergeViewDebugProperties(_ props: [ViewDebugProperty]) {
        var merged = 0
        for i in elements.indices {
            let el = elements[i]
            guard el.semanticType == "text" || el.semanticType == "button" else { continue }
            guard el.fontFamily == nil || el.fontFamily == ".applesystemuifont" else { continue }

            for prop in props {
                guard boundsMatch(el.bounds, prop.bounds) else { continue }

                let newFont = prop.fontFamily ?? el.fontFamily
                let newSize = prop.fontSize ?? el.fontSize
                let newWeight = prop.fontWeight ?? el.fontWeight
                let newColor = prop.foregroundColor ?? el.textColor
                let newLineCount = prop.lineLimit ?? el.lineCount

                if newFont != el.fontFamily || newColor != el.textColor || newLineCount != el.lineCount {
                    elements[i] = SemanticElement(
                        id: el.id, platformId: el.platformId, semanticType: el.semanticType,
                        content: el.content, bounds: el.bounds, zIndex: el.zIndex,
                        clickable: el.clickable, enabled: el.enabled, render: el.render,
                        accessible: el.accessible, a11yLabel: el.a11yLabel, a11yId: el.a11yId,
                        fontFamily: newFont, fontSize: newSize, fontWeight: newWeight,
                        textColor: newColor, lineCount: newLineCount, truncated: el.truncated,
                        background: el.background, foreground: el.foreground,
                        cornerRadius: el.cornerRadius, imageResource: el.imageResource,
                        imagePath: el.imagePath, borderWidth: el.borderWidth, borderColor: el.borderColor
                    )
                    merged += 1
                }
                break
            }
        }
        if merged > 0 {
            log += "VIEWDEBUG: merged \(merged) elements with SwiftUI properties\n"
        }
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

// MARK: - Glyph Fingerprinter

private final class GlyphFingerprinter {
    private var bundleHashes: [UInt64: String] = [:]
    private var cache: [String: String] = [:]

    init() {
        buildBundleIndex()
    }

    func identify(_ font: UIFont) -> String? {
        let cacheKey = "\(font.fontName)_\(font.pointSize)"
        if let cached = cache[cacheKey] { return cached == "" ? nil : cached }

        let hash = renderHash(font)
        if let family = bundleHashes[hash] {
            cache[cacheKey] = family
            return family
        }

        cache[cacheKey] = ""
        return nil
    }

    private func buildBundleIndex() {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: resourcePath) else { return }

        while let file = enumerator.nextObject() as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            let fullPath = (resourcePath as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: fullPath) as? NSData,
                  let provider = CGDataProvider(data: data),
                  let cgFont = CGFont(provider) else { continue }

            let ctFont = CTFontCreateWithGraphicsFont(cgFont, 48, nil, nil)
            let family = CTFontCopyFamilyName(ctFont) as String
            let hash = renderHash(ctFont)
            bundleHashes[hash] = family
        }
    }

    private func renderHash(_ font: UIFont) -> UInt64 {
        let ctFont = font as CTFont
        return renderHash(ctFont)
    }

    private func renderHash(_ ctFont: CTFont) -> UInt64 {
        let refString = "HgQW" as CFString
        let attrString = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(attrString, CFRange(location: 0, length: 0), refString)
        CFAttributedStringSetAttribute(attrString, CFRange(location: 0, length: 4),
                                       kCTFontAttributeName, ctFont)

        let line = CTLineCreateWithAttributedString(attrString)
        var bounds = CTLineGetBoundsWithOptions(line, [])
        let w = Int(ceil(bounds.width)) + 4
        let h = Int(ceil(bounds.height)) + 4
        guard w > 0, h > 0, w < 2000, h < 2000 else { return 0 }

        let bitmapSize = w * h
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)

        let origin = CGPoint(x: 2 - bounds.origin.x, y: 2 - bounds.origin.y)
        ctx.textPosition = origin
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return 0 }
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        var hash: UInt64 = 14695981039346656037 // FNV-1a offset basis
        for i in 0..<bitmapSize {
            let byte = pixels[i] > 127 ? UInt8(1) : UInt8(0)
            hash ^= UInt64(byte)
            hash &*= 1099511628211 // FNV-1a prime
        }
        return hash
    }
}
#endif
