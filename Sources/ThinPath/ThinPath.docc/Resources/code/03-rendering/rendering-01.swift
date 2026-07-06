import UIKit
import ThinPath

func makeIcon(from document: SVGDocument, side: CGFloat) -> UIImage? {
    let renderer = ThinPath()
    guard let cgImage = renderer.render(document, size: CGSize(width: side, height: side), scale: 2) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}
