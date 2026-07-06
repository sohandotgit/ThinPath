# Rendering to an Image

Rasterize a parsed document into a `CGImage` at a specific point size and screen scale.

## Overview

`ThinPath.render(_:size:scale:)` allocates a bitmap context sized to `size` points at `scale` device pixels per point, draws the document into it once, and returns the resulting `CGImage`. Pass `scale: 2` for a @2x bitmap or `scale: 3` for @3x. The method returns `nil` for a degenerate `size` or `scale`.

```swift
let renderer = ThinPath()
if let cgImage = renderer.render(document, size: CGSize(width: 44, height: 44), scale: UIScreen.main.scale) {
    imageView.image = UIImage(cgImage: cgImage)
}
```

### Reuse the document across renders

Parse once and keep the resulting ``SVGDocument``. When you need the same artwork at a new size — after a layout change, rotation, or Dynamic Type update — call `render` again on the existing document instead of re-parsing the bytes.

```swift
let (document, _) = parse(data: svgData)
let renderer = ThinPath()

let thumb = renderer.render(document, size: CGSize(width: 44, height: 44), scale: 2)
let large = renderer.render(document, size: CGSize(width: 320, height: 320), scale: 2)
```

See <doc:MemoryModel> for why re-rendering is cheaper than re-parsing, and <doc:ScaleAwareImageDecoding> for how embedded images track the render size.
