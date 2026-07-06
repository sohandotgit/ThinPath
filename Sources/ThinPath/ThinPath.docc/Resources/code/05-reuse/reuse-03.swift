import UIKit
import ThinPath

final class IconStore {
    private let document: SVGDocument
    private let renderer = ThinPath()

    init(data: Data) {
        (self.document, _) = parse(data: data)
    }

    func thumbnail() -> UIImage? {
        guard let cgImage = renderer.render(document, size: CGSize(width: 44, height: 44), scale: UIScreen.main.scale) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
