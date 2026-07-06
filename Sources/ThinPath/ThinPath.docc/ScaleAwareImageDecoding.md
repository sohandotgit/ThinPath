# Scale-Aware Image Decoding

Embedded raster images decode at the size you draw them, not at their source resolution.

## Overview

The IR never retains decoded pixels. An `<image>` element stores only its `href`; decoding happens at render time and only at the target's device-pixel size. Internally, ThinPath decodes through `CGImageSourceCreateThumbnailAtIndex` with an explicit `kCGImageSourceThumbnailMaxPixelSize` and never invokes the full-resolution decode path.

The practical effect: a 12-megapixel source photo drawn into a 44×44pt slot decodes at roughly that size, not at tens of megabytes of full-resolution pixels.

```swift
// The embedded raster in this document decodes at ~88×88px for a @2x,
// 44pt render — not at its full source resolution.
let renderer = ThinPath()
let icon = renderer.render(document, size: CGSize(width: 44, height: 44), scale: 2)
```

Because decode size tracks the render request, re-rendering the same document at a larger size re-decodes embedded images at the new size — sharp output without a permanently oversized bitmap cached in the document.

### Frame selection

Multi-frame sources such as animated GIF or APNG render frame 0 only, matching SVG's static-rendering semantics for embedded rasters.

For the memory constraint that applies when a large image is used as an `objectBoundingBox` pattern fill, see <doc:SupportedFeaturesAndLimits>.
