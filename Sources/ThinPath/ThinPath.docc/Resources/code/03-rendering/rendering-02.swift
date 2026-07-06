import UIKit
import ThinPath

func makeIcon(from document: SVGDocument, side: CGFloat) -> UIImage? {
    let renderer = ThinPath()
    let scale = UIScreen.main.scale
    guard let cgImage = renderer.render(document, size: CGSize(width: side, height: side), scale: scale) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}
