# CascadeRules.md — Computed-style resolution

Companion to `Sources/SVGRenderer/StyleResolver.swift`. Describes how a per-element
`RawStyle` (presentation attributes + inline `style=""`) becomes a fully-resolved
`ComputedStyle`, which properties inherit, and the deferred / tricky bits.

---

## 1. Inputs and where they come from

Each element contributes a `RawStyle` (in `SVGModel.swift`) that is the merge of:

1. **Presentation attributes** — e.g. `fill="red"`, `stroke-width="2"`.
2. **The inline `style=""` declaration block** — e.g. `style="fill:red;opacity:.5"`.

Precedence: **inline `style` wins over presentation attributes** (inline style has
higher CSS specificity). The parser folds both into one `RawStyle`, applying that
precedence, so the resolver never sees the two sources separately.

A `RawStyle` field is **optional**. `nil` means "not specified on this element",
which is exactly the signal the cascade needs to distinguish *inherit* from
*explicitly set*.

---

## 2. The resolution algorithm

`StyleResolver.resolve(_ raw:, inheriting parent:)` produces a `ComputedStyle`
where every property is concrete. For each property:

- **Inheritable & unspecified** → take the **parent's computed value**.
  (CSS inherits *computed* values, not specified ones — hence the parent argument
  is a `ComputedStyle`, not a `RawStyle`.)
- **Non-inheritable & unspecified** → take the property's **initial value**
  (`ComputedStyle.initial`).
- **Specified** → use the specified value (after `currentColor` resolution and
  clamping).

The root element is resolved `inheriting: .initial`.

The resolver **does not mutate the IR** and **does not cache** computed style on
nodes. It returns the computed style to the caller, which threads it down the walk.
This is deliberate — see §5 (`<use>`).

---

## 3. Property inheritance table

| Property | Inherits? | Initial | Notes |
|---|---|---|---|
| `fill` | ✅ | `black` | paint |
| `stroke` | ✅ | `none` | paint |
| `stroke-width` | ✅ | `1` | |
| `color` | ✅ | `black` | feeds `currentColor`; resolved first |
| `fill-opacity` | ✅ | `1` | alpha of fill paint only |
| `stroke-opacity` | ✅ | `1` | alpha of stroke paint only |
| **`opacity`** | ❌ | `1` | **group/element** opacity; isolates. See §4 |
| `fill-rule` | ✅ | `nonzero` | |
| `clip-rule` | ✅ | `nonzero` | applies inside `clipPath` geometry |
| `stroke-linecap` | ✅ | `butt` | |
| `stroke-linejoin` | ✅ | `miter` | |
| `stroke-miterlimit` | ✅ | `4` | |
| `stroke-dasharray` | ✅ | none | |
| `stroke-dashoffset` | ✅ | `0` | |
| `font-family` | ✅ | UA default | |
| `font-size` | ✅ | `16` (medium) | |
| `font-weight` | ✅ | `400` | |
| `font-style` | ✅ | `normal` | |
| `text-anchor` | ✅ | `start` | |
| `visibility` | ✅ | `visible` | |
| `display` | ❌ | `inline` | `none` prunes the subtree from rendering |
| `clip-path` | ❌ | none | applies to this element only |
| `mask` | ❌ | none | applies to this element only |
| `filter` | ❌ | none | (not modeled yet) |

---

## 4. The opacity split (a common source of wrong output)

SVG defines **three independent opacities**; collapsing them produces visibly wrong
results wherever fill and stroke overlap or where a group is semi-transparent:

- **`opacity`** (→ `ComputedStyle.groupOpacity`): element/group opacity. The element
  is composited as an **isolated group** at this alpha *after* its fill and stroke
  are combined. It is **non-inherited** — it applies to the element it is set on,
  and a child starts fresh at `1`.
- **`fill-opacity`** (→ `fillOpacity`): alpha applied to the **fill paint only**.
  **Inherited.**
- **`stroke-opacity`** (→ `strokeOpacity`): alpha applied to the **stroke paint
  only**. **Inherited.**

Why keeping them separate matters: a shape with a semi-transparent fill *and* a
semi-transparent stroke that overlap must show the fill through the stroke overlap
region blended correctly, which a single combined alpha cannot express. Group
opacity additionally requires *isolation* (render to a transient layer, then
composite) — it is not the same as multiplying fill/stroke alpha.

All three are clamped to `0...1` at resolution time.

---

## 5. `currentColor`

`currentColor` resolves to the computed value of the `color` property. Because
`color` is inheritable, the resolver computes `color` **first**, then substitutes
it wherever `fill`/`stroke` is `currentColor`.

Subtlety (handled): once a paint is inherited as a concrete color, it is **not**
re-resolved against a descendant's different `color`. Inheritance carries *computed*
values, so an inherited `currentColor` was already concretized on the ancestor that
specified it. Only an element that *itself* writes `fill="currentColor"` picks up
its own `color`.

---

## 6. Known-tricky: inheritance across `<use>` / `<symbol>` shadow trees — DEFERRED

`<use>` is not implemented yet; a later thread will. The intended rule (also captured
as `TODO(use-instancing)` in `StyleResolver.swift`) is:

1. The instanced shadow tree inherits from the **`<use>` element's own computed
   style**, *not* from the target's original parent in the document. So the target's
   root is resolved `inheriting: resolve(useNode, …)` — the style computed **at the
   `<use>` site**.
2. Properties **specified on the target** (and its descendants) still win over that
   inherited context. Instancing changes only *inherited* values.
3. Presentation attributes on `<use>` therefore act as inheritable **defaults** for
   the instance, overridable inside the target.
4. `width`/`height` on `<use>` apply only when the target is `<svg>`/`<symbol>`
   (viewport establishment — see CoordinateNotes.md), never to plain shapes.
5. `currentColor` inside the instance resolves against the `color` computed at the
   `<use>` site (a corollary of rule 1).

**This is the reason the resolver is stateless and never caches computed style on
nodes**: the same target node must be resolvable under many different inherited
contexts — one per `<use>` that references it. Intended entry point:

```swift
func resolveInstanceRoot(target:, at useNode:, inheriting outer:) -> ComputedStyle {
    let useStyle = resolve(useNode, inheriting: outer) // style at the use site
    return resolve(target, inheriting: useStyle)       // target inherits from it
}
```

Cycle safety (a `<use>` chain revisiting an ancestor) belongs to the instancing
thread; the resolver is stateless and will not detect it.

---

## 7. Deferred: full CSS selector matching

**Out of scope** for this layer: `<style>` sheets, class/type/id/descendant/
attribute selectors, specificity ordering, `!important`, and the UA stylesheet.

How it slots in without disturbing the above: a future `StyleSheet` pass matches
selectors against elements, orders the matched declarations by
`(origin, specificity, source order, !important)`, and folds the winners into each
element's `RawStyle` **before** `resolve` runs. Because the resolver is agnostic to
*how* a `RawStyle` was populated, selector support attaches at the `SELECTOR-HOOK`
marker in `StyleResolver.swift` with **no change to the inheritance logic** here.

Open question for that thread: presentation attributes have specificity 0 (below any
selector), while inline `style` beats normal selectors — the fold must preserve
those two facts. The current parser-side merge already puts inline `style` above
presentation attributes, which is the correct starting point.
