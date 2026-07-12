# CSS `<style>` / Selector Support — Test Spec

**Session:** S6 (CSS design + test spec) · **Model:** Opus · **Status: FROZEN**
**Input:** `Design/css-support.md` (the design — treated as fixed) · **Blocks:** S7 (impl), S8 (review)
**Output on implementation:** `Tests/ThinPathTests/CSSSelectorTests.swift` (correctness) +
`Tests/ThinPathTests/CSSMemoryTests.swift` (allocation/flatness), authored by S7 to match this spec.

This spec is **FROZEN**. Session S7 (implementation) must make every case below pass by implementing
`Design/css-support.md`; it must **not** weaken, delete, or renegotiate an assertion here. If S7
believes a case is wrong, that is a design question routed back through S6/S8, **not** a quiet edit.
Every case cites the design section it pins. Test IDs (`T-C*`, `T-A*`) are stable references used by
`css-support.md` §8 and the S8 review.

Two files, two purposes (mirroring the `PatternImageMemoryTests` / `StyleResolverTests` split
already in the suite):
- **`CSSSelectorTests`** — correctness: selector matching, specificity, cascade vs. inline,
  `!important`, tokenizer edge cases. Known-answer style, like `StyleResolverTests`.
- **`CSSMemoryTests`** — the **decisive allocation/flatness block**. These stand in for a profiling
  session (per phase-plan.md S6/S11 rationale: IR flatness is *deterministic*, so it is asserted, not
  Instruments-profiled). Modeled on `PatternImageMemoryTests`' `phys_footprint` proxy plus structural
  invariants that are exact, not statistical.

All tests parse via the public `parse(data:)` entry point and assert against the returned
`SVGDocument` / `RawStyle` (and, where noted, `StyleResolver`). Colors follow the existing
`RGBA` conventions (`ParsingTests`/`StyleResolverTests`): `red` = `RGBA(255,0,0)`,
`green` = `RGBA(0,128,0)`, `blue` = `RGBA(0,0,255)`.

---

## 1. Test helpers (S7 provides; not part of the frozen assertions)

```swift
// Parse inline SVG text, assert no fatal parse error, return the document.
func doc(_ svg: String) -> SVGDocument

// The first node whose id interns to `id`, via document.idMap + strings. Returns its RawStyle.
func rawStyle(_ document: SVGDocument, id: String) -> RawStyle

// Resolve `id`'s node to a ComputedStyle at the document root context (inheriting: .initial along
// the real ancestor chain). Used only where inheritance interacts with selectors.
func computed(_ document: SVGDocument, id: String) -> ComputedStyle
```
These helpers are test glue — S7 may implement them however is convenient, as long as they do not
weaken what a case asserts.

---

## 2. Correctness — selector matching (`CSSSelectorTests`)

Unless stated, each fixture is a 100×100 root `<svg>` with a `<style>` sheet and shapes carrying
`id`s so the test can address them. Assertions are on the **folded `RawStyle`** (design §5.3), i.e.
what the sheet resolved to on that element.

### T-C1 — type selector
```svg
<svg viewBox="0 0 100 100"><style>rect { fill: red }</style>
  <rect id="r" x="0" y="0" width="10" height="10"/>
  <circle id="c" cx="5" cy="5" r="5"/>
</svg>
```
- `rawStyle(_, "r").fill == .color(red)` — type selector matched the rect.
- `rawStyle(_, "c").fill == nil` — the circle is untouched (fill stays unspecified → resolves to the
  initial black later, but the *raw* fill is `nil`). Pins that a type selector matches only its type.
Pins design §5.2.

### T-C2 — class selector, and multi-class elements
```svg
<svg viewBox="0 0 100 100"><style>.hot { fill: red } .big { stroke-width: 4 }</style>
  <rect id="a" class="hot" .../>
  <rect id="b" class="hot big" .../>
  <rect id="c" class="cold" .../>
</svg>
```
- `a.fill == .color(red)`, `a.strokeWidth == nil`.
- `b.fill == .color(red)` **and** `b.strokeWidth == 4` — both classes applied.
- `c.fill == nil` — non-matching class untouched.
Pins design §4.2 (multi-token `class`) + §5.5 class membership.

### T-C3 — id selector beats class beats type (specificity)
```svg
<svg viewBox="0 0 100 100"><style>
  rect { fill: red }
  .k   { fill: green }
  #t   { fill: blue }
</style>
  <rect id="t" class="k" .../>
</svg>
```
- `rawStyle(_, "t").fill == .color(blue)` — id (1,0,0) > class (0,1,0) > type (0,0,1).
Pins design §5.4.

### T-C4 — source-order tie-break at equal specificity
```svg
<svg viewBox="0 0 100 100"><style>
  .k { fill: red }
  .k { fill: green }
</style>
  <rect id="t" class="k" .../>
</svg>
```
- `rawStyle(_, "t").fill == .color(green)` — later rule wins at equal specificity.
Pins design §5.3/§5.5 ascending `(specificity, sourceOrder)` application.

### T-C5 — universal selector is lowest and matches everything
```svg
<svg viewBox="0 0 100 100"><style>
  * { fill: red }
  rect { fill: green }
</style>
  <rect id="r" .../><circle id="c" .../>
</svg>
```
- `c.fill == .color(red)` — `*` matched the circle.
- `r.fill == .color(green)` — type (0,0,1) beats universal (0,0,0) on the rect.
Pins design §5.2/§5.4.

### T-C6 — descendant combinator (space)
```svg
<svg viewBox="0 0 100 100"><style>g .hot { fill: red }</style>
  <g><rect id="inside" class="hot" .../></g>
  <rect id="outside" class="hot" .../>
</svg>
```
- `inside.fill == .color(red)` — has a `<g>` ancestor.
- `outside.fill == nil` — no `<g>` ancestor; descendant selector did not match.
Also add a **deep** variant: wrap `inside` two more `<g>`s deep and assert it still matches (any-depth
ancestor). Pins design §5.5 ancestor walk via `parent` links.

### T-C7 — cascade order: presentation attr < normal sheet < inline
```svg
<svg viewBox="0 0 100 100"><style>rect { fill: green }</style>
  <rect id="pa"  fill="red" .../>                          <!-- presentation only -->
  <rect id="inl" fill="red" style="fill: blue" .../>       <!-- presentation + inline -->
</svg>
```
- `pa.fill == .color(green)` — normal sheet beats the presentation attribute `fill="red"`.
- `inl.fill == .color(blue)` — inline `style` beats the normal sheet rule.
This is the load-bearing cascade case. Pins design §5.3 layers 1→2→3.

### T-C8 — `!important` sheet beats inline normal
```svg
<svg viewBox="0 0 100 100"><style>rect { fill: green !important }</style>
  <rect id="t" style="fill: blue" .../>
</svg>
```
- `rawStyle(_, "t").fill == .color(green)` — important sheet (layer 4) beats inline normal (layer 3).
Pins design §5.3 + §4.4 important split.

### T-C9 — inline `!important` beats important sheet
```svg
<svg viewBox="0 0 100 100"><style>rect { fill: green !important }</style>
  <rect id="t" style="fill: blue !important" .../>
</svg>
```
- `rawStyle(_, "t").fill == .color(blue)` — inline important (layer 5) is the top layer.
Pins design §5.3 layer 5.

### T-C10 — CDATA-wrapped stylesheet
```svg
<svg viewBox="0 0 100 100"><style><![CDATA[ .k { fill: red } ]]></style>
  <rect id="t" class="k" .../>
</svg>
```
- `rawStyle(_, "t").fill == .color(red)` — CSS delivered via `foundCDATA` is parsed.
Pins design §4.1 (must implement `parser(_:foundCDATA:)`).

### T-C11 — multiple `<style>` blocks, one after the referenced element (forward ref)
```svg
<svg viewBox="0 0 100 100">
  <rect id="t" class="k" .../>
  <style>.k { fill: red }</style>
  <style>.k { stroke: blue }</style>
</svg>
```
- `t.fill == .color(red)` **and** `t.stroke == .color(blue)` — a `<style>` appearing *after* the
  element still styles it, and multiple sheets accumulate.
Pins design §2 (post-parse fold; position-independent matching).

### T-C12 — selector list shares a block
```svg
<svg viewBox="0 0 100 100"><style>rect, circle { fill: red }</style>
  <rect id="r" .../><circle id="c" .../><line id="l" .../>
</svg>
```
- `r.fill == .color(red)`, `c.fill == .color(red)`, `l.fill == nil`.
Pins design §4.4 comma splitting.

### T-C13 — unsupported selectors degrade gracefully (no crash, no error, no match)
```svg
<svg viewBox="0 0 100 100"><style>
  rect > text { fill: red }     /* child combinator: unsupported */
  [data-x] { fill: red }        /* attribute selector: unsupported */
  rect:hover { fill: red }      /* pseudo-class: unsupported */
  rect { fill: green }          /* supported, must still apply */
</style>
  <rect id="t" .../>
</svg>
```
- `parse` returns with no fatal error; `rawStyle(_, "t").fill == .color(green)` — the unsupported
  rules are dropped and the supported one still wins.
Pins design §4.4 (drop unsupported selectors) + §1 out-of-scope list.

### T-C14 — type selector distinguishes shape subtypes and poly closed-ness
```svg
<svg viewBox="0 0 100 100"><style>
  polygon { fill: red } polyline { fill: green } circle { fill: blue }
</style>
  <polygon id="pg" points="0,0 1,0 1,1"/>
  <polyline id="pl" points="0,0 1,0 1,1"/>
  <circle id="c" cx="5" cy="5" r="5"/>
</svg>
```
- `pg.fill == .color(red)`, `pl.fill == .color(green)`, `c.fill == .color(blue)`.
Pins the §5.2 derivation table (polygon vs polyline via `closed`; shape subtypes).

### T-C15 — selector output flows through `StyleResolver` unchanged (inheritance)
```svg
<svg viewBox="0 0 100 100"><style>g { fill: red }</style>
  <g id="grp"><rect id="child" .../></g>
</svg>
```
- `computed(_, "child").fill == .color(red)` — `fill` set on the group by a selector **inherits** to
  the child through the unmodified resolver (design §7). Confirms the fold produced a genuine
  specified value the resolver treats normally, and that `StyleResolver.swift` was not changed.

> **RED-state note for T-C1–C15 before S7:** with `class` unparsed and no `<style>` handling, every
> selector-driven assertion currently fails (folded fields are all `nil`; `pa`/`inl` reflect only
> today's presentation/inline behavior). T-C15 fails because the group's `fill` is never set. These
> are the expected pre-implementation failures.

---

## 3. Correctness — matrix summary

| ID | Feature | Design § |
|---|---|---|
| T-C1 | type selector | §5.2 |
| T-C2 | class selector, multi-class | §4.2, §5.5 |
| T-C3 | specificity id>class>type | §5.4 |
| T-C4 | source-order tie-break | §5.3/§5.5 |
| T-C5 | universal, lowest | §5.2/§5.4 |
| T-C6 | descendant combinator (incl. deep) | §5.5 |
| T-C7 | pres-attr < sheet < inline | §5.3 |
| T-C8 | important sheet > inline normal | §5.3/§4.4 |
| T-C9 | inline important > important sheet | §5.3 |
| T-C10 | CDATA sheet | §4.1 |
| T-C11 | forward ref + multiple sheets | §2 |
| T-C12 | selector list | §4.4 |
| T-C13 | unsupported selectors degrade | §4.4/§1 |
| T-C14 | shape subtype / poly closed | §5.2 |
| T-C15 | flows through resolver, inherits | §7 |

---

## 4. The allocation / flatness block (`CSSMemoryTests`) — decisive, deterministic

These are the tests that stand in for a profiling session. They are written to **fail loudly if the
implementation retains a rule graph or a per-node matched-style structure**, and to be
*deterministic* (exact counts / structural reflection), not timing- or footprint-noise dependent.
The one footprint-proxy test (T-A3b) uses the same `task_vm_info` phys_footprint technique as
`PatternImageMemoryTests.physFootprintBytes()` and is framed with a generous bound as
corroboration, not as the primary guarantee.

Shared heavy fixture (built in code, not a file), parameterized by `n`:
```
func heavyStyledSVG(elements n: Int, rules m: Int) -> Data
// Root <svg viewBox="0 0 1000 1000"> containing:
//   • one <style> with `m` class rules ".c0{fill:#f00} .c1{...} … .c{m-1}{…}" (varied properties),
//     the FIRST of which, ".hot { fill: red }", matches every element below;
//   • `n` <rect class="hot"> elements with distinct ids r0…r{n-1}.
func heavyInlineSVG(elements n: Int) -> Data
// Same `n` <rect> elements but each carries fill="red" inline (fill="red" attribute), NO <style>.
```

### T-A1 — `<style>` adds no render node
Parse `heavyStyledSVG(elements: 1000, rules: 50)`.
- `document.nodes.count == 1000 + 1` (the 1000 rects + the single root `<svg>`; the `<style>`
  element itself contributes **zero** nodes). Assert exactly.
Pins design §4.1 (`<style>` is a node-less passthrough like `<stop>`). A regression that turned
`<style>` into a node, or that materialized a node per rule, changes this count.

### T-A2 — `SVGDocument` retains no stylesheet/rule storage (structural, exact)
Reflect the parsed document and assert its stored-property set is **exactly** the known flat arena
set plus the single new `classNames` arena — no rule/stylesheet/declaration/matched-style field
exists:
```swift
let names = Set(Mirror(reflecting: document).children.compactMap { $0.label })
// The complete allowed set after CSS support lands:
let allowed: Set<String> = [
  "nodes","root","pathCommands","points","gradientStops","strings","transforms",
  "idMap","rootViewBox","rootPreserveAspectRatio",
  "classNames",                 // the ONE new arena §3.1
]
XCTAssertEqual(names, allowed)
// Belt-and-suspenders: no field name hints at a retained rule graph.
for forbidden in ["rule","selector","stylesheet","declaration","matched","css","sheet"] {
    XCTAssertFalse(names.contains { $0.lowercased().contains(forbidden) },
                   "SVGDocument retains a CSS structure: \(names)")
}
```
This is the single most decisive test: **there is nowhere in the IR to retain a rule.** If S7 adds
a `rules`/`stylesheet` arena to `SVGDocument`, this fails. (If S7 legitimately needs another *flat*
arena the design didn't foresee, that is a design change through S6, and this `allowed` set is what
must be updated — deliberately making silent additions impossible.)

### T-A3 — sheet-styled node is byte-for-byte the inline-styled node (fold, not new storage)
Parse `heavyStyledSVG(elements: 1000, rules: 50)` and `heavyInlineSVG(elements: 1000)`.
- (a) For every id `r0…r999`, `rawStyle(sheetDoc, id) == rawStyle(inlineDoc, id)` (they are
  `Equatable`). The `.hot` sheet rule folded `fill:red` into the *same* `RawStyle.fill` field the
  inline `fill="red"` uses — proving no parallel per-node matched-style object exists; the selector
  result lives in the existing field. (Reuse of `applyStyleProperties`, design §5.3.)
- (b) *Footprint corroboration (secondary, generous bound).* Measure retained `phys_footprint`
  delta across parsing a **large-sheet** document `heavyStyledSVG(elements: 2000, rules: 2000)`
  versus the **inline** document `heavyInlineSVG(elements: 2000)`. Both fold to the same flat arena
  and discard the sheet, so retained footprints must be within a small constant:
  ```
  XCTAssertLessThan(abs(sheetFootprint - inlineFootprint), 8 * 1024 * 1024) // 8 MB slack
  ```
  Guarded by `phys_footprint >= 0` like `PatternImageMemoryTests`. A retained rule graph or
  per-node matched-style would make the 2000-rule sheet document grow by O(rules)+O(nodes) beyond
  the inline one and blow this bound. (Marked secondary because footprint is inherently noisier than
  the exact structural checks; T-A2/T-A3a are the primary guarantees.)

### T-A4 — class arena grows with class tokens only, independent of rule count
- `classNames.count` after `heavyStyledSVG(elements: 1000, rules: 50)` equals **exactly 1000** (each
  rect has one class token `hot`). After `heavyStyledSVG(elements: 1000, rules: 5000)` it is **still
  exactly 1000** — the arena tracks class *usage*, not rules.
- After a fixture where each of 100 rects carries `class="a b c"`, `classNames.count == 300`.
Pins design §3.1/§3.5(2): class storage is `Σ classCount`, linear in usage, rule-count-independent.

### T-A5 — `SVGNode` stays a fixed-size trivial value
- `MemoryLayout<SVGNode>.stride` is bounded: assert it is `<= 320` bytes. The node's absolute size
  is set by two inline fixed-size payloads that predate CSS — `kind: NodeKind` (~88 bytes) and
  `style: RawStyle` (~20 `Optional` fields, ~192 bytes) — so the node already measured ~296 bytes
  before CSS support; `classes: ArenaRange` adds the final 8, giving 304 measured. The exact number
  is compiler-dependent, so a bound above the measured size (not equality) is frozen. The point is
  that the class addition is a `(start,count)` window, **not** an owned array that would make the
  node carry a heap pointer.
- Assert `SVGNode` gained no reference-typed member: parsing 10 000 class-bearing rects and dropping
  the document must not require ARC teardown — asserted indirectly by T-A6 (footprint returns flat
  after the document is released).
Pins design §3.2/§3.5(1).

### T-A6 — scratch is released; no per-parse growth accumulates
Parse `heavyStyledSVG(elements: 500, rules: 500)` **100 times in a loop**, discarding each document.
- Retained `phys_footprint` after the loop exceeds the pre-loop baseline by less than a small bound
  (`< 16 MB`, `phys_footprint >= 0` guarded). Because the rule/selector/inline scratch is transient
  (design §6) and each `SVGDocument` is released, there is no monotonic growth. A retained-per-parse
  stylesheet, or a leaked delegate scratch, shows up here as unbounded growth across iterations —
  the same failure shape `PatternImageMemoryTests` catches for the image path.
Pins design §6 (scratch freed inside `parse`).

---

## 5. Allocation-block summary

| ID | Asserts | Kind | Design § |
|---|---|---|---|
| T-A1 | `<style>` = 0 nodes; no per-rule node | exact count | §4.1 |
| T-A2 | no rule/stylesheet field on `SVGDocument` | exact reflection | §3.4/§3.5(3) |
| T-A3a | sheet-styled `RawStyle` == inline `RawStyle`, per node | exact equality | §5.3 |
| T-A3b | sheet vs inline retained footprint within 8 MB | footprint proxy (secondary) | §3.5(3) |
| T-A4 | `classNames.count` = Σ class tokens, rule-count-independent | exact count | §3.1/§3.5(2) |
| T-A5 | `SVGNode` fixed-size, no heap member | layout bound | §3.2/§3.5(1) |
| T-A6 | scratch freed; no growth over 100 parses | footprint proxy | §6 |

Primary (exact, deterministic): **T-A1, T-A2, T-A3a, T-A4, T-A5.** Corroborating footprint proxies:
T-A3b, T-A6. The primary set alone is sufficient to prove "the IR stays flat and no per-node rule
structure is allocated"; the proxies catch a leak the structural checks can't see (transient scratch
that is retained across parses).

---

## 6. Done criteria

At **freeze** (this session, S6): the two artifacts (`Design/css-support.md`, this file) fully pin
the subsystem; no `.swift` is written (S6 is design-only per the S6 prompt). Every case above cites a
design section and has a concrete fixture and exact expected value, so S7 can transcribe tests and
implement with **no further design decisions**.

At **implementation** (S7): every `T-C*` and `T-A*` case is green under `swift test`, with **no edit
to this spec**. In particular the allocation block (`T-A1–A6`) passes, which — per phase-plan.md's
S6/S11 rationale — is the deterministic stand-in for a profiling session certifying the flat-arena
invariant holds for the CSS subsystem.

At **review** (S8): the reviewer confirms (a) `T-A2`'s `allowed` set was not widened to sneak in a
retained rule structure, (b) `T-A3a` genuinely compares a heavy sheet-styled document against its
inline twin, and (c) `StyleResolver.swift` is unchanged (T-C15 + diff inspection).
