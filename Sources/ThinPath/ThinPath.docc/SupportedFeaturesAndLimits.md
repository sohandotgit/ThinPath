# Supported Features and Limits

What ThinPath renders today, what is explicitly deferred, and the constraints worth knowing before you rely on pixel-exact output.

## Overview

This is a factual inventory, not a roadmap. "Deferred" means not implemented in the current source, not "coming soon" on any particular timeline.

### Supported

**Shapes** — `<path>` (including elliptical arcs), `<line>`, `<polyline>`, `<polygon>`, `<rect>`, `<circle>`, `<ellipse>`.

**Structure** — `<g>`, nested `<svg>` viewports, `<defs>`, `<use>` (reference-based instancing, not tree expansion — see <doc:MemoryModel>), `<symbol>`.

**Transforms** — `translate`, `scale`, `rotate`, `skewX`, `skewY`, `matrix`, and the full `transform` attribute grammar; nested `viewBox` and `preserveAspectRatio`.

**Paint servers** — solid fills and strokes, `currentColor`, linear and radial gradients (stops, `spreadMethod` pad/reflect/repeat, `gradientTransform`), and `<pattern>` fills realized via `CGPattern` tiling rather than a pre-rendered bitmap. Both `objectBoundingBox` and `userSpaceOnUse` units are supported for gradients and patterns.

**Clipping and masking** — `<clipPath>` and `<mask>`, including `clipPathUnits`, `maskUnits`, and `maskContentUnits` bounding-box mapping.

**Compositing** — `mix-blend-mode` and `isolation: isolate`. A blended (or explicitly isolated) element composites through a single transparency layer — the same isolation machinery used for group `opacity` and masks, adding no second offscreen surface (verified memory-safe by profiling). All 16 CSS blend modes (`normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `color-dodge`, `color-burn`, `hard-light`, `soft-light`, `difference`, `exclusion`, `hue`, `saturation`, `color`, `luminosity`) are parsed, mapped 1:1 to the corresponding `CGBlendMode`, and verified against exact pixel references computed by an independent CSS-Compositing oracle. ThinPath renders in device sRGB, so Core Graphics evaluates each blend on the sRGB-encoded channels — the CSS-correct result — including the four non-separable modes, which match the CSS luminance model exactly. An unknown keyword degrades to `normal` (invalid value → initial), never a parse error.

> **Known limitation — `soft-light`.** Core Graphics' `soft-light` implementation is not the W3C CSS Compositing soft-light formula; the two differ by up to ~4% per channel on mid-tone backdrops (e.g. for a 50%-grey backdrop under an opaque red source, CSS specifies `181` where Core Graphics produces `192`). ThinPath uses the Core Graphics result. The other 15 modes match the CSS specification exactly.

**Text** — single-line `<text>` only: exactly one positioned run per element (`x`, `y`, text content), honoring `font-family`, `font-size`, `font-weight`, `font-style`, and `text-anchor`, filled with a solid color. There is no `<tspan>` support, no per-glyph `dx`/`dy` shifting, no multiline layout, no bidi handling, and no text-on-a-path — the IR carries one run per text node, so richer layout is not representable without extending the model first.

**Images** — embedded `<image>` (including `data:` URIs) and external file-based references, decoded lazily at the target's device-pixel size (see <doc:ScaleAwareImageDecoding>). Multi-frame sources render frame 0 only.

**CSS styling** — document `<style>` stylesheets (any position or depth, including `<![CDATA[…]]>`-wrapped and `type="text/css"` sheets) and CSS selectors: type (`rect`), class (`.cls`), id (`#id`), universal (`*`), compound simple selectors (`rect.cls#id`), the descendant combinator (`g .cls`), and comma-separated selector lists. Full `(id, class, type)` specificity ordering, source-order tie-breaking, and `!important` are honored, cascaded correctly against presentation attributes and inline `style=""`. Selectors are resolved once at parse time and folded into each element's style, so there is no runtime matching cost and no change to the flat-arena IR (see <doc:MemoryModel>). Note that `<tspan>` and `<text>` type selectors both match any text node (the IR models both as one kind). Unsupported selector features — attribute selectors (`[fill]`), pseudo-classes/elements (`:hover`), and the child/sibling combinators (`>`, `+`, `~`) — are ignored rather than treated as errors, so an unsupported rule simply never matches; the rest of the sheet still applies.

### Explicitly deferred

- **SMIL animation** — `<animate>`, `<animateMotion>`, `<set>`, and related elements are not implemented.
- **CSS animations and transitions** — static CSS styling via `<style>` and selectors is supported (see above), but `@keyframes`, `animation`, and `transition` are not: they would require time-based state management beyond static cascade resolution.
- **Advanced filters** — `<filter>`, `<feGaussianBlur>`, and the other filter-effects primitives are not implemented.
- **Scripting** — `onload`, `onclick`, and other event-handler attributes are out of scope.
- **Embedded fonts** — `@font-face` and font embedding are not implemented; font resolution only consults fonts already available on the system. (`<style>` blocks themselves *are* parsed for selector styling — see **CSS styling** above — but any `@font-face` at-rule inside one is skipped.)
- **`background-blend-mode` and Porter-Duff operators** — `mix-blend-mode` *is* supported (see **Compositing** above), but `background-blend-mode` (ThinPath has no CSS backgrounds) and compositing operators beyond `src-over` (`clear`, `xor`, …) are out of scope; `mix-blend-mode` never selects those.

### Not a goal: interactivity

ThinPath is render-only by design. Tap gestures, hit-testing, and runtime node mutation are out of scope — and not merely deferred. The parsed document is a flat arena of value types (see <doc:MemoryModel>) with no mutable, addressable node identity to attach behavior to or to mutate in place; adding interactivity would mean a different data model, not an incremental feature. For interactive SVG — gestures, live DOM-style mutation, per-node inspection — use a retained-tree renderer such as [SVGView](https://github.com/exyte/SVGView) instead.

### Font fallback substitutes and does not promise metric compatibility

`font-family` is a comma-separated, prioritized list. ThinPath walks it, verifies each candidate actually resolved to the requested family (Core Text can silently substitute a default for an unknown name), and falls back to the platform's system font if nothing resolves. A document authored against a desktop font — Inkscape's default export of `'Liberation Sans'` is a common case — renders with a substituted font if that family is not installed on the current platform. The substituted font is not guaranteed to be metric-identical, so glyph widths and text layout may differ from the original design.

### External image references resolve local files only, not network URLs

Href resolution accepts `file:` URLs and filesystem paths but refuses `http:` and `https:` schemes — the render path is synchronous and performs no network I/O. An `<image href="https://...">` renders as nothing (SVG's behavior for an unresolvable reference) unless the app has already fetched it to local storage or inlined it as a `data:` URI before parsing.

### Large images used as pattern fills must be sized correctly

The pattern-content coordinate mapping (`patternUnits` × `patternContentUnits`) determines how large a fill an embedded image is asked to cover. Getting that mapping wrong for the `objectBoundingBox`/`objectBoundingBox` combination is the one documented case that has produced a runaway resample buffer in practice (a ~57 GB target from a 592×400 render). ThinPath guards this with a tested coordinate-mapping rule and a visible-region bound on the resample target, so the guarantee is "bounded to the visible, on-screen region" — not "unlimited image size at any fill area is free." A very large source image used as a pattern fill still costs a decode at the size the fill actually needs, per element.

See also <doc:HowItWorks> and <doc:HowThinPathDiffers>.
