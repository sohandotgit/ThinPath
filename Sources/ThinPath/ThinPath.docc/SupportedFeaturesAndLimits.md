# Supported Features & Limits

What ThinPath renders today, what's explicitly deferred, and the constraints worth knowing about before you rely on pixel-exact output.

## Overview

This is a factual inventory, not a roadmap promise. "Deferred" means not implemented in the attached source, not "coming soon" on any particular timeline.

### Supported

**Shapes** — `<path>` (including elliptical arcs via `ArcTo`), `<line>`, `<polyline>`, `<polygon>`, `<rect>`, `<circle>`, `<ellipse>`.

**Structure** — `<g>`, nested `<svg>` viewports, `<defs>`, `<use>` (reference-based instancing, not tree expansion — see <doc:HowItWorks>), `<symbol>`.

**Transforms** — `translate`, `scale`, `rotate`, `skewX`, `skewY`, `matrix`, and the full `transform` attribute grammar; nested `viewBox` and `preserveAspectRatio`.

**Paint servers** — solid fills/strokes, `currentColor`, linear and radial gradients (stops, `spreadMethod` pad/reflect/repeat, `gradientTransform`), and `<pattern>` fills realized via `CGPattern` tiling rather than a pre-rendered bitmap (see <doc:ThinPath>). Both `objectBoundingBox` and `userSpaceOnUse` units are supported for gradients and patterns.

**Clipping and masking** — `<clipPath>` and `<mask>`, including `clipPathUnits`/`maskUnits`/`maskContentUnits` bounding-box mapping.

**Text** — basic `<text>`: a single positioned run per element (`x`, `y`, text content), honoring `font-family`, `font-size`, `font-weight`, `font-style`, and `text-anchor`, filled with a solid color. There is no multi-`<tspan>` layout, no per-glyph `dx`/`dy` shifting, no bidi handling, and no text-on-a-path — the IR only carries one run per text node, so richer layout isn't representable without extending the model first.

**Images** — embedded `<image>` (including `data:` URIs) and external file-based references, decoded lazily at render time at the target's device-pixel size (never at full source resolution) — see `Design/ImageDecodeNotes.md`. Multi-frame sources (animated GIF/APNG) render frame 0 only, matching SVG's static-rendering semantics for embedded rasters.

### Explicitly deferred

- **SMIL animation** — `<animate>`, `<animateMotion>`, `<set>`, and related elements are not implemented.
- **CSS animations/transitions** — would require a CSS parser and additional state management beyond the current cascade resolution.
- **Advanced filters** — `<filter>`, `<feGaussianBlur>`, and the rest of the filter-effects primitives are not implemented.
- **Scripting** — `onload`/`onclick` and other event-handler attributes are out of scope.
- **Embedded fonts** — `<style>` blocks and `@font-face` parsing are not implemented; font resolution only ever consults fonts already available on the system (see below).

### Known constraints

**Font fallback substitutes, and does not promise metric compatibility.** `font-family` is a comma-separated, prioritized list. ThinPath walks it, verifies each candidate actually resolved to the requested family (Core Text can silently substitute a default for an unknown name), and falls back to the iOS system font if nothing in the list resolves. This means a document authored against a desktop font — Inkscape's default export of `'Liberation Sans'` is a common case — renders with a substituted font on iOS if that family isn't installed, and the substituted font is not guaranteed to be metric-identical (line widths, glyph widths, and consequently text layout, may differ from the original design).

**External image references only resolve local files, not network URLs.** `ImageDecoder`'s href resolution accepts `file:` URLs and filesystem paths, but explicitly refuses `http:`/`https:` schemes — the render path is synchronous and does not perform network I/O. An `<image href="https://...">` in a document renders as nothing (SVG's behavior for an unresolvable image reference) unless the app has already fetched it to local storage or inlined it as a `data:` URI before parsing.

**Large embedded images used as `objectBoundingBox` pattern fills must be sized correctly to stay within the library's memory guarantees.** The pattern-content coordinate mapping (`patternUnits` × `patternContentUnits`, `Design/Compositing.md` §4a) determines how large a fill an embedded image is asked to cover; getting that mapping wrong for the `objectBoundingBox`/`objectBoundingBox` combination is the one documented case that has produced a runaway resample buffer in practice (a ~57 GB target from a 592×400 render, per the incident recorded in `Design/Compositing.md`). ThinPath guards this with a tested coordinate-mapping rule and a visible-region bound on the resample target, but the guarantee is "bounded to the visible, on-screen region" — not "unlimited image size at any fill area is free." Very large source images used as pattern fills still cost a decode at the size the fill actually needs, per element.

See also: <doc:HowItWorks>, <doc:HowThinPathDiffers>.
