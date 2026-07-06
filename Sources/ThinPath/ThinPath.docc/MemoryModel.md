# Memory Model

Why a parsed document's footprint stays proportional to what you draw.

## Overview

A parsed ``SVGDocument`` is a flat, arena-based intermediate representation, not a graph of heap-allocated node classes. The document is a handful of contiguous arrays — `nodes`, `pathCommands`, `points`, `gradientStops`, and an interned string pool — linked by `Int32` indices. Releasing a document is a few array deallocations rather than a recursive teardown of thousands of ARC-retained objects.

`<use>` instancing stores a *reference* to the target node, never an expanded copy. An icon reused thousands of times costs one shape plus thousands of small reference structs, not thousands of full subtrees.

### Parse once, render many

Because parsing produces the reusable artifact, parse the bytes once and reuse the ``SVGDocument`` for every subsequent render rather than re-parsing the same data.

```swift
let (document, _) = parse(data: svgData)
let renderer = ThinPath()

// Re-render at new sizes without re-parsing.
let small = renderer.render(document, size: CGSize(width: 44, height: 44), scale: 2)
let large = renderer.render(document, size: CGSize(width: 320, height: 320), scale: 2)
```

### Isolation layers only when required

Group opacity, masks, and certain compositing cases require rendering into an intermediate layer before compositing back. ThinPath creates that layer only for the elements that need it, clamps it to the element's own device-space bounds rather than the full canvas, and releases it immediately after compositing.

### The tradeoff

The arena design is deliberate, not free. Index links and side arenas are less ergonomic to extend than a conventional class hierarchy, and a node cannot cache its computed style — the same node can be reached through more than one `<use>` path, so a cached style would be wrong. See <doc:HowItWorks> for how styles are resolved during the walk, and <doc:HowThinPathDiffers> for the reasoning behind the tradeoff.
