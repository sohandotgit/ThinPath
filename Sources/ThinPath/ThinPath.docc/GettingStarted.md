# Getting Started

Parse an SVG document and render it to an image in three calls.

## Overview

You render an SVG in three steps: read the document bytes, parse them into an ``SVGDocument``, and draw that document with a ``ThinPath`` renderer. Parsing and rendering are synchronous and perform no network I/O, so you drive them from wherever you already have the bytes and a target size.

Import the module and render an SVG loaded from your app bundle:

```swift
import ThinPath

let svgData = try Data(contentsOf: url)
let (document, errors) = parse(data: svgData)

let renderer = ThinPath()
if let image = renderer.render(document, size: CGSize(width: 64, height: 64), scale: 2) {
    imageView.image = UIImage(cgImage: image)
}
```

`parse(data:)` always returns a usable ``SVGDocument``. The `errors` array holds non-fatal ``SVGParseError`` diagnostics: an empty array means a clean parse, and a non-empty array does not necessarily mean the document is unusable. You can inspect the diagnostics and still render.

### Next steps

- Load bytes from a bundle resource, file URL, or `data:` URI in <doc:LoadingSVGData>.
- Draw into a live view instead of an image in <doc:RenderingIntoAView>.
- Understand the parse-and-render pipeline in <doc:HowItWorks>.
