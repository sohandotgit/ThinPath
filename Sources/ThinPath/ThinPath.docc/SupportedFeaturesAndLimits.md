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

**Text** — basic `<text>`: a single positioned run per element (`x`, `y`, text content), honoring `font-family`, `font-size`, `font-weight`, `font-style`, and `text-anchor`, filled with a solid color. There is no multi-`<tspan>` layout, no per-glyph `dx`/`dy` shifting, no bidi handling, and no text-on-a-path — the IR carries one run per text node, so richer layout is not representable without extending the model first.

**Images** — embedded `<image>` (including `data:` URIs) and external file-based references, decoded lazily at the target's device-pixel size (see <doc:ScaleAwareImageDecoding>). Multi-frame sources render frame 0 only.

### Explicitly deferred

- **SMIL animation** — `<animate>`, `<animateMotion>`, `<set>`, and related elements are not implemented.
- **CSS animations and transitions** — would require a CSS parser and additional state management beyond the current cascade resolution.
- **Advanced filters** — `<filter>`, `<feGaussianBlur>`, and the other filter-effects primitives are not implemented.
- **Scripting** — `onload`, `onclick`, and other event-handler attributes are out of scope.
- **Embedded fonts** — `<style>` blocks and `@font-face` parsing are not implemented; font resolution only consults fonts already available on the system.

### Font fallback substitutes and does not promise metric compatibility

`font-family` is a comma-separated, prioritized list. ThinPath walks it, verifies each candidate actually resolved to the requested family (Core Text can silently substitute a default for an unknown name), and falls back to the iOS system font if nothing resolves. A document authored against a desktop font — Inkscape's default export of `'Liberation Sans'` is a common case — renders with a substituted font on iOS if that family is not installed. The substituted font is not guaranteed to be metric-identical, so glyph widths and text layout may differ from the original design.

### External image references resolve local files only, not network URLs

Href resolution accepts `file:` URLs and filesystem paths but refuses `http:` and `https:` schemes — the render path is synchronous and performs no network I/O. An `<image href="https://...">` renders as nothing (SVG's behavior for an unresolvable reference) unless the app has already fetched it to local storage or inlined it as a `data:` URI before parsing.

### Large images used as pattern fills must be sized correctly

The pattern-content coordinate mapping (`patternUnits` × `patternContentUnits`) determines how large a fill an embedded image is asked to cover. Getting that mapping wrong for the `objectBoundingBox`/`objectBoundingBox` combination is the one documented case that has produced a runaway resample buffer in practice (a ~57 GB target from a 592×400 render). ThinPath guards this with a tested coordinate-mapping rule and a visible-region bound on the resample target, so the guarantee is "bounded to the visible, on-screen region" — not "unlimited image size at any fill area is free." A very large source image used as a pattern fill still costs a decode at the size the fill actually needs, per element.

See also <doc:HowItWorks> and <doc:HowThinPathDiffers>.
