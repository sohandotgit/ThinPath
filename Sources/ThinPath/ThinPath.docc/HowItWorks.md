# How It Works

The conceptual pipeline from SVG bytes to pixels: parse, resolve style, walk.

## Overview

ThinPath's pipeline has three stages, and each stage is deliberately narrow in what it retains.

### 1. Parse — event-driven, no retained DOM

`parse(data:)` (implemented by `SVGParser.parse(data:)`) reads the document and builds the `SVGDocument` IR directly — there is no intermediate retained DOM/XML tree that gets walked and thrown away. Elements become fixed-size `SVGNode` values appended to a flat `nodes` array as they're encountered; variable-length payloads (path commands, polygon points, gradient stops) are appended to their own side arenas, with each node storing only a `(start, count)` window (`ArenaRange`) into the relevant arena.

Parsing is resilient by design: a malformed attribute, an unknown element, or an unresolved `href` is recorded as a non-fatal `SVGParseError` rather than aborting the parse, so a document that is "mostly fine" still produces a renderable `SVGDocument`. `errors` being non-empty does not mean the document is unusable.

### 2. Computed styles — resolved on the fly, not cached on the node

SVG styling is inherited and cascading: an element's effective fill, stroke, opacity, and font properties depend on its ancestors, and the *same* node can need to resolve differently depending on where it's reached from (a `<symbol>` referenced by two different `<use>` sites with different inherited context, for instance). Because of that, ThinPath does not store a resolved `ComputedStyle` on the node — `StyleResolver.resolve(_:inheriting:)` computes it during the walk, threading the inherited context down as it descends. Caching a computed style on the node would be incorrect for any node reachable through more than one path.

### 3. Render — a single depth-first walk into a CGContext

`RenderWalk` performs one depth-first traversal of the arena, dispatching to a `NodeVisitor` (`DefaultVisitor` in this module) at each node: containers (`<g>`, `<svg>`, `<defs>`) are pass-through, and leaf kinds (shape, image, text) delegate to their dedicated renderer (`ShapeRenderer`, `ImageRenderer`, `TextRenderer`).

State during the walk lives on a `RenderContext` save/restore stack (`RenderFrame`): the current user-to-device transform, the device-space clip bounds, and the current viewport. Entering a node that applies a `transform`, a `clip-path`, or a viewport change pushes a frame; exiting pops it. Isolation (an offscreen layer) is only introduced when an element's `opacity` or `mask` cannot be expressed as a direct paint operation — `RenderContext.needsIsolationLayer` decides this per element, and `beginIsolationLayer`/`endIsolationLayer` bracket exactly that element's subtree, clamped to its own device bounds.

Paint resolution (`PaintResolver`) turns a `Paint` value (solid color, `currentColor`, or a reference to a `<linearGradient>`/`<radialGradient>`/`<pattern>`) into a concrete `PaintSource` — `SolidPaint`, `GradientPaint`, or `PatternPaint` — at the point of use, without copying the referenced gradient/pattern definition. See `Design/Compositing.md` for the full coordinate-mapping rules (`objectBoundingBox` vs. `userSpaceOnUse`, `gradientTransform`/`patternTransform`) and how pattern tiling avoids a full-size intermediate bitmap.

See also: <doc:HowThinPathDiffers>, <doc:SupportedFeaturesAndLimits>.
