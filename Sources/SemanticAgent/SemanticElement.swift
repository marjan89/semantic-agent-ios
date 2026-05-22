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
}
#endif
