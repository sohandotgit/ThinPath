# ResolutionRules.md — defs / use / symbol / href resolution

Companion to `Sources/SVGRenderer/ReferenceResolver.swift`. Describes how
references resolve over the `id → NodeIndex` table **without deep-copying any
subtree**, cycle detection, `<use>` x/y/width/height, `<symbol>` viewport +
`preserveAspectRatio`, and the inheritance-into-instance rule flagged in
CascadeRules.

The two pure, unit-testable parts — **cycle detection** and **instance coordinate
mapping** — are implemented for real and covered by `ReferenceResolverTests.swift`
(written first). Everything the renderer does with these resolutions lives in
`RenderWalk` (RenderPipeline.md §6).

---

## 1. Everything resolves to an index; nothing is copied

`idMap` (`StringRef → NodeIndex`) is the single id resolver (MemoryModel invariant
4). Every reference — `<use href>`, paint `url(#…)`, gradient/pattern `href`
template, `clip-path`, `mask` — resolves to a `NodeIndex` into the **shared** arena.
Instancing then **re-walks those same nodes** at draw time under a per-instance
transform + inherited style. No shadow subtree is materialized (MemoryModel §4);
instancing 500 icons costs ~500 `Use` structs, not 500 deep copies.

Lookups are tolerant of `.none` (invariant 2 permits unresolved forward/dangling
references): `useTarget`, `paintServerNode`, `templateOf` each prefer a parse-time
pre-resolved index and fall back to `idMap`, returning `.none` if undefined. The
caller decides what an unresolved reference means (skip; apply `PaintFallback`).

---

## 2. Cycle detection (REAL, tested)

SVG forbids a `<use>` referencing itself directly or transitively; a cyclic
instance renders nothing.

`hasUseCycle(startingAt:)` is a **3-colour depth-first search** over the
render-expansion graph, whose edges are:
- **structural containment** — a node → each of its children, and
- **instancing** — a `<use>` → its target.

Colours: **grey** = on the current DFS stack, **black** = finished and proven
acyclic. A grey node reached again is a back edge ⇒ **cycle**. Black nodes are
memoized so shared/diamond reuse (the same target reached by several `<use>`s) is
**not** re-expanded — keeping it O(nodes) and allocation-light rather than
exponential. `documentHasUseCycle()` shares one black set across the whole tree.

Cases pinned by tests:

| Case | Cyclic? |
|---|---|
| `use` → group → rect, no back-reference | no |
| `use #u` with `id=u` (direct self) | **yes** |
| `<g id=g><use href=#g></g>` (targets structural ancestor) | **yes** |
| `#a`→`use #b`, `#b`→`use #a` (mutual) | **yes** |
| one target reached by three `<use>`s (diamond DAG) | no (and no blow-up) |
| `use` → dangling id | no (unresolvable ≠ cyclic) |

Gradient/pattern `href` **template** chains cycle too
(`<linearGradient id=a href=#b>` ↔ `#b href=#a>`); `hasTemplateCycle(startingAt:)`
is a simple visited-set walk since `template` links form a linear chain.

---

## 3. `<use>` x/y/width/height & `<symbol>` viewport (REAL, tested)

`instanceTransform(for:currentViewport:)` returns the transform that places an
instance into the use-site user space:

- **Plain target** (shape/group/path) → `translate(use.x, use.y)`. `width`/`height`
  on `<use>` are **ignored** for non-viewport targets (spec).
- **`<symbol>` or nested `<svg>` target** → establishes a viewport at `(use.x,
  use.y)` sized by the width/height precedence below, then:
  - with a `viewBox` → `ViewportMath.viewportTransform(viewBox:viewport:par:)`
    (reuses Transforms.swift), which **folds in both** the placement translate and
    the viewBox→viewport alignment;
  - without a `viewBox` → just the placement translate (content is in viewport
    coordinates).

**Width/height precedence** (`resolveLength`): explicit `value` on the `<use>` wins;
else a `value` on the target's own `width`/`height`; else `auto` = **100% of the
current viewport** dimension. `instanceViewportRect(...)` returns the rect the
`slice`/`overflow:hidden` clip is applied to.

Cases pinned by tests: plain target = translate only; symbol `viewBox 0 0 10 10`
into a 20×20 use = uniform scale 2; `auto` sizing falls back to the current
viewport; non-zero `use.x/y` translates the placement.

`<symbol>`/nested-viewport **composition** (which `preserveAspectRatio` wins when
viewports nest, `slice` overflow clip ordering vs `clip-path`, percentage basis)
follows the plain matrix-composition rule and is the open question tracked in
CoordinateNotes.md §4 — this resolver supplies the per-instance building block; the
walk composes them onto the state stack (RenderPipeline §3/§6).

---

## 4. Inheritance into the instance (CascadeRules §6)

The **style** side of instancing is owned by `StyleResolver`
(`TODO(use-instancing)`), not duplicated here. The rule both files agree on:

```
useStyle     = styleResolver.resolve(useNode, inheriting: outer)   // style AT the use site
instanceRoot = styleResolver.resolve(target,  inheriting: useStyle)
```

1. The instanced target inherits from the computed style **at the `<use>` site**,
   not from the target's original document parent.
2. Properties **specified on the target** still win — instancing changes only
   *inherited* values.
3. Presentation attributes on `<use>` thus act as inheritable **defaults** for the
   instance.
4. `width`/`height` on `<use>` apply only to `svg`/`symbol` targets (§3).
5. `currentColor` in the instance resolves against the `color` computed at the use
   site (corollary of 1).

This is **why the resolver is stateless and never caches computed style on nodes**:
the same target must resolve under many different use-site contexts. `RenderWalk`
does the composition — it already holds the `<use>` node's resolved `style` and
passes it straight down as the target's inherited context (RenderPipeline §6), so no
extra machinery is needed and, critically, no node is copied.

---

## 5. What this resolver does NOT do

- It does not render (that is `RenderWalk` + the visitor).
- It does not fold gradient/pattern template **attributes**/stops — only follows the
  `template` link and guards its cycle; attribute inheritance is a paint-time concern
  (Compositing.md §4–§5).
- It does not deep-copy, expand, or mutate the arena (MemoryModel invariant 1).
