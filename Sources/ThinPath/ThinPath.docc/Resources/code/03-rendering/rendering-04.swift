import UIKit
import ThinPath

final class SVGView: UIView {
    var document: SVGDocument?

    override func draw(_ rect: CGRect) {
        guard let document, let context = UIGraphicsGetCurrentContext() else { return }
    }
}
