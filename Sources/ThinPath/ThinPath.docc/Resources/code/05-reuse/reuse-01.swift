import UIKit
import ThinPath

final class IconStore {
    private let document: SVGDocument

    init(data: Data) {
        (self.document, _) = parse(data: data)
    }
}
