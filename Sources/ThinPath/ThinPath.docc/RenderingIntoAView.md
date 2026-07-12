# Rendering into a View

Draw a document directly into a graphics context you already have.

## Overview

`ThinPath.render(_:into:rect:)` draws into a `CGContext` you supply, fitting the document's `viewBox` or intrinsic size into `rect` per its `preserveAspectRatio`. Use it when you want ThinPath to paint into a live context — a `UIView` draw cycle, a PDF context, or any other `CGContext` — rather than producing a standalone image.

```swift
final class SVGView: UIView {
    var document: SVGDocument?

    override func draw(_ rect: CGRect) {
        guard let document, let context = UIGraphicsGetCurrentContext() else { return }
        ThinPath().render(document, into: context, rect: bounds)
    }
}
```

The renderer draws into `rect` in the context's own coordinate space, so you control placement by choosing that rectangle. To produce a standalone image instead, see <doc:RenderingToAnImage>. For SwiftUI, use the render-only wrapper described in <doc:SwiftUIViews>.
