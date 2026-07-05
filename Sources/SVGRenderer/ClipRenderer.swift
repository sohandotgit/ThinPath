//
//  ClipRenderer.swift
//  SVGRenderer
//
//  `clip-path` realized as a CGContext clip (never a layer — Compositing.md /
//  RenderPipeline.md §4). Unions a `<clipPath>`'s child geometry into one path,
//  honoring each child's own `transform` and `clip-rule`, and `clipPathUnits`
//  (objectBoundingBox maps through `ObjectBoundingBox.transform` using the
//  CLIPPED element's own geometry bounding box — the same shared mapping
//  gradients/patterns/masks use).
//
//  Also hosts `localGeometryBounds`, the pure-geometry (stroke-excluded) bbox
//  used both here (objectBoundingBox mapping) and by
//  `RenderContext.subtreeDeviceBounds` (layer clamping) — one definition, per
//  RenderPipeline.md §5's requirement that the two never disagree.
//

import CoreGraphics
import Foundation

public enum ClipRenderer {

    /// Build the clip geometry for `clipPathNode`, to be applied via
    /// `RenderContext.clip(toPath:rule:)` in the CURRENT user space (the space
    /// of the element whose `clip-path` this is). `objectBounds` is that
    /// element's own geometry bbox, needed only for objectBoundingBox units.
    public static func buildClipPath(_ clipPathNode: NodeIndex, objectBounds: CGRect,
                                     document: SVGDocument) -> (path: CGPath, rule: FillRule)? {
        guard case .clipPath(let units) = document.node(clipPathNode).kind else { return nil }

        let unitsMatrix: CGAffineTransform
        switch units {
        case .userSpaceOnUse:
            unitsMatrix = .identity
        case .objectBoundingBox:
            guard let m = ObjectBoundingBox.transform(objectBounds) else { return nil }   // degenerate bbox
            unitsMatrix = m
        }

        let combined = CGMutablePath()
        var singleRule: FillRule?
        var childCount = 0

        document.forEachChild(of: clipPathNode) { child in
            let n = document.node(child)
            if n.style.display == Display.none { return }
            let localPath = ShapeRenderer.leafPath(child, document: document)
            guard !localPath.isEmpty else { return }
            var childTransform = document.affineTransform(n.transform)
            let mapped = childTransform.isIdentity ? localPath : localPath.copy(using: &childTransform)!
            var units = unitsMatrix
            let finalPath = units.isIdentity ? mapped : mapped.copy(using: &units)!
            combined.addPath(finalPath)
            childCount += 1
            let rule = n.style.clipRule ?? .nonZero
            singleRule = (childCount == 1) ? rule : nil   // only trustworthy for a single child
        }

        guard childCount > 0 else { return nil }
        return (combined, singleRule ?? .nonZero)
    }

    // MARK: - Shared geometry-only bounding box

    /// Geometry-only (stroke-excluded) bounding box of `node` in ITS OWN local
    /// user space (the element's own transform is not applied — callers
    /// compose it themselves, matching how `RenderContext` threads transforms).
    /// `.null` for anything not modeled here (text metrics, paint-server-only
    /// kinds) — always a SAFE fallback per `RenderContext.subtreeDeviceBounds`'s
    /// contract (clamps widen, never narrow incorrectly).
    public static func localGeometryBounds(of node: NodeIndex, document: SVGDocument) -> CGRect {
        let n = document.node(node)
        if n.style.display == Display.none { return .null }

        switch n.kind {
        case .shape, .poly, .path:
            let path = ShapeRenderer.leafPath(node, document: document)
            return path.isEmpty ? .null : path.boundingBoxOfPath

        case .image(let image):
            return CGRect(x: image.x, y: image.y, width: image.width, height: image.height)

        case .use(let use):
            let target = use.resolved.isNone ? document.nodeForID(use.href) : use.resolved
            guard !target.isNone else { return .null }
            let targetBounds = localGeometryBounds(of: target, document: document)
            guard !targetBounds.isNull else { return .null }
            return targetBounds.applying(CGAffineTransform(translationX: use.x, y: use.y))

        case .group, .svg, .symbol:
            var result = CGRect.null
            document.forEachChild(of: node) { child in
                let childLocal = localGeometryBounds(of: child, document: document)
                guard !childLocal.isNull else { return }
                let childTransform = document.affineTransform(document.node(child).transform)
                let mapped = childLocal.applying(childTransform)
                result = result.isNull ? mapped : result.union(mapped)
            }
            return result

        default:
            return .null   // defs / clipPath / mask / gradient / pattern / text
        }
    }
}
