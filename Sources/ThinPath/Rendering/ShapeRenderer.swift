//
//  ShapeRenderer.swift
//  ThinPath
//
//  Leaf geometry for `rect`/`circle`/`ellipse`/`line`/`polyline`/`polygon`/`path`,
//  plus the fill-then-stroke paint dispatch shared by every shape kind, and the
//  cheap `SolidPaint` case of the `PaintSource` protocol (Compositing.md §2 — no
//  clip, no layer, no coordinate mapping).
//
//  Geometry building is pure value math (`CGPath`); painting draws directly into
//  `context.cg` with a single save/restore bracket per pass so a mid-fill CG
//  state change (fill color, clip) can never leak into the stroke pass or beyond.
//

import CoreGraphics
import Foundation

// MARK: - Leaf geometry

public enum ShapeRenderer {

    /// Build the fillable geometry for a `shape`/`poly`/`path` node, in the
    /// node's own user space (no transform applied — the CTM is already
    /// positioned by the walk). `.none`-kind nodes (containers, etc.) yield an
    /// empty path.
    public static func leafPath(_ node: NodeIndex, document: SVGDocument) -> CGPath {
        switch document.node(node).kind {
        case .shape(let shape):
            return basicShapePath(shape)
        case .poly(let points, let closed):
            return polyPath(document.points(points), closed: closed)
        case .path(let commands):
            return PathBuilder.build(document.commands(commands))
        default:
            return CGMutablePath()
        }
    }

    private static func basicShapePath(_ shape: Shape) -> CGPath {
        switch shape {
        case .rect(let x, let y, let width, let height, let rx, let ry):
            guard width > 0, height > 0 else { return CGMutablePath() }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if rx > 0 || ry > 0 {
                // rx/ry default to each other when only one is specified
                // (SVGParser.makeNodeKind already mirrors that), so both are
                // positive here whenever either was authored.
                return CGPath(roundedRect: rect,
                              cornerWidth: min(rx > 0 ? rx : ry, width / 2),
                              cornerHeight: min(ry > 0 ? ry : rx, height / 2),
                              transform: nil)
            }
            return CGPath(rect: rect, transform: nil)

        case .circle(let cx, let cy, let r):
            guard r > 0 else { return CGMutablePath() }
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)

        case .ellipse(let cx, let cy, let rx, let ry):
            guard rx > 0, ry > 0 else { return CGMutablePath() }
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)

        case .line(let x1, let y1, let x2, let y2):
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            return path
        }
    }

    private static func polyPath(_ points: ArraySlice<CGPoint>, closed: Bool) -> CGPath {
        let path = CGMutablePath()
        var first = true
        for p in points {
            if first {
                path.move(to: p)
                first = false
            } else {
                path.addLine(to: p)
            }
        }
        if closed, !first {
            path.closeSubpath()
        }
        return path
    }

    // MARK: - Fill-then-stroke paint dispatch

    /// Paint one shape/path/poly node: fill first, then stroke (SVG paint
    /// order), each through its resolved `PaintSource`. `opacity` (group
    /// opacity) is folded into the fill/stroke alpha here UNLESS an isolation
    /// layer already accounts for it (see `RenderContext.needsIsolationLayer`
    /// — a shape only gets a layer when it paints both fill and stroke AND a
    /// mask is absent; every other case must fold or double-apply the alpha).
    public static func drawShape(_ node: NodeIndex, path: CGPath, style: ComputedStyle, context: RenderContext) {
        guard style.visibility == .visible else { return }

        let fillSource = PaintResolver.resolve(style.fill, references: context.references)
        let strokeWidth = style.strokeWidth
        let strokeSource = strokeWidth > 0 ? PaintResolver.resolve(style.stroke, references: context.references) : nil

        let paintsFill = fillSource != nil
        let paintsStroke = strokeSource != nil
        guard paintsFill || paintsStroke else { return }

        let isolate = context.needsIsolationLayer(node, style: style,
                                                   paintsFillAndStroke: paintsFill && paintsStroke)
        // The layer (when opened) composites at `style.groupOpacity` UNLESS a
        // mask is present, in which case the layer's own alpha is fixed at 1
        // (RenderWalk.render) and group opacity must still be folded here.
        let opacityConsumedByLayer = isolate && style.mask.isNone
        let extraAlpha: CGFloat = opacityConsumedByLayer ? 1 : style.groupOpacity

        let objectBounds = path.boundingBoxOfPath

        if let fillSource, paintsFill {
            let alpha = style.fillOpacity * extraAlpha
            if alpha > 0 {
                fillSource.fill(path: path, rule: style.fillRule, objectBounds: objectBounds,
                                alpha: alpha, into: context)
            }
        }

        if let strokeSource, paintsStroke {
            let alpha = style.strokeOpacity * extraAlpha
            if alpha > 0 {
                let outline = path.copy(strokingWithWidth: strokeWidth,
                                        lineCap: cgLineCap(style.strokeLineCap),
                                        lineJoin: cgLineJoin(style.strokeLineJoin),
                                        miterLimit: style.strokeMiterLimit)
                strokeSource.fill(path: outline, rule: .nonZero, objectBounds: objectBounds,
                                  alpha: alpha, into: context)
            }
        }
    }

    private static func cgLineCap(_ cap: LineCap) -> CGLineCap {
        switch cap {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }

    private static func cgLineJoin(_ join: LineJoin) -> CGLineJoin {
        switch join {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }

    // MARK: - SolidPaint (the cheap PaintSource case)

    /// `SolidPaint.fill` body (Compositing.md §2): set the fill color at
    /// `color × alpha`, add the path, fill with `rule`. No clip, no layer, no
    /// coordinate mapping — the single cheapest paint path.
    public static func fillSolid(_ paint: SolidPaint, path: CGPath, rule: FillRule,
                                 alpha: CGFloat, into context: RenderContext) {
        guard alpha > 0 else { return }
        let cg = context.cg
        cg.saveGState()
        let a = CGFloat(paint.color.a) / 255 * alpha
        cg.setFillColor(red: CGFloat(paint.color.r) / 255,
                        green: CGFloat(paint.color.g) / 255,
                        blue: CGFloat(paint.color.b) / 255,
                        alpha: a)
        cg.addPath(path)
        cg.fillPath(using: rule == .nonZero ? .winding : .evenOdd)
        cg.restoreGState()
    }
}
