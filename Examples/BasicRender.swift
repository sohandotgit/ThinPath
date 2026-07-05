import UIKit
import ThinPath

/// Parse an SVG and render it to a UIImageView.
func renderSVGToImageView(url: URL, imageView: UIImageView) {
    let svgData = try! Data(contentsOf: url)
    let (document, errors) = parse(data: svgData)

    if !errors.isEmpty {
        print("Parse warnings: \(errors.map { $0.message })")
    }

    let renderer = ThinPath()
    if let cgImage = renderer.render(document, size: CGSize(width: 300, height: 300), scale: 2) {
        imageView.image = UIImage(cgImage: cgImage)
    }
}

/// Parse an SVG and measure its natural size (viewBox).
func getSVGDimensions(url: URL) -> CGSize? {
    let svgData = try! Data(contentsOf: url)
    let (document, _) = parse(data: svgData)

    return document.rootViewBox.map { CGSize(width: $0.width, height: $0.height) }
}
