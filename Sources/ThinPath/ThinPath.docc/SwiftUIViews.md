# SwiftUI Views

Present a parsed document in SwiftUI with a render-only wrapper.

## Overview

When `SwiftUI` can be imported, ThinPath adds a thin convenience layer over its existing rasterizer: a ``ThinPathView`` and two `Image` initializers. The layer is **render-only** and preserves ThinPath's immutable-IR, memory-first mission — it exposes no mutable nodes, no gestures, and no hit-testing.

Parsing is the allocating step, so it stays where it belongs: the free ``parse(data:)`` function. Parse once, hold the resulting `SVGDocument` outside the SwiftUI `body`, and hand it to a view. The wrapper never parses inside a layout pass and never re-parses on `body` recomputation.

The symbols are available on iOS 13+, macOS 11+, and watchOS 7+, matching the package's declared platforms.

## Rendering a document in a view

``ThinPathView`` rasterizes an `SVGDocument` to a `CGImage` sized to its laid-out frame and the environment's display scale, then presents it as a decorative `Image`.

```swift
import SwiftUI
import ThinPath

struct LogoView: View {
    let document: SVGDocument // parsed once, held outside body

    var body: some View {
        ThinPathView(document)
            .frame(width: 200, height: 200)
    }
}
```

The view accepts any size the layout system proposes and renders into it, like a resizable image. Its ideal size (used when the proposal is unspecified — under `.fixedSize()` or in a scroll view) is the document's `rootViewBox` size, or `.zero` when there is no `viewBox`. It does **not** auto-apply `.aspectRatio`; compose SwiftUI's own modifier if you want the outer view to track the document's aspect ratio.

## Threading

By default (`rendering: .asynchronous`), rasterization runs on a background executor so large, many-node documents never block the UI. A placeholder shows until the first image for the current size and scale is ready; on resize the previous image stays in place so the view never flashes to the placeholder. At most one raster is in flight per view, and a superseding size/scale change cancels the stale one.

```swift
ThinPathView(document, rendering: .asynchronous) {
    ProgressView() // custom placeholder while the first raster is in flight
}
```

Pass `rendering: .synchronous` to rasterize inline within the layout pass — deterministic and placeholder-free, best for small icons and snapshot tests.

The view caches at most one `CGImage`, keyed by `(resolved frame size, effective scale, effective preserveAspectRatio)`. It re-rasterizes only when that key changes. Because `SVGDocument` is a value type, the key never includes document contents: the document is assumed immutable for a given view identity. To present a different document, give the view new SwiftUI identity (a changed `.id(_:)`).

## Fit and scale

Fit within the resolved frame is governed entirely by `preserveAspectRatio:`. Passing `nil` (the default) honors the document's own `rootPreserveAspectRatio`; a non-nil value overrides it for this view only — it is render configuration and never mutates the IR. SVG's `preserveAspectRatio` already encodes both content-mode and alignment:

| Intent                        | `PreserveAspectRatio` value                |
|-------------------------------|--------------------------------------------|
| Aspect-fit (letterbox)        | `align != .none`, `.meetOrSlice == .meet`  |
| Aspect-fill (crop)            | `align != .none`, `.meetOrSlice == .slice` |
| Stretch to fill (non-uniform) | `.align == .none`                          |

`scale:` defaults to `nil`, which reads `@Environment(\.displayScale)`. Pin it to a fixed value for deterministic snapshot tests.

## Fixed-size images

For a plain SwiftUI `Image` at a caller-chosen pixel size — a toolbar icon, a `List` row leading image — use the `Image` initializers instead of a layout-driven view:

```swift
// Synchronous, on the calling thread. nil for a degenerate size/scale,
// mirroring render(_:size:scale:).
Image(document, size: CGSize(width: 24, height: 24), scale: 2)

// Off-thread producer for large documents.
let image = await Image.thinPath(document, size: CGSize(width: 24, height: 24), scale: 2)
```

Both present the result as a decorative `Image` and fit using the document's own `preserveAspectRatio`. Use ``ThinPathView`` when you need layout-driven sizing or a `preserveAspectRatio` override.

## Errors and accessibility

The views have no parsing entry point and no error surface. Handle the `[SVGParseError]` from ``parse(data:)`` before constructing a view:

```swift
let (document, errors) = parse(data: svgData)
if !errors.isEmpty { /* log or decide */ }
ThinPathView(document) // render-only; never sees errors
```

A document with no root content, no `viewBox`, or a degenerate frame renders as empty (a transparent region) rather than throwing. The presented `Image` is decorative and carries no accessibility label — SVG art has no intrinsic label. Attach `.accessibilityLabel(_:)` yourself when the graphic is meaningful.

## Topics

### Views

- ``ThinPathView``
- ``ThinPathRenderingMode``
