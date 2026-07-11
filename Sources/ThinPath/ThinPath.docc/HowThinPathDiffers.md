# How ThinPath Differs

The design choices ThinPath makes, and the tradeoffs that come with them.

## Overview

This article describes ThinPath's own choices and why they were made. It intentionally makes no claims about the internals of other named SVG libraries — their implementations are not something this document can verify. Where a general industry pattern is relevant, it is described generically.

### Native Core Graphics, zero third-party dependencies

ThinPath is built entirely on Core Graphics, Core Text, and ImageIO — frameworks that ship on iOS, macOS, and watchOS. The `ThinPath` library target declares no package dependencies. The tradeoff: ThinPath draws only what these frameworks can draw, and features requiring their own rendering engine are out of scope until built on the same primitives (see <doc:SupportedFeaturesAndLimits>).

A library that ships its own rendering engine, rather than delegating to the platform's 2D stack, can offer a more complete or more portable feature set — at the cost of a larger binary and a second pipeline to keep correct alongside the platform's own.

### Memory-first: an arena IR instead of a retained node graph

ThinPath's parsed representation is a flat, indexed arena rather than a graph of heap-allocated, ARC-retained node objects. This is a real tradeoff, not a free win: index links and side arenas are less ergonomic to extend than a class hierarchy, and some conveniences — a node caching its computed style — are deliberately unavailable because they would break correctness for shared or instanced subtrees. See <doc:MemoryModel> for the full picture.

A library that builds a retained tree of node objects, mirroring something like a DOM, makes incremental mutation and per-node inspection more convenient, at the cost of per-node heap allocation and ARC traffic proportional to document size.

### Direct rendering at a target size and scale

`ThinPath.render(_:into:rect:)` draws directly into a caller-supplied `CGContext`; `ThinPath.render(_:size:scale:)` allocates one context sized to the request and draws into it once. There is no intermediate full-document rasterization and no retained bitmap cache inside the library beyond the render-scoped image cache used for embedded rasters.

Rasterizing at a fixed "natural" resolution up front and caching that bitmap can be cheaper for repeated draws at the *same* size, but wastes memory and blurs output when the actual draw size differs. ThinPath's scale-aware decode (see <doc:ScaleAwareImageDecoding>) is a direct response to that failure mode for embedded raster content.

### What this means in practice

None of this makes ThinPath strictly "better." It means ThinPath fits when you are already committed to Core Graphics, UIKit, or SwiftUI rendering, you want zero third-party dependencies, and your workload is memory-sensitive — many icons, image-heavy feeds, or large documents where peak memory matters more than raw feature coverage. See <doc:SupportedFeaturesAndLimits> for what is and isn't implemented today.
