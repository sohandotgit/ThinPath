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

    static func fromDataURI(_ string: String) -> SVGDocument? {
        guard let comma = string.firstIndex(of: ","),
              let payload = Data(base64Encoded: String(string[string.index(after: comma)...])) else {
            return nil
        }
        let (document, _) = parse(data: payload)
        return document
    }

    static func fromRemote(_ url: URL) async throws -> SVGDocument {
        let (data, _) = try await URLSession.shared.data(from: url)
        let (document, _) = parse(data: data)
        return document
    }
}
