//
//  ReferenceResolver.swift
//  SVGRenderer
//
//  defs / use / symbol / href resolution over the id→index table, WITHOUT deep
//  copying any subtree. Every reference (`<use href>`, paint-server `url(#…)`,
//  gradient/pattern `href` template, `clip-path`, `mask`) resolves to a
//  `NodeIndex` into the shared arena; instancing happens by re-walking those same
//  nodes at draw time under a per-instance transform + inherited style, never by
//  materializing a copy (MemoryModel §4).
//
//  This file owns three things and they are the reason it exists as its own unit:
//    1. CYCLE DETECTION — a `<use>` (or gradient/pattern `href`) chain must not
//       reference itself directly or transitively. Real, unit-tested (3-colour DFS).
//    2. INSTANCE COORDINATE MAPPING — `<use>` x/y/width/height and `<symbol>`
//       viewport + preserveAspectRatio → the transform that places an instance.
//       Real, unit-tested (reuses Transforms.swift).
//    3. The plumbing to look a reference up by id/index tolerantly (`.none`-safe).
//
//  The two tested parts are implemented here for real; see
//  Tests/SVGRendererTests/ReferenceResolverTests.swift (written first). See
//  Design/ResolutionRules.md for the rules and the inheritance-into-instance rule.
//

import CoreGraphics
import Foundation

// MARK: - ReferenceResolver

public struct ReferenceResolver {

    public let document: SVGDocument

    public init(document: SVGDocument) {
        self.document = document
    }

    // MARK: Lookups (id/index, tolerant of `.none`)

    /// The node a `<use>` targets: prefer the parse-time pre-resolved index, else
    /// resolve the interned href through `idMap`. `.none` if unresolvable
    /// (invariant 2 permits an unresolved forward/dangling reference).
    public func useTarget(_ use: Use) -> NodeIndex {
        if !use.resolved.isNone { return use.resolved }
        return document.nodeForID(use.href)
    }

    /// The node a paint reference (`fill="url(#g)"`) targets. `.none` if unresolved
    /// — the caller then applies the `PaintFallback`.
    public func paintServerNode(_ server: PaintServer) -> NodeIndex {
        if !server.node.isNone { return server.node }
        return document.nodeForID(server.id)
    }

    /// The `href` template of a gradient/pattern node (`<linearGradient href="#base">`),
    /// or `.none`. Attribute/stop inheritance from the template is a resolver
    /// concern handled at paint time; here we only follow the link.
    public func templateOf(_ node: NodeIndex) -> NodeIndex {
        guard !node.isNone else { return .none }
        switch document.node(node).kind {
        case .gradient(let g): return g.template
        case .pattern(let p): return p.template
        default: return .none
        }
    }

    // MARK: - Cycle detection (REAL, unit-tested)

    /// Does expanding the `<use>` at `start` reference itself directly or
    /// transitively? Per SVG a cyclic `<use>` is an error and the offending
    /// instance renders nothing.
    ///
    /// Implementation: a 3-colour depth-first search over the *render-expansion*
    /// graph, whose edges are (a) structural containment (a node → its children)
    /// and (b) instancing (a `<use>` → its target). A grey (on-stack) node reached
    /// again is a back edge ⇒ cycle. Black (finished, proven acyclic) nodes are
    /// memoized so shared/diamond reuse does not re-expand — keeping it O(nodes)
    /// and allocation-light, not exponential.
    public func hasUseCycle(startingAt start: NodeIndex) -> Bool {
        var grey = Set<NodeIndex>()
        var black = Set<NodeIndex>()
        return useDFS(start, &grey, &black)
    }

    /// Whole-document check: is there ANY cyclic `<use>` reachable from the root?
    /// Shares one black set across starts so it stays linear overall.
    public func documentHasUseCycle() -> Bool {
        guard !document.root.isNone else { return false }
        var grey = Set<NodeIndex>()
        var black = Set<NodeIndex>()
        return useDFS(document.root, &grey, &black)
    }

    private func useDFS(_ node: NodeIndex,
                        _ grey: inout Set<NodeIndex>,
                        _ black: inout Set<NodeIndex>) -> Bool {
        if node.isNone || black.contains(node) { return false }
        if grey.contains(node) { return true }          // back edge → cycle
        grey.insert(node)

        let n = document.node(node)
        // Instancing edge: a <use> expands into its target subtree.
        if case .use(let use) = n.kind {
            if useDFS(useTarget(use), &grey, &black) { return true }
        }
        // Structural edges: children may themselves contain <use>s.
        var c = n.firstChild
        while !c.isNone {
            if useDFS(c, &grey, &black) { return true }
            c = document.node(c).nextSibling
        }

        grey.remove(node)
        black.insert(node)
        return false
    }

    /// Does the gradient/pattern `href` template chain from `start` cycle?
    /// (`<linearGradient id=a href=#b>`, `<linearGradient id=b href=#a>`.) A linear
    /// chain of `template` links, so a simple visited-set walk suffices.
    public func hasTemplateCycle(startingAt start: NodeIndex) -> Bool {
        var seen = Set<NodeIndex>()
        var cur = start
        while !cur.isNone {
            if seen.contains(cur) { return true }
            seen.insert(cur)
            cur = templateOf(cur)
        }
        return false
    }

    // MARK: - Instance coordinate mapping (REAL, unit-tested)

    /// The transform that places an instance of a `<use>` into the use site's user
    /// space.
    ///
    ///  * Plain shape/group/path target → `translate(use.x, use.y)`.
    ///  * `<symbol>` / nested `<svg>` target → establishes a viewport at
    ///    `(use.x, use.y)` sized by the width/height precedence below, then (if the
    ///    target has a `viewBox`) applies `ViewportMath.viewportTransform` so the
    ///    result already includes both the placement translate and the
    ///    viewBox→viewport alignment. With no `viewBox` it is just the translate
    ///    (content is in viewport coordinates).
    ///
    /// Width/height precedence (per SVG): a `value` on the `<use>` wins; else a
    /// `value` on the target's own width/height; else `auto` = 100% of the current
    /// viewport. `<use>` may only override sizing for `svg`/`symbol` targets.
    public func instanceTransform(for use: Use, currentViewport: CGSize) -> CGAffineTransform {
        let translate = CGAffineTransform(translationX: use.x, y: use.y)
        let target = useTarget(use)
        guard !target.isNone else { return translate }

        switch document.node(target).kind {
        case .symbol(let vp), .svg(let vp):
            let w = resolveLength(use.width, fallback: vp.width, viewport: currentViewport.width)
            let h = resolveLength(use.height, fallback: vp.height, viewport: currentViewport.height)
            let rect = CGRect(x: use.x, y: use.y, width: w, height: h)
            if let viewBox = vp.viewBox {
                // viewportTransform already folds in the placement (rect.minX/minY).
                return ViewportMath.viewportTransform(viewBox: viewBox,
                                                      viewport: rect,
                                                      par: vp.preserveAspectRatio)
            }
            return translate
        default:
            return translate
        }
    }

    /// The viewport rect a `<use>` establishes for a `symbol`/`svg` target, in the
    /// use site's user space. The `slice`/overflow clip is applied to this rect.
    /// Returns `nil` for non-viewport targets (nothing to clip).
    public func instanceViewportRect(for use: Use, currentViewport: CGSize) -> CGRect? {
        let target = useTarget(use)
        guard !target.isNone else { return nil }
        switch document.node(target).kind {
        case .symbol(let vp), .svg(let vp):
            let w = resolveLength(use.width, fallback: vp.width, viewport: currentViewport.width)
            let h = resolveLength(use.height, fallback: vp.height, viewport: currentViewport.height)
            return CGRect(x: use.x, y: use.y, width: w, height: h)
        default:
            return nil
        }
    }

    /// `<use>` width/height resolution: explicit `value` > target's own `value` >
    /// `auto` (100% of the current viewport dimension).
    private func resolveLength(_ primary: LengthOrAuto,
                               fallback: LengthOrAuto,
                               viewport: CGFloat) -> CGFloat {
        if case .value(let v) = primary { return v }
        if case .value(let v) = fallback { return v }
        return viewport
    }
}

// MARK: - Inheritance into the instance (CascadeRules §6 — DEFERRED entry point)

extension ReferenceResolver {

    // The style side of instancing is owned by StyleResolver
    // (`TODO(use-instancing)`), NOT re-implemented here. The rule, restated so the
    // two files agree:
    //
    //   let useStyle = styleResolver.resolve(useNode, inheriting: outer)
    //   let instanceRoot = styleResolver.resolve(target, inheriting: useStyle)
    //
    // i.e. the instanced target inherits from the computed style AT THE USE SITE,
    // and any property SPECIFIED on the target still wins. This resolver supplies
    // only the *which node* + *which transform*; the walk (RenderWalk.renderUse)
    // combines them with the style resolver. Because nothing is copied, the same
    // target resolves cleanly under every distinct use-site context.
}
