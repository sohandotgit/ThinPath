import Foundation
import ThinPath

enum SVGLoader {
    static func fromBundle(_ name: String) -> SVGDocument? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let (document, _) = parse(data: data)
        return document
    }

    static func fromFile(_ url: URL) -> SVGDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let (document, _) = parse(data: data)
        return document
    }
}
