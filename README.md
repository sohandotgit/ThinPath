# ThinPath

A memory-efficient native iOS SVG renderer built with Swift and Core Graphics. No dependencies.

## Installation

Add to `Package.swift`:

```swift
.package(url: "https://github.com/sohandotgit/ThinPath.git", branch: "main")
```

Or with Xcode: File → Add Packages → paste the repository URL.

## Quick Start

```swift
import ThinPath

// Parse SVG
let svgData = try Data(contentsOf: url)
let (document, errors) = parse(data: svgData)
if !errors.isEmpty {
    print("Parse warnings: \(errors)")
}

// Render into a CGContext
let renderer = ThinPath()
renderer.render(document, into: context, rect: CGRect(x: 0, y: 0, width: 200, height: 200))

// Or render directly to CGImage
if let image = renderer.render(document, size: CGSize(width: 200, height: 200), scale: 2) {
    imageView.image = UIImage(cgImage: image)
}
```

## Supported SVG Features

### Shapes
- `<path>`, `<line>`, `<polyline>`, `<polygon>`, `<rect>`, `<circle>`, `<ellipse>`

### Structure
- `<g>` (groups), `<svg>` (nested viewports), `<defs>`, `<use>` (instancing), `<symbol>`

### Styling
- Fill, stroke, opacity, display, visibility
- Inherited CSS properties, inline `style` attributes
- Color keywords and hex notation

### Paint Servers
- Solid fills and strokes
- Linear gradients, radial gradients
- `<pattern>` rasterization

### Effects
- Clipping paths (`<clipPath>`)
- Masks (`<mask>`)
- Opacity and blending modes

### Text
- Basic `<text>` rendering with system fonts
- Font family, size, weight, style

### Images
- Embedded `<image>` with lazy decoding
- External image references (via href)

### Transforms
- SVG transform attribute (`translate`, `rotate`, `scale`, `skewX`, `skewY`, `matrix`)
- Nested `viewBox` and `preserveAspectRatio`

## Unsupported / Stretch Goals

- **SMIL Animation** — `<animate>`, `<animateMotion>`, `<set>` not implemented; see separate animation layer
- **CSS Animations / Transitions** — requires CSS parsing and state management
- **Advanced Filters** — `<filter>`, `<feGaussianBlur>`, etc. (significant Core Graphics integration)
- **Scripting / Event Handlers** — `onload`, `onclick`, etc. (out of scope)
- **Embedded Fonts** — `<style>` blocks and `@font-face` parsing deferred

## Memory Efficiency

ThinPath stores parsed SVG as a flat arena of contiguous arrays with integer indices, not a pointer-linked node graph. This design ensures:

- **Zero allocation overhead per node** — no class instances, no retain cycles
- **Cache-dense tree traversal** — linear memory scans, minimal pointer chasing
- **Instant release** — dropping a document frees a handful of arrays directly
- **Cheap instancing** — `<use>` copies reference a shape, not the shape itself

Gradient stops, path commands, and text data live in shared side arenas, keeping individual node structs small and fixed-size.

### Verified Assumptions

See `Design/MemoryModel.md` for a full list of profiling checks (use-expansion cost, color depth, geometry precision, index overflow, string pool overhead, arena slack, node struct size).

## Documentation

- **[PublicAPI.md](PublicAPI.md)** — function signatures and code examples
- **[Design/MemoryModel.md](Design/MemoryModel.md)** — IR architecture and layout reasoning
- **[Design/RenderPipeline.md](Design/RenderPipeline.md)** — render walk and visitor pattern
- **[Design/CascadeRules.md](Design/CascadeRules.md)** — style resolution and inheritance
- **[Examples/](Examples/)** — runnable code snippets

## Requirements

- iOS 13+
- Swift 5.9+
