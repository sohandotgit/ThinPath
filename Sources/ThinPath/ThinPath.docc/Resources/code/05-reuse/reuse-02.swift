import UIKit
import ThinPath

final class IconStore {
    private let document: SVGDocument
    private let renderer = ThinPath()

    init(data: Data) {
        (self.document, _) = parse(data: data)
    }
}
