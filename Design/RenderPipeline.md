# RenderPipeline.md — Traversal-and-draw architecture

Companion to `Sources/ThinPath/RenderContext.swift`. Explains the render
walk, the explicit state stack, and — the memory-critical decision — exactly when
an offscreen layer is unavoidable and how its backing store is clamped so it never
allocates the full canvas.

Every unverified assumption is tagged **PROFILE-CHECK** (grep-able, same convention
as MemoryModel.md).

---

## 1. Thesis

Render is a **single depth-first walk over the flat node arena** that draws
**directly into the caller's `CGContext`**. Transform, clip, and opacity are held
on an **explicit stack kept in lock-step with CGContext `saveGState`/`restoreGState`**.
No retained render tree, no scene graph, no per-node draw objects — the arena *is*
the scene, and the walk is transient. Offscreen bitmaps are the enemy of the memory
budget, so they are established **only when SVG semantics leave no alternative**, and
even then **clamped to the visible region**.

---

## 2. The two pieces

| Piece | Type | Owns |
|---|---|---|
| `RenderContext` | `final class` | the target `CGContext`, the explicit `frames` stack, the dirty rect, layer-depth guard, and handles to the style resolver / reference resolver / image cache. All the hard decisions (`needsIsolationLayer`, `beginIsolationLayer`). |
| `NodeVisitor` | `protocol` | the leaf-render seam. Traversal hands it an element whose CTM/clip/layer are already configured; it emits the CG draw calls. |
| `RenderWalk<V>` | `struct` | the DFS spine (`render(_:inheriting:)`): resolves style, pushes transform/clip, decides isolation, dispatches, recurses. |

### Why `RenderContext` is a class

We are driving an imperative, stateful `CGContext`. Threading value-type state via
`inout` through a recursive walk would fight that and make it easy to desync the
tracked state from the context's real gstate. A class with an explicit `frames`
array mutated in exact correspondence with `saveGState`/`restoreGState` keeps the
two stacks provably parallel — `save()` pushes both, `restore()` pops both.

### Why keep an explicit stack *alongside* CGContext's own

CGContext already stacks gstate. We duplicate a **minimal** frame
(`userToDevice`, `clipDeviceBounds`, `viewport`) because to size an offscreen
layer we need the **device-space** bounds of the current clip, and CGContext only
exposes clip bounds in **user** space (`boundingBoxOfClipPath`). Tracking
`userToDevice` + a running `clipDeviceBounds` lets `beginIsolationLayer` clamp in
O(1) without round-tripping through the context. Nothing else is duplicated — paint
state, line attributes, etc. live only in CGContext.

---

## 3. The per-node contract (`RenderWalk.render`)

Read `render(_:inheriting:)` top-to-bottom; it is the whole renderer in miniature:

1. **Resolve style** for the node from the parent's computed style
   (`StyleResolver`, threaded — never cached on the node, so `<use>` can re-resolve
   under a different context).
2. **Prune** `display:none` (subtree not even walked). `visibility:hidden` still
   walks (descendants may show) but suppresses this element's own paint — a visitor
   concern. Skip kinds that never paint in document flow (`defs`, `clipPath`,
   `mask`, `gradient`, `pattern`, `symbol`); those render only when referenced.
3. `save()`.
4. **Concatenate** the element transform (`TransformRef` → matrix; identity is free).
5. **Apply `clip-path`** as a CGContext clip (never a layer — see §4).
6. **Decide isolation** (`needsIsolationLayer`) and, if required,
   `beginIsolationLayer(elementDeviceBounds:alpha:)`.
7. **Dispatch** by kind: containers recurse (`willEnterContainer` → children →
   `didExitContainer`); shapes/images/text go to the visitor; `<use>` instances by
   reference (§6).
8. **Mask multiply** inside the still-open layer, then `endIsolationLayer()`.
9. `restore()`.

---

## 4. When an offscreen layer is unavoidable (THE RULE)

An offscreen (transparency) layer flattens an element's paint operations so a
**group-level** operation can apply to the *aggregate*. It is established **iff** that
is semantically required — encoded in `RenderContext.needsIsolationLayer`:

1. **Group opacity < 1 on a container** (`group`/`svg`/`symbol`/`use`) with ≥1
   painted descendant. `opacity` multiplies the composited subtree, so children
   must be flattened first, then faded as a unit. Fading each child independently
   would wrongly show overlaps double-faded.
2. **Group opacity < 1 on a shape that paints BOTH fill and stroke.** Where fill and
   stroke overlap, fading each separately double-fades the overlap. **Only** a shape
   with a single contribution (fill-only *or* stroke-only) may fold `opacity` into
   `fill-opacity`/`stroke-opacity` and **skip the layer** — the common cheap path.
3. **A `mask`.** Render the element to a layer, then multiply by the mask's
   luminance/alpha. Not expressible as a CG clip.
4. **An isolated blend** (`mix-blend-mode` ≠ normal / explicit isolation). Not
   modeled yet; the hook is present so it slots in without reshaping the walk.

**Explicitly NOT a layer:**
- `clip-path` → a CGContext clip (a path, or the intersection of the clipPath's
  child geometry). Clipping is free of offscreen memory.
- `opacity == 1`.
- fill-only / stroke-only shape with `opacity < 1` → **folded**, no layer.

This fold (case 2's negative) is the single biggest layer-avoidance lever for
typical icon/illustration content, where the vast majority of elements are a
single-paint shape.

**PROFILE-CHECK (fold-correctness):** confirm the folded single-paint path is
pixel-identical to an isolated layer for representative content; the fold is only
valid when there is exactly one paint contribution.

---

## 5. Clamping the layer to the visible region

`CGContext.beginTransparencyLayer` sizes the layer's backing store from the
context's **current clip bounding box** at the call site. So the clamp is: **tighten
the clip before beginning the layer.**

`beginIsolationLayer(elementDeviceBounds:alpha:)`:

```
clamped = currentClipDeviceBounds ∩ dirtyRect ∩ elementDeviceBounds
if clamped is empty  → skip element entirely (return false, no layer opened)
saveGState()
clip(to: clamped mapped back to user space)   // CG now sizes the layer to `clamped`
setAlpha(alpha); beginTransparencyLayer()
```

Three intersecting bounds, each essential:
- **`dirtyRect`** — the outer clamp. A layer can never exceed what we were asked to
  paint (a tile, an invalidation rect, or the whole output). This alone caps every
  layer at the output size.
- **`currentClipDeviceBounds`** — ancestor clips (viewport `overflow`, `clip-path`)
  already shrink the visible area; the layer inherits that.
- **`elementDeviceBounds`** — the subtree's own extent (`subtreeDeviceBounds`). A
  small faded group inside a large canvas backs only its own box.

If the intersection is empty the element is invisible and is skipped — no layer, no
draw. `elementDeviceBounds == .null` (unknown) is safe: the clamp falls back to
clip ∩ dirty, correct but potentially larger than necessary.

`subtreeDeviceBounds` is the one geometry dependency and is TODO(render-thread). Its
bbox definition **must match** the objectBoundingBox definition used by
`PaintServer` (geometry only, **stroke excluded**, per the SVG bbox rule), and it
should be memoized by `NodeIndex` within a pass (arena is immutable).
**PROFILE-CHECK (bbox-cost):** confirm subtree-bounds is not a hotspot on deep
trees; add the per-pass memo if it is.

**PROFILE-CHECK (layer-depth):** `maxLayerDepth` (default 24) guards runaway nesting
by degrading to non-isolated compositing. Confirm real content never hits it and
that degradation is acceptable when it does.

---

## 6. `<use>` instancing without copying

`<use>` renders **by reference** (`RenderWalk.renderUse`): resolve the target,
`concatenate` the instance transform (`ReferenceResolver.instanceTransform` —
translate for shapes, viewport matrix for symbol/svg), and **re-walk the target's
existing arena nodes** under the use-site inherited style. No subtree is copied
(MemoryModel §4); only the transient walk sees the "expanded" instance.

- **Cycle guard:** `renderUse` calls `references.hasUseCycle` first; a cyclic
  instance renders nothing (SVG rule).
- **Inheritance-into-instance:** the target inherits from the computed style **at
  the use site** (CascadeRules §6), which is exactly the `style` already resolved for
  the `<use>` node — passed straight down as the target's inherited context.
- **PROFILE-CHECK (use-expansion cost):** carried over from MemoryModel §4 — on-the-
  fly instancing must not hotspot for pathological reuse (`<use>` of a `<g>` of many
  `<use>`s). The 3-colour cycle check is O(nodes); the *render* re-walk is the cost
  to watch. Do **not** move expansion into the retained model.

---

## 7. Non-goals at this layer

- No image decoding (deferred to the visitor + `ImageCache` at target scale).
- No text shaping (a `drawText` hook only).
- No blend modes / filters yet (isolation hook reserved).
- No parallel/tiled scheduling decided here — but `dirtyRect` is the seam a tile
  scheduler would drive, and layer clamping already respects it.
