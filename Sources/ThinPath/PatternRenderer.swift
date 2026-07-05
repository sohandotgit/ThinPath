//
//  PatternRenderer.swift
//  ThinPath
//
//  `PatternPaint`'s real body (Compositing.md §4): tiles a `<pattern>`'s child
//  subtree via a `CGPattern` draw callback that Core Graphics invokes ONCE per
//  tile cell and caches — never a pre-rendered, region-sized bitmap. The
//  callback re-walks the pattern's children into a small per-tile `RenderContext`
//  wrapping the callback's own tile-sized `CGContext`.
//

import CoreGraphics
import Foundation

public enum PatternRenderer {

    public static func fill(node: NodeIndex, path: CGPath, rule: FillRule,
                            objectBounds: CGRect, alpha: CGFloat, into context: RenderContext) {
        guard alpha > 0 else { return }
        guard case .pattern(let pattern) = context.document.node(node).kind else { return }

        // Resolve the effective content source: own children, else follow the
        // `href` template chain (cycle-guarded) to the first ancestor with any.
        guard !context.references.hasTemplateCycle(startingAt: node) else { return }
        var contentSource = node
        var cursor = node
        while context.document.node(cursor).firstChild.isNone {
            let next = context.references.templateOf(cursor)
            guard !next.isNone else { break }
            cursor = next
            if !context.document.node(cursor).firstChild.isNone { contentSource = cursor }
        }
        guard !context.document.node(contentSource).firstChild.isNone else { return }

        let patternTransform = context.document.affineTransform(pattern.patternTransform)
        let space = PaintCoordinateSpace(units: pattern.patternUnits, serverTransform: patternTransform,
                                         objectBounds: objectBounds)
        guard let serverToUser = space.serverToUser else { return }

        let tileBounds = CGRect(x: pattern.x, y: pattern.y, width: pattern.width, height: pattern.height)
        guard tileBounds.width > 0, tileBounds.height > 0 else { return }

        // "Pattern space" (what `tileBounds`/`matrix`/`xStep`/`yStep` below are
        // expressed in) is whatever unit `patternUnits` implies for x/y/width/
        // height — here that's bbox-FRACTIONAL, since `serverToUser` folds in
        // `ObjectBoundingBox.transform`. `patternContentUnits` is independent:
        // when it's `userSpaceOnUse` (the default), the pattern's CHILDREN are
        // authored in ABSOLUTE document user-space units regardless of how the
        // tile rect itself was scaled — so if `patternUnits` is
        // objectBoundingBox, content coordinates must be converted from
        // absolute space INTO that same fractional pattern space (the inverse
        // of the units mapping) before drawing, or they land in the wrong
        // (much larger) coordinate frame entirely.
        var contentMatrix = CGAffineTransform.identity
        if let viewBox = pattern.viewBox {
            contentMatrix = ViewportMath.viewportTransform(
                viewBox: viewBox,
                viewport: CGRect(origin: tileBounds.origin, size: tileBounds.size),
                par: pattern.preserveAspectRatio)
        } else if pattern.patternContentUnits == .objectBoundingBox {
            contentMatrix = ObjectBoundingBox.transform(objectBounds) ?? .identity
        } else if pattern.patternUnits == .objectBoundingBox {
            if let unitsMatrix = ObjectBoundingBox.transform(objectBounds) {
                contentMatrix = unitsMatrix.inverted()
            }
        }

        let cg = context.cg
        cg.saveGState()
        cg.addPath(path)
        cg.clip(using: rule == .nonZero ? .winding : .evenOdd)

        let patternSpaceToDevice = serverToUser.concatenating(cg.ctm)

        let box = Unmanaged.passRetained(PatternCellBox(
            document: context.document, images: context.images,
            contentSource: contentSource, contentMatrix: contentMatrix,
            tileBounds: tileBounds
        )).toOpaque()

        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: { info, cgContext in
                let cell = Unmanaged<PatternCellBox>.fromOpaque(info!).takeUnretainedValue()
                cell.draw(into: cgContext)
            },
            releaseInfo: { info in
                Unmanaged<PatternCellBox>.fromOpaque(info!).release()
            }
        )

        guard let cgPattern = CGPattern(
            info: box,
            bounds: tileBounds,
            matrix: patternSpaceToDevice,
            xStep: tileBounds.width,
            yStep: tileBounds.height,
            tiling: .constantSpacing,
            isColored: true,
            callbacks: &callbacks
        ) else {
            Unmanaged<PatternCellBox>.fromOpaque(box).release()
            cg.restoreGState()
            return
        }

        let patternColorSpace = CGColorSpace(patternBaseSpace: nil)!
        cg.setFillColorSpace(patternColorSpace)
        var alphaComponents: [CGFloat] = [alpha]
        cg.setFillPattern(cgPattern, colorComponents: &alphaComponents)
        cg.fill(cg.boundingBoxOfClipPath)

        cg.restoreGState()
    }
}

/// Retained context handed through the `CGPattern` callback's opaque `info`
/// pointer. Holds only what one tile's redraw needs; released by CG when the
/// pattern itself is released (see `releaseInfo`).
private final class PatternCellBox {
    let document: SVGDocument
    let images: ImageCache
    let contentSource: NodeIndex
    let contentMatrix: CGAffineTransform
    let tileBounds: CGRect

    init(document: SVGDocument, images: ImageCache, contentSource: NodeIndex,
         contentMatrix: CGAffineTransform, tileBounds: CGRect) {
        self.document = document
        self.images = images
        self.contentSource = contentSource
        self.contentMatrix = contentMatrix
        self.tileBounds = tileBounds
    }

    func draw(into cgContext: CGContext) {
        let cellContext = RenderContext(cg: cgContext, document: document,
                                        dirtyRect: tileBounds, images: images)
        cellContext.concatenate(contentMatrix)
        var walk = RenderWalk(visitor: DefaultVisitor(), context: cellContext)
        document.forEachChild(of: contentSource) { child in
            walk.render(child, inheriting: .initial)
        }
    }
}
