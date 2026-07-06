import UIKit
import ThinPath

final class SVGView: UIView {
    var document: SVGDocument?

    override func draw(_ rect: CGRect) {
        guard let document, let context = UIGraphicsGetCurrentContext() else { return }

        // The document's viewBox is fit into `rect` using its
        // preserveAspectRatio. `bounds` fills the whole view.
        ThinPath().render(document, into: context, rect: bounds)
    }
}
