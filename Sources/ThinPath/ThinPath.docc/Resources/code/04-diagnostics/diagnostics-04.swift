import CoreGraphics
import ThinPath

func loadIcon(_ data: Data) -> CGImage? {
    let (document, errors) = parse(data: data)

    for error in errors {
        print("SVG warning: \(error.message)")
    }

    let renderer = ThinPath()
    return renderer.render(document, size: CGSize(width: 64, height: 64), scale: 2)
}
