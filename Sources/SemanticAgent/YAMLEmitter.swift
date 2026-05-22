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
            if let c = el.content {
                y += "  content: \(esc(c))\n"
            }
            if let f = el.font {
                y += "  font:\n"
                y += "    family: \(f.family)\n"
                y += "    weight: \(f.weight)\n"
                y += "    size: \(f.size)\n"
            }
            if let c = el.color {
                y += "  color: '\(c)'\n"
            }
            if let bg = el.backgroundColor {
                y += "  background: '\(bg)'\n"
            }
            y += "  bounds:\n"
            y += "    x: \(Int(el.bounds.origin.x))\n"
            y += "    y: \(Int(el.bounds.origin.y))\n"
            y += "    w: \(Int(el.bounds.width))\n"
            y += "    h: \(Int(el.bounds.height))\n"
            y += "  clickable: \(el.clickable)\n"
            if el.cornerRadius > 0 {
                y += "  corner_radius: \(Int(el.cornerRadius))\n"
            }
            if let p = el.padding {
                y += "  padding:\n"
                y += "    top: \(Int(p.top))\n"
                y += "    bottom: \(Int(p.bottom))\n"
                y += "    start: \(Int(p.left))\n"
                y += "    end: \(Int(p.right))\n"
            }
            if let icon = el.iconName {
                y += "  icon:\n"
                y += "    name: \(esc(icon))\n"
                y += "    format: unknown\n"
            }
            if let clip = el.clipShape {
                y += "  clip: \(clip)\n"
            }
            if let children = el.children, !children.isEmpty {
                y += "  children:\n"
                for child in children {
                    y += "  - id: \(esc(child.id))\n"
                    y += "    type: \(child.semanticType)\n"
                    if let c = child.content {
                        y += "    content: \(esc(c))\n"
                    }
                    if let f = child.font {
                        y += "    font:\n"
                        y += "      family: \(f.family)\n"
                        y += "      weight: \(f.weight)\n"
                        y += "      size: \(f.size)\n"
                    }
                    if let c = child.color {
                        y += "    color: '\(c)'\n"
                    }
                    y += "    bounds:\n"
                    y += "      x: \(Int(child.bounds.origin.x))\n"
                    y += "      y: \(Int(child.bounds.origin.y))\n"
                    y += "      w: \(Int(child.bounds.width))\n"
                    y += "      h: \(Int(child.bounds.height))\n"
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
