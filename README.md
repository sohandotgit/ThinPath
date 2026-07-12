# ThinPath

[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20watchOS-lightgrey.svg)](https://developer.apple.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A memory-first native SVG renderer for iOS, macOS, and watchOS, built directly on Core Graphics.

ThinPath parses SVG into a flat, index-based intermediate representation and draws it straight to a `CGContext` — no node graph, no intermediate bitmaps, no third-party dependencies. It's built for apps that render many SVGs and can't afford the allocation churn or memory footprint of a pointer-linked DOM.

## Features

- Renders directly into any `CGContext`, or rasterizes to a `CGImage`.
- Render-only SwiftUI wrapper: a `ThinPathView` and fixed-size `Image` initializers, with off-main-thread rasterization by default.
- Flat arena IR: parsed documents are contiguous arrays, not a heap of node objects.
- Shapes, groups, `<use>`/`<symbol>` instancing, nested viewports.
- Solid fills, linear/radial gradients, and `<pattern>` fills.
- Clip paths, masks, and opacity.
- CSS `<style>` stylesheets and selectors (type, class, id, universal, compound, and descendant), with full specificity, source order, and `!important` cascading against presentation attributes and inline `style`.
- Single-line `<text>` with system fonts (one positioned run per element — no `<tspan>`, `dx`/`dy`, multiline, or text-on-path), and embedded/referenced `<image>` with on-demand decoding.
- Full SVG transform support and `preserveAspectRatio` fitting.
- Zero third-party dependencies.

## Requirements

- iOS 13+, macOS 11+, or watchOS 7+
- Swift 5.9+
- Xcode 15.0+ <!-- [TODO: confirm] -->

## Installation

### Swift Package Manager

Add ThinPath to the `dependencies` in your `Package.swift`:

```swift
.package(url: "https://github.com/sohandotgit/ThinPath.git", from: "2.0.0")
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
    imageView.image = UIImage(cgImage: image) // NSImage(cgImage:size:) on macOS
}
```

To draw into an existing context instead — e.g. from `draw(_:)`:

```swift
renderer.render(document, into: context, rect: bounds)
```

## SwiftUI

When `SwiftUI` is available, ThinPath ships a small **render-only** wrapper. Parse once (allocation stays out of `body`), then hand the parsed `SVGDocument` to a `ThinPathView`:

```swift
import SwiftUI
import ThinPath

struct LogoView: View {
    let document: SVGDocument // from parse(data:), held outside body

    var body: some View {
        ThinPathView(document)
            .frame(width: 200, height: 200)
    }
}
```

`ThinPathView` rasterizes off the main thread by default (`rendering: .asynchronous`), showing a placeholder until the first image is ready and never flashing to it on resize. Pass `rendering: .synchronous` for small icons and deterministic snapshot tests. Fit is controlled entirely by `preserveAspectRatio:` — the view never mutates the document's IR.

For a plain, caller-sized `Image` (toolbar icon, list row), use the `Image` initializers:

```swift
// Synchronous, on the calling thread; nil for a degenerate size/scale.
Image(document, size: CGSize(width: 24, height: 24), scale: 2)

// Off-thread producer for large documents.
let image = await Image.thinPath(document, size: size, scale: 2)
```

The wrapper stays true to ThinPath's mission: no mutable nodes, no gestures, no hit-testing. Parse errors are handled at the `parse(data:)` boundary — the views never see them. See the [SwiftUI views guide](https://sohandotgit.github.io/ThinPath/docs/documentation/thinpath/swiftuiviews) for the full contract.

## Documentation

Full documentation is generated with DocC and hosted at [sohandotgit.github.io/ThinPath](https://sohandotgit.github.io/ThinPath/docs/documentation/thinpath/).

- [API reference](https://sohandotgit.github.io/ThinPath/docs/documentation/thinpath/) — every entry point and type
- [Design docs](https://sohandotgit.github.io/ThinPath/docs/documentation/thinpath/howitworks) — how the flat arena and compositing model work
- [Examples](https://sohandotgit.github.io/ThinPath/docs/documentation/thinpath/gettingstarted) — copy-paste snippets for common rendering and integration scenarios

## Design Notes

The parsed IR is a flat arena of contiguous arrays addressed by integer indices — no class instances and no retain cycles, so dropping a document frees a handful of arrays. Path commands, points, and gradient stops live in shared side arenas, keeping node structs small and fixed-size. Image bitmaps are never retained by the document; they decode on demand at render scale, so long-lived documents stay lean. See [Design/MemoryModel.md](Design/MemoryModel.md) for the full rationale.

Static CSS styling (`<style>` blocks and selectors) is supported; not yet supported: SMIL and CSS *animation*, `<filter>` effects, scripting, general `mix-blend-mode` compositing, and `@font-face` embedded fonts.

**Non-goal: interactivity.** ThinPath is render-only by design. Tap gestures, hit-testing, and runtime node mutation are out of scope — the flat, value-type IR has no mutable node identity to attach behavior to or to mutate in place. If you need interactive SVG (gestures, live DOM-style mutation), reach for a retained-tree renderer such as [SVGView](https://github.com/exyte/SVGView) instead.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) — please open an issue to discuss substantial changes before submitting a PR.

## License

ThinPath is available under the MIT License. See [LICENSE](LICENSE).
