# GoldenWorkflow.md — generating reference PNGs for the GOLDEN test tier

`RenderTests.swift` has two tiers. The EXACT tier (spot-pixel assertions) needs
nothing from you — it's hand-computed and self-contained. The **GOLDEN** tier
needs reference PNGs you generate **offline, from an independent renderer**,
placed in `SampleSVGs/references/` (see `references/MANIFEST.md` for the exact
list of filenames and pixel sizes). This document is instructions for *you*,
the human running this workflow — not something the implementation thread
needs to read.

## 1. Why an independent oracle, and what that buys you (and doesn't)

The whole point of a golden image is that it encodes a correctness claim this
renderer didn't produce itself. If you generated the references *with this
renderer* (even an earlier "mostly working" build of it), a golden test would
only catch **regressions** — it could never catch a bug this renderer has
always had, because the bug would be baked into the golden too.

So references must come from a renderer that isn't this codebase: a headless
browser (Chromium via Playwright/Puppeteer, or Safari/WebKit) or a dedicated
SVG library (`librsvg`'s `rsvg-convert`, or `resvg`). Any of these is fine.
Pick one, and **use the same one for every reference PNG** in this corpus —
mixing oracles means every golden file also carries that oracle's own AA/
color-management quirks inconsistently, which makes tolerance-tuning (§4)
close to impossible.

**A golden test is only as trustworthy as its oracle.** If the oracle itself
mishandles something in the corpus — a `preserveAspectRatio` edge case, sRGB
vs. linear-light gradient interpolation, an unusual `spreadMethod` — the
golden will quietly encode that mistake as "correct," and this renderer will
be marked wrong for disagreeing with it. Concretely:

- **Do not** treat a golden failure as automatically this renderer's bug.
  When one fails, look at the actual output. If it looks more correct than the
  reference, the reference is wrong — fix the reference, or drop that case
  back to hand-verification, don't chase the oracle's behavior.
- Golden coverage in this corpus is deliberately limited to composited cases
  (gradients, patterns, masks, text, images) where an exact hand-computed
  answer isn't practical. **Every case simple enough to hand-compute is
  already covered by the EXACT tier in `RenderTests.swift`, independent of any
  oracle.** That EXACT tier is what actually carries correctness weight in
  this suite — the GOLDEN tier is a coarser regression net around it, not a
  replacement for it.

## 2. Render at the exact size the test uses — no scale factor

Every GOLDEN case in `RenderTests.swift` renders at **scale 1**, at the pixel
size listed in `references/MANIFEST.md` (and in the test itself, right next to
the `render(...)` call). Generate each reference PNG at *exactly* that pixel
size:

- **`rsvg-convert`**: `rsvg-convert -w <width> -h <height> --keep-aspect-ratio=no in.svg -o out.png`
  (the SVG's own `width`/`height`/`viewBox` in this corpus already match the
  target size 1:1, so aspect-ratio flags shouldn't need to do any real work —
  if `rsvg-convert` produces a different size than requested, that's a sign
  the source SVG and the manifest size have drifted; fix the mismatch rather
  than forcing a resize).
- **Headless Chromium** (Playwright/Puppeteer): set the viewport to the exact
  pixel size, load the SVG (e.g. `file://.../foo.svg` or inlined into a
  minimal HTML page with no margin/padding), and screenshot at
  `deviceScaleFactor: 1`. Double-check the browser isn't silently upscaling
  for a Retina host display — that's the most common way people accidentally
  hand in a 2x image here.

If a reference PNG's dimensions don't match its test's requested size,
`assertMatchesGolden` fails immediately on a size mismatch before comparing
any pixels — so a wrong-size golden is at least a loud, unambiguous failure,
not a silent bad comparison.

## 3. Where files go

Save each PNG directly into `Tests/SVGRendererTests/SampleSVGs/references/`
using the exact filename from `references/MANIFEST.md` (e.g.
`linear_gradient_basic.png`). No subfolders. `SnapshotSupport.loadReferencePNG`
looks them up by that name via `Bundle.module`, so `Package.swift`'s existing
`.copy("SampleSVGs")` resource rule picks them up automatically — nothing else
to wire up.

## 4. Tolerance is doing real work — understand what it's hiding

`assertMatchesGolden` has two knobs, both set per-call in `RenderTests.swift`:

- `perPixelTolerance` (default 10): max per-channel (R/G/B/A, 0–255) delta for
  a pixel to count as matching.
- `maxDivergentFraction` (default 0.02): the fraction of the image allowed to
  exceed that tolerance before the whole comparison fails.

These exist **only** to absorb anti-aliasing differences at shape/gradient
boundaries between this renderer and the oracle — different AA algorithms
(box filter vs. analytic coverage vs. supersampling) legitimately disagree by
a handful of levels for a thin ring of edge pixels, and that disagreement
means nothing about correctness. It should **not** be absorbing:

- Wrong gradient color-space interpolation (sRGB vs. linear-light) — this
  produces a systematic mid-ramp shift affecting a large fraction of pixels,
  not a thin edge band. If you need to raise `maxDivergentFraction` past
  single digits to make a gradient case pass, stop — that's a real
  correctness bug, not an AA artifact.
- Wrong mask color-space/luminance coefficients — same shape of problem,
  same fix (find and correct the bug, don't widen tolerance around it).
- Text hinting/font-substitution differences — if the oracle doesn't have the
  same font available, its glyph shapes may differ from what this renderer
  produces even when both are "correct." `text_basic` already uses a wider
  tolerance (`perPixelTolerance: 40`, `maxDivergentFraction: 0.05`) for this
  reason; if that's still not enough with your chosen oracle, prefer pinning
  both to an identical bundled font over widening tolerance further.

When tuning, look at the actual failure output first (`assertMatchesGolden`
reports the divergent pixel count/fraction and the first divergent pixel's
coordinates + actual/expected colors) rather than guessing at a tolerance
value.

## 5. Regenerating a golden

If you deliberately change a golden (oracle upgrade, corrected a bad
reference, corpus SVG edited): regenerate that one file the same way, confirm
its dimensions still match `references/MANIFEST.md`, and note in your commit
message *why* — a changed golden with no stated reason is indistinguishable
from someone quietly loosening a test.
