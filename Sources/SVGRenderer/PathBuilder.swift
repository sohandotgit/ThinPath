//
//  PathBuilder.swift
//  SVGRenderer
//
//  Converts an IR path-command stream into a `CGMutablePath` in user
//  coordinates. No transforms are applied here; the render pass composes the
//  CTM separately (see Transforms.swift).
//
//  The IR already carries absolute coordinates for every command —
//  PathDataParser lowers H/V into `lineTo` and resolves the S/T reflected
//  control points into explicit `cubicTo`/`quadTo` (see the smooth-curve state
//  machine there) — so this pass is a data-preserving mapping for five of the
//  six commands. The real work is the elliptical arc: `ArcTo` stores the raw
//  SVG endpoint parameters and this file owns the endpoint→center
//  parameterization (SVG 1.1 §F.6.5) with the degenerate-case dispositions of
//  §F.6.2/§F.6.6, followed by a cubic-Bezier approximation.
//
//  Numeric notes, error bounds, and the adversarial-input checklist live in
//  Design/ArcGeometryNotes.md. The invariant tests are ArcGeometryTests.swift.
//

import CoreGraphics
import Foundation

public enum PathBuilder {

    /// Build a `CGMutablePath` from IR path commands, in user coordinates.
    ///
    /// Per the SVG spec a path must begin with a moveto; drawing commands that
    /// arrive before any `moveTo` have no current point and are dropped rather
    /// than inventing one (CGPath would otherwise raise a console error or
    /// behave inconsistently across OS versions).
    public static func build(_ commands: some Sequence<PathCommand>) -> CGMutablePath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var hasCurrentPoint = false

        for command in commands {
            switch command {
            case .moveTo(let p):
                path.move(to: p)
                current = p
                subpathStart = p
                hasCurrentPoint = true

            case .lineTo(let p):
                guard hasCurrentPoint else { continue }
                path.addLine(to: p)
                current = p

            case .quadTo(let control, let end):
                guard hasCurrentPoint else { continue }
                path.addQuadCurve(to: end, control: control)
                current = end

            case .cubicTo(let control1, let control2, let end):
                guard hasCurrentPoint else { continue }
                path.addCurve(to: end, control1: control1, control2: control2)
                current = end

            case .arc(let arc):
                guard hasCurrentPoint else { continue }
                appendArc(to: path, from: current, arc: arc)
                current = arc.end

            case .close:
                guard hasCurrentPoint else { continue }
                path.closeSubpath()
                current = subpathStart
            }
        }
        return path
    }

    // MARK: - Elliptical arc (SVG 1.1 §F.6)

    /// Below this, a radius is "zero" and the arc degenerates to a line
    /// (§F.6.6 step 1). Deliberately tiny: any humanly-authored positive
    /// radius, however small, is legal input that the out-of-range correction
    /// scales up to fit the chord (§F.6.6 step 3). This only guards against
    /// exact zeros and sub-denormal noise that would otherwise divide to
    /// inf/NaN.
    private static let radiusEpsilon: CGFloat = 1e-12

    /// Maximum unit-circle angle covered by one cubic segment. π/2 keeps the
    /// standard tangent-length formula's radial error ≤ ~2.7e-4·r — see
    /// ArcGeometryNotes.md for why that is far below a device pixel at any
    /// plausible content scale.
    private static let maxSegmentAngle = CGFloat.pi / 2

    private static func appendArc(to path: CGMutablePath, from start: CGPoint, arc: ArcTo) {
        // §F.6.2: if the endpoints are identical, the segment is omitted
        // entirely. Exact comparison on purpose: NEARLY coincident endpoints
        // are meaningful input (large-arc turns them into an almost-full
        // ellipse) and must not be swallowed by an epsilon here.
        if start == arc.end {
            return
        }

        // §F.6.6 steps 1–2: radii signs are ignored; zero radius → straight
        // line to the endpoint.
        var rx = abs(arc.rx)
        var ry = abs(arc.ry)
        if rx < radiusEpsilon || ry < radiusEpsilon {
            path.addLine(to: arc.end)
            return
        }

        // x-axis-rotation is periodic in 360°; fold it before converting so
        // huge authored values don't lose precision in the trig below.
        let phi = arc.xAxisRotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // §F.6.5 step 1: transform the midpoint of the chord into the frame
        // aligned with the (unrotated) ellipse axes.
        let dx = (start.x - arc.end.x) / 2
        let dy = (start.y - arc.end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // §F.6.6 step 3: if the radii can't span the chord, scale both up by
        // the same factor (preserving rx:ry) until the ellipse exactly fits.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        // §F.6.5 step 2: center in the primed frame. After the radius
        // correction the radicand is ≥ 0 mathematically; clamp it because
        // rounding can leave it at -1e-17 when the chord ≈ 2r (near-180°
        // arcs), and sqrt of that would poison everything downstream with NaN.
        let rx2 = rx * rx, ry2 = ry * ry
        let x1p2 = x1p * x1p, y1p2 = y1p * y1p
        let radicand = max(0, (rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
                            / (rx2 * y1p2 + ry2 * x1p2))
        let centerSign: CGFloat = (arc.largeArc != arc.sweep) ? 1 : -1
        let coef = centerSign * sqrt(radicand)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        // §F.6.5 step 3: center back in user space.
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + arc.end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + arc.end.y) / 2

        // §F.6.5 step 4: start and sweep angles on the unit circle (dividing
        // by the radii maps the ellipse to the unit circle, where atan2 gives
        // the true parametric angle — using undivided vectors would be wrong
        // whenever rx ≠ ry).
        let theta1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
        let theta2 = atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx)
        var deltaTheta = theta2 - theta1
        if arc.sweep, deltaTheta < 0 {
            deltaTheta += 2 * .pi
        } else if !arc.sweep, deltaTheta > 0 {
            deltaTheta -= 2 * .pi
        }

        // Emit the arc as cubic Beziers over ≤ 90° spans of the parametric
        // angle. For a span δ starting at θ, with the ellipse point
        //   E(θ)  = c + R(φ)·(rx·cosθ, ry·sinθ)
        // and derivative
        //   E′(θ) = R(φ)·(−rx·sinθ, ry·cosθ),
        // the segment is (E(θ), E(θ)+t·E′(θ), E(θ+δ)−t·E′(θ+δ), E(θ+δ)) with
        // the standard tangent length t = (4/3)·tan(δ/4).
        func ellipsePoint(_ theta: CGFloat) -> CGPoint {
            let ex = rx * cos(theta), ey = ry * sin(theta)
            return CGPoint(x: cx + cosPhi * ex - sinPhi * ey,
                           y: cy + sinPhi * ex + cosPhi * ey)
        }
        func ellipseDerivative(_ theta: CGFloat) -> CGPoint {
            let ex = -rx * sin(theta), ey = ry * cos(theta)
            return CGPoint(x: cosPhi * ex - sinPhi * ey,
                           y: sinPhi * ex + cosPhi * ey)
        }

        let segmentCount = max(1, Int(ceil(abs(deltaTheta) / maxSegmentAngle)))
        let segmentDelta = deltaTheta / CGFloat(segmentCount)
        let tangentLength = (4.0 / 3.0) * tan(segmentDelta / 4)

        var theta = theta1
        for segment in 0..<segmentCount {
            let thetaNext = theta + segmentDelta
            let p0 = ellipsePoint(theta)
            // Snap the final segment to the commanded endpoint so accumulated
            // trig rounding can never leave a gap at a subpath joint.
            let p1 = segment == segmentCount - 1 ? arc.end : ellipsePoint(thetaNext)
            let d0 = ellipseDerivative(theta)
            let d1 = ellipseDerivative(thetaNext)
            path.addCurve(to: p1,
                          control1: CGPoint(x: p0.x + tangentLength * d0.x,
                                            y: p0.y + tangentLength * d0.y),
                          control2: CGPoint(x: p1.x - tangentLength * d1.x,
                                            y: p1.y - tangentLength * d1.y))
            theta = thetaNext
        }
    }
}
