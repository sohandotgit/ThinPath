# Image Loader Integration

Pairing ThinPath with an image-loading library (Nuke, Kingfisher) without giving up ThinPath's scale-aware memory advantage.

## Overview

> Note: this article currently covers the architecture only. The Nuke and Kingfisher code samples referenced in the project brief for this article require the app's actual integration glue code, which wasn't available when this article was written — see the maintainer note at the bottom before publishing this page.

### The size-aware approach, and why it matters

ThinPath's entire memory story for embedded raster content rests on one fact: `ImageDecoder` never decodes an image at more than the target's device-pixel size (see `Design/ImageDecodeNotes.md` and the `ImageDecoder.decodedImage(href:pool:targetPixelSize:cache:)` entry point). A 12-megapixel source photo drawn into a 44×44pt slot decodes at roughly that size, not at full resolution — that's the whole point of routing decode through `CGImageSourceCreateThumbnailAtIndex` with an explicit `kCGImageSourceThumbnailMaxPixelSize` instead of ever calling `CGImageSourceCreateImageAtIndex`.

An image-loading library like Nuke or Kingfisher is normally responsible for three things: fetching bytes over the network, deduplicating in-flight requests, and caching the result. For an *SVG* image, the "result" that's worth fetching and caching is the **encoded SVG bytes** — not a rasterized bitmap at some fixed size the loader guessed at. The size-aware integration pattern is:

1. Register the loader's SVG handling as a **passthrough/no-op decoder** — it hands back the raw encoded data it fetched, instead of decoding to a bitmap itself.
2. The loader still does what it's good at: fetch, dedupe concurrent requests for the same URL, and cache the compressed bytes (on disk and/or in memory).
3. At the point where the app actually knows the view's **real layout size and screen scale** (e.g. in `layoutSubviews`, `onGeometryChange`, or an `NSCache`-backed rasterization step keyed by size), parse once with `parse(data:)` and rasterize with `ThinPath().render(_:size:scale:)` at that exact size.
4. If the view's size changes (rotation, dynamic type, adaptive layout), re-rasterize at the new size — re-parsing isn't necessary if the `SVGDocument` from step 3 is still around, only step 3's render call needs to repeat.

### Why a naive fixed-size decoder wastes the advantage

If instead the loader's SVG decoder rasterizes once at some fixed, guessed size (e.g. "always decode SVGs to 300×300") and caches *that bitmap*, two things go wrong relative to ThinPath's design:

- **Oversized for small placements.** A 300×300 rasterization cached and then downscaled by the loader's image view for a 24×24 icon spot means ThinPath's whole scale-aware decode path — the mechanism that keeps a document's memory proportional to its actual draw size — never gets exercised. You paid for a 300×300 decode to display 24×24 pixels.
- **Blurry/incorrect for large placements.** The inverse case — a fixed size smaller than where the image is actually displayed (e.g. a hero image or a zoomed detail view) — means the cached bitmap upscales, producing soft or pixelated output where a size-aware re-render at the real display size and screen scale would have been sharp.

Both failure modes come from caching a rasterized bitmap at a size decided independently of where it's displayed. Caching the *encoded bytes* and deferring rasterization to ThinPath at the real layout size and scale is what keeps the memory/sharpness tradeoff where the rest of this library's design puts it.

---

**Maintainer note (remove before publishing):** the project brief asked for Nuke and Kingfisher code samples based on "attached glue code" that described the app's actual integration — that file wasn't provided. Before publishing, add two sections here:

- **Nuke**: a custom `ImageDecoding`/`ImageDecoder` conformance that hands back `ImageContainer` wrapping the raw SVG `Data` unmodified (no bitmap decode in the `ImageDecoding` step), plus the call site that runs `parse(data:)` + `ThinPath().render(_:size:scale:)` against the fetched bytes at the view's real size/scale. Flag the exact Nuke version the glue targets — the `ImageDecoding` protocol shape has changed across major Nuke versions.
- **Kingfisher**: a custom `ImageProcessor` (or `CacheSerializer`, depending on where the app's glue hooks in) that similarly passes through encoded bytes and defers rasterization to ThinPath, plus the `KFImage`/`UIImageView` call site. Flag the exact Kingfisher version.

Both sections should be grounded in the actual glue code, not invented API shapes.
