# How It Works

The conceptual pipeline from SVG bytes to pixels: parse, resolve style, walk.

## Overview

ThinPath's pipeline has three stages, and each stage is deliberately narrow in what it retains. The two public calls map onto them: `parse(data:)` runs the parse stage and produces an ``SVGDocument``; a ``ThinPath`` `render` call runs style resolution and the render walk over that document.

```swift
let (document, _) = parse(data: svgData)   // Stage 1: parse
ThinPath().render(document, into: context, rect: bounds)  // Stages 2–3: resolve + walk
```

### 1. Parse — event-driven, no retained DOM

`parse(data:)` reads the document and builds the ``SVGDocument`` IR directly. There is no intermediate DOM or XML tree that gets walked and thrown away. Elements become fixed-size node values appended to a flat `nodes` array as they are encountered; variable-length payloads — path commands, polygon points, gradient stops — are appended to their own side arenas, and each node stores only a `(start, count)` window into the relevant arena.

Parsing is resilient by design. A malformed attribute, an unknown element, or an unresolved `href` is recorded as a non-fatal ``SVGParseError`` rather than aborting the parse. A document that is "mostly fine" still produces a renderable ``SVGDocument``, and a non-empty `errors` array does not mean the document is unusable.

### 2. Computed styles — resolved on the fly, not cached on the node

SVG styling is inherited and cascading: an element's effective fill, stroke, opacity, and font properties depend on its ancestors. The *same* node can also resolve differently depending on where it is reached from — a `<symbol>` referenced by two `<use>` sites with different inherited context, for instance.

Because of that, ThinPath does not store a resolved style on the node. It computes the style during the walk, threading the inherited context down as it descends. Caching a computed style on the node would be incorrect for any node reachable through more than one path.

### 3. Render — a single depth-first walk into a CGContext

Rendering is one depth-first traversal of the arena. Container elements (`<g>`, `<svg>`, `<defs>`) are pass-through; leaf kinds (shape, image, text) delegate to a dedicated renderer. State during the walk lives on a save/restore stack: the current user-to-device transform, the device-space clip bounds, and the current viewport. Entering a node that applies a `transform`, a `clip-path`, or a viewport change pushes a frame; exiting pops it.

An offscreen isolation layer is introduced only when an element's `opacity` or `mask` cannot be expressed as a direct paint operation, and it is clamped to that element's own device bounds. Paint resolution turns a `Paint` value — a solid color, `currentColor`, or a reference to a `<linearGradient>`, `<radialGradient>`, or `<pattern>` — into a concrete paint source at the point of use, without copying the referenced definition.

See also <doc:MemoryModel>, <doc:HowThinPathDiffers>, and <doc:SupportedFeaturesAndLimits>.
