//
//  GradientRenderer.swift
//  ThinPath
//
//  `GradientPaint`'s real body (Compositing.md §3, §5): resolves the effective
//  gradient (folding an `href` template chain for stops only — every other
//  gradient attribute is already defaulted at parse time, see SVGParser), maps
//  its geometry into the painted element's user space via `PaintCoordinateSpace`,
//  and realizes `spreadMethod` reflect/repeat by synthesizing an extended stop
//  ramp across only the periods needed to cover the paint region.
//
//  KEY TRICK for radial gradients under a non-uniform `objectBoundingBox` matrix:
//  rather than mapping the gradient's circle geometry into user space (which
//  would turn a circle into an ellipse CG's two-circle radial shading can't
//  express directly), we clip to the fill path, concatenate `serverToUser` onto
//  the CTM, and draw the gradient's UNMAPPED (server-space) circle geometry —
//  the CTM does the elliptical distortion for free, exactly like everything
//  else in this renderer.
//

import CoreGraphics
import Foundation

public enum GradientRenderer {

    public static func fill(node: NodeIndex, path: CGPath, rule: FillRule,
                            objectBounds: CGRect, alpha: CGFloat, into context: RenderContext) {
        guard alpha > 0 else { return }
        guard case .gradient(let gradient) = context.document.node(node).kind else { return }

        let stops = effectiveStops(node: node, gradient: gradient, context: context)
        guard !stops.isEmpty else { return }

        let serverTransform = context.document.affineTransform(gradient.gradientTransform)
        let space = PaintCoordinateSpace(units: gradient.units, serverTransform: serverTransform,
                                         objectBounds: objectBounds)
        guard let serverToUser = space.serverToUser else { return }   // degenerate bbox → absent

        let cg = context.cg
        cg.saveGState()
        cg.addPath(path)
        cg.clip(using: rule == .nonZero ? .winding : .evenOdd)
        cg.concatenate(serverToUser)

        switch gradient.geometry {
        case .linear(let x1, let y1, let x2, let y2):
            drawLinear(cg: cg, stops: stops, spread: gradient.spread, alpha: alpha,
                      p0: CGPoint(x: x1, y: y1), p1: CGPoint(x: x2, y: y2))
        case .radial(let cx, let cy, let r, let fx, let fy):
            drawRadial(cg: cg, stops: stops, spread: gradient.spread, alpha: alpha,
                      center: CGPoint(x: cx, y: cy), radius: r, focus: CGPoint(x: fx, y: fy))
        }

        cg.restoreGState()
    }

    // MARK: - Stop resolution (href template chain, stops only)

    /// A gradient with no stops of its own inherits its stop list from the
    /// nearest ancestor (via `href`) that has any — every other attribute is
    /// already concrete at parse time (SVGParser bakes defaults), so stops are
    /// the only thing that needs to walk the template chain. Cycle-guarded.
    private static func effectiveStops(node: NodeIndex, gradient: Gradient, context: RenderContext) -> [GradientStop] {
        if !gradient.stops.isEmpty {
            return Array(context.document.stops(gradient.stops))
        }
        guard !context.references.hasTemplateCycle(startingAt: node) else { return [] }
        var current = context.references.templateOf(node)
        while !current.isNone {
            if case .gradient(let g) = context.document.node(current).kind, !g.stops.isEmpty {
                return Array(context.document.stops(g.stops))
            }
            current = context.references.templateOf(current)
        }
        return []
    }

    // MARK: - Linear

    private static func drawLinear(cg: CGContext, stops: [GradientStop], spread: SpreadMethod,
                                   alpha: CGFloat, p0: CGPoint, p1: CGPoint) {
        switch spread {
        case .pad:
            let cgGradient = makeCGGradient(stops, alpha: alpha)
            cg.drawLinearGradient(cgGradient, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .reflect, .repeatSpread:
            let extent = periodExtent(p0: p0, p1: p1, region: cg.boundingBoxOfClipPath)
            let (newP0, newP1, extended) = extendedLinear(stops: stops, spread: spread,
                                                          p0: p0, p1: p1, extent: extent)
            let cgGradient = makeCGGradient(extended, alpha: alpha)
            cg.drawLinearGradient(cgGradient, start: newP0, end: newP1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// How many whole periods (of length `|p1-p0|`) before/after the base
    /// vector are needed to cover `region` (the current clip's user-space
    /// bounding box — i.e. clip ∩ dirty, never the unbounded plane).
    private static func periodExtent(p0: CGPoint, p1: CGPoint, region: CGRect) -> (before: Int, after: Int) {
        guard !region.isNull, !region.isInfinite else { return (0, 1) }
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return (0, 1) }
        // Project each corner of region onto the gradient axis, in units of
        // the period length, to find the parametric range that needs cover.
        let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY)]
        var minT: CGFloat = 0, maxT: CGFloat = 1
        for c in corners {
            let t = ((c.x - p0.x) * dx + (c.y - p0.y) * dy) / lenSq
            minT = min(minT, t)
            maxT = max(maxT, t)
        }
        let before = max(0, Int((-minT).rounded(.up)))
        let after = max(1, Int(maxT.rounded(.up)))
        // Cap synthetic-stop growth (Compositing.md §5 PROFILE-CHECK).
        let cap = 64
        return (min(before, cap), min(after, cap))
    }

    private static func extendedLinear(stops: [GradientStop], spread: SpreadMethod,
                                       p0: CGPoint, p1: CGPoint,
                                       extent: (before: Int, after: Int)) -> (CGPoint, CGPoint, [GradientStop]) {
        let totalPeriods = extent.before + extent.after
        guard totalPeriods > 0 else { return (p0, p1, stops) }
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let newP0 = CGPoint(x: p0.x - dx * CGFloat(extent.before), y: p0.y - dy * CGFloat(extent.before))
        let newP1 = CGPoint(x: p1.x + dx * CGFloat(extent.after - 1), y: p1.y + dy * CGFloat(extent.after - 1))
        let extended = expandStops(stops, spread: spread, periodsBefore: extent.before, totalPeriods: totalPeriods)
        return (newP0, newP1, extended)
    }

    /// Build the extended stop array spanning `totalPeriods` periods, with the
    /// original vector's period index `periodsBefore` (offsets normalized so the
    /// caller's extended start/end vector spans exactly `totalPeriods` periods).
    private static func expandStops(_ stops: [GradientStop], spread: SpreadMethod,
                                    periodsBefore: Int, totalPeriods: Int) -> [GradientStop] {
        var result: [GradientStop] = []
        result.reserveCapacity(stops.count * totalPeriods)
        for period in 0..<totalPeriods {
            let periodIndex = period - periodsBefore
            let reflected = spread == .reflect && periodIndex % 2 != 0
            let ordered = reflected ? stops.reversed().map { GradientStop(offset: 1 - $0.offset, color: $0.color) } : stops
            for s in ordered {
                let global = (CGFloat(period) + s.offset) / CGFloat(totalPeriods)
                result.append(GradientStop(offset: global, color: s.color))
            }
        }
        return result
    }

    // MARK: - Radial

    private static func drawRadial(cg: CGContext, stops: [GradientStop], spread: SpreadMethod,
                                   alpha: CGFloat, center: CGPoint, radius: CGFloat, focus: CGPoint) {
        guard radius > 0 else { return }
        switch spread {
        case .pad:
            let cgGradient = makeCGGradient(stops, alpha: alpha)
            cg.drawRadialGradient(cgGradient, startCenter: focus, startRadius: 0,
                                  endCenter: center, endRadius: radius,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .reflect, .repeatSpread:
            // Extend outward by however many whole radii cover the clip's
            // extent from the gradient's own center, capped as with linear.
            let region = cg.boundingBoxOfClipPath
            var periods = 1
            if !region.isNull, !region.isInfinite {
                let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                              CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY)]
                let maxDist = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? radius
                periods = max(1, min(64, Int((maxDist / radius).rounded(.up))))
            }
            let extended = expandStops(stops, spread: spread, periodsBefore: 0, totalPeriods: periods)
            let cgGradient = makeCGGradient(extended, alpha: alpha)
            cg.drawRadialGradient(cgGradient, startCenter: focus, startRadius: 0,
                                  endCenter: center, endRadius: radius * CGFloat(periods),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: - CGGradient construction

    private static func makeCGGradient(_ stops: [GradientStop], alpha: CGFloat) -> CGGradient {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var locations: [CGFloat] = []
        var components: [CGFloat] = []
        locations.reserveCapacity(stops.count)
        components.reserveCapacity(stops.count * 4)
        for s in stops {
            locations.append(s.offset)
            components.append(CGFloat(s.color.r) / 255)
            components.append(CGFloat(s.color.g) / 255)
            components.append(CGFloat(s.color.b) / 255)
            components.append(CGFloat(s.color.a) / 255 * alpha)
        }
        return CGGradient(colorSpace: colorSpace, colorComponents: components,
                          locations: locations, count: locations.count)!
    }
}
