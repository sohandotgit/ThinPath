//
//  PaintServer.swift
//  SVGRenderer
//
//  The paint-server protocol and coordinate machinery: how a resolved `fill`/
//  `stroke` (solid, linear/radial gradient, or pattern) is installed into a
//  `CGContext` to paint a shape, and how each server's coordinate system
//  (objectBoundingBox vs userSpaceOnUse, plus gradientTransform/patternTransform)
//  maps into the user space where the shape is drawn.
//
//  NAMING: the IR already has a `PaintServer` *value* (SVGModel.swift) — an
//  id+index reference to a server element. This file's rendering-side protocol is
//  `PaintSource` to avoid the clash: a `PaintSource` is a thing that can install
//  paint, produced by resolving a `Paint`/`PaintServer` against the document.
//
//  MEMORY-SENSITIVE DECISIONS (the reason this is its own subsystem):
//    * Patterns tile via `CGPattern` draw callbacks — CG re-invokes a closure per
//      tile cell — NOT by rendering one giant pre-tiled bitmap. One tile's worth
//      of pixels, reused across the fill region.
//    * spreadMethod reflect/repeat is realized by extending the gradient's stop
//      array across only the VISIBLE periods (clip ∩ dirty), so cost scales with
//      what is on screen, not the canvas.
//
//  IMPLEMENTATION STATUS: protocol, coordinate mapping, and the pattern/gradient
//  strategy are specified; `ObjectBoundingBox.transform` is real + unit-tested;
//  the CG-emitting bodies are TODO(render-thread). See Design/Compositing.md.
//

import CoreGraphics
import Foundation

// MARK: - Object bounding box coordinate mapping (REAL, unit-tested)

/// The shared `objectBoundingBox` mapping used by gradients, patterns, clipPath,
/// and mask when their `*Units` is `.objectBoundingBox`. Kept in one place (and
/// unit-tested) because getting it wrong silently mis-places every fractional
/// gradient/pattern.
public enum ObjectBoundingBox {

    /// Map the unit square `[0,1]²` onto `bounds` (an element's geometry bounding
    /// box, stroke excluded). This is the matrix `M` such that a coordinate `u`
    /// authored in objectBoundingBox space becomes `u · M` in the element's user
    /// space:
    ///
    ///     M = | w  0  0 |     (a=w, d=h, tx=minX, ty=minY)
    ///         | 0  h  0 |
    ///         | x  y  1 |
    ///
    /// Returns `nil` for a degenerate (zero-area) box: per SVG a bounding-box-units
    /// paint server on a zero-width/height object is not rendered, and callers must
    /// treat the paint as absent rather than divide by zero.
    public static func transform(_ bounds: CGRect) -> CGAffineTransform? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGAffineTransform(a: bounds.width, b: 0,
                                 c: 0, d: bounds.height,
                                 tx: bounds.minX, ty: bounds.minY)
    }
}

// MARK: - Resolved coordinate space for a paint server

/// The concrete matrix that maps a paint server's own coordinate space into the
/// user space of the element being painted, combining the units mapping with the
/// server's `gradientTransform`/`patternTransform`.
///
/// For `.userSpaceOnUse` the server is authored in the user space in effect where
/// it is REFERENCED (the filled element's user space), so the units matrix is
/// identity and only the server transform applies. For `.objectBoundingBox` the
/// units matrix is `ObjectBoundingBox.transform(bounds)`.
///
/// Order (row-vector, `p' = p · M`): `serverSpace → [serverTransform] → [units] →
/// userSpace`, i.e. `M = serverTransform · unitsMatrix`.
public struct PaintCoordinateSpace {

    /// The combined server→user matrix, or `nil` if the units mapping is
    /// degenerate (zero-area bbox with objectBoundingBox) — paint is then absent.
    public let serverToUser: CGAffineTransform?

    public init(units: Units,
                serverTransform: CGAffineTransform,
                objectBounds: CGRect) {
        switch units {
        case .userSpaceOnUse:
            serverToUser = serverTransform
        case .objectBoundingBox:
            if let unitsMatrix = ObjectBoundingBox.transform(objectBounds) {
                serverToUser = serverTransform.concatenating(unitsMatrix)
            } else {
                serverToUser = nil
            }
        }
    }
}

// MARK: - PaintSource protocol (the paint-server seam)

/// Something that can paint a region of the current context. Produced by
/// resolving a `ComputedStyle` paint (`fill`/`stroke`) against the document.
///
/// The contract: the caller has already added the fill/stroke geometry as the
/// current path (or will pass it in) and set up the CTM; a `PaintSource`
/// installs its colour/gradient/pattern and fills that region, honouring the
/// supplied `alpha` (the folded fill-opacity or stroke-opacity — the opacity
/// split from CascadeRules §4 is applied by the caller, not here).
public protocol PaintSource {

    /// Fill `path` (in current user space) with this paint, using `rule`.
    /// `objectBounds` is the element's geometry bbox (for objectBoundingBox units)
    /// and `alpha` is the pre-resolved fill/stroke opacity to multiply in.
    func fill(path: CGPath, rule: FillRule, objectBounds: CGRect,
              alpha: CGFloat, into context: RenderContext)
}

// MARK: - Solid colour

public struct SolidPaint: PaintSource {
    public let color: RGBA
    public init(_ color: RGBA) { self.color = color }

    public func fill(path: CGPath, rule: FillRule, objectBounds: CGRect,
                     alpha: CGFloat, into context: RenderContext) {
        _ = objectBounds   // solid color needs no coordinate mapping
        ShapeRenderer.fillSolid(self, path: path, rule: rule, alpha: alpha, into: context)
    }
}

// MARK: - Gradients

/// Linear/radial gradient paint. Resolves stops (following the `href` template
/// chain, cycle-guarded), maps geometry via `PaintCoordinateSpace`, and realizes
/// `spreadMethod`.
public struct GradientPaint: PaintSource {

    public let node: NodeIndex
    public init(node: NodeIndex) { self.node = node }

    public func fill(path: CGPath, rule: FillRule, objectBounds: CGRect,
                     alpha: CGFloat, into context: RenderContext) {
        GradientRenderer.fill(node: node, path: path, rule: rule, objectBounds: objectBounds,
                              alpha: alpha, into: context)
    }
}

// MARK: - Patterns

/// Pattern paint. Tiles its child subtree via a `CGPattern` callback so a single
/// tile's worth of drawing is reused across the fill region.
public struct PatternPaint: PaintSource {

    public let node: NodeIndex
    public init(node: NodeIndex) { self.node = node }

    public func fill(path: CGPath, rule: FillRule, objectBounds: CGRect,
                     alpha: CGFloat, into context: RenderContext) {
        PatternRenderer.fill(node: node, path: path, rule: rule, objectBounds: objectBounds,
                             alpha: alpha, into: context)
    }
}

// MARK: - Resolving a ComputedStyle paint to a PaintSource

public enum PaintResolver {

    /// Turn a resolved `Paint` (fill or stroke) into a `PaintSource`, or `nil`
    /// for `.none`/unresolved-without-fallback (nothing to paint).
    ///
    /// `PROFILE-CHECK (paint-alloc)`: this allocates a small `PaintSource` value
    /// per painted element per pass. Confirm it is a stack/enum-cheap value and
    /// does not churn the heap on large documents; if it does, hand back an enum
    /// instead of an existential.
    public static func resolve(_ paint: Paint,
                               references: ReferenceResolver) -> PaintSource? {
        switch paint {
        case .none:
            return nil
        case .currentColor:
            // currentColor is concretized to `.color` by StyleResolver before here;
            // a stray `.currentColor` means an unresolved cascade bug — treat as none.
            return nil
        case .color(let rgba):
            return SolidPaint(rgba)
        case .server(let server, let fallback):
            let target = references.paintServerNode(server)
            if target.isNone {
                return resolveFallback(fallback)
            }
            switch references.document.node(target).kind {
            case .gradient: return GradientPaint(node: target)
            case .pattern:  return PatternPaint(node: target)
            default:        return resolveFallback(fallback)   // url points at a non-server
            }
        }
    }

    private static func resolveFallback(_ fallback: PaintFallback) -> PaintSource? {
        switch fallback {
        case .none, .explicitNone: return nil
        case .color(let rgba): return SolidPaint(rgba)
        }
    }
}
