# ThinPath

A memory-first native SVG renderer for iOS, built directly on Core Graphics.

<!--
Badges to wire up (shields.io):
- Swift Package Manager compatible
- Platform: iOS 13+
- Swift: 5.9+
- License: MIT
-->

ThinPath parses SVG into a flat, index-based intermediate representation and draws it straight to a `CGContext` — no node graph, no intermediate bitmaps, no third-party dependencies. It's built for apps that render many SVGs and can't afford the allocation churn or memory footprint of a pointer-linked DOM.

## Features

- Renders directly into any `CGContext`, or rasterizes to a `CGImage`.
- Flat arena IR: parsed documents are contiguous arrays, not a heap of node objects.
- Shapes, groups, `<use>`/`<symbol>` instancing, nested viewports.
- Solid fills, linear/radial gradients, and `<pattern>` fills.
- Clip paths, masks, opacity, and blending modes.
- Basic `<text>` with system fonts, and embedded/referenced `<image>` with on-demand decoding.
- Full SVG transform support and `preserveAspectRatio` fitting.
- Zero third-party dependencies.

## Requirements

- iOS 13+
- Swift 5.9+
- Xcode 15.0+ <!-- [TODO: confirm] -->

## Installation

### Swift Package Manager

Add ThinPath to the `dependencies` in your `Package.swift`:

```swift
.package(url: "https://github.com/sohandotgit/ThinPath.git", from: "1.0.0") // [TODO: confirm tagged release]
```

Then add `"ThinPath"` to your target's dependencies.

In Xcode, use **File → Add Package Dependencies…** and paste the repository URL:

```
https://github.com/sohandotgit/ThinPath.git
```

## Quick Start

```swift
import ThinPath

let data = try Data(contentsOf: url)
let (document, _) = parse(data: data)

let renderer = ThinPath()
if let image = renderer.render(document, size: CGSize(width: 200, height: 200), scale: 2) {
    imageView.image = UIImage(cgImage: image)
}
```

To draw into an existing context instead — e.g. from `draw(_:)`:

```swift
renderer.render(document, into: context, rect: bounds)
```

## Documentation

- [API reference](https://sohandotgit.github.io/ThinPath/docs/documentation/thinpath/)
- [Examples/](Examples/) — runnable snippets for batch rendering, custom views, and error handling
- [Design/](Design/) — IR memory model, render pipeline, and cascade rules

## Design Notes

The parsed IR is a flat arena of contiguous arrays addressed by integer indices — no class instances and no retain cycles, so dropping a document frees a handful of arrays. Path commands, points, and gradient stops live in shared side arenas, keeping node structs small and fixed-size. Image bitmaps are never retained by the document; they decode on demand at render scale, so long-lived documents stay lean. See [Design/MemoryModel.md](Design/MemoryModel.md) for the full rationale.

Not yet supported: SMIL/CSS animation, `<filter>` effects, scripting, and `@font-face` embedded fonts.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) — please open an issue to discuss substantial changes before submitting a PR.

## License

ThinPath is available under the MIT License. See [LICENSE](LICENSE).
