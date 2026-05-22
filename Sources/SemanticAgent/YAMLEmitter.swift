#if DEBUG
import UIKit

enum SemanticYAMLEmitter {

    static func emit(elements: [SemanticUIElement], screen: String, device: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())

        var y = ""
        y += "screen: \(esc(screen))\n"
        y += "device: \(esc(device))\n"
        y += "platform: ios\n"
        y += "timestamp: \(ts)\n"
        y += "source: instrumented\n"
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
