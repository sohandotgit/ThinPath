# MemoryModel.md — Rationale for the SVG IR memory design

Companion to `Sources/SVGRenderer/SVGModel.swift`. This document explains *why*
the IR is shaped the way it is, what is deliberately **not** retained, how large
subtrees stay cheap, and which assumptions a later profiling pass must confirm.

Every unverified assumption is tagged **PROFILE-CHECK** so it can be grepped.

---

## 1. The one-sentence thesis

A parsed SVG is a handful of contiguous `Array`s of small value types, with all
structure expressed as integer indices — not a graph of heap-allocated,
ARC-retained node classes. This makes documents cache-dense, cheap to release,
and cheap to *reference* (instancing, paint servers) without copying.

---

## 2. What we intentionally do NOT retain

| Not retained | Instead | Why |
|---|---|---|
| A class per node (`class SVGNode`) | `struct SVGNode` in a flat `[SVGNode]` arena | No per-node heap allocation, no ARC traffic on tree walks, no retain cycles. Releasing a document is a few `Array` deallocations, not a recursive teardown of thousands of objects. |
| Parent/child *object pointers* | `NodeIndex` (Int32) links: `parent`, `firstChild`, `nextSibling` | Intrusive index links cost 12 bytes and never allocate. A subtree walk touches only `nodes`. |
| Per-node child *arrays* (`[NodeIndex]`) | first-child / next-sibling intrusive list | An owned array per node is a heap allocation per node. The intrusive list has zero auxiliary allocations regardless of fan-out. |
| Embedded paint servers on each shape | `Paint.server(PaintServer)` storing an id + resolved index | A gradient shared by 10 000 shapes exists **once**. Shapes reference it; they never copy stops or geometry. |
| Expanded `<use>` shadow trees | `Use { href, resolved }` — a reference only | Instancing 500 copies of an icon costs ~500 `Use` structs, not 500 deep-copied subtrees. Expansion (if ever needed) happens transiently at render time, not in the retained model. See §4. |
| Decoded image bitmaps | `Image { href }` — an interned href string | Decoding at parse time would pin full-resolution bitmaps in memory for the document's whole life. Decoding is deferred to render time at the *target* scale (a core project constraint). |
| Center-parameterized arcs | `ArcTo` raw endpoint params, as authored | Keeps the IR a faithful, compact record; avoids computing center/sweep we may re-derive at a different flatten scale anyway. |
| Duplicated id / href / font strings | `StringPool` interning → `StringRef` (Int32) | SVGs repeat ids, classes, hrefs, font names heavily; store each unique string once. |
| Resolved computed styles on nodes | Computed on the fly by `StyleResolver`, threaded through the walk | The same node must resolve under different inherited contexts (each `<use>` site). Caching computed style on the node would break instancing and bloat the model. See CascadeRules.md. |
| Foundation `Scanner` / regex machinery | A tiny private `MiniScanner` | Avoids per-token `String`/`NSString` bridging allocations in hot parse paths. |

---

## 3. Why large subtrees stay cheap

- **Contiguity.** All nodes of a document live in one `[SVGNode]`. A depth- or
  breadth-first walk is a linear scan over cache-friendly memory; there is no
  pointer chasing across the heap.
- **O(1) structural references.** "This `<use>` points at that `<symbol>`" is one
  `Int32`. Deduplicated definitions (gradients, patterns, symbols) are pointed at,
  never copied.
- **Fixed-size nodes.** Variable-length payloads (path commands, polygon points,
  gradient stops) live in *side arenas* (`pathCommands`, `points`,
  `gradientStops`); a node stores only an `ArenaRange` (start, count) window. So
  `SVGNode` stays a small fixed-size value and a `path` with 10 000 commands does
  not enlarge the node — it enlarges one shared arena by a contiguous run.
- **Single-move release.** Dropping the `SVGDocument` frees the arenas directly;
  there is no recursive ARC teardown proportional to node count.
- **Cheap copies where needed.** Because everything is value types + indices, a
  transient sub-view (e.g. for a render tile) can be described by index ranges
  without deep-copying nodes.

---

## 4. `<use>` / instancing and memory

`<use>` is stored as a *reference* (`Use.resolved` / `href`), never as an expanded
copy. This is the single biggest memory lever for icon-font-style documents that
reuse one shape thousands of times.

Consequence for a later thread: instancing must be handled at **traversal /
render** time by resolving the target and re-resolving style under the `<use>`
site's inherited context (see the `TODO(use-instancing)` in `StyleResolver.swift`).
The retained model stays flat and small; only the transient render walk sees the
"expanded" tree, and only for the nodes actually being drawn.

**PROFILE-CHECK (use-expansion cost):** confirm that on-the-fly instancing at
render time does not create a CPU hotspot for pathological reuse (e.g. `<use>` of
a `<g>` of many `<use>`s). If it does, consider a bounded, evicting expansion
cache — but do **not** move expansion into the retained model.

---

## 5. Numeric precision & packing choices

- **`RGBA` is packed 8-bit/channel (4 bytes)** rather than four `CGFloat`s (32
  bytes). Gradient stop arrays and per-element colors are the most-repeated
  numeric payloads.
  - **PROFILE-CHECK (color depth):** 8-bit/channel is fine for sRGB display but
    loses wide-gamut / ICC-tagged color and precise gradient interpolation. If we
    later target Display-P3 or high-precision gradients, revisit whether stops
    need float components or a color-space tag.
- **Geometry uses `CGFloat` (Double on 64-bit)** to match Core Graphics and avoid
  conversion noise in the coordinate math.
  - **PROFILE-CHECK (Float geometry):** for very large documents, storing path
    points as `Float`/`SIMD2<Float>` could roughly halve the geometry arenas.
    Measure whether precision at typical zoom is acceptable before switching; CG
    APIs would then need conversion at the boundary.
- **Indices are `Int32`.** Halves the size of the many cross-links vs. `Int`.
  - **PROFILE-CHECK (index width):** documents are assumed < 2^31 nodes /
    arena elements. Validate against the largest real inputs; widening is a
    one-line typealias change but doubles link footprint.

---

## 6. Assumptions a profiling pass MUST verify

Consolidated **PROFILE-CHECK** list:

1. **use-expansion cost** — on-the-fly `<use>` instancing is not a render hotspot
   (§4).
2. **color depth** — 8-bit `RGBA` is sufficient; no wide-gamut/gradient banding
   regressions (§5).
3. **Float geometry** — whether `Float`/`SIMD` geometry is worth the precision
   trade for large documents (§5).
4. **index width** — `Int32` indices never overflow on real inputs (§5).
5. **StringPool dictionary overhead** — the interner's `[String: StringRef]`
   lookup dictionary is itself retained for the document lifetime. Confirm its
   overhead is dwarfed by the dedup savings; if the pool is only needed during
   parsing, consider dropping the reverse `lookup` map post-parse and keeping only
   the `[String]` storage.
6. **side-arena slack** — arenas grown by `append` may hold up to ~2× capacity
   slack. Confirm whether a post-parse `reserveCapacity`/shrink pass is worth it
   for long-lived documents.
7. **node struct size** — confirm `SVGNode`'s in-memory size (enum payload +
   links + `RawStyle`) stays small; `RawStyle` carries many optionals and is the
   most likely bloat source. If it dominates, move `RawStyle` into its own side
   arena referenced by index (mirrors the transform arena pattern).

---

## 7. Non-goals at this layer (so they don't accidentally get "optimized" in)

- No rendering, rasterization, or CGContext work.
- No image decoding.
- No CSS selector engine (see CascadeRules.md § Deferred).
- No `<use>` expansion in the retained model.
- No center-form arc conversion, path flattening, or dashing geometry — those are
  render-time transforms of this IR, not part of it.
