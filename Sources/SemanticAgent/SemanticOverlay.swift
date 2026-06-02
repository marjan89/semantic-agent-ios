#if DEBUG
import UIKit

public final class OverlayWindow: UIWindow {}

public enum OverlayMode {
    case stroke
    case fill
}

public enum SemanticOverlay {

    static func draw(elements: [SemanticElement], mode: OverlayMode,
                     scene: UIWindowScene) -> (window: OverlayWindow, colorMap: [(id: String, z: Int, r: Int, g: Int, b: Int)]) {

        let screenBounds = scene.screen.bounds
        let wThresh = screenBounds.width * 0.95
        let hThresh = screenBounds.height * 0.95

        var filtered = elements
            .filter { $0.bounds.width > 0 && $0.bounds.height > 0 && $0.render != "external" }
            .sorted { $0.zIndex < $1.zIndex }

        if mode == .fill {
            filtered = filtered.filter { $0.bounds.width < wThresh || $0.bounds.height < hThresh }
        }

        let window = OverlayWindow(windowScene: scene)
        window.windowLevel = .statusBar + 100
        window.isUserInteractionEnabled = false
        let vc = UIViewController()
        vc.view.isHidden = true
        window.rootViewController = vc
        window.layer.backgroundColor = UIColor.white.cgColor

        let scale = scene.screen.scale
        let strokePt = 4.0 / scale
        var colorMap: [(id: String, z: Int, r: Int, g: Int, b: Int)] = []

        window.layer.contentsScale = scale
        window.layer.shouldRasterize = false
        window.layer.allowsEdgeAntialiasing = false
        window.layer.edgeAntialiasingMask = []

        for el in filtered {
            let (r, g, b) = colorFromID(el.id)
            let uiColor = UIColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )

            let rect = CGRect(
                x: CGFloat(Int(el.bounds.origin.x)),
                y: CGFloat(Int(el.bounds.origin.y)),
                width: CGFloat(Int(el.bounds.width)),
                height: CGFloat(Int(el.bounds.height))
            )

            switch mode {
            case .stroke:
                let whiteFill = CALayer()
                whiteFill.frame = rect
                whiteFill.backgroundColor = UIColor.white.cgColor
                whiteFill.contentsScale = scale
                whiteFill.shouldRasterize = false
                whiteFill.allowsEdgeAntialiasing = false
                whiteFill.edgeAntialiasingMask = []
                window.layer.addSublayer(whiteFill)

                let strokeLayer = CALayer()
                strokeLayer.frame = rect
                strokeLayer.backgroundColor = UIColor.clear.cgColor
                strokeLayer.borderColor = uiColor.cgColor
                strokeLayer.borderWidth = strokePt
                strokeLayer.contentsScale = scale
                strokeLayer.shouldRasterize = false
                strokeLayer.allowsEdgeAntialiasing = false
                strokeLayer.edgeAntialiasingMask = []
                window.layer.addSublayer(strokeLayer)

            case .fill:
                let layer = CALayer()
                layer.frame = rect
                layer.backgroundColor = uiColor.cgColor
                layer.contentsScale = scale
                layer.shouldRasterize = false
                layer.allowsEdgeAntialiasing = false
                layer.edgeAntialiasingMask = []
                window.layer.addSublayer(layer)
            }

            colorMap.append((id: el.id, z: el.zIndex, r: r, g: g, b: b))
        }

        window.isHidden = false
        window.makeKeyAndVisible()

        return (window, colorMap)
    }

    // MARK: - djb2 Color Generation

    static func colorFromID(_ id: String) -> (r: Int, g: Int, b: Int) {
        let hue = Double(djb2(id) % 360)
        return hslToRGB(h: hue, s: 1.0, l: 0.5)
    }

    private static func djb2(_ s: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in s.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return hash
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Int, g: Int, b: Int) {
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let hp = h / 60.0
        let x = c * (1.0 - abs(hp.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0

        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }

        return (
            r: Int(((r1 + m) * 255.0).rounded()),
            g: Int(((g1 + m) * 255.0).rounded()),
            b: Int(((b1 + m) * 255.0).rounded())
        )
    }
}
#endif
