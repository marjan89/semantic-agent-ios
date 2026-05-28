#if DEBUG
import UIKit

struct SemanticElement {
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
    let fontFamily: String?
    let fontSize: CGFloat?
    let fontWeight: String?
    let textColor: String?
    let lineCount: Int?
    let truncated: Bool?
    let background: String?
    let foreground: String?
    let cornerRadius: CGFloat?
    let imageResource: String?
    let imagePath: String?
    let borderWidth: CGFloat
    let borderColor: String?
}
#endif
