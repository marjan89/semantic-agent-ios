#if DEBUG
import UIKit

struct ViewDebugProperty {
    let bounds: CGRect
    let fontFamily: String?
    let fontSize: CGFloat?
    let fontWeight: String?
    let foregroundColor: String?
    let lineLimit: Int?
}

enum ViewDebugBridge {

    static var lastLog = ""
    static var activationLog = ""

    private static var propertiesEnabled = false
    private static var activationFailed = false

    static func activate() {
        guard !propertiesEnabled, !activationFailed else { return }
        enableViewDebugProperties()
        propertiesEnabled = true
    }

    static func extractProperties(from window: UIWindow) -> [ViewDebugProperty] {
        lastLog = ""

        if activationFailed {
            lastLog += "skipped — activation previously failed\n"
            lastLog += activationLog
            return []
        }

        if !propertiesEnabled {
            enableViewDebugProperties()
            propertiesEnabled = true
        }

        let hostingViews = findHostingViews(in: window)
        lastLog += "found \(hostingViews.count) hosting views\n"
        var results: [ViewDebugProperty] = []
        for hv in hostingViews {
            guard let jsonData = callMakeViewDebugData(hv) else { continue }
            let props = parseDebugJSON(jsonData, hostingViewOrigin: hv.convert(CGPoint.zero, to: nil))
            lastLog += "  -> \(props.count) properties parsed\n"
            results.append(contentsOf: props)
        }
        return results
    }

    private static func enableViewDebugProperties() {
        let frameworks = [
            "/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
            "/System/Library/PrivateFrameworks/SwiftUICore.framework/SwiftUICore",
            "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore"
        ]

        let getterSym = "$s7SwiftUI10_ViewDebugO10propertiesAC10PropertiesVvgZ"

        func log(_ s: String) { activationLog += s + "\n" }

        for fw in frameworks {
            guard let handle = dlopen(fw, RTLD_NOLOAD) else { continue }
            defer { dlclose(handle) }

            guard let getterPtr = dlsym(handle, getterSym) else {
                log("no getter in \(fw)")
                continue
            }

            log("found getter at \(getterPtr) in \(fw)")

            let insns = getterPtr.assumingMemoryBound(to: UInt32.self)
            var instrDump = "  insns:"
            for idx in 0..<8 {
                instrDump += String(format: " %08x", insns[idx])
            }
            log(instrDump)

            guard let dataAddr = findDataAddress(fnPtr: getterPtr, insns: insns, is32bit: true) else {
                log("  could not decode ADRP+LDR")
                activationFailed = true
                return
            }

            log("  data at \(String(format: "0x%lx", dataAddr))")
            guard let propPtr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(dataAddr)) else {
                log("  null pointer from dataAddr")
                activationFailed = true
                return
            }

            let old = propPtr.pointee
            log("  current: \(old)")

            if old == 0x1FF {
                log("  already set")
                return
            }

            let pageSize = Int(getpagesize())
            let pageAddr = dataAddr & ~(pageSize - 1)
            guard let page = UnsafeMutableRawPointer(bitPattern: UInt(pageAddr)) else {
                log("  null page pointer")
                activationFailed = true
                return
            }

            let r = mprotect(page, pageSize, PROT_READ | PROT_WRITE)
            if r != 0 {
                log("  mprotect failed: errno=\(errno) — skipping _ViewDebug")
                activationFailed = true
                return
            }

            propPtr.pointee = 0x1FF
            let verify = propPtr.pointee
            log("  wrote 0x1FF, readback: \(verify)")
            return
        }
        log("no framework handle found")
        activationFailed = true
    }

    private static func findDataAddress(fnPtr: UnsafeMutableRawPointer, insns: UnsafeMutablePointer<UInt32>, is32bit: Bool) -> Int? {
        for i in 0..<7 {
            let insn0 = insns[i]
            let insn1 = insns[i + 1]

            guard (insn0 & 0x9F00_0000) == 0x9000_0000 else { continue } // ADRP

            let ldr32 = (insn1 & 0xFFC0_0000) == 0xB940_0000
            let ldrb  = (insn1 & 0xFFC0_0000) == 0x3940_0000
            let add64 = (insn1 & 0xFFC0_0000) == 0x9100_0000  // ADD Xd, Xn, #imm12
            let add32 = (insn1 & 0xFFC0_0000) == 0x1100_0000  // ADD Wd, Wn, #imm12

            let isLdr = ldr32 || ldrb
            let isAdd = add64 || add32
            guard isLdr || isAdd else { continue }

            let immlo = UInt64((insn0 >> 29) & 0x3)
            let immhi = UInt64((insn0 >> 5) & 0x7FFFF)
            var pageOff = Int64(bitPattern: (immhi << 14) | (immlo << 12))
            if pageOff & (1 << 32) != 0 {
                pageOff |= Int64(bitPattern: 0xFFFF_FFFE_0000_0000)
            }

            let pc = Int(bitPattern: fnPtr) + i * 4
            let page = Int64(pc) & ~0xFFF

            let offset: Int64
            if isLdr {
                let scale: Int64 = ldr32 ? 4 : 1
                offset = Int64((insn1 >> 10) & 0xFFF) * scale
            } else {
                // ADD: imm12 is unscaled, optionally shifted by 12
                let sh = (insn1 >> 22) & 1
                offset = Int64((insn1 >> 10) & 0xFFF) << (sh == 1 ? 12 : 0)
            }

            return Int(page + pageOff + offset)
        }
        return nil
    }

    // MARK: - Find _UIHostingView instances

    private static func findHostingViews(in view: UIView) -> [UIView] {
        var found: [UIView] = []
        let cls = NSStringFromClass(type(of: view))
        if cls.contains("UIHostingView") || cls.contains("_UIHostingView") {
            found.append(view)
        }
        for sub in view.subviews {
            found.append(contentsOf: findHostingViews(in: sub))
        }
        return found
    }

    // MARK: - Call makeViewDebugData() via ObjC runtime

    private static func callMakeViewDebugData(_ view: UIView) -> Data? {
        let sel = NSSelectorFromString("makeViewDebugData")
        guard view.responds(to: sel),
              let method = class_getInstanceMethod(type(of: view), sel) else {
            return nil
        }
        let imp = method_getImplementation(method)
        typealias MakeDebugDataFunc = @convention(c) (AnyObject, Selector) -> Data?
        let fn = unsafeBitCast(imp, to: MakeDebugDataFunc.self)
        let data = fn(view, sel)
        if let d = data {
            lastLog += "  makeViewDebugData: \(d.count) bytes\n"
            if d.count <= 10 {
                lastLog += "  content: \(String(data: d, encoding: .utf8) ?? "?")\n"
            }
            if d.count > 2 { return d }
        } else {
            lastLog += "  makeViewDebugData: returned nil\n"
        }

        return nil
    }

    // MARK: - Parse the JSON tree

    private static func parseDebugJSON(_ data: Data, hostingViewOrigin: CGPoint) -> [ViewDebugProperty] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parseNode(single)
            }
            return []
        }
        var results: [ViewDebugProperty] = []
        for node in root {
            results.append(contentsOf: parseNode(node))
        }
        return results
    }

    private static func parseNode(_ node: [String: Any]) -> [ViewDebugProperty] {
        var results: [ViewDebugProperty] = []

        let position = extractPosition(node)
        let size = extractSize(node)
        let bounds: CGRect?
        if let pos = position, let sz = size, sz.width > 0, sz.height > 0 {
            bounds = CGRect(origin: pos, size: sz)
        } else {
            bounds = nil
        }

        var fontFamily: String?
        var fontSize: CGFloat?
        var fontWeight: String?
        var foregroundColor: String?
        var lineLimit: Int?

        if let displayList = node["8"] as? [String: Any] {
            let (ff, fs, fw, fc) = extractFromDisplayList(displayList)
            fontFamily = ff; fontSize = fs; fontWeight = fw; foregroundColor = fc
        }

        if let value = node["1"] as? [String: Any] {
            let typeName = node["0"] as? String ?? ""

            if typeName.contains("EnvironmentKeyWritingModifier") {
                if typeName.contains("Int?") || typeName.contains("LineLimit") {
                    if let v = value["value"] as? Int {
                        lineLimit = v
                    }
                }
                if typeName.contains("Color") || typeName.contains("Foreground") {
                    if let colorStr = extractColorFromValue(value) {
                        foregroundColor = colorStr
                    }
                }
                if typeName.contains("Font") {
                    let (ff, fs, fw) = extractFontFromValue(value)
                    if ff != nil { fontFamily = ff }
                    if fs != nil { fontSize = fs }
                    if fw != nil { fontWeight = fw }
                }
            }
        }

        let hasData = fontFamily != nil || foregroundColor != nil || lineLimit != nil
        if hasData, let b = bounds {
            results.append(ViewDebugProperty(
                bounds: b, fontFamily: fontFamily, fontSize: fontSize,
                fontWeight: fontWeight, foregroundColor: foregroundColor, lineLimit: lineLimit))
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                results.append(contentsOf: parseNode(child))
            }
        }

        return results
    }

    // MARK: - Extract position/size from node

    private static func extractPosition(_ node: [String: Any]) -> CGPoint? {
        guard let pos = node["3"] as? [String: Any] else { return nil }
        if let x = pos["x"] as? CGFloat, let y = pos["y"] as? CGFloat {
            return CGPoint(x: x, y: y)
        }
        if let arr = pos["value"] as? [CGFloat], arr.count >= 2 {
            return CGPoint(x: arr[0], y: arr[1])
        }
        return nil
    }

    private static func extractSize(_ node: [String: Any]) -> CGSize? {
        guard let size = node["4"] as? [String: Any] else { return nil }
        if let w = size["width"] as? CGFloat, let h = size["height"] as? CGFloat {
            return CGSize(width: w, height: h)
        }
        if let arr = size["value"] as? [CGFloat], arr.count >= 2 {
            return CGSize(width: arr[0], height: arr[1])
        }
        return nil
    }

    // MARK: - Extract from DisplayList (resolved text attributes)

    private static func extractFromDisplayList(_ displayList: [String: Any]) -> (String?, CGFloat?, String?, String?) {
        var fontFamily: String?
        var fontSize: CGFloat?
        var fontWeight: String?
        var foregroundColor: String?

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let font = dict["font"] as? [String: Any] {
                    if let name = font["name"] as? String { fontFamily = name }
                    if let fam = font["family"] as? String { fontFamily = fam }
                    if let size = font["size"] as? CGFloat { fontSize = size }
                    if let sc = font["sizeCategory"] as? CGFloat, fontSize == nil { fontSize = sc }
                    if let weight = font["weight"] as? String { fontWeight = weight }
                    if let w = font["weight"] as? [String: Any], let wName = w["description"] as? String {
                        fontWeight = wName
                    }
                }
                if let color = dict["foregroundColor"] as? [Any] {
                    foregroundColor = rgbaArrayToHex(color)
                } else if let color = dict["foregroundColor"] as? [String: Any] {
                    foregroundColor = colorDictToHex(color)
                }
                if let attrs = dict["attributes"] as? [[String: Any]] {
                    for attr in attrs { walk(attr) }
                }
                for (_, v) in dict { walk(v) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(displayList)
        return (fontFamily, fontSize, fontWeight, foregroundColor)
    }

    // MARK: - Extract font/color from modifier value

    private static func extractFontFromValue(_ value: [String: Any]) -> (String?, CGFloat?, String?) {
        if let provider = value["provider"] as? [String: Any] {
            let name = provider["name"] as? String
            let size = provider["size"] as? CGFloat
            let weight = provider["weight"] as? String
            return (name, size, weight)
        }
        return (nil, nil, nil)
    }

    private static func extractColorFromValue(_ value: [String: Any]) -> String? {
        if let _ = value["linearRed"] as? CGFloat {
            let r = value["linearRed"] as? CGFloat ?? 0
            let g = value["linearGreen"] as? CGFloat ?? 0
            let b = value["linearBlue"] as? CGFloat ?? 0
            let a = value["opacity"] as? CGFloat ?? 1
            return rgbaToHex(r, g, b, a)
        }
        if let resolved = value["value"] as? [String: Any] {
            return extractColorFromValue(resolved)
        }
        if let arr = value["value"] as? [Any] {
            return rgbaArrayToHex(arr)
        }
        return nil
    }

    // MARK: - Color helpers

    private static func rgbaArrayToHex(_ arr: [Any]) -> String? {
        guard arr.count >= 3 else { return nil }
        let r = (arr[0] as? CGFloat) ?? (arr[0] as? Double).map { CGFloat($0) } ?? 0
        let g = (arr[1] as? CGFloat) ?? (arr[1] as? Double).map { CGFloat($0) } ?? 0
        let b = (arr[2] as? CGFloat) ?? (arr[2] as? Double).map { CGFloat($0) } ?? 0
        let a = arr.count >= 4 ? ((arr[3] as? CGFloat) ?? (arr[3] as? Double).map { CGFloat($0) } ?? 1) : 1.0
        return rgbaToHex(r, g, b, a)
    }

    private static func colorDictToHex(_ dict: [String: Any]) -> String? {
        let r = dict["red"] as? CGFloat ?? dict["r"] as? CGFloat ?? 0
        let g = dict["green"] as? CGFloat ?? dict["g"] as? CGFloat ?? 0
        let b = dict["blue"] as? CGFloat ?? dict["b"] as? CGFloat ?? 0
        let a = dict["alpha"] as? CGFloat ?? dict["a"] as? CGFloat ?? dict["opacity"] as? CGFloat ?? 1
        return rgbaToHex(r, g, b, a)
    }

    private static func rgbaToHex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> String {
        let ri = Int(min(max(r, 0), 1) * 255)
        let gi = Int(min(max(g, 0), 1) * 255)
        let bi = Int(min(max(b, 0), 1) * 255)
        if a < 0.999 {
            let ai = Int(min(max(a, 0), 1) * 255)
            return String(format: "#%02X%02X%02X%02X", ai, ri, gi, bi)
        }
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

}
#endif
