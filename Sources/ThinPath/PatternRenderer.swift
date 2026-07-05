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
        // height — bbox-FRACTIONAL when it's objectBoundingBox, since
        // `serverToUser` folds in `ObjectBoundingBox.transform`. The children
        // are authored in the space `patternContentUnits` implies (or the
        // viewBox, which overrides it) and must be mapped INTO pattern space;
        // see `contentUnitsMatrix` for the four unit combinations and
        // Compositing.md §4a for the incident where one wrong combination
        // inflated every tile child by the bbox size.
        let contentMatrix: CGAffineTransform
        if let viewBox = pattern.viewBox {
            contentMatrix = ViewportMath.viewportTransform(
                viewBox: viewBox,
                viewport: CGRect(origin: tileBounds.origin, size: tileBounds.size),
                par: pattern.preserveAspectRatio)
        } else {
            contentMatrix = contentUnitsMatrix(patternUnits: pattern.patternUnits,
                                               contentUnits: pattern.patternContentUnits,
                                               objectBounds: objectBounds)
        }

        let cg = context.cg
        cg.saveGState()
        cg.addPath(path)
        cg.clip(using: rule == .nonZero ? .winding : .evenOdd)

        let patternSpaceToDevice = serverToUser.concatenating(cg.ctm)

        let box = Unmanaged.passRetained(PatternCellBox(
            document: context.document, images: context.images,
            contentSource: contentSource, contentMatrix: contentMatrix,
            tileBounds: tileBounds,
            tileDeviceBounds: tileBounds.applying(patternSpaceToDevice)
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

    /// Map pattern-CONTENT coordinates into PATTERN space — the space
    /// `tileBounds` and the `CGPattern` matrix are expressed in, i.e. the user
    /// space the tile callback's context starts in.
    ///
    /// Two independent selectors are in play and BOTH matter:
    /// `patternContentUnits` says what space the children are authored in
    /// (absolute user space, or bbox fractions); `patternUnits` says what
    /// space the tile rect — and therefore pattern space itself — is
    /// expressed in. The mapping is contentSpace → userSpace → patternSpace
    /// (`M = contentToUser · userToPattern`), which collapses to:
    ///
    ///   * same units on both sides (user/user or bbox/bbox) → IDENTITY: the
    ///     children are already authored in pattern space. The bbox/bbox case
    ///     previously (incorrectly) applied the bbox transform here, scaling
    ///     the content by the bbox size a SECOND time — the tile matrix
    ///     already contains that mapping — which inflated everything inside
    ///     the tile ~bboxWidth × bboxHeight-fold (Compositing.md §4a).
    ///   * content bbox-fractional, tile user-space → the bbox transform.
    ///   * content user-space, tile bbox-fractional → its INVERSE.
    ///
    /// A degenerate bbox yields identity: when `patternUnits` is
    /// objectBoundingBox the caller has already bailed out via
    /// `PaintCoordinateSpace`, and bbox-fractional content on a zero-area
    /// element paints nothing meaningful either way.
    static func contentUnitsMatrix(patternUnits: Units, contentUnits: Units,
                                   objectBounds: CGRect) -> CGAffineTransform {
        guard contentUnits != patternUnits,
              let bbox = ObjectBoundingBox.transform(objectBounds)
        else { return .identity }
        return contentUnits == .objectBoundingBox ? bbox : bbox.inverted()
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
    /// The tile rect in DEVICE pixels (`tileBounds` × the pattern matrix).
    /// `RenderContext.dirtyRect`/`clipDeviceBounds` are device-space by
    /// contract; seeding them with the pattern-space `tileBounds` (a 1×1 rect
    /// for a bbox-fractional tile) would make every device-space clamp inside
    /// the cell — layer sizing, ImageRenderer's resample bound — nonsense.
    let tileDeviceBounds: CGRect

    init(document: SVGDocument, images: ImageCache, contentSource: NodeIndex,
         contentMatrix: CGAffineTransform, tileBounds: CGRect, tileDeviceBounds: CGRect) {
        self.document = document
        self.images = images
        self.contentSource = contentSource
        self.contentMatrix = contentMatrix
        self.tileBounds = tileBounds
        self.tileDeviceBounds = tileDeviceBounds
    }

    func draw(into cgContext: CGContext) {
        let cellContext = RenderContext(cg: cgContext, document: document,
                                        dirtyRect: tileDeviceBounds, images: images)
        cellContext.setViewport(tileBounds.size)   // % lengths stay pattern-space
        cellContext.concatenate(contentMatrix)
        var walk = RenderWalk(visitor: DefaultVisitor(), context: cellContext)
        document.forEachChild(of: contentSource) { child in
            walk.render(child, inheriting: .initial)
        }
    }
}
