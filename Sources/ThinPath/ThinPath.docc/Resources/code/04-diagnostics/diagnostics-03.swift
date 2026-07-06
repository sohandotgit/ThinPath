import CoreGraphics
import ThinPath

func loadIcon(_ data: Data) -> CGImage? {
    let (document, errors) = parse(data: data)

    // A non-empty `errors` array does not mean the document is unusable.
    let renderer = ThinPath()
    return renderer.render(document, size: CGSize(width: 64, height: 64), scale: 2)
}
