# Arc Geometry Notes

How `PathBuilder.swift` turns IR path commands into a `CGMutablePath`, with the
weight on SVG elliptical arcs (`A`/`a`). Companion invariant tests:
`Tests/SVGRendererTests/ArcGeometryTests.swift`. Spec references are to SVG 1.1
Appendix F.6 ("Elliptical arc implementation notes"), which SVG 2 adopts
unchanged.

## Where each command is handled

The builder consumes the six IR commands (`moveTo`, `lineTo`, `quadTo`,
`cubicTo`, `arc`, `close`). The full authored command set M/L/H/V/C/S/Q/T/A/Z,
absolute and relative, funnels into these because `PathDataParser` lowers at
parse time:

| Authored              | IR form the builder sees                            |
|-----------------------|-----------------------------------------------------|
| `M`/`m`               | `moveTo` (absolute)                                 |
| `L`/`l`, `H`/`h`, `V`/`v` | `lineTo` (absolute; H/V get the held coordinate) |
| `C`/`c`               | `cubicTo`                                           |
| `S`/`s`               | `cubicTo` with control1 already reflected           |
| `Q`/`q`               | `quadTo`                                            |
| `T`/`t`               | `quadTo` with control already reflected             |
| `A`/`a`               | `arc` — raw endpoint parameters, endpoint absolute  |
| `Z`/`z`               | `close`                                             |

The smooth-curve reflected-control-point state machine (including the rule
that the reflection state is cleared by any command outside the matching curve
family, and that a smooth command with no eligible predecessor uses the
current point as its control) lives in `PathDataParser.parse` and is covered
by `PathDataTests`. The builder therefore performs a data-preserving mapping
for everything except the arc — `quadTo`/`cubicTo` become real
`addQuadCurve`/`addCurve` elements with the commanded control points, never
pre-flattened.

One builder-side policy: SVG requires a path to begin with a moveto, so
drawing commands arriving before any `moveTo` (possible with a malformed `d`
that the parser truncated) are **dropped**. CGPath has no defined current
point there, and silently inventing (0,0) would paint geometry the author
never wrote.

## Endpoint → center parameterization (the arc algorithm)

Input: current point `(x1,y1)`, `ArcTo(rx, ry, φ°, large-arc, sweep, (x2,y2))`.

Degenerate dispositions, checked in spec order:

1. **Coincident endpoints (§F.6.2).** If `(x1,y1) == (x2,y2)` *exactly*, the
   segment is omitted — no geometry at all. The comparison is deliberately
   exact, not epsilon-based: endpoints that are merely *nearly* coincident are
   meaningful input (with large-arc=1 they describe an almost-full ellipse,
   |Δθ| → 2π) and an epsilon here would silently erase them.
2. **Radii signs (§F.6.6 step 1).** `rx ← |rx|`, `ry ← |ry|`. (The parser also
   does this; the builder repeats it so it is safe against IR produced by any
   other frontend.)
3. **Zero radius (§F.6.6 step 2).** If either radius is below `1e-12`, emit a
   straight `lineTo(end)`. The threshold is intentionally tiny — see "Chosen
   tolerances" below.

Main path (all formula numbers §F.6.5):

4. **Rotation normalization.** `φ` is folded with
   `truncatingRemainder(dividingBy: 360)` *before* converting to radians, so
   an authored `rotation="3600037"` doesn't lose the fractional degree to
   floating-point when multiplied by π/180. Negative values are fine as-is
   (cos/sin are exact under the fold).
5. **Step 1 — primed frame.** Rotate the chord midpoint vector by −φ:
   `(x1′, y1′)`.
6. **Radius correction (§F.6.6 step 3).** `Λ = x1′²/rx² + y1′²/ry²`. If
   `Λ > 1` the radii cannot span the chord; scale **both** by `√Λ`
   (preserving the rx:ry ratio) so the ellipse exactly fits. This is what
   makes tiny-but-positive radii legal: `A 1e-8 1e-8 … 10 0` becomes a
   half-ellipse with corrected radius 5, not a line.
7. **Step 2 — center in the primed frame.** The radicand
   `(rx²ry² − rx²y1′² − ry²x1′²)/(rx²y1′² + ry²x1′²)` is mathematically ≥ 0
   after step 6, but for chord ≈ 2r (near-180° arcs) rounding can land it at
   ~−1e-17; it is clamped to 0 before `sqrt` or the NaN would poison the whole
   path. Sign of the root: `+` iff `large-arc ≠ sweep`.
8. **Step 3 — center back to user space** (rotate by +φ, add chord midpoint).
9. **Step 4 — angles.** θ₁ and θ₂ are computed with `atan2` on the
   *radius-normalized* vectors `((x1′∓cx′)/rx, (y1′∓cy′)/ry)` — dividing by
   the radii maps the ellipse to the unit circle where `atan2` returns the
   true parametric angle. Using the raw vectors is a classic bug that only
   shows up when `rx ≠ ry`. Then `Δθ = θ₂ − θ₁`, adjusted into `(0, 2π]` when
   `sweep=1` and `[−2π, 0)` when `sweep=0`. The sweep flag alone fixes the
   sign; the large-arc flag acted earlier through the center-sign choice in
   step 7, which is what makes |Δθ| land above or below π.

   Sign convention reminder: these are plain-number angles; in SVG's y-down
   user space, `sweep=1` (positive Δθ) is *clockwise on screen*. No axis flip
   happens in this file — the builder stays in user coordinates and the
   viewport transform owns orientation.

## Mapping to CGPath: cubic Beziers, not `addRelativeArc`

`addRelativeArc`/`addArc` are circle primitives; driving them for ellipses
requires wrapping them in a per-arc affine transform, which contaminates a
shared `CGMutablePath` being built incrementally (the transform argument
applies to the *added geometry's* coordinate assumptions and interacts badly
with the running current point, and historically has platform quirks around
sweep direction). The builder instead emits explicit cubics, which is also
what keeps output deterministic across OS versions.

The arc is split into `n = ceil(|Δθ| / (π/2))` equal spans. For a span of
width δ starting at θ, with the ellipse point
`E(θ) = c + R(φ)·(rx·cosθ, ry·sinθ)` and derivative
`E′(θ) = R(φ)·(−rx·sinθ, ry·cosθ)`, the cubic is

```
P0 = E(θ)
P1 = E(θ) + t·E′(θ)          t = (4/3)·tan(δ/4)
P2 = E(θ+δ) − t·E′(θ+δ)
P3 = E(θ+δ)
```

This is the standard arc approximation with exact endpoint and endpoint-
tangent interpolation. The final segment's `P3` is **snapped to the commanded
endpoint** verbatim, so accumulated trig rounding can never open a hairline
gap at a subpath joint (visible on stroked paths with joins, and load-bearing
for `Z` closure geometry).

### Error bound and why π/2 spans are enough for high DPI

For a circular span of angle δ the maximum radial error of this cubic is
approximately `r · (4/27) · sin⁶(δ/4) / cos²(δ/4)`; at δ = π/2 that evaluates
to ≈ 2.7 × 10⁻⁴ · r, and it falls off as δ⁶ (a 45° span is already ~4e-6 · r).
For an ellipse the same bound holds with `r = max(rx, ry)` after the affine
map. Consequences:

- A full-screen arc with r ≈ 1000 pt errs by ≤ 0.27 pt ≈ 0.8 physical pixels
  at 3× — worst case, at exactly four points per quadrant, and in practice
  invisible under antialiasing. Any radius under ~1200 pt stays within ±1
  physical pixel at 3×; under ~400 pt it is within a *quarter* pixel.
- Huge-radius shallow arcs (`rx = 10⁶`, chord 100) are *not* a problem despite
  the scary `2.7e-4 · r = 270` product: such an arc spans δ ≈ 10⁻⁴ rad, one
  segment, and the δ⁶ falloff makes the error ~10⁻¹⁹ user units.
- If a future zoomable-canvas feature renders paths at extreme magnification,
  drop `maxSegmentAngle` (π/4 buys ~64× accuracy) or re-tessellate per scale —
  the IR keeps raw arc parameters precisely so re-flattening is possible.

### Chosen tolerances (summary)

| Constant | Value | Why |
|---|---|---|
| `radiusEpsilon` | 1e-12 | Only guards exact zeros / sub-denormal noise against inf/NaN division. Anything larger would misclassify legal tiny radii that §F.6.6 step 3 is supposed to scale up. |
| Coincident endpoints | exact `==` | Spec omits the segment only for *identical* endpoints; near-coincident is meaningful (near-full ellipse). |
| Radicand clamp | `max(0, ·)` | Absorbs ~−1e-17 rounding at chord ≈ 2r; mathematically the value is ≥ 0 post-correction. |
| `maxSegmentAngle` | π/2 | ≤ 2.7e-4·r radial error; sub-pixel at 3× for r ≲ 1200 pt (see above). |
| Test: ellipse-equation deviation | 2e-3 (dimensionless) | Approximation predicts \|f−1\| ≲ 6e-4; 2e-3 gives headroom without admitting visually wrong curves. |
| Test: endpoint fidelity | 1e-6 | Endpoints are interpolated exactly (last segment snapped); tolerance covers only representation noise. |

## Adversarial input checklist for the test corpus

Implemented in `ArcGeometryTests.swift` unless marked ☐. The tests assert only
input-derivable invariants — endpoint fidelity, on-(corrected-)ellipse,
sweep-flag direction, large-arc magnitude — with the corrected radii/center
computed by an independent transcription of the spec formulas in the test
file, never by reading values back from the implementation.

- [x] All four large-arc × sweep combinations on a chord strictly shorter than
      2r (so small and large arcs are genuinely distinct).
- [x] Near-180° arcs, both flag sides (chord 99.99, r = 50): radicand → 0⁺,
      center-sign selection must not flip the center to the wrong side.
- [x] Exactly-180° arc (chord = 2r, radicand exactly 0, all 4 flag combos) —
      arc-size assertion disabled since both large-arc choices give |Δθ| = π.
- [x] Coincident endpoints, large-arc=1 sweep=1: segment omitted entirely,
      path is exactly the moveTo.
- [x] Near-coincident endpoints (1e-6 apart) with large-arc=1: NOT omitted;
      |Δθ| ≈ 2π near-full ellipse, both sweeps.
- [x] Zero radius (rx=0, ry=0, both) with nonzero rotation and flags set:
      straight line, all samples collinear.
- [x] Tiny positive radii (1e-8): scaled up per §F.6.6, not a line.
- [x] Out-of-range radii, isotropic (r=10, chord=100 → corrected 50,
      half-circle) — on-ellipse check runs against the *corrected* radii.
- [x] Out-of-range radii, anisotropic + rotated (rx:ry ratio must survive the
      correction).
- [x] Huge radii (10⁶, chord 100): shallow arc stays within the analytic sag
      bound of the chord; no catastrophic bulge from cancellation.
- [x] Negative radii: identical to |r| behavior.
- [x] x-axis-rotation normalization: 37° ≡ 397° ≡ −323° produce pointwise
      identical geometry.
- [x] Rotated non-circular ellipse (rx=80, ry=30, φ=37°), small/large/both
      sweeps — exercises the radius-normalized `atan2` (step 9 bug class).
- [x] Extreme aspect ratio (rx=1000, ry=1).
- [x] Arc chained after lines/cubics inside a longer path (current-point
      threading), and continuation after the arc.
- [x] Full authored command set M/L/H/V/C/S/Q/T/A/Z through
      `PathDataParser` → builder, endpoint + closure fidelity.
- [x] Drawing commands before any moveTo: dropped, no crash, no invented
      start point.
- [ ] NaN/infinite coordinates in `ArcTo` (parser can't currently produce
      them, but the IR is public API — worth a guard + test if hardening).
- [ ] Sub-degree Δθ arcs chained hundreds of times (cumulative joint error
      under stroking) — needs a rendered-output harness, not path math.

## Flagged for validation against reference renders

Confidence is high on the algebra (it is a direct spec transcription and the
invariant suite is green), but the following should still be eyeballed against
reference renderers (resvg / Chrome) once the raster pipeline exists, because
invariant tests can't see *visual* orientation or stroking artifacts:

1. **Sweep direction on screen.** The tests verify the sign of Δθ in
   coordinate terms; that `sweep=1` looks clockwise on iOS depends on the
   viewport transform applied elsewhere (UIKit is y-down like SVG, so no flip
   is expected — but this is exactly the kind of thing that's wrong once, in
   one place, with a sign).
2. **Extreme aspect-ratio ellipses** (rx:ry ≥ ~1000:1, and worse). The π/2
   split is by *parametric* angle; on a very eccentric ellipse, curvature near
   the flat ends concentrates within a single segment and the error bound in
   terms of max(rx, ry) is loose there. The 1000:1 test passes the 2e-3
   dimensionless tolerance, but hairline-stroke rendering at high zoom could
   show flattening. If it does, split adaptively by curvature instead of by
   angle.
3. **Near-full-ellipse arcs** (near-coincident endpoints, large-arc=1): the
   center position is numerically touchy (radicand is huge and the chord tiny);
   invariants pass, but the rendered ellipse's *position* should be compared
   against a reference, since a center error parallel to the tiny chord
   barely moves the ellipse-equation residual.
4. **Stroked near-180° arcs with round joins** at the snap-to-endpoint seam —
   the snap is ≤ ~1e-10 user units, which should be invisible, but stroking
   amplifies geometry defects.
