# PublicAPI — ThinPath Entry Points

## Parsing

```swift
public func parse(data: Data) -> (document: SVGDocument, errors: [SVGParseError])
```

Parse SVG document data into an in-memory IR.

**Parameters:**
- `data: Data` — Raw SVG document bytes (XML or text)

**Returns:**
- `document: SVGDocument` — Parsed IR, guaranteed non-nil (empty document if parse fails completely)
- `errors: [SVGParseError]` — Non-fatal warnings (unknown elements, malformed attributes, unresolved references). Empty array = clean parse.

**Example:**

```swift
let url = Bundle.main.url(forResource: "icon", withExtension: "svg")!
let svgData = try Data(contentsOf: url)
let (document, errors) = parse(data: svgData)

if !errors.isEmpty {
    print("Warnings during parse:")
    for error in errors {
        print("  - \(error.message)")
    }
}
```

---

## Rendering

### Render into CGContext

```swift
public struct ThinPath {
    public init()
    
    public func render(_ document: SVGDocument, into context: CGContext, rect: CGRect)
}
```

Draw document into an existing graphics context.

**Parameters:**
- `document: SVGDocument` — Parsed document from `parse(data:)`
- `context: CGContext` — Destination graphics context (created by caller)
- `rect: CGRect` — Target rectangle in context's coordinate space. The document's `viewBox` is fit into this rect per `preserveAspectRatio`

**Example:**

```swift
let renderer = ThinPath()

// Render into a view's graphics context at draw time
if let context = UIGraphicsGetCurrentContext() {
    let drawRect = CGRect(x: 50, y: 50, width: 200, height: 200)
    renderer.render(document, into: context, rect: drawRect)
}
```

---

### Render to CGImage

```swift
public func render(_ document: SVGDocument, size: CGSize, scale: CGFloat = 1) -> CGImage?
```

Rasterize document to a standalone `CGImage` at given pixel dimensions.

**Parameters:**
- `document: SVGDocument` — Parsed document
- `size: CGSize` — Image dimensions in points (logical)
- `scale: CGFloat` — Device scale factor. Default `1`; use `2` for @2x, `3` for @3x

**Returns:**
- `CGImage?` — Rasterized bitmap, or `nil` if `size` or `scale` is invalid

**Example:**

```swift
let renderer = ThinPath()

// Render at 200×200 points, @2x device scale (400×400 pixels)
if let cgImage = renderer.render(document, size: CGSize(width: 200, height: 200), scale: 2) {
    let uiImage = UIImage(cgImage: cgImage)
    imageView.image = uiImage
}
```

---

## SwiftUI (when `canImport(SwiftUI)`)

A render-only convenience layer over the rasterizer above. Available on iOS 13+, macOS 11+, watchOS 7+. It exposes no mutable nodes, gestures, or hit-testing, and never parses inside a SwiftUI `body` — parse once with `parse(data:)` and pass the `SVGDocument` in.

### ThinPathView

```swift
@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
public struct ThinPathView<Placeholder: View>: View {
    public init(_ document: SVGDocument,
                preserveAspectRatio: PreserveAspectRatio? = nil,
                scale: CGFloat? = nil,
                rendering: ThinPathRenderingMode = .asynchronous,
                @ViewBuilder placeholder: () -> Placeholder)
}

// Common case: placeholder defaults to Color.clear, call site is ThinPathView(doc).
extension ThinPathView where Placeholder == Color {
    public init(_ document: SVGDocument,
                preserveAspectRatio: PreserveAspectRatio? = nil,
                scale: CGFloat? = nil,
                rendering: ThinPathRenderingMode = .asynchronous)
}
```

Rasterizes `document` to a `CGImage` sized to the view's laid-out frame and presents it as a decorative `Image`.

- `preserveAspectRatio: nil` honors the document's `rootPreserveAspectRatio`; a non-nil value overrides it for this view only (render config, not an IR mutation).
- `scale: nil` reads `@Environment(\.displayScale)`; a non-nil value pins it (deterministic snapshots).
- The view caches one `CGImage`, keyed on `(frame size, scale, preserveAspectRatio)`, and re-rasterizes only when that key changes. It never keys on document contents — the document is assumed immutable for a view's identity.

```swift
public enum ThinPathRenderingMode: Equatable {
    case asynchronous // default: rasterize off the main thread, show placeholder until first image
    case synchronous  // rasterize inline in the layout pass; placeholder never shown
}
```

### Image initializers

```swift
@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
extension Image {
    // Synchronous, on the calling thread. nil for a degenerate size/scale.
    public init?(_ document: SVGDocument, size: CGSize, scale: CGFloat = 1)

    // Off-thread producer for large documents.
    public static func thinPath(_ document: SVGDocument,
                                size: CGSize,
                                scale: CGFloat = 1) async -> Image?
}
```

Both present a fixed-size decorative `Image`, fit using the document's own `preserveAspectRatio`, and mirror `render(_:size:scale:)` by returning `nil` on a degenerate size/scale.

**Example:**

```swift
let (document, _) = parse(data: svgData)

struct LogoView: View {
    let document: SVGDocument
    var body: some View {
        ThinPathView(document)
            .frame(width: 200, height: 200)
    }
}

// Or a fixed-size icon:
Image(document, size: CGSize(width: 24, height: 24), scale: 2)
```

---

## Types

### SVGDocument

The parsed IR. Owns all backing storage (arenas, strings, transforms). Indices are only valid against the document they came from.

```swift
public struct SVGDocument {
    public var nodes: [SVGNode]
    public var root: NodeIndex
    public var pathCommands: [PathCommand]
    public var points: [CGPoint]
    public var gradientStops: [GradientStop]
    public var strings: StringPool
    public var transforms: [CGAffineTransform]
    public var idMap: [StringRef: NodeIndex]
    public var rootViewBox: ViewBox?
    public var rootPreserveAspectRatio: PreserveAspectRatio
}
```

See `Design/MemoryModel.md` for the IR design rationale.

### SVGParseError

A non-fatal parse problem.

```swift
public struct SVGParseError: Error, Equatable {
    public var message: String
}
```

---

## Memory Considerations

Each `SVGDocument` retains:
- A single flat array of all nodes (no per-node heap allocation)
- Side arenas for path commands, polygon points, gradient stops
- An interned string pool with one copy of each unique string
- A transform array (only non-identity transforms stored)

Parsing does **not** retain decoded image bitmaps — images are decoded on demand at render time, at the target scale. This keeps long-lived documents lean.

For repeated renders of the same document, pass a shared `SVGDocument` instance (parse once, render many times) rather than parsing repeatedly.
