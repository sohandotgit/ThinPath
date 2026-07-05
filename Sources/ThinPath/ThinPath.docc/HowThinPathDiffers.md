# How ThinPath Differs

The design choices ThinPath makes, and the tradeoffs that come with them — not a feature comparison against any specific library.

## Overview

This article describes ThinPath's own choices and why they were made. It intentionally does not make claims about the internals of other named SVG libraries — their implementations aren't something this document can verify, and a scoreboard-style comparison would risk asserting things about code this project doesn't control. Where a general industry pattern is relevant, it's described generically.

### Native Core Graphics, zero third-party dependencies

ThinPath is built entirely on Core Graphics, Core Text, and ImageIO — frameworks that ship with iOS. `Package.swift` declares no package dependencies for the `ThinPath` library target. The tradeoff: ThinPath only draws what these frameworks can draw, and features requiring their own rendering/compositing engine (see <doc:SupportedFeaturesAndLimits> for what's deferred) aren't in scope until built on top of the same primitives.

A generic tradeoff worth naming: libraries that ship their own rendering engine (rather than delegating to the platform's 2D graphics stack) can offer a more complete or more portable feature set, at the cost of a larger binary and a second rendering pipeline to keep correct alongside the platform's own.

### Memory-first: an arena IR instead of a retained node graph

As covered in <doc:HowItWorks> and `Design/MemoryModel.md`, ThinPath's parsed representation is a flat, indexed arena rather than a graph of heap-allocated, ARC-retained node objects. This is a real tradeoff, not a free win: intrusive index links and side arenas are less ergonomic to extend than a conventional class hierarchy, and some conveniences (e.g., a node holding a cached computed style) are deliberately not available because they'd break correctness for shared/instanced subtrees.

A generic tradeoff worth naming: a library that builds a retained tree of node objects (mirroring something like a DOM) makes incremental mutation and per-node inspection more convenient, at the cost of per-node heap allocation and ARC traffic proportional to document size.

### Renders directly to a CGContext at a target size and scale

`ThinPath.render(_:into:rect:)` draws directly into a caller-supplied `CGContext`; `ThinPath.render(_:size:scale:)` is a convenience that allocates one context sized to the request and draws into it once. There is no intermediate full-document rasterization step and no retained bitmap cache inside the library beyond the render-scoped `ImageCache` used for embedded/referenced raster images.

A generic tradeoff worth naming: rasterizing at a fixed "natural" resolution up front and caching that bitmap can be cheaper for repeated draws at the *same* size, but wastes memory and blurs output when the actual draw size differs from that fixed resolution. ThinPath's scale-aware decode (see the overview in <doc:ThinPath> and `Design/ImageDecodeNotes.md`) is a direct response to that failure mode for embedded raster content specifically.

### What this means in practice

None of the above makes ThinPath strictly "better" — it means ThinPath is a good fit when: you're already committed to Core Graphics/UIKit/SwiftUI rendering, you want zero third-party dependencies, and your workload is memory-sensitive (many icons, image-heavy feeds, or large/complex documents where peak memory matters more than raw feature coverage). See <doc:SupportedFeaturesAndLimits> for the concrete list of what is and isn't implemented today.
