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
