#if DEBUG
import UIKit

public enum SemanticYAMLEmitter {

    static func emit(elements: [SemanticElement], screen: String, device: String,
                      scrollMeta: ScrollCaptureMeta? = nil) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        let screenBounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale

        var y = ""
        y += "screen: \(esc(screen))\n"
        y += "device: \(esc(device))\n"
        y += "platform: ios\n"
        y += "timestamp: \(ts)\n"
        y += "source: instrumented\n"
        y += "viewport:\n"
        y += "  width: \(Int(screenBounds.width))\n"
        y += "  height: \(Int(screenBounds.height))\n"
        y += "  density: \(scale)\n"
        if let sm = scrollMeta {
            y += "scroll_capture:\n"
            y += "  scroll_view:\n"
            y += "    x: \(Int(sm.scrollViewFrame.origin.x))\n"
            y += "    y: \(Int(sm.scrollViewFrame.origin.y))\n"
            y += "    w: \(Int(sm.scrollViewFrame.width))\n"
            y += "    h: \(Int(sm.scrollViewFrame.height))\n"
            y += "  content_size:\n"
            y += "    w: \(Int(sm.contentSize.width))\n"
            y += "    h: \(Int(sm.contentSize.height))\n"
            y += "  steps:\n"
            for step in sm.steps {
                y += "  - step: \(step.step)\n"
                y += "    offset_y: \(Int(step.offsetY))\n"
            }
        }
        y += "elements:\n"

        for el in elements {
            y += "- id: \(esc(el.id))\n"
            if !el.platformId.isEmpty && el.platformId != el.id {
                y += "  platform_id: \(esc(el.platformId))\n"
            }
            y += "  type: \(el.semanticType)\n"
            y += "  bounds:\n"
            y += "    x: \(Int(el.bounds.origin.x))\n"
            y += "    y: \(Int(el.bounds.origin.y))\n"
            y += "    w: \(Int(el.bounds.width))\n"
            y += "    h: \(Int(el.bounds.height))\n"
            y += "  z_index: \(el.zIndex)\n"
            if let c = el.content {
                y += "  content: \(esc(c))\n"
            }
            if let r = el.render {
                y += "  render: \(r)\n"
            }
            y += "  clickable: \(el.clickable)\n"
            y += "  enabled: \(el.enabled)\n"
            y += "  accessible: \(el.accessible)\n"
            if let al = el.a11yLabel, !al.isEmpty {
                y += "  a11y_label: \(esc(al))\n"
            }
            if let ai = el.a11yId, !ai.isEmpty {
                y += "  a11y_id: \(esc(ai))\n"
            }
            if el.fontFamily != nil || el.textColor != nil {
                if let ff = el.fontFamily {
                    y += "  font:\n"
                    y += "    family: \(esc(ff.lowercased()))\n"
                    if let fs = el.fontSize {
                        y += "    size: \(Int(fs))\n"
                    }
                    if let fw = el.fontWeight {
                        y += "    weight: \(fw)\n"
                    }
                }
                if let tc = el.textColor {
                    y += "  color: \(esc(tc))\n"
                }
                if let lc = el.lineCount {
                    y += "  line_count: \(lc)\n"
                }
                if let tr = el.truncated {
                    y += "  truncated: \(tr)\n"
                }
            }
            if let bg = el.background {
                y += "  background: \(esc(bg))\n"
            }
            if let fg = el.foreground {
                y += "  foreground: \(esc(fg))\n"
            }
            if let cr = el.cornerRadius, cr > 0 {
                y += "  corner_radius: \(Int(cr))\n"
            }
            if el.borderWidth > 0 {
                y += "  border:\n"
                y += "    width: \(Int(el.borderWidth))\n"
                if let bc = el.borderColor {
                    y += "    color: '\(bc)'\n"
                }
            }
            if el.imageResource != nil || el.imagePath != nil {
                y += "  image:\n"
                if let res = el.imageResource {
                    y += "    resource: \(esc(res))\n"
                }
                if let path = el.imagePath {
                    y += "    path: \(esc(path))\n"
                }
            }
        }

        return y
    }

    private static func esc(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let needs = s.contains(":") || s.contains("#") || s.contains("'")
            || s.contains("\"") || s.contains("\n") || s.contains("&")
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s == "true" || s == "false" || s == "null"
            || Double(s) != nil
        if needs {
            return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
        }
        return s
    }
}
#endif
