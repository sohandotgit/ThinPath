# ``ThinPath``

A memory-first, native iOS SVG renderer built directly on Core Graphics, Core Text, and ImageIO — no third-party dependencies.

## Overview

ThinPath parses an SVG document into an in-memory intermediate representation (IR) and draws it with a single depth-first walk into a `CGContext`. Every design decision in the library is driven by one constraint: keep memory proportional to what is actually being drawn, not to the document's nominal complexity or its embedded assets' native resolution.

That constraint shows up in four concrete choices:

- **A flat, arena-based IR**, not a graph of heap-allocated node classes. A parsed `SVGDocument` is a handful of contiguous arrays (`nodes`, `pathCommands`, `points`, `gradientStops`, an interned string pool) linked by `Int32` indices. Releasing a document is a few array deallocations, not a recursive teardown of thousands of ARC-retained objects. `<use>` instancing stores a *reference* to the target node, never an expanded copy, so an icon reused thousands of times costs one shape plus thousands of small reference structs. See <doc:HowItWorks> and the source-level rationale in `Design/MemoryModel.md`.

- **Scale-aware image decode.** The IR never retains decoded pixels — an `<image>` element stores only its `href`. Decoding happens at render time, and only at the target's *device-pixel* size (`ImageDecoder` calls `CGImageSourceCreateThumbnailAtIndex` with an explicit `kCGImageSourceThumbnailMaxPixelSize`; the full-resolution decode path is never invoked). A 12-megapixel source photo drawn into a 44×44pt icon slot decodes at roughly that size, not at 48 MB of full-resolution pixels.

- **`CGPattern` tiling instead of giant offscreen bitmaps.** A `<pattern>` is realized as a `CGPattern` whose `drawPattern` callback Core Graphics invokes once per tile cell, re-walking the pattern's child subtree for that one cell. The result is one tile's worth of vector drawing, reused across the fill region — never a pre-rendered bitmap sized to the whole fill area. Getting the pattern-content coordinate mapping wrong here is exactly the failure mode that costs the most memory (see <doc:HowItWorks> and `Design/Compositing.md` §4).

- **Offscreen isolation layers only when semantically required.** Group opacity, masks, and certain compositing cases require rendering into an intermediate layer before compositing back — there is no way to do a group-level alpha blend or a luminance mask without one. ThinPath creates that layer only for the elements that actually need it, clamps it to the element's own device-space bounds (never the full canvas), and releases it immediately after compositing.

## Getting Started

```swift
import ThinPath

let svgData = try Data(contentsOf: url)
let (document, errors) = parse(data: svgData)

let renderer = ThinPath()
if let image = renderer.render(document, size: CGSize(width: 64, height: 64), scale: 2) {
    imageView.image = UIImage(cgImage: image)
}
```

See <doc:APIReferenceAndUsage> for the full entry-point reference and more usage patterns (bundle, URL, and `data:` sources).

## Topics

### Essentials

- <doc:HowItWorks>
- <doc:APIReferenceAndUsage>
- <doc:SupportedFeaturesAndLimits>

### Design rationale

- <doc:HowThinPathDiffers>

### Integration

- <doc:ImageLoaderIntegration>

### Core API

- ``parse(data:)``
- ``ThinPath``
- ``SVGParseError``
- ``SVGDocument``
