//
//  StyleResolver.swift
//  SVGRenderer
//
//  Computed-style resolution: turns each element's `RawStyle` (presentation
//  attributes + inline `style=""`) into a fully-populated `ComputedStyle` by
//  applying inheritance and initial values down the tree.
//
//  SCOPE
//  - IN:  the presentation-attribute / inline-style cascade, correct
//         inheritance of inheritable properties, the opacity split
//         (fill/stroke vs. group), and `currentColor` resolution.
//  - OUT: full CSS selector matching (`<style>` sheets, class/type/descendant
//         selectors, specificity, `!important`). See "Deferred" below and
//         CascadeRules.md. The hooks to slot it in are marked `SELECTOR-HOOK`.
//
//  This pass reads the IR but does not mutate it; computed styles are returned
//  to the caller (typically threaded through a tree walk) rather than stored
//  back on nodes, so the same node can be resolved under different inherited
//  contexts — which is exactly what `<use>` shadow instancing needs.
//
//  See Design/CascadeRules.md for the property tables and rationale.
//

import CoreGraphics
import Foundation

// MARK: - Computed style

/// A fully-resolved style: every property has a concrete value (no `nil`,
/// no "inherit"). This is what layout/rendering consumes.
///
/// Note the opacity split. SVG defines THREE independent opacities:
///   * `opacity`         — element/group opacity; composites the element as an
///                         isolated group (a rendered shape blends at this alpha
///                         *after* fill+stroke are combined). It does NOT
///                         inherit; it applies per element.
///   * `fill-opacity`    — alpha of the fill paint only.
///   * `stroke-opacity`  — alpha of the stroke paint only.
/// Collapsing these loses correct results whenever fill and stroke overlap, so
/// they are kept distinct here and combined only at paint time.
public struct ComputedStyle: Equatable {
    // Paint
    public var fill: Paint
    public var stroke: Paint
    public var strokeWidth: CGFloat
    public var color: RGBA                 // the `color` property; feeds currentColor

    // Opacities (see note above) — all pre-clamped to 0...1.
    public var groupOpacity: CGFloat       // from `opacity`; non-inherited
    public var fillOpacity: CGFloat
    public var strokeOpacity: CGFloat

    // Fill/stroke detail
    public var fillRule: FillRule
    public var clipRule: FillRule
    public var strokeLineCap: LineCap
    public var strokeLineJoin: LineJoin
    public var strokeMiterLimit: CGFloat
    public var strokeDashArray: ArenaRange?
    public var strokeDashOffset: CGFloat

    // Font / text
    public var fontFamily: StringRef
    public var fontSize: CGFloat
    public var fontWeight: FontWeight
    public var fontStyle: FontStyle
    public var textAnchor: TextAnchor

    // Painting control
    public var visibility: Visibility

    // Non-inherited element-scoped references
    public var clipPath: NodeIndex
    public var mask: NodeIndex

    /// The CSS initial values (the root's starting context). Per SVG/CSS these
    /// are the values an element gets when a property is neither specified nor
    /// inherited.
    public static let initial = ComputedStyle(
        fill: .color(.black),          // initial fill is black
        stroke: .none,                 // initial stroke is none
        strokeWidth: 1,
        color: .black,
        groupOpacity: 1,
        fillOpacity: 1,
        strokeOpacity: 1,
        fillRule: .nonZero,
        clipRule: .nonZero,
        strokeLineCap: .butt,
        strokeLineJoin: .miter,
        strokeMiterLimit: 4,
        strokeDashArray: nil,
        strokeDashOffset: 0,
        fontFamily: .none,
        fontSize: 16,                  // CSS medium
        fontWeight: .normal,
        fontStyle: .normal,
        textAnchor: .start,
        visibility: .visible,
        clipPath: .none,
        mask: .none
    )
}

// MARK: - Resolver

public struct StyleResolver {

    public let document: SVGDocument

    public init(document: SVGDocument) {
        self.document = document
    }

    /// Resolve the computed style for `node` given the computed style of its
    /// parent (the inherited context). For the root, pass `ComputedStyle.initial`.
    ///
    /// The `inherited` parameter is the *parent's already-computed style*, which
    /// is the correct source of inherited values — inheritance flows from
    /// computed values, not specified values, per CSS.
    public func resolve(_ nodeIndex: NodeIndex, inheriting inherited: ComputedStyle) -> ComputedStyle {
        let raw = document.node(nodeIndex).style
        return resolve(raw, inheriting: inherited)
    }

    /// Core cascade. Split out from the node accessor so `<use>` instancing and
    /// tests can drive it with a `RawStyle` directly.
    public func resolve(_ raw: RawStyle, inheriting p: ComputedStyle) -> ComputedStyle {

        // SELECTOR-HOOK: full selector matching would merge matched declarations
        // into `raw` (respecting specificity + !important) BEFORE this point.
        // Because that merge yields another `RawStyle`, nothing below changes.
        // See "Deferred: CSS selector matching".

        // `color` first — later `currentColor` resolutions depend on it. It is
        // inheritable, so start from the parent's resolved color.
        let color = raw.color ?? p.color

        // Inheritable properties fall back to the *parent's computed* value.
        // Non-inheritable properties fall back to their *initial* value.
        return ComputedStyle(
            fill:            resolvePaint(raw.fill,   inheritedResolved: p.fill,   color: color),   // inherited
            stroke:          resolvePaint(raw.stroke, inheritedResolved: p.stroke, color: color),   // inherited
            strokeWidth:     raw.strokeWidth ?? p.strokeWidth,     // inherited
            color:           color,                                // inherited

            // Opacity split: `opacity` (group) is NON-inherited → initial (1);
            // fill/stroke-opacity ARE inherited.
            groupOpacity:    clamp01(raw.opacity ?? 1),                        // non-inherited
            fillOpacity:     clamp01(raw.fillOpacity   ?? p.fillOpacity),      // inherited
            strokeOpacity:   clamp01(raw.strokeOpacity ?? p.strokeOpacity),    // inherited

            fillRule:        raw.fillRule ?? p.fillRule,           // inherited
            clipRule:        raw.clipRule ?? p.clipRule,           // inherited
            strokeLineCap:   raw.strokeLineCap ?? p.strokeLineCap, // inherited
            strokeLineJoin:  raw.strokeLineJoin ?? p.strokeLineJoin, // inherited
            strokeMiterLimit: raw.strokeMiterLimit ?? p.strokeMiterLimit, // inherited
            strokeDashArray: raw.strokeDashArray ?? p.strokeDashArray,    // inherited
            strokeDashOffset: raw.strokeDashOffset ?? p.strokeDashOffset, // inherited

            fontFamily:      raw.fontFamily ?? p.fontFamily,       // inherited
            fontSize:        raw.fontSize ?? p.fontSize,           // inherited
            fontWeight:      raw.fontWeight ?? p.fontWeight,       // inherited
            fontStyle:       raw.fontStyle ?? p.fontStyle,         // inherited
            textAnchor:      raw.textAnchor ?? p.textAnchor,       // inherited

            visibility:      raw.visibility ?? p.visibility,       // inherited

            // clip-path / mask apply to THIS element only → non-inherited.
            clipPath:        raw.clipPath ?? .none,                // non-inherited
            mask:            raw.mask ?? .none                     // non-inherited
        )
    }

    // MARK: Paint resolution

    /// Resolve one paint property. `currentColor` collapses to the resolved
    /// `color`. An unspecified paint inherits the parent's *already-resolved*
    /// paint (so an inherited `currentColor` is not re-resolved against a child's
    /// different `color` — it was already concretized on the parent, which is the
    /// CSS-correct behavior for inherited computed values).
    private func resolvePaint(_ raw: Paint?, inheritedResolved: Paint, color: RGBA) -> Paint {
        guard let raw else { return inheritedResolved }
        switch raw {
        case .currentColor:
            return .color(color)
        case .none, .color, .server:
            return raw
        }
    }
}

// MARK: - <use> / <symbol> shadow-tree inheritance (DEFERRED — see TODO)

extension StyleResolver {

    // TODO(use-instancing): Inheritance across a <use> reference boundary.
    //
    // A <use> element instances a target subtree as a *shadow tree*. Per SVG,
    // computed style crosses the boundary as follows and a later thread that
    // implements <use> MUST honor it:
    //
    //   1. The shadow tree inherits from the <use> element's own computed style
    //      — NOT from the target's original parent in the document. I.e. the
    //      inherited context for the target's root is `resolve(useNode, ...)`,
    //      the style computed AT THE <use> SITE. This is why this resolver never
    //      caches computed style back onto nodes: the same target node must be
    //      resolvable under many different inherited contexts (one per <use>).
    //
    //   2. Properties SPECIFIED on the target (and its descendants) still win
    //      over the inherited <use> context — instancing changes only the
    //      *inherited* values, not the target's own specified declarations.
    //
    //   3. Presentation attributes on <use> itself (e.g. fill) therefore act as
    //      inheritable defaults for the instance, overridable inside the target.
    //
    //   4. width/height on <use> apply only when the target is <svg>/<symbol>
    //      (viewport establishment — see Transforms.swift), not to shapes.
    //
    //   5. currentColor inside the instance resolves against the `color` value
    //      as computed at the <use> site (a consequence of rule 1).
    //
    // Intended entry point (to implement later):
    //
    //     func resolveInstanceRoot(target: NodeIndex, at useNode: NodeIndex,
    //                              inheriting outer: ComputedStyle) -> ComputedStyle {
    //         let useStyle = resolve(useNode, inheriting: outer)   // style at the use site
    //         return resolve(target, inheriting: useStyle)         // target inherits from it
    //     }
    //
    // Cycle safety (a <use> chain that revisits an ancestor) is the instancing
    // thread's responsibility; this resolver is stateless and will not detect it.
}

// MARK: - Deferred: CSS selector matching
//
// Out of scope for this layer. When added, a `StyleSheet` pass matches selectors
// against elements, orders declarations by (origin, specificity, source order,
// !important), and folds the winning declarations into each node's `RawStyle`
// BEFORE resolution. The resolver above is intentionally agnostic to how a
// `RawStyle` was populated, so selector support slots in at the `SELECTOR-HOOK`
// with no change to inheritance logic. See CascadeRules.md § "Deferred".

// MARK: - Helpers

@inline(__always)
private func clamp01(_ v: CGFloat) -> CGFloat {
    v < 0 ? 0 : (v > 1 ? 1 : v)
}
