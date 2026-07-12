import SwiftUI
import ThinPath

/// Load and parse a document once, outside any SwiftUI `body`. Parsing is the
/// allocating step, so it stays out of the layout pass.
func loadDocument(url: URL) -> SVGDocument {
    let svgData = try! Data(contentsOf: url)
    let (document, errors) = parse(data: svgData)
    if !errors.isEmpty {
        print("Parse warnings: \(errors.map { $0.message })")
    }
    return document
}

/// Present a parsed document with the render-only `ThinPathView`. It rasterizes
/// off the main thread by default and sizes to its laid-out frame.
struct LogoView: View {
    let document: SVGDocument

    var body: some View {
        ThinPathView(document)
            .frame(width: 200, height: 200)
            .accessibilityLabel("Company logo")
    }
}

/// Show a custom placeholder while the first async raster is in flight, and
/// override the fit with `preserveAspectRatio:`.
struct BannerView: View {
    let document: SVGDocument

    var body: some View {
        ThinPathView(document,
                     preserveAspectRatio: .init(align: .xMidYMid, meetOrSlice: .slice),
                     rendering: .asynchronous) {
            ProgressView()
        }
        .frame(height: 120)
    }
}

/// Use the fixed-size `Image` initializer for a plain, caller-sized icon —
/// e.g. a `List` row leading image. Synchronous; `nil` for a degenerate size.
struct IconRow: View {
    let document: SVGDocument
    let title: String

    var body: some View {
        HStack {
            Image(document, size: CGSize(width: 24, height: 24), scale: 2)
            Text(title)
        }
    }
}
