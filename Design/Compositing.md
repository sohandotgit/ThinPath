# Compositing.md — Paint servers & coordinate mapping

Companion to `Sources/ThinPath/PaintServer.swift`. Covers the paint-server
protocol (solid / linear / radial gradient / pattern), the coordinate mapping for
`objectBoundingBox` vs `userSpaceOnUse` plus `gradientTransform`/`patternTransform`,
how patterns tile via `CGPattern` callbacks (**not** a giant bitmap), and how
`spreadMethod` reflect/repeat is realized. Memory-sensitive items are tagged
**PROFILE-CHECK**.

---

## 1. Naming: `PaintServer` (IR) vs `PaintSource` (render)

The IR already has a `PaintServer` **value** (SVGModel.swift): an `id`+`node`
*reference* to a `<linearGradient>`/`<radialGradient>`/`<pattern>` element, stored
once and shared by every element that paints with it (a gradient used by 10 000
shapes exists once — MemoryModel §2).

The render side is the protocol **`PaintSource`**: a thing that can *install paint*
into a `CGContext`. `PaintResolver.resolve(_:references:)` turns a resolved
`ComputedStyle` paint into a `PaintSource` (`SolidPaint` / `GradientPaint` /
`PatternPaint`), or `nil` (nothing to paint). Distinct names, distinct jobs; no
copying of the server node ever happens.

---

## 2. The paint-server protocol

```swift
protocol PaintSource {
    func fill(path: CGPath, rule: FillRule, objectBounds: CGRect,
              alpha: CGFloat, into context: RenderContext)
}
```

The caller has resolved geometry (fill path, or the stroked-outline path for a
stroke) and the fill/stroke **alpha** (the opacity split from CascadeRules §4 is
applied by the caller — `fill-opacity` for a fill, `stroke-opacity` for a stroke;
group `opacity` is handled by the pipeline's isolation layer, never here).
`objectBounds` is the element's **geometry** bbox (stroke excluded), needed only for
`objectBoundingBox` units.

- **`SolidPaint`** — the cheap case: `setFillColor(color × alpha)`, add path, fill.
  No clip, no layer, no coordinate mapping.
- **`GradientPaint`** / **`PatternPaint`** — clip to the path, then draw the
  gradient/pattern under the mapped coordinate system (§3–§5).

---

## 3. Coordinate mapping (the part that silently mis-places everything)

A paint server is authored in its own coordinate space and must be mapped into the
**user space of the element being painted**. Two selectors combine:

### units

- **`userSpaceOnUse`** — the server's coordinates are in the user space in effect
  **where the server is referenced** (the filled element's user space), *not* where
  the server element is defined. Units matrix = **identity**.
- **`objectBoundingBox`** — coordinates are fractions of the element's bounding box.
  Units matrix = `ObjectBoundingBox.transform(objectBounds)` (maps the unit square
  `[0,1]²` onto the bbox). **Degenerate (zero-area) bbox → paint absent** (spec), so
  the mapping returns `nil` and the element is left unpainted rather than dividing by
  zero.

### server transform

`gradientTransform` / `patternTransform` post-multiplies in the server's own space.

### combined

`PaintCoordinateSpace(units:serverTransform:objectBounds:)` yields the single
`serverToUser` matrix (row-vector `p' = p · M`):

```
M = serverTransform · unitsMatrix      // userSpaceOnUse: unitsMatrix = identity
```

For a gradient, map its geometry endpoints (linear `x1,y1→x2,y2`; radial centre /
focus / `r`) through `serverToUser` and hand CG **user-space** points. Both the
mapping and its degenerate-bbox handling are unit-tested
(`ReferenceResolverTests` → `PaintCoordinateSpace…`, `ObjectBoundingBox…`), because
this is pure value math that is cheap to fix and expensive to get subtly wrong.

`ObjectBoundingBox.transform` is the **shared** bbox mapping — gradients, patterns,
`clipPath`(`clipPathUnits`), and `mask`(`maskUnits`/`maskContentUnits`) all route
through it, so the objectBoundingBox rule lives in exactly one tested place.

---

## 4. Patterns tile via `CGPattern` callbacks (NOT a bitmap)

The memory decision: a `<pattern>` is realized with **`CGPattern`**, whose
`drawPattern` callback Core Graphics invokes **once per tile cell** it needs to
fill. We re-walk the pattern's child subtree (a nested `RenderWalk` into a
tile-local context) inside that callback. Result: **one tile's worth of drawing**,
reused across the entire fill region — never a pre-rendered
region-sized-or-larger bitmap.

Steps (`PatternPaint.fill`, TODO(render-thread) bodies):
1. Resolve the effective `Pattern` by folding the `href` `template` chain
   (cycle-guarded via `ReferenceResolver.hasTemplateCycle`).
2. **Tile rect** from `(x,y,width,height)` mapped by `patternUnits`
   (objectBoundingBox → `ObjectBoundingBox.transform(objectBounds)`).
3. **Content matrix** from `patternContentUnits` + optional `viewBox`/
   `preserveAspectRatio` (`ViewportMath`) positions the children within one tile
   — see §4a for the exact units rule; it is the step that has already caused a
   multi-GB incident when wrong.
4. Build the `CGPattern` (callback re-walks children per cell); compose
   `patternTransform` into the pattern matrix; set as fill pattern; clip to the
   fill path; fill.

The tile callback's `RenderContext` is seeded with the tile's **device-space**
rect as `dirtyRect`/`clipDeviceBounds` (`tileBounds` × the pattern matrix).
`dirtyRect` is device-space *by contract*; seeding it with the pattern-space
tile rect (1×1 for a bbox-fractional tile) silently disables every
device-space clamp inside the cell — layer sizing, ImageRenderer's resample
bound.

- **PROFILE-CHECK (pattern-tile-memory):** the callback must draw **vector** content
  per cell; confirm we do not accidentally snapshot the tile to an oversized
  intermediate. A tile with its own group-opacity/mask will itself trigger an
  isolation layer *per cell* — clamp that layer to the tile cell (RenderPipeline §5),
  and profile pathological small-tile-over-large-area fills.
  *Realized once* (2026-07, `hotel_offer_bg_img1.svg`) via the §4a units bug:
  the oversized intermediate was ImageRenderer's resample buffer, sized from a
  content matrix that inflated the tile's children by bboxW × bboxH. Guarded
  since by ImageDecodeNotes §3b's visible-region bound; regression-tested in
  `PatternImageMemoryTests`.

### 4a. Pattern content units — the four combinations

`patternUnits` and `patternContentUnits` are **independent** selectors. The tile
callback draws in *pattern space* (the space `tileBounds` and the `CGPattern`
matrix are expressed in — bbox-fractional when `patternUnits` is
objectBoundingBox). The children are authored in the space `patternContentUnits`
implies (a `viewBox` overrides this entirely), so the content matrix is
`contentSpace → userSpace → patternSpace`:

| `patternContentUnits` | `patternUnits` | content matrix |
|---|---|---|
| userSpaceOnUse | userSpaceOnUse | identity |
| objectBoundingBox | userSpaceOnUse | `ObjectBoundingBox.transform(bbox)` |
| userSpaceOnUse | objectBoundingBox | `ObjectBoundingBox.transform(bbox)⁻¹` |
| objectBoundingBox | objectBoundingBox | **identity** |

The last row is the trap, and it is the *common* real-world case (Figma-style
exports: `patternUnits` left at its objectBoundingBox default,
`patternContentUnits="objectBoundingBox"`, content pre-scaled to fractions by a
`<use transform="scale(~1/imageSize)">`). Pattern space is already
bbox-fractional there; applying the bbox transform to the content *again*
scales every tile child by bboxW × bboxH. In the incident file that inflated an
embedded image's device fit rect to ~178,800 × 80,000 px on a 592×400 render —
a ~57 GB resample buffer (observed as unbounded growth to ~40 GB, then a
crash). The rule lives in one tested place,
`PatternRenderer.contentUnitsMatrix`, with all four combinations pinned by
`PatternImageMemoryTests`.
- **PROFILE-CHECK (pattern-of-pattern / pattern-of-use):** nested paint servers and
  `<use>` inside a tile re-enter the walk; confirm depth is bounded and cheap.

---

## 5. `spreadMethod` reflect / repeat

Core Graphics gradients natively support only **pad**
(`drawsBeforeStartLocation`/`drawsAfterEndLocation` extend the end colours). So:

- **`pad`** → draw as-is; let CG pad.
- **`reflect`** → synthesize an extended stop array that **mirrors** the 0→1 stop
  ramp across successive periods.
- **`repeat`** → synthesize an extended stop array that **repeats** the ramp across
  successive periods.

Crucially, the extension covers **only the periods that intersect the current
clip ∩ dirty region** (`GradientPaint.realizedSpreadStops(_:spread:visiblePeriods:)`),
so synthetic-stop count scales with **what is on screen**, not the canvas or the
infinite gradient plane.

- **PROFILE-CHECK (spread-stops):** a gradient whose period is tiny relative to a
  large visible extent produces many synthetic stops. Confirm the visible-period
  count is derived from clip ∩ dirty (not the full canvas) and that synthetic-stop
  count has a sane hard cap (fall back to `pad`-like behaviour past the cap).

---

## 6. Mask / offscreen memory — PROFILE-CHECK items

Masks are the compositing feature most likely to blow the memory budget, because a
`mask` forces (a) an isolation layer for the masked element (RenderPipeline §4 case
3) **and** (b) a place to render the mask content itself:

- **PROFILE-CHECK (mask-scratch):** the mask's luminance/alpha is built by rendering
  the mask subtree, converting to a single-channel mask image, then
  `clip(to:mask:)` or a multiply. That mask surface **must** be clamped to the
  masked element's clamped layer bounds (RenderPipeline §5), **not** the canvas.
  Confirm the mask bitmap and the element layer are the *same* clamped size and are
  both released the instant the layer is composited.
- **PROFILE-CHECK (mask-color-space):** a luminance mask needs a defined luminance
  coefficient + colour space; a wrong space is a correctness bug, an unnecessarily
  wide space is a memory bug. Pin both against a reference renderer.
- **PROFILE-CHECK (nested-mask):** mask-inside-mask multiplies scratch surfaces;
  the `maxLayerDepth` guard applies, but profile the realistic worst case.

---

## 7. Resolution & fallbacks

`PaintResolver.resolve`:
- `.none` / stray `.currentColor` (should be concretized by StyleResolver) → `nil`.
- `.color` → `SolidPaint`.
- `.server(ref, fallback)` → resolve `ref` via `ReferenceResolver`; if it targets a
  `gradient`/`pattern`, build that; otherwise (unresolved, or points at a non-server)
  apply the `PaintFallback` (`.color` → solid; `.none`/`.explicitNone` → nothing).

**PROFILE-CHECK (paint-alloc):** a `PaintSource` value is produced per painted
element per pass. Confirm it stays enum/stack-cheap; if the existential churns the
heap on large documents, return a concrete enum instead.
