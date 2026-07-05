import UIKit
import ThinPath

/// Efficient pattern: parse once, render at different scales.
class IconSet {
    let document: SVGDocument
    let renderer = ThinPath()

    init(svgURL: URL) throws {
        let data = try Data(contentsOf: svgURL)
        let (doc, errors) = parse(data: data)
        if !errors.isEmpty {
            print("Parse warnings: \(errors)")
        }
        document = doc
    }

    /// Render at a specific size and scale (e.g., @2x icon).
    func image(size: CGSize, scale: CGFloat = 1) -> UIImage? {
        guard let cgImage = renderer.render(document, size: size, scale: scale) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Precompute multiple sizes (e.g., app icon sizes).
    func precomputedImages() -> [CGFloat: UIImage] {
        let sizes: [CGFloat] = [40, 60, 120]
        var results: [CGFloat: UIImage] = [:]

        for size in sizes {
            let cgSize = CGSize(width: size, height: size)
            if let image = image(size: cgSize, scale: 1) {
                results[size] = image
            }
        }
        return results
    }
}

/// Usage: load once, render on demand.
func demonstrateBatchRendering() {
    let iconURL = Bundle.main.url(forResource: "myicon", withExtension: "svg")!
    let iconSet = try! IconSet(svgURL: iconURL)

    // Render at 48×48 points, 2× scale
    let imageView = UIImageView()
    imageView.image = iconSet.image(size: CGSize(width: 48, height: 48), scale: 2)
}
