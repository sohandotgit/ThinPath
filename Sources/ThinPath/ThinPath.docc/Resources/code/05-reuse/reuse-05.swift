import UIKit
import ThinPath

final class IconStore {
    private let document: SVGDocument
    private let renderer = ThinPath()

    init(data: Data) {
        (self.document, _) = parse(data: data)
    }

    func image(side: CGFloat) -> UIImage? {
        // Re-rendering reuses the parsed document — no re-parse.
        guard let cgImage = renderer.render(document, size: CGSize(width: side, height: side), scale: UIScreen.main.scale) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func thumbnail() -> UIImage? {
        guard let cgImage = renderer.render(document, size: CGSize(width: 44, height: 44), scale: UIScreen.main.scale) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func detail() -> UIImage? {
        guard let cgImage = renderer.render(document, size: CGSize(width: 320, height: 320), scale: UIScreen.main.scale) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
