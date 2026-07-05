# API Reference & Usage

Every public entry point, with runnable integration snippets.

## Overview

ThinPath's public surface for typical app integration is three calls: parse, render into an existing context, or render to a standalone image. (The module also exposes lower-level renderer/resolver types used internally across its own source files; those aren't part of the documented app-facing API and aren't covered here — see <doc:ThinPath> for the intended entry points.)

### Parsing

```swift
public func parse(data: Data) -> (document: SVGDocument, errors: [SVGParseError])
```

Parses SVG document bytes into the in-memory ``SVGDocument`` IR. Always returns a usable (possibly empty) document; ``SVGParseError`` values are non-fatal diagnostics collected during the parse, not exceptions — an empty `errors` array means a clean parse, but a non-empty array doesn't necessarily mean the document is unusable.

### Rendering into an existing context

```swift
public struct ThinPath {
    public init()
    public func render(_ document: SVGDocument, into context: CGContext, rect: CGRect)
}
```

Draws `document` into `context`, fitting the document's `viewBox`/intrinsic size into `rect` per its `preserveAspectRatio`.

### Rendering to a standalone image

```swift
public func render(_ document: SVGDocument, size: CGSize, scale: CGFloat = 1) -> CGImage?
```

Rasterizes `document` into a new `CGImage` at `size` points, `scale` device pixels per point (`2` for @2x, `3` for @3x). Returns `nil` for a degenerate `size` or `scale`.

## Loading SVG bytes

### From the app bundle

```swift
import ThinPath

guard let url = Bundle.main.url(forResource: "icon", withExtension: "svg") else { return }
let svgData = try Data(contentsOf: url)
let (document, errors) = parse(data: svgData)
if !errors.isEmpty {
    print("Parse warnings: \(errors.map(\.message))")
}
```

### From a URL (local file already on disk)

```swift
let localURL = URL(fileURLWithPath: "/path/to/downloaded/icon.svg")
let svgData = try Data(contentsOf: localURL)
let (document, _) = parse(data: svgData)
```

`parse(data:)` itself only accepts `Data` — fetching bytes from a remote URL is the caller's responsibility (e.g. `URLSession`), matching ThinPath's synchronous, no-I/O rendering path (see <doc:ImageLoaderIntegration> for the pattern used to fetch and cache SVG bytes via an image-loading library).

### From a `data:` URI source

```swift
let dataURIString = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0i...=="
guard let comma = dataURIString.firstIndex(of: ","),
      let payload = Data(base64Encoded: String(dataURIString[dataURIString.index(after: comma)...]))
else { return }
let (document, errors) = parse(data: payload)
```

This mirrors how `<image href="data:...">` elements are decoded internally (see `ImageDecoder`'s `data:` URI handling) — for a top-level SVG document delivered as a `data:` URI, the caller extracts and base64-decodes the payload before handing raw bytes to `parse(data:)`.

## Rendering into a UIKit view

```swift
final class SVGView: UIView {
    var document: SVGDocument?

    override func draw(_ rect: CGRect) {
        guard let document, let context = UIGraphicsGetCurrentContext() else { return }
        ThinPath().render(document, into: context, rect: bounds)
    }
}
```

## Rendering to a UIImage at a specific size and scale

```swift
let renderer = ThinPath()
if let cgImage = renderer.render(document, size: CGSize(width: 44, height: 44), scale: UIScreen.main.scale) {
    imageView.image = UIImage(cgImage: cgImage)
}
```

Parse once and reuse the resulting `SVGDocument` for repeated renders (e.g. re-rendering at a new size after a layout change) rather than re-parsing the same bytes — see ``SVGDocument`` and the memory notes in <doc:ThinPath>.

## Topics

### Entry points

- ``parse(data:)``
- ``ThinPath``

### Types

- ``SVGDocument``
- ``SVGParseError``
