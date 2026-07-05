//
//  ArcGeometryTests.swift
//  SVGRendererTests
//
//  Frozen spec for `PathBuilder` — IR path commands → CGMutablePath — with the
//  weight on SVG elliptical-arc geometry (spec §F.6, "endpoint to center
//  parameterization").
//
//  METHOD: every assertion here is an INVARIANT derivable from the input
//  command stream plus the SVG specification alone. No expected value was read
//  back from the implementation. Where a check needs the corrected radii or
//  the arc center, they are computed in this file by `SpecArc`, a direct,
//  independent transcription of spec sections F.6.5 (center parameterization)
//  and F.6.6 (out-of-range radius correction) — spec formulas, not
//  implementation output. The geometry checks then run against points sampled
//  from the CGPath the builder actually produced:
//
//    1. ENDPOINTS   — the built path starts at the commanded start point and
//                     ends exactly at the commanded arc endpoint.
//    2. ON-ELLIPSE  — every sampled point p satisfies the corrected ellipse
//                     equation: with u = R(-φ)·(p − c), (uₓ/rx)² + (u_y/ry)² = 1.
//    3. SWEEP SIGN  — the total signed angle traversed around the center (in
//                     the ellipse's normalized frame) is positive iff sweep=1.
//    4. ARC SIZE    — |total angle| > π iff large-arc=1 (asserted only where
//                     the input geometry doesn't force ≈180° for both flags).
//
//  These tests are expected to be RED against the empty PathBuilder stub and
//  drive the implementation.
//

import XCTest
import CoreGraphics
@testable import SVGRenderer

final class ArcGeometryTests: XCTestCase {

    // MARK: - Tolerances

    /// Endpoint fidelity. Endpoints are interpolated exactly by the command,
    /// so only representation noise is tolerated.
    private static let endpointTol: CGFloat = 1e-6

    /// Tolerance on the ellipse-equation value f = (uₓ/rx)² + (u_y/ry)², which
    /// is dimensionless (f = 1 on the ellipse). A cubic approximation using
    /// ≤ 90° segments has max relative radial error ~2.7e-4, i.e. |f−1| ≲ 6e-4.
    /// 2e-3 leaves headroom without admitting a visually wrong curve.
    private static let ellipseTol: CGFloat = 2e-3

    /// Tolerance on total traversed angle vs. the spec-computed Δθ (radians).
    private static let angleTol: CGFloat = 5e-3

    // MARK: - Path sampling helpers (read the BUILT geometry back)

    private enum Element {
        case move(CGPoint)
        case line(CGPoint)
        case quad(control: CGPoint, end: CGPoint)
        case cubic(c1: CGPoint, c2: CGPoint, end: CGPoint)
        case close
    }

    private func elements(of path: CGPath) -> [Element] {
        var out: [Element] = []
        path.applyWithBlock { elementPtr in
            let e = elementPtr.pointee
            switch e.type {
            case .moveToPoint:         out.append(.move(e.points[0]))
            case .addLineToPoint:      out.append(.line(e.points[0]))
            case .addQuadCurveToPoint: out.append(.quad(control: e.points[0], end: e.points[1]))
            case .addCurveToPoint:     out.append(.cubic(c1: e.points[0], c2: e.points[1], end: e.points[2]))
            case .closeSubpath:        out.append(.close)
            @unknown default:          break
            }
        }
        return out
    }

    /// Densely sample the path's segments in order. Curves are evaluated with
    /// the exact Bezier polynomial at `samplesPerCurve` parameters, so the
    /// returned points are points of the built geometry itself.
    private func samplePoints(of path: CGPath, samplesPerCurve: Int = 64) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        for element in elements(of: path) {
            switch element {
            case .move(let p):
                current = p; subpathStart = p
                points.append(p)
            case .line(let p):
                points.append(p)
                current = p
            case .quad(let c, let e):
                for i in 1...samplesPerCurve {
                    let t = CGFloat(i) / CGFloat(samplesPerCurve)
                    let mt = 1 - t
                    let x = mt * mt * current.x + 2 * mt * t * c.x + t * t * e.x
                    let y = mt * mt * current.y + 2 * mt * t * c.y + t * t * e.y
                    points.append(CGPoint(x: x, y: y))
                }
                current = e
            case .cubic(let c1, let c2, let e):
                for i in 1...samplesPerCurve {
                    let t = CGFloat(i) / CGFloat(samplesPerCurve)
                    let mt = 1 - t
                    let a = mt * mt * mt, b = 3 * mt * mt * t
                    let cc = 3 * mt * t * t, d = t * t * t
                    let x = a * current.x + b * c1.x + cc * c2.x + d * e.x
                    let y = a * current.y + b * c1.y + cc * c2.y + d * e.y
                    points.append(CGPoint(x: x, y: y))
                }
                current = e
            case .close:
                points.append(subpathStart)
                current = subpathStart
            }
        }
        return points
    }

    private func lastPoint(of path: CGPath) -> CGPoint? {
        samplePoints(of: path).last
    }

    // MARK: - Independent spec reference (SVG 1.1 §F.6.5 / §F.6.6)

    /// Center parameterization computed straight from the spec formulas.
    /// Returns nil for the two degenerate dispositions the spec defines:
    /// coincident endpoints (segment omitted) and zero radius (straight line).
    private struct SpecArc {
        let center: CGPoint
        let rx: CGFloat        // corrected radii (F.6.6 step 3)
        let ry: CGFloat
        let phi: CGFloat       // x-axis rotation, radians
        let theta1: CGFloat    // start angle (F.6.5 step 4)
        let deltaTheta: CGFloat

        init?(from p1: CGPoint, arc: ArcTo) {
            // F.6.2: identical endpoints → segment omitted.
            if p1 == arc.end { return nil }
            // F.6.6 step 1/2: take |r|; zero radius → straight line.
            var rx = abs(arc.rx), ry = abs(arc.ry)
            if rx == 0 || ry == 0 { return nil }
            let phi = arc.xAxisRotation.truncatingRemainder(dividingBy: 360) * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)

            // F.6.5 step 1: midpoint frame.
            let dx = (p1.x - arc.end.x) / 2
            let dy = (p1.y - arc.end.y) / 2
            let x1p = cosPhi * dx + sinPhi * dy
            let y1p = -sinPhi * dx + cosPhi * dy

            // F.6.6 step 3: scale up out-of-range radii.
            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                let s = sqrt(lambda)
                rx *= s
                ry *= s
            }

            // F.6.5 step 2: center in the primed frame.
            let rx2 = rx * rx, ry2 = ry * ry
            let x1p2 = x1p * x1p, y1p2 = y1p * y1p
            let radicand = max(0, (rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
                                / (rx2 * y1p2 + ry2 * x1p2))
            let sign: CGFloat = (arc.largeArc != arc.sweep) ? 1 : -1
            let coef = sign * sqrt(radicand)
            let cxp = coef * (rx * y1p / ry)
            let cyp = coef * -(ry * x1p / rx)

            // F.6.5 step 3: back to user space.
            let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + arc.end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + arc.end.y) / 2

            // F.6.5 step 4: angles between vectors, then the sweep-flag fixup.
            let theta1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
            let theta2 = atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx)
            var delta = theta2 - theta1
            if arc.sweep && delta < 0 { delta += 2 * .pi }
            if !arc.sweep && delta > 0 { delta -= 2 * .pi }

            self.center = CGPoint(x: cx, y: cy)
            self.rx = rx
            self.ry = ry
            self.phi = phi
            self.theta1 = theta1
            self.deltaTheta = delta
        }

        /// Map a user-space point into the ellipse's normalized frame:
        /// unrotate about the center, divide out the radii. On the ellipse the
        /// result lies on the unit circle.
        func normalized(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            let ux = cos(phi) * dx + sin(phi) * dy
            let uy = -sin(phi) * dx + cos(phi) * dy
            return CGPoint(x: ux / rx, y: uy / ry)
        }
    }

    // MARK: - Invariant assertion engine

    /// Build `M start` + the arc, then assert the four input-derivable
    /// invariants listed in the header against the sampled built geometry.
    /// `checkArcSize` is disabled by callers whose input geometry forces the
    /// two flag choices to coincide at ≈180° (chord == 2r after correction).
    private func assertArcInvariants(from start: CGPoint,
                                     arc: ArcTo,
                                     checkArcSize: Bool = true,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard let ref = SpecArc(from: start, arc: arc) else {
            XCTFail("input is degenerate per spec; use the dedicated degenerate tests", file: file, line: line)
            return
        }
        let path = PathBuilder.build([.moveTo(start), .arc(arc)])
        let pts = samplePoints(of: path)

        // 1. ENDPOINTS — the path exists, starts at `start`, ends at `arc.end`.
        guard let first = pts.first, let last = pts.last, pts.count >= 3 else {
            XCTFail("built path has no arc geometry", file: file, line: line)
            return
        }
        XCTAssertEqual(first.x, start.x, accuracy: Self.endpointTol, "start x", file: file, line: line)
        XCTAssertEqual(first.y, start.y, accuracy: Self.endpointTol, "start y", file: file, line: line)
        XCTAssertEqual(last.x, arc.end.x, accuracy: Self.endpointTol, "end x", file: file, line: line)
        XCTAssertEqual(last.y, arc.end.y, accuracy: Self.endpointTol, "end y", file: file, line: line)

        // 2. ON-ELLIPSE — every sample satisfies the corrected ellipse equation.
        var worst: CGFloat = 0
        for p in pts {
            let u = ref.normalized(p)
            let f = u.x * u.x + u.y * u.y
            worst = max(worst, abs(f - 1))
        }
        XCTAssertLessThanOrEqual(worst, Self.ellipseTol,
                                 "max ellipse-equation deviation \(worst)", file: file, line: line)

        // 3./4. SWEEP SIGN and ARC SIZE — unwrap the angle of each sample in
        // the normalized frame; the summed increments are the traversed angle.
        var total: CGFloat = 0
        var prevAngle: CGFloat?
        for p in pts {
            let u = ref.normalized(p)
            let a = atan2(u.y, u.x)
            if let prev = prevAngle {
                var d = a - prev
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                total += d
            }
            prevAngle = a
        }
        if arc.sweep {
            XCTAssertGreaterThan(total, 0, "sweep=1 must traverse positive angles", file: file, line: line)
        } else {
            XCTAssertLessThan(total, 0, "sweep=0 must traverse negative angles", file: file, line: line)
        }
        if checkArcSize {
            if arc.largeArc {
                XCTAssertGreaterThan(abs(total), .pi, "large-arc=1 must take the >180° arc", file: file, line: line)
            } else {
                XCTAssertLessThan(abs(total), .pi, "large-arc=0 must take the <180° arc", file: file, line: line)
            }
        }
        // Cross-check magnitude against the spec-computed Δθ.
        XCTAssertEqual(total, ref.deltaTheta, accuracy: Self.angleTol,
                       "traversed angle vs. spec Δθ", file: file, line: line)
    }

    // MARK: - All four flag combinations (well-separated geometry)

    /// rx=ry=60, chord 80 < 2r, so small (<180°) and large (>180°) arcs are
    /// genuinely distinct for every flag combination.
    func testFlagCombination_small_ccwNegative() {
        assertArcInvariants(from: CGPoint(x: 10, y: 20),
                            arc: ArcTo(rx: 60, ry: 60, xAxisRotation: 0,
                                       largeArc: false, sweep: false,
                                       end: CGPoint(x: 90, y: 20)))
    }

    func testFlagCombination_small_cwPositive() {
        assertArcInvariants(from: CGPoint(x: 10, y: 20),
                            arc: ArcTo(rx: 60, ry: 60, xAxisRotation: 0,
                                       largeArc: false, sweep: true,
                                       end: CGPoint(x: 90, y: 20)))
    }

    func testFlagCombination_large_ccwNegative() {
        assertArcInvariants(from: CGPoint(x: 10, y: 20),
                            arc: ArcTo(rx: 60, ry: 60, xAxisRotation: 0,
                                       largeArc: true, sweep: false,
                                       end: CGPoint(x: 90, y: 20)))
    }

    func testFlagCombination_large_cwPositive() {
        assertArcInvariants(from: CGPoint(x: 10, y: 20),
                            arc: ArcTo(rx: 60, ry: 60, xAxisRotation: 0,
                                       largeArc: true, sweep: true,
                                       end: CGPoint(x: 90, y: 20)))
    }

    // MARK: - Near-180° arcs (radicand → 0 from above)

    /// Chord 99.99, r=50: Δθ is within ~1.1° of π on the small side and the
    /// large side — the radicand in F.6.5 step 2 is nearly zero and its sign
    /// handling must not flip the center to the wrong side.
    func testNear180_smallSide() {
        for sweep in [false, true] {
            assertArcInvariants(from: CGPoint(x: 0, y: 0),
                                arc: ArcTo(rx: 50, ry: 50, xAxisRotation: 0,
                                           largeArc: false, sweep: sweep,
                                           end: CGPoint(x: 99.99, y: 0)))
        }
    }

    func testNear180_largeSide() {
        for sweep in [false, true] {
            assertArcInvariants(from: CGPoint(x: 0, y: 0),
                                arc: ArcTo(rx: 50, ry: 50, xAxisRotation: 0,
                                           largeArc: true, sweep: sweep,
                                           end: CGPoint(x: 99.99, y: 0)))
        }
    }

    /// Chord exactly 2r: radicand exactly 0, Δθ = ±π for BOTH large-arc
    /// choices, so only endpoint/ellipse/sweep invariants apply.
    func testExact180_chordEqualsDiameter() {
        for largeArc in [false, true] {
            for sweep in [false, true] {
                assertArcInvariants(from: CGPoint(x: 0, y: 0),
                                    arc: ArcTo(rx: 50, ry: 50, xAxisRotation: 0,
                                               largeArc: largeArc, sweep: sweep,
                                               end: CGPoint(x: 100, y: 0)),
                                    checkArcSize: false)
            }
        }
    }

    // MARK: - Coincident and near-coincident endpoints

    /// F.6.2: identical endpoints → the arc segment is omitted entirely.
    /// The built path must contain the moveTo and nothing else.
    func testCoincidentEndpoints_arcOmitted() {
        let start = CGPoint(x: 42, y: -7)
        let path = PathBuilder.build([
            .moveTo(start),
            .arc(ArcTo(rx: 50, ry: 50, xAxisRotation: 0,
                       largeArc: true, sweep: true, end: start)),
        ])
        let elems = elements(of: path)
        XCTAssertEqual(elems.count, 1, "arc with coincident endpoints must add no geometry")
        if case .move(let p) = elems.first {
            XCTAssertEqual(p.x, start.x, accuracy: Self.endpointTol)
            XCTAssertEqual(p.y, start.y, accuracy: Self.endpointTol)
        } else {
            XCTFail("expected the path to consist of exactly the moveTo")
        }
    }

    /// Endpoints 1e-6 apart with large-arc=1: per spec this is NOT omitted —
    /// it is a nearly-full ellipse (|Δθ| → 2π). The traversal magnitude check
    /// inside the engine enforces that via the spec Δθ cross-check.
    func testNearCoincidentEndpoints_largeArc_nearFullEllipse() {
        for sweep in [false, true] {
            assertArcInvariants(from: CGPoint(x: 0, y: 0),
                                arc: ArcTo(rx: 50, ry: 50, xAxisRotation: 0,
                                           largeArc: true, sweep: sweep,
                                           end: CGPoint(x: 1e-6, y: 0)))
        }
    }

    // MARK: - Zero / near-zero radii → straight line (F.6.6 step 1)

    func testZeroRadiusIsStraightLine() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 110, y: 60)
        for (rx, ry): (CGFloat, CGFloat) in [(0, 40), (40, 0), (0, 0)] {
            let path = PathBuilder.build([
                .moveTo(start),
                .arc(ArcTo(rx: rx, ry: ry, xAxisRotation: 30,
                           largeArc: true, sweep: false, end: end)),
            ])
            let pts = samplePoints(of: path)
            guard let last = pts.last, pts.count >= 2 else {
                XCTFail("zero-radius arc must still produce a line to the endpoint")
                continue
            }
            XCTAssertEqual(last.x, end.x, accuracy: Self.endpointTol)
            XCTAssertEqual(last.y, end.y, accuracy: Self.endpointTol)
            // Collinearity: every sample lies on segment start→end.
            let vx = end.x - start.x, vy = end.y - start.y
            let len = (vx * vx + vy * vy).squareRoot()
            for p in pts {
                let cross = (p.x - start.x) * vy - (p.y - start.y) * vx
                XCTAssertEqual(cross / len, 0, accuracy: 1e-6,
                               "point \(p) is off the straight line")
            }
        }
    }

    // MARK: - Out-of-range radii (F.6.6 step 3 scaling)

    /// rx=ry=10 but chord=100: radii must be scaled up (to 50 here) and the
    /// result is a half-circle on the corrected ellipse. `SpecArc` computes
    /// the corrected radii from the spec, so the on-ellipse check validates
    /// the correction. Both flag choices give |Δθ|=π → arc-size check off.
    func testOutOfRangeRadiiScaledUp() {
        for largeArc in [false, true] {
            for sweep in [false, true] {
                assertArcInvariants(from: CGPoint(x: 0, y: 0),
                                    arc: ArcTo(rx: 10, ry: 10, xAxisRotation: 0,
                                               largeArc: largeArc, sweep: sweep,
                                               end: CGPoint(x: 100, y: 0)),
                                    checkArcSize: false)
            }
        }
    }

    /// Anisotropic out-of-range radii with rotation: the correction must scale
    /// rx and ry by the same factor (preserving their ratio).
    func testOutOfRangeRadii_anisotropicRotated() {
        assertArcInvariants(from: CGPoint(x: -30, y: 12),
                            arc: ArcTo(rx: 8, ry: 3, xAxisRotation: 25,
                                       largeArc: false, sweep: true,
                                       end: CGPoint(x: 70, y: -5)),
                            checkArcSize: false)
    }

    /// Tiny positive radii are NOT a line — the spec scales them up.
    func testTinyRadiiScaledUpNotLine() {
        assertArcInvariants(from: CGPoint(x: 0, y: 0),
                            arc: ArcTo(rx: 1e-8, ry: 1e-8, xAxisRotation: 0,
                                       largeArc: false, sweep: true,
                                       end: CGPoint(x: 10, y: 0)),
                            checkArcSize: false)
    }

    // MARK: - Huge radii (shallow arc; catastrophic-cancellation territory)

    func testHugeRadiiShallowArc() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let arc = ArcTo(rx: 1e6, ry: 1e6, xAxisRotation: 0,
                        largeArc: false, sweep: true, end: end)
        assertArcInvariants(from: start, arc: arc)
        // Additionally: the sag of this arc is r − √(r² − (c/2)²) ≈ 0.00125,
        // derivable from the input alone. No sampled point may stray far from
        // the chord.
        let path = PathBuilder.build([.moveTo(start), .arc(arc)])
        let maxSag = 1e6 - (1e12 - 2500 as CGFloat).squareRoot()  // ≈ 0.00125
        for p in samplePoints(of: path) {
            XCTAssertLessThanOrEqual(abs(p.y), maxSag * 1.5,
                                     "shallow arc bulged to \(p.y); expected ≤ ~\(maxSag)")
            XCTAssertGreaterThanOrEqual(p.x, -1e-3)
            XCTAssertLessThanOrEqual(p.x, 100 + 1e-3)
        }
    }

    // MARK: - Rotation handling

    func testRotatedEllipseBothSweeps() {
        for sweep in [false, true] {
            assertArcInvariants(from: CGPoint(x: 5, y: 40),
                                arc: ArcTo(rx: 80, ry: 30, xAxisRotation: 37,
                                           largeArc: false, sweep: sweep,
                                           end: CGPoint(x: 60, y: 90)))
        }
    }

    func testRotatedEllipseLargeArc() {
        assertArcInvariants(from: CGPoint(x: 5, y: 40),
                            arc: ArcTo(rx: 80, ry: 30, xAxisRotation: 37,
                                       largeArc: true, sweep: true,
                                       end: CGPoint(x: 60, y: 90)))
    }

    /// x-axis-rotation is periodic: 37°, 397° and −323° describe the same
    /// ellipse, so the built geometry must coincide pointwise. (An equivalence
    /// derivable from the input, not a comparison against stored output.)
    func testRotationNormalizationMod360() {
        let start = CGPoint(x: 5, y: 40)
        let end = CGPoint(x: 60, y: 90)
        func build(_ rotation: CGFloat) -> [CGPoint] {
            samplePoints(of: PathBuilder.build([
                .moveTo(start),
                .arc(ArcTo(rx: 80, ry: 30, xAxisRotation: rotation,
                           largeArc: false, sweep: true, end: end)),
            ]))
        }
        let base = build(37), plus = build(397), minus = build(-323)
        XCTAssertGreaterThan(base.count, 2, "expected arc geometry")
        XCTAssertEqual(base.count, plus.count)
        XCTAssertEqual(base.count, minus.count)
        for (a, b) in zip(base, plus) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
        for (a, b) in zip(base, minus) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    /// Negative radii: F.6.6 step 1 takes |r|; must behave exactly like the
    /// positive-radius arc.
    func testNegativeRadiiUseAbsoluteValue() {
        assertArcInvariants(from: CGPoint(x: 10, y: 20),
                            arc: ArcTo(rx: -60, ry: -60, xAxisRotation: 0,
                                       largeArc: false, sweep: true,
                                       end: CGPoint(x: 90, y: 20)))
    }

    // MARK: - Extreme aspect ratio (flagged in ArcGeometryNotes.md)

    func testExtremeAspectRatio() {
        assertArcInvariants(from: CGPoint(x: 0, y: 0),
                            arc: ArcTo(rx: 1000, ry: 1, xAxisRotation: 0,
                                       largeArc: false, sweep: true,
                                       end: CGPoint(x: 200, y: 0)))
    }

    // MARK: - Arcs inside longer paths

    /// The arc must start from the running current point (after lines/curves),
    /// and drawing continues from its endpoint.
    func testArcChainedAfterOtherSegments() {
        let arcStart = CGPoint(x: 50, y: 30)
        let arcEnd = CGPoint(x: 120, y: 30)
        let arc = ArcTo(rx: 40, ry: 40, xAxisRotation: 0,
                        largeArc: false, sweep: true, end: arcEnd)
        let path = PathBuilder.build([
            .moveTo(CGPoint(x: 0, y: 0)),
            .lineTo(CGPoint(x: 20, y: 10)),
            .cubicTo(control1: CGPoint(x: 30, y: 10),
                     control2: CGPoint(x: 40, y: 30),
                     end: arcStart),
            .arc(arc),
            .lineTo(CGPoint(x: 150, y: 60)),
        ])
        guard let ref = SpecArc(from: arcStart, arc: arc) else {
            return XCTFail("unexpected degenerate reference")
        }
        let pts = samplePoints(of: path)
        XCTAssertEqual(pts.first?.x ?? .nan, 0, accuracy: Self.endpointTol)
        XCTAssertEqual(pts.last?.x ?? .nan, 150, accuracy: Self.endpointTol)
        XCTAssertEqual(pts.last?.y ?? .nan, 60, accuracy: Self.endpointTol)
        // Both arc endpoints must be reachable within tolerance somewhere in
        // the sampled stream (the arc is stitched between them).
        func closestDistance(to target: CGPoint) -> CGFloat {
            pts.map { hypot($0.x - target.x, $0.y - target.y) }.min() ?? .infinity
        }
        XCTAssertLessThanOrEqual(closestDistance(to: arcStart), 1e-6)
        XCTAssertLessThanOrEqual(closestDistance(to: arcEnd), 1e-6)
        // Every sample near the arc's ellipse-frame must not violate the
        // ellipse equation by being between the endpoints angularly yet far
        // off the ellipse — instead check the specific arc samples: rebuild
        // the arc alone from its commanded start and verify invariants.
        assertArcInvariants(from: arcStart, arc: arc)
        _ = ref
    }

    // MARK: - Non-arc command mapping (endpoint fidelity of the full set)

    /// H/V/S/T and all relative forms are lowered by PathDataParser into the
    /// six IR commands, so the full M/L/H/V/C/S/Q/T/A/Z set funnels through
    /// this builder. Parse a d-string using every command letter and verify
    /// the built path's endpoints and closure — values below are hand-derived
    /// from the SVG path grammar.
    func testFullCommandSetThroughParser() {
        let d = "M 10 10 L 20 10 H 30 V 20 C 30 30 40 30 40 20 " +
                "S 50 10 50 20 Q 55 30 60 20 T 70 20 " +
                "a 5 5 0 0 1 10 0 Z"
        let commands = PathDataParser.parse(d)
        XCTAssertEqual(commands.count, 10, "parser should produce 10 IR commands")
        let path = PathBuilder.build(commands)
        let elems = elements(of: path)
        XCTAssertFalse(path.isEmpty)
        // Path is closed.
        guard case .close = elems.last else {
            return XCTFail("expected closing element")
        }
        // The point before Z is the arc endpoint (70+10, 20) = (80, 20).
        let pts = samplePoints(of: path)
        // Last sample is the subpath start (10,10) due to close; the one
        // before the close-run must be (80, 20).
        XCTAssertEqual(pts.last?.x ?? .nan, 10, accuracy: Self.endpointTol)
        XCTAssertEqual(pts.last?.y ?? .nan, 10, accuracy: Self.endpointTol)
        let beforeClose = pts[pts.count - 2]
        XCTAssertEqual(beforeClose.x, 80, accuracy: Self.endpointTol)
        XCTAssertEqual(beforeClose.y, 20, accuracy: Self.endpointTol)
        // And the moveTo is (10,10).
        XCTAssertEqual(pts.first?.x ?? .nan, 10, accuracy: Self.endpointTol)
        XCTAssertEqual(pts.first?.y ?? .nan, 10, accuracy: Self.endpointTol)
    }

    /// Quadratic and cubic IR commands must map to real curve elements with
    /// their commanded control points (data-preserving mapping, not flattening).
    func testCurveCommandsPreserveControlPoints() {
        let path = PathBuilder.build([
            .moveTo(CGPoint(x: 0, y: 0)),
            .quadTo(control: CGPoint(x: 10, y: 20), end: CGPoint(x: 20, y: 0)),
            .cubicTo(control1: CGPoint(x: 30, y: 10),
                     control2: CGPoint(x: 40, y: -10),
                     end: CGPoint(x: 50, y: 0)),
        ])
        let elems = elements(of: path)
        XCTAssertEqual(elems.count, 3)
        guard elems.count == 3 else { return }
        if case .quad(let c, let e) = elems[1] {
            XCTAssertEqual(c.x, 10, accuracy: Self.endpointTol)
            XCTAssertEqual(c.y, 20, accuracy: Self.endpointTol)
            XCTAssertEqual(e.x, 20, accuracy: Self.endpointTol)
        } else {
            XCTFail("expected a quad element, got \(elems[1])")
        }
        if case .cubic(let c1, let c2, let e) = elems[2] {
            XCTAssertEqual(c1.x, 30, accuracy: Self.endpointTol)
            XCTAssertEqual(c2.y, -10, accuracy: Self.endpointTol)
            XCTAssertEqual(e.x, 50, accuracy: Self.endpointTol)
        } else {
            XCTFail("expected a cubic element, got \(elems[2])")
        }
    }

    /// SVG requires a path to begin with a moveto; drawing commands with no
    /// current point are dropped (never crash, never invent a start point).
    func testCommandsBeforeFirstMoveAreDropped() {
        let path = PathBuilder.build([
            .lineTo(CGPoint(x: 10, y: 10)),
            .arc(ArcTo(rx: 5, ry: 5, xAxisRotation: 0,
                       largeArc: false, sweep: true, end: CGPoint(x: 20, y: 0))),
            .moveTo(CGPoint(x: 1, y: 2)),
            .lineTo(CGPoint(x: 3, y: 4)),
        ])
        let elems = elements(of: path)
        XCTAssertEqual(elems.count, 2, "pre-moveTo commands must be dropped")
        if case .move(let p) = elems.first {
            XCTAssertEqual(p.x, 1, accuracy: Self.endpointTol)
        } else {
            XCTFail("first element must be the moveTo")
        }
    }
}
