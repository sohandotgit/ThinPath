# CoordinateNotes.md — Transform & viewport coordinate math

Companion to `Sources/ThinPath/Transforms.swift`. Records the conventions,
the composition-order derivation (easy to get backwards), the viewBox /
preserveAspectRatio equations, and the open question for nested viewports.

---

## 1. Conventions

- **Coordinate system:** SVG user space is **y-down** (origin top-left), which
  matches `CGAffineTransform` applied to points. We keep everything in SVG user
  space; any y-flip for a specific `CGContext` is a render-time concern, not here.
- **Matrix convention:** `CGAffineTransform` uses **row vectors**: a point is
  transformed as `p' = p · M`. `X.concatenating(Y)` yields `X · Y`, i.e. "apply
  X, then Y".
- **Angles:** SVG transform angles are in **degrees**; we convert to radians for CG.
- **Identity is free:** an absent transform is `TransformRef == -1` (not stored in
  the transform arena), so the common no-transform element costs nothing.

---

## 2. Composition order (the part that's easy to reverse)

SVG establishes **nested coordinate systems left-to-right**. For
`transform="A B C"`:

- The **leftmost** primitive (`A`) is the **outermost** coordinate transform.
- A local point is transformed by the **rightmost first** (`C`), then `B`, then `A`.
- Effect on a point: `p' = p · Mc · Mb · Ma` (row-vector convention).

To build that with CG while iterating the list **in written order**, we
**pre-concatenate**:

```swift
result = primitive.concatenating(result)   // for each primitive, left to right
```

After processing `A` then `B`, `result = B.concatenating(A) = Mb · Ma` — B applies
before A, exactly as required. Folding the other way
(`result = result.concatenating(primitive)`) is the classic bug: it makes the
first-listed transform apply *first*, which is wrong.

**Verified by test** `CoordinateMathTests.testCompositionOrderScaleThenTranslate`:
`translate(10,0) scale(2)` maps local `(5,0)` → `(20,0)` (scale first, then
translate), not `(30,0)`.

### Primitive matrices

| Primitive | Matrix / construction |
|---|---|
| `matrix(a b c d e f)` | `CGAffineTransform(a,b,c,d,tx:e,ty:f)` |
| `translate(tx [ty])` | `ty` defaults to 0 |
| `scale(sx [sy])` | `sy` defaults to `sx` |
| `rotate(a)` | rotation by `a°` |
| `rotate(a cx cy)` | `translate(cx,cy) · rotate(a) · translate(-cx,-cy)` — center is a fixed point (tested) |
| `skewX(a)` | `c = tan(a)` |
| `skewY(a)` | `b = tan(a)` |

Malformed lists (bad arg counts, unknown primitive, unbalanced parens) return
`nil`; the **caller** decides drop-as-identity vs. fail-the-parse.

---

## 3. viewBox + preserveAspectRatio → viewport matrix

`ViewportMath.viewportTransform(viewBox:viewport:par:)` maps content authored in
`viewBox` coordinates into a target `viewport` rectangle.

Base scales:

```
sx = viewport.width  / viewBox.width
sy = viewport.height / viewBox.height
```

- **`align == none`** → non-uniform: keep `sx`, `sy` independently; the content
  stretches to exactly fill the viewport (tested `…NoneStretches`).
- **`align != none`** → **uniform** scale `s`:
  - `meet`  → `s = min(sx, sy)` — entire viewBox visible, letterboxed
    (tested `…MeetLetterboxesAndCenters`).
  - `slice` → `s = max(sx, sy)` — viewBox covers the viewport; overflow is clipped
    **by the caller** (this function does not clip) (tested `…SliceCoversAndOverflows`).

Translation:

```
tx = viewport.minX − viewBox.minX · s      (+ alignment slack in x)
ty = viewport.minY − viewBox.minY · s      (+ alignment slack in y)
```

Alignment distributes the leftover space `extra = viewport.size − viewBox.size · s`
(≥ 0 for `meet`, ≤ 0 for `slice`):

| token | x/y offset added |
|---|---|
| `Min` | `0` |
| `Mid` | `extra / 2` |
| `Max` | `extra` |

(tested `…AlignMaxCornerPlacement`.)

**Degenerate viewBox** (zero/negative width or height) or zero-size viewport →
returns `.identity`. Per spec such an element disables rendering; the caller should
treat identity-from-degenerate as "don't render this viewport's content" (tested
`…DegenerateViewBoxIsIdentity`). *Consider surfacing this as an explicit optional
return if callers need to distinguish "identity because degenerate" from "identity
because it genuinely maps 1:1" — noted as a possible small API refinement.*

---

## 4. OPEN QUESTION — nested viewports (`<svg>` / `<symbol>`) — for the reference-resolution thread

How `preserveAspectRatio` **composes across nested viewports** is deferred to the
thread that implements `<use>` / `<symbol>` / nested `<svg>` reference resolution.
The unresolved points:

1. **`<symbol>` sizing via `<use>`.** A `<symbol>` has no intrinsic position; it is
   given a viewport by the `<use>` that instances it (`use.width`/`use.height`, with
   `auto` defaulting to `100%` of the *nearest* viewport). The precedence when both
   `<use>` and `<symbol>` (and a wrapping `<svg>`) specify sizing/`preserveAspectRatio`
   needs to be pinned down against the spec and a reference renderer.

2. **Which `preserveAspectRatio` wins.** When an inner `<svg>`/`<symbol>` has its own
   `preserveAspectRatio` *and* is placed inside an outer viewport that also aligned
   its content, the two alignment matrices simply **compose** (outer viewport matrix ·
   inner viewport matrix). Confirm there is no special-casing beyond plain matrix
   composition, and decide where clipping for a `slice` inner viewport is applied
   (each viewport establishes its own clip rectangle).

3. **`overflow` and clipping.** Nested viewports clip to their viewport rect by
   default (`overflow: hidden`). The clip stack interaction with `slice` overflow and
   with element `clip-path` needs a defined order.

4. **Percentage resolution basis.** Percentages inside a nested viewport resolve
   against **that** viewport's dimensions (or the diagonal for some properties), not
   the root's. The reference-resolution thread must thread the current viewport size
   through so lengths resolve against the right basis.

None of these change the single-viewport math in §3; they are about *stacking*
viewports, which this layer intentionally leaves to the later thread. The primitives
here (per-viewport matrix, composition rule in §2) are the building blocks it will
compose.
