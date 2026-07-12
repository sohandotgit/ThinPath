# ThinPath Examples

Short, runnable code snippets demonstrating common patterns.

## BasicRender.swift

Simple parse-and-render flow:
- `renderSVGToImageView()` — Load SVG, parse, render to UIImageView
- `getSVGDimensions()` — Extract viewBox dimensions

**Best for:** Getting started, simple one-off renders

## CustomViewRender.swift

Rendering SVG in a custom `UIView` subclass:
- `SVGView` — Draws parsed document in `draw(_:)`
- Automatically updates when document changes

**Best for:** Integrating SVG rendering into your view hierarchy

## EfficientBatchRender.swift

Parse once, render at multiple scales:
- `IconSet` — Loads and caches a parsed document
- `image(size:scale:)` — Render on demand at any size
- `precomputedImages()` — Pre-generate a set of icon sizes

**Best for:** Icon sets, theme assets, performance-critical rendering

## SwiftUIRender.swift

Presenting a parsed document in SwiftUI with the render-only wrapper:
- `loadDocument(url:)` — Parse once, outside `body`
- `LogoView` — `ThinPathView` sized to its frame
- `BannerView` — Custom placeholder and a `preserveAspectRatio` override
- `IconRow` — Fixed-size `Image(_:size:scale:)` for a list row

**Best for:** SwiftUI apps, icons and logos in a view hierarchy

## ErrorHandling.swift

Graceful error handling and fallbacks:
- `parseWithDiagnostics()` — Log parse warnings, proceed anyway
- `renderWithFallback()` — Display fallback image if render fails
- `isDocumentValid()` — Check if a document can be rendered

**Best for:** Production apps, user-facing error recovery

## Running the Examples

Copy code snippets into your project. Each example is self-contained and ready to adapt to your use case.
