//
//  RenderContext.swift
//  SVGRenderer
//
//  The traversal-and-draw architecture: a single depth-first walk over the flat
//  node arena that renders DIRECTLY into a caller-supplied `CGContext`, keeping an
//  explicit transform / clip / opacity stack in lock-step with CGContext
//  save/restore, and establishing an offscreen (transparency) layer ONLY when a
//  group-level operation semantically forces one (see `needsIsolationLayer`).
//
//  This file defines the two architectural pieces:
//    * `RenderContext` — the mutable render state (target context + explicit
//      state stack + budget guards + resolver/cache handles). It owns the hard
//      decisions: when a layer is unavoidable and how its backing store is
//      clamped to the intersected clip/dirty region rather than the full canvas.
//    * `NodeVisitor` — the dispatch seam a later thread implements to emit the
//      actual Core Graphics draw calls for each drawable leaf. Traversal, the
//      state stack, and layer management stay here; leaf pixels are the visitor's.
//
//  IMPLEMENTATION STATUS: architecture + hard decisions are real; the per-kind
//  Core Graphics draw bodies and subtree-bounds geometry are marked
//  TODO(render-thread). Nothing here rasterizes yet.
//
//  See Design/RenderPipeline.md for the rationale and the layer-clamping rule.
//

import CoreGraphics
import Foundation

// MARK: - TransformRef resolution helper

extension SVGDocument {
    /// Resolve a `TransformRef` to a concrete matrix. `.none` (`-1`) is identity
    /// and is never stored in the arena, so the common no-transform case is free.
    @inline(__always)
    public func affineTransform(_ ref: TransformRef) -> CGAffineTransform {
        ref.isNone ? .identity : transforms[Int(ref)]
    }
}

// MARK: - Explicit render-state frame

/// One entry on the explicit graphics-state stack. We keep this ALONGSIDE
/// CGContext's own gstate stack (not instead of it) for one reason: to size an
/// offscreen layer's backing store we must know the *device-space* bounds of the
/// current clip, and CGContext only exposes clip bounds in user space
/// (`boundingBoxOfClipPath`). Tracking `userToDevice` + `clipDeviceBounds`
/// ourselves lets us clamp a layer to the visible region in O(1) without
/// round-tripping through the context. Every `RenderContext.save()/restore()`
/// pushes/pops one of these in exact correspondence with a CG gsave/grestore.
public struct RenderFrame {
    /// Full CTM at this node: maps current user space → device pixels. Kept in
    /// sync with `cg.ctm` but readable without a CG call.
    public var userToDevice: CGAffineTransform

    /// Running intersection of every clip established from the root to here, in
    /// DEVICE space. Used only to clamp offscreen-layer bounds; the authoritative
    /// clip is still enforced by CGContext itself. `.null` means "unclipped"
    /// (treated as the dirty rect when clamping).
    public var clipDeviceBounds: CGRect

    /// The viewport size (user units) in effect for this subtree. Percentage
    /// lengths and `auto` `<use>`/`<symbol>` sizing resolve against this. A nested
    /// `<svg>`/`<symbol>` replaces it for its subtree. See CoordinateNotes.md §4.
    public var viewport: CGSize

    public init(userToDevice: CGAffineTransform, clipDeviceBounds: CGRect, viewport: CGSize) {
        self.userToDevice = userToDevice
        self.clipDeviceBounds = clipDeviceBounds
        self.viewport = viewport
    }
}

// MARK: - RenderContext

/// The mutable state of one render pass.
///
/// It is a `final class` on purpose. The whole point of this design is to draw
/// straight into an imperative, stateful `CGContext`; threading value-type state
/// via `inout` through a recursive walk would fight that model and make the
/// stack/CGContext correspondence easy to desync. A class with an explicit
/// `frames` stack that is mutated in lock-step with `cg.saveGState()` /
/// `cg.restoreGState()` keeps the two stacks provably parallel.
public final class RenderContext {

    /// The caller's target context. We render here directly; offscreen layers are
    /// transparency layers *within* this same context, never separate canvases,
    /// except where a mask forces a scratch bitmap (see Compositing.md).
    public let cg: CGContext

    /// The document being rendered. Immutable for the pass (MemoryModel invariant 1).
    public let document: SVGDocument

    /// Style cascade. Stateless; safe to share and to re-drive per `<use>` site.
    public let styles: StyleResolver

    /// defs/use/symbol/href resolution + cycle detection over the id→index table.
    public let references: ReferenceResolver

    /// Decoded-image cache. Decoding is deferred to here at the target scale so we
    /// never pin full-resolution bitmaps (a core project constraint).
    public let images: ImageCache

    /// The device-space region actually being produced this pass (a tile, an
    /// invalidated rect, or the whole output). Anything whose device bounds do not
    /// intersect this is skipped — and it is the outer clamp for every offscreen
    /// layer, so a layer can never be larger than what we are asked to paint.
    public let dirtyRect: CGRect

    /// Explicit state stack (see `RenderFrame`). Never empty during a walk; index
    /// `count-1` is the current frame.
    public private(set) var frames: [RenderFrame]

    /// Depth of nested offscreen layers currently open. A guard against runaway
    /// layering (deeply nested group-opacity/mask). See `maxLayerDepth`.
    public private(set) var layerDepth: Int = 0

    /// Hard cap on nested offscreen layers. Beyond this we degrade gracefully
    /// (composite without isolation) rather than risk unbounded scratch memory.
    /// PROFILE-CHECK (layer-depth): confirm the cap is never hit by real content
    /// and that graceful degradation is visually acceptable when it is.
    public var maxLayerDepth: Int = 24

    public init(cg: CGContext,
                document: SVGDocument,
                dirtyRect: CGRect,
                images: ImageCache) {
        self.cg = cg
        self.document = document
        self.styles = StyleResolver(document: document)
        self.references = ReferenceResolver(document: document)
        self.images = images
        self.dirtyRect = dirtyRect
        // Seed the stack from the context's initial CTM so device-space bookkeeping
        // is correct even if the caller pre-transformed `cg`.
        let seed = RenderFrame(userToDevice: cg.ctm,
                               clipDeviceBounds: dirtyRect,
                               viewport: dirtyRect.size)
        self.frames = [seed]
    }

    // MARK: State stack

    @inline(__always)
    public var current: RenderFrame { frames[frames.count - 1] }

    /// Push a new gstate. MUST be balanced by `restore()`. Duplicates the top
    /// frame so callers can then mutate the new top (concat, clip, viewport).
    public func save() {
        cg.saveGState()
        frames.append(current)
    }

    public func restore() {
        cg.restoreGState()
        frames.removeLast()
        precondition(!frames.isEmpty, "RenderContext state stack underflow")
    }

    /// Concatenate a matrix onto the CTM and keep the device transform in sync.
    public func concatenate(_ m: CGAffineTransform) {
        guard !m.isIdentity else { return }
        cg.concatenate(m)
        frames[frames.count - 1].userToDevice = m.concatenating(current.userToDevice)
    }

    /// Replace the current viewport (nested `<svg>`/`<symbol>`), for % / auto sizing.
    public func setViewport(_ size: CGSize) {
        frames[frames.count - 1].viewport = size
    }

    // MARK: Clipping

    /// Clip to a rectangle given in the CURRENT user space (viewport / overflow
    /// clip). Updates the tracked device bounds so later layer clamping is tight.
    public func clip(toUserRect rect: CGRect) {
        cg.clip(to: rect)
        let deviceRect = rect.applying(current.userToDevice)
        frames[frames.count - 1].clipDeviceBounds =
            intersectionOrEmpty(current.clipDeviceBounds, deviceRect)
    }

    /// Clip to an arbitrary path (a `clip-path`'s unioned geometry). We tighten
    /// the tracked device bounds to the path's device bounding box; the exact
    /// (possibly concave) clip is still enforced by CGContext. Bounding-box
    /// tracking is a conservative *over*-estimate, which is always safe for layer
    /// sizing (a layer may be slightly larger than strictly needed, never smaller).
    public func clip(toPath path: CGPath, rule: FillRule) {
        cg.addPath(path)
        switch rule {
        case .nonZero: cg.clip()
        case .evenOdd: cg.clip(using: .evenOdd)
        }
        let deviceBox = path.boundingBoxOfPath.applying(current.userToDevice)
        frames[frames.count - 1].clipDeviceBounds =
            intersectionOrEmpty(current.clipDeviceBounds, deviceBox)
    }

    // MARK: - Offscreen layers (the memory-sensitive core)

    /// THE RULE (see RenderPipeline.md §"When a layer is unavoidable").
    ///
    /// An offscreen transparency layer is established for `node`/`style` iff a
    /// group-level compositing operation must be applied to the element's
    /// *flattened* result rather than to each of its paint operations
    /// independently. Concretely, exactly these cases force a layer:
    ///
    ///  1. **Group opacity < 1 on a container** (`group`/`svg`/`symbol`/`use`)
    ///     that has ≥1 painted descendant. The alpha multiplies the composited
    ///     subtree, so children must be flattened first, then faded as a unit.
    ///  2. **Group opacity < 1 on a shape that paints BOTH fill and stroke.**
    ///     Where fill and stroke overlap, fading each separately double-fades the
    ///     overlap. Only when a shape paints a single contribution (fill-only or
    ///     stroke-only) can `opacity` be folded into `fill/stroke-opacity` and the
    ///     layer skipped — that fold is the common, cheap path.
    ///  3. **A `mask`.** The element is rendered to a layer, then multiplied by the
    ///     mask's luminance/alpha. Cannot be expressed as a CG clip. (Mask
    ///     construction itself may need a scratch bitmap — see Compositing.md
    ///     PROFILE-CHECK.)
    ///  4. **An isolated blend** (mix-blend-mode ≠ normal / explicit isolation).
    ///     Not modeled yet; the hook is here so it slots in without reshaping the
    ///     walk.
    ///
    /// NOT in this list, on purpose:
    ///  * `clip-path` — realized as a CGContext clip (a path or the intersection
    ///    of paths), never a layer.
    ///  * `opacity == 1`, or a fill-only/stroke-only shape with opacity < 1 —
    ///    folded, no layer.
    ///
    /// - Parameter paintsFillAndStroke: whether this node (if a shape) will emit
    ///   both a fill and a stroke pass; the visitor knows this from the resolved
    ///   paints and passes it in.
    public func needsIsolationLayer(_ node: NodeIndex,
                                    style: ComputedStyle,
                                    paintsFillAndStroke: Bool) -> Bool {
        if !style.mask.isNone { return true }                     // (3)
        // (4) isolated blend — TODO(render-thread) when blend modes are modeled.
        guard style.groupOpacity < 1 else { return false }
        switch document.node(node).kind {
        case .group, .svg, .symbol, .use:
            return true                                            // (1)
        case .shape, .path, .poly, .text, .image:
            return paintsFillAndStroke                             // (2) else fold
        default:
            return false
        }
    }

    /// Begin an offscreen layer clamped to the visible region.
    ///
    /// KEY MEMORY DECISION: `CGContext.beginTransparencyLayer` sizes the layer's
    /// backing store from the context's CURRENT CLIP bounding box at the moment it
    /// is called. So to keep a layer from allocating the full canvas, we first
    /// tighten the clip to
    ///
    ///     elementDeviceBounds ∩ currentClipDeviceBounds ∩ dirtyRect
    ///
    /// and only then begin the layer. CG then backs only that region. If the
    /// intersection is empty the element is entirely invisible and we skip it
    /// (returning `false`, and NOT opening a layer).
    ///
    /// Balanced by `endIsolationLayer()` only when this returns `true`.
    ///
    /// - Parameters:
    ///   - elementDeviceBounds: device-space bounds of the subtree about to be
    ///     drawn (from `subtreeDeviceBounds`). Pass `.null` if unknown, in which
    ///     case the clamp falls back to the current clip ∩ dirty rect.
    ///   - alpha: the group alpha to composite the finished layer with (1 for
    ///     mask/blend-only layers).
    @discardableResult
    public func beginIsolationLayer(elementDeviceBounds: CGRect, alpha: CGFloat) -> Bool {
        guard layerDepth < maxLayerDepth else { return false }    // graceful degrade

        var clamped = intersectionOrEmpty(current.clipDeviceBounds, dirtyRect)
        if !elementDeviceBounds.isNull {
            clamped = intersectionOrEmpty(clamped, elementDeviceBounds)
        }
        guard !clamped.isEmpty else { return false }              // nothing visible

        cg.saveGState()
        frames.append(current)
        // Tighten the CG clip to the clamped device region so the layer is sized
        // to it. Convert device → current user space for `clip(to:)`.
        let toUser = current.userToDevice.inverted()
        cg.clip(to: clamped.applying(toUser))
        frames[frames.count - 1].clipDeviceBounds = clamped

        cg.setAlpha(alpha)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        layerDepth += 1
        return true
    }

    public func endIsolationLayer() {
        cg.endTransparencyLayer()
        layerDepth -= 1
        cg.restoreGState()
        frames.removeLast()
    }

    // MARK: Geometry (subtree bounds for layer clamping)

    /// Device-space bounds of everything `node` would paint, for layer clamping
    /// and objectBoundingBox mapping. For a shape this is its path box; for a
    /// container it is the union over painted descendants; `<use>` maps through
    /// the instance transform.
    ///
    /// TODO(render-thread): implement over the arena. It must (a) share the same
    /// bbox definition PaintServer uses for objectBoundingBox (geometry only, no
    /// stroke widening — SVG bbox excludes stroke), (b) be memotypable by
    /// NodeIndex within a single pass since the arena is immutable, and (c) honor
    /// `display:none`/`visibility` pruning. Returning `.null` here is the safe
    /// fallback: `beginIsolationLayer` then clamps to clip ∩ dirty, which is
    /// correct but potentially larger than necessary.
    /// PROFILE-CHECK (bbox-cost): confirm subtree-bounds computation is not itself
    /// a hotspot for deep trees; add the per-pass memo if it is.
    public func subtreeDeviceBounds(of node: NodeIndex) -> CGRect {
        let local = ClipRenderer.localGeometryBounds(of: node, document: document)
        guard !local.isNull else { return .null }
        return local.applying(current.userToDevice)
    }

    // MARK: Helpers

    /// `CGRect.intersection` returns `.null` for disjoint rects; normalize to a
    /// canonical empty so `.isEmpty` checks read cleanly and `.null` means only
    /// "unbounded/unknown".
    @inline(__always)
    private func intersectionOrEmpty(_ a: CGRect, _ b: CGRect) -> CGRect {
        if a.isNull { return b }
        if b.isNull { return a }
        let r = a.intersection(b)
        return r.isNull ? .zero : r
    }
}

// MARK: - NodeVisitor (the leaf-render dispatch seam)

/// The extensibility seam a later thread implements to emit Core Graphics draw
/// calls. The pipeline (`RenderWalk`) owns traversal, the state stack, clip
/// setup, and layer isolation; a `NodeVisitor` is handed an element whose CTM,
/// clip, and (if needed) transparency layer are ALREADY configured, and is
/// responsible only for turning that element's geometry into pixels.
///
/// Container enter/exit hooks exist so a visitor can observe grouping without
/// taking over traversal. Returning `.skipChildren` from `willEnterContainer`
/// prunes a subtree (e.g. `display:none`, or an empty clip) without the visitor
/// having to understand the arena.
public protocol NodeVisitor {

    /// Called for a container (`group`/`svg`/`symbol`/`defs`) before its children
    /// are walked. The context's transform/clip/layer for the container are set.
    mutating func willEnterContainer(_ node: NodeIndex, style: ComputedStyle,
                                     context: RenderContext) -> ChildWalk

    /// Called after a container's children have been walked (and its layer, if
    /// any, is about to be composited).
    mutating func didExitContainer(_ node: NodeIndex, style: ComputedStyle,
                                   context: RenderContext)

    /// Draw a shape/path/polygon whose fillable geometry is `path` (already in
    /// current user space; build via `PathBuilder`). Fill then stroke per SVG
    /// paint order, honoring `style` paints and the fill/stroke opacity split.
    mutating func drawShape(_ node: NodeIndex, path: CGPath, style: ComputedStyle,
                            context: RenderContext)

    /// Draw an `<image>`; the visitor pulls the decoded bitmap from
    /// `context.images` at the current device scale (never full-res).
    mutating func drawImage(_ node: NodeIndex, image: Image, style: ComputedStyle,
                            context: RenderContext)

    /// Draw `<text>`. Text shaping is a later concern; this is the hook.
    mutating func drawText(_ node: NodeIndex, text: Text, style: ComputedStyle,
                           context: RenderContext)
}

/// Whether to descend into a container's children.
public enum ChildWalk { case children, skipChildren }

// MARK: - RenderWalk (the depth-first traversal)

/// The single depth-first walk. It resolves style down the tree, maintains the
/// transform/clip/opacity stack via `RenderContext`, decides per node whether an
/// offscreen layer is unavoidable, and dispatches leaves to a `NodeVisitor`.
///
/// The traversal control flow is real; the parts that need geometry or actual
/// drawing delegate to `RenderContext.subtreeDeviceBounds` / the visitor and are
/// marked TODO(render-thread).
public struct RenderWalk<V: NodeVisitor> {

    public var visitor: V
    public let context: RenderContext

    public init(visitor: V, context: RenderContext) {
        self.visitor = visitor
        self.context = context
    }

    /// Render the document from its root.
    public mutating func run() {
        let doc = context.document
        guard !doc.root.isNone else { return }
        render(doc.root, inheriting: .initial)
    }

    /// Render one node under `inherited` computed style. This is the spine of the
    /// whole renderer; read it top-to-bottom as the per-node contract.
    public mutating func render(_ node: NodeIndex, inheriting inherited: ComputedStyle) {
        let doc = context.document
        let n = doc.node(node)
        let style = context.styles.resolve(node, inheriting: inherited)

        // `display:none` prunes the subtree entirely (it is not even laid out).
        // `visibility:hidden`/`collapse` still walk (descendants may be visible)
        // but suppress this element's own paint — that suppression is the
        // visitor's concern; pruning is ours. `display` lives on RawStyle, not
        // ComputedStyle, so read it raw here.
        if n.style.display == Display.none { return }

        // defs and other never-painted-in-flow kinds are skipped by document flow;
        // they render only when referenced (paint server / clip / mask / use).
        switch n.kind {
        case .defs, .clipPath, .mask, .gradient, .pattern, .symbol:
            return
        default:
            break
        }

        context.save()
        defer { context.restore() }

        // 1. Element transform.
        context.concatenate(doc.affineTransform(n.transform))

        // 2. clip-path (a CGContext clip, never a layer).
        if !style.clipPath.isNone {
            let clippedOut = applyClipPath(style.clipPath, referencing: node)
            if clippedOut { return }   // clip resolved to empty geometry — nothing to draw
        }

        // 3. Decide isolation. `paintsFillAndStroke` is precise for shapes
        //    (both fill and stroke actually resolve to a paint); text/image
        //    are conservatively always-isolate-on-opacity (a shape with a
        //    single contribution folds instead — the common cheap path).
        let paintsFillAndStroke: Bool
        switch n.kind {
        case .shape, .path, .poly:
            let hasFill = PaintResolver.resolve(style.fill, references: context.references) != nil
            let hasStroke = style.strokeWidth > 0
                && PaintResolver.resolve(style.stroke, references: context.references) != nil
            paintsFillAndStroke = hasFill && hasStroke
        default:
            paintsFillAndStroke = isDrawableLeaf(n.kind)
        }
        let isolate = context.needsIsolationLayer(node, style: style,
                                                  paintsFillAndStroke: paintsFillAndStroke)

        var layerOpen = false
        if isolate {
            let bounds = context.subtreeDeviceBounds(of: node)
            let alpha = style.mask.isNone ? style.groupOpacity : 1   // mask composited separately
            layerOpen = context.beginIsolationLayer(elementDeviceBounds: bounds, alpha: alpha)
            if !layerOpen, !style.mask.isNone {
                // Clip clamped to empty → invisible; nothing to draw.
                return
            }
        }
        defer { if layerOpen { context.endIsolationLayer() } }

        // 4. Dispatch.
        dispatch(node, kind: n.kind, style: style)

        // 5. Mask multiply (inside the still-open layer), only meaningful if a
        //    layer is actually open — a mask with no layer (graceful
        //    layer-depth degradation) is a known, documented approximation.
        if !style.mask.isNone, layerOpen {
            let objectBounds = ClipRenderer.localGeometryBounds(of: node, document: doc)
            if let maskImage = MaskRenderer.buildAlphaMaskImage(
                maskNode: style.mask, context: context,
                deviceBounds: context.current.clipDeviceBounds,
                objectBounds: objectBounds.isNull ? .zero : objectBounds
            ) {
                let cg = context.cg
                cg.saveGState()
                cg.concatenate(cg.ctm.inverted())   // reset to device pixel space
                cg.setBlendMode(.destinationIn)
                cg.draw(maskImage, in: context.current.clipDeviceBounds)
                cg.restoreGState()
            }
        }
    }

    // MARK: Dispatch

    private mutating func dispatch(_ node: NodeIndex, kind: NodeKind, style: ComputedStyle) {
        switch kind {
        case .group, .svg:
            if case .svg(let vp) = kind { applyNestedViewport(vp, isRoot: node == context.document.root) }
            let decision = visitor.willEnterContainer(node, style: style, context: context)
            if decision == .children {
                context.document.forEachChild(of: node) { child in
                    render(child, inheriting: style)
                }
            }
            visitor.didExitContainer(node, style: style, context: context)

        case .use(let use):
            renderUse(node, use: use, style: style)

        case .shape, .path, .poly:
            let path = buildLeafPath(node, kind: kind)
            visitor.drawShape(node, path: path, style: style, context: context)

        case .image(let image):
            visitor.drawImage(node, image: image, style: style, context: context)

        case .text(let text):
            visitor.drawText(node, text: text, style: style, context: context)

        case .defs, .clipPath, .mask, .gradient, .pattern, .symbol:
            break   // handled by the pre-filter in `render`
        }
    }

    // MARK: <use> instancing (BY REFERENCE — no subtree copy)

    /// Render a `<use>` by resolving its target and re-walking it in place under
    /// the instance transform and the use-site inherited style. The target
    /// subtree is NOT copied (MemoryModel §4); we simply recurse into the arena
    /// nodes the target already occupies.
    private mutating func renderUse(_ node: NodeIndex, use: Use, style: ComputedStyle) {
        // Cycle guard: refuse to expand a `<use>` chain that revisits itself.
        if context.references.hasUseCycle(startingAt: node) {
            // TODO(render-thread): surface as a non-fatal diagnostic; per SVG a
            // cyclic <use> renders nothing for the offending instance.
            return
        }
        let target = context.references.useTarget(use)
        guard !target.isNone else { return }

        context.save()
        defer { context.restore() }

        // Overflow clip for a symbol/svg target's viewport (a no-op for a
        // plain-shape target, per `instanceViewportRect`). MUST happen in the
        // use-site's user space, i.e. BEFORE the instance transform below
        // folds in the viewBox alignment matrix — `use.x/y/width/height` are
        // only meaningful in that outer frame.
        UseSymbolRenderer.applyViewportClip(for: use, context: context)

        // Instance transform (translate by x/y; symbol/svg targets add the
        // viewport matrix). Reuses ReferenceResolver + Transforms.swift.
        context.concatenate(context.references.instanceTransform(for: use,
                                                                 currentViewport: context.current.viewport))

        // Inheritance-into-instance (CascadeRules §6): the target inherits from
        // the computed style AT THE USE SITE, not from its own document parent.
        let instanceInherited = style   // = resolve(useNode, inheriting: outer)

        // A `<use>` of a `<symbol>` promotes it to a rendered viewport; a `<use>`
        // of anything else renders the target as-is under the new context.
        let targetKind = context.document.node(target).kind
        if case .symbol = targetKind {
            renderSymbolInstance(target, use: use, inheriting: instanceInherited)
        } else {
            render(target, inheriting: instanceInherited)
        }
    }

    /// Render a `<symbol>` as instanced by a `<use>`: its viewport (clip +
    /// viewBox transform) was already established by `renderUse` (the clip
    /// before, the viewBox matrix folded into the instance transform), so this
    /// is just the child walk.
    private mutating func renderSymbolInstance(_ symbol: NodeIndex, use: Use,
                                               inheriting: ComputedStyle) {
        context.document.forEachChild(of: symbol) { child in
            render(child, inheriting: inheriting)
        }
    }

    // MARK: Viewport / clip application

    /// Establish a viewport (root `<svg>` or a nested `<svg>`/`<symbol>` via
    /// `<use>`): translate to `(vp.x, vp.y)`, clip to the viewport rect
    /// (overflow:hidden — the only policy modeled), then fold in the
    /// viewBox→viewport alignment matrix if present.
    ///
    /// The ROOT is special-cased to size its viewport from the render pass's
    /// own `dirtyRect` (the caller-requested output rect) rather than the
    /// root `<svg>`'s own `width`/`height` attributes — matching
    /// `SVGRenderer.render(_:into:rect:)`'s documented contract of fitting the
    /// document into the caller's `rect`. Every sample in this corpus happens
    /// to declare `width`/`height` equal to its render size 1:1, so the two
    /// policies coincide there; the root case exists for callers that differ.
    private func applyNestedViewport(_ vp: NestedViewport, isRoot: Bool) {
        let parentViewport = context.current.viewport
        context.concatenate(CGAffineTransform(translationX: vp.x, y: vp.y))

        let width: CGFloat
        let height: CGFloat
        if isRoot {
            width = parentViewport.width
            height = parentViewport.height
        } else {
            width = resolveViewportLength(vp.width, viewport: parentViewport.width)
            height = resolveViewportLength(vp.height, viewport: parentViewport.height)
        }
        let viewportRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(toUserRect: viewportRect)

        if let viewBox = vp.viewBox {
            let m = ViewportMath.viewportTransform(viewBox: viewBox, viewport: viewportRect,
                                                   par: vp.preserveAspectRatio)
            context.concatenate(m)
            context.setViewport(CGSize(width: viewBox.width, height: viewBox.height))
        } else {
            context.setViewport(viewportRect.size)
        }
    }

    private func resolveViewportLength(_ length: LengthOrAuto, viewport: CGFloat) -> CGFloat {
        if case .value(let v) = length { return v }
        return viewport
    }

    /// Apply `clip-path` as a CGContext clip. Returns `true` if the clip
    /// resolved to empty/absent geometry — the caller then skips this
    /// subtree's work entirely, since nothing painted under an empty clip is
    /// visible.
    private func applyClipPath(_ clip: NodeIndex, referencing node: NodeIndex) -> Bool {
        let objectBounds = ClipRenderer.localGeometryBounds(of: node, document: context.document)
        guard let (path, rule) = ClipRenderer.buildClipPath(
            clip, objectBounds: objectBounds.isNull ? .zero : objectBounds, document: context.document
        ) else {
            // Degenerate objectBoundingBox mapping or no clip geometry at all
            // → per spec the referencing element renders nothing.
            context.clip(toUserRect: .zero)
            return true
        }
        context.clip(toPath: path, rule: rule)
        return false
    }

    // MARK: Leaf geometry

    private func buildLeafPath(_ node: NodeIndex, kind: NodeKind) -> CGPath {
        _ = kind
        return ShapeRenderer.leafPath(node, document: context.document)
    }

    private func isDrawableLeaf(_ kind: NodeKind) -> Bool {
        switch kind {
        case .shape, .path, .poly, .text, .image: return true
        default: return false
        }
    }
}
