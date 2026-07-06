import UIKit
import ThinPath

// `photo-card.svg` embeds a large <image> element.
func renderCard(_ data: Data) {
    let (document, _) = parse(data: data)
    let renderer = ThinPath()

    // Decodes the embedded image at ~88×88px for this @2x, 44pt render.
    let thumbnail = renderer.render(document, size: CGSize(width: 44, height: 44), scale: 2)
}
