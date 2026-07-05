//
//  SVGModel.swift
//  ThinPath
//
//  The in-memory intermediate representation (IR) produced by the parser and
//  consumed by the style resolver, layout/coordinate math, and (eventually) the
//  Core Graphics renderer.
//
//  DESIGN CONSTRAINT: memory efficiency. The IR is deliberately a *flat arena*
//  of value types. There is no pointer-linked node graph of classes; every
//  cross-reference (parent, child, sibling, paint server, clip, href target) is
//  an integer index into a contiguous array. This keeps a parsed document as a
//  handful of `Array` allocations that can be released in one move, keeps nodes
//  cache-dense, and makes whole-subtree operations (skip, copy, measure) O(1) on
//  ranges instead of chasing pointers.
//
//  See Design/MemoryModel.md for the rationale and the PROFILE-CHECK items that
//  a later profiling pass must confirm.
//

import CoreGraphics
import Foundation

// MARK: - Index types

/// Index into `SVGDocument.nodes`. `-1` is the null sentinel (`.none`).
///
/// `Int32` is used rather than `Int` to halve the footprint of the many
/// cross-links each node carries. A single document is not expected to exceed
/// 2^31 nodes; if that ever changes it is a one-line typealias edit.
public typealias NodeIndex = Int32

/// Index into `SVGDocument.strings` (the interned string pool). `-1` is null.
public typealias StringRef = Int32

/// Index into `SVGDocument.transforms`. `-1` means "identity, not stored".
public typealias TransformRef = Int32

extension NodeIndex {
    /// The null node sentinel. Named on `NodeIndex` for readability at call sites.
    public static let none: NodeIndex = -1
    public var isNone: Bool { self < 0 }
}

// MARK: - Document (the arena)

/// A fully parsed SVG document.
///
/// The document owns *all* backing storage. Every `SVGNode` and every reference
/// inside the IR is an index that is only valid against the document instance it
/// was produced from. Indices are NOT stable across documents and must never be
/// persisted or mixed between documents.
///
/// ## Lifetime invariants
///
/// 1. **Append-only arenas.** During parsing the arenas (`nodes`, `pathCommands`,
///    `points`, `gradientStops`, `strings`, `transforms`) grow by appending.
///    Once parsing finishes the document is treated as immutable by all
///    downstream passes (style resolution, coordinate math, rendering). Nothing
///    downstream removes or reorders arena elements, so every stored index stays
///    valid for the lifetime of the document.
///
/// 2. **No dangling indices.** Any non-null index stored anywhere in the IR
///    (parent/child/sibling links, `Paint.ref`, `href`, `clipPath`, `mask`,
///    range starts/counts) points inside the corresponding arena's bounds. The
///    parser is responsible for either resolving a reference to a valid index or
///    recording it as unresolved (`.none` / `PaintServer.unresolved`). Downstream
///    code may assume in-bounds but MUST tolerate `.none`.
///
/// 3. **Tree shape via links, not containment.** Children are encoded as a
///    first-child / next-sibling intrusive list of indices (see `SVGNode`). There
///    is exactly one `root`. Every non-root reachable node has a `parent` that
///    lists it (transitively) through `firstChild`/`nextSibling`. `defs` subtrees
///    are part of the same arena and same tree; they are simply not painted
///    directly (see `NodeKind.defs`).
///
/// 4. **`idMap` is the only id resolver.** Element `id`s are interned into
///    `strings`; `idMap` maps the interned `StringRef` to the defining node. A
///    reference-by-id (`use`, `fill="url(#g)"`, `clip-path`) is resolved by
///    interning the referenced id and looking it up here. Later definitions win
///    per the SVG rule that a document has at most one element per id (last-wins
///    is a parser policy, documented there).
public struct SVGDocument {

    /// The flat node arena. Index 0 is not special; `root` names the tree root.
    public var nodes: [SVGNode] = []

    /// Root node index. Conventionally the outermost `<svg>` element.
    public var root: NodeIndex = .none

    // --- Side arenas for variable-length node payloads ---
    // Nodes store (start, count) windows into these instead of owning arrays,
    // so a node stays a fixed-size value with no per-node heap allocation.

    /// Path command stream. `NodeKind.path` stores a `Range`-like window here.
    public var pathCommands: [PathCommand] = []

    /// Point stream for `polyline`/`polygon`. Shape nodes store a window here.
    public var points: [CGPoint] = []

    /// Gradient stop stream. Gradient nodes store a window here.
    public var gradientStops: [GradientStop] = []

    /// Interned string pool: ids, hrefs, text runs, font family names, etc.
    public var strings: StringPool = StringPool()

    /// Parsed transform arena. `TransformRef` indexes here; identity is not
    /// stored (represented by `-1`) so the common no-transform case costs nothing.
    public var transforms: [CGAffineTransform] = []

    /// id → node lookup for all `defs`-style resolution. Keyed by interned id.
    public var idMap: [StringRef: NodeIndex] = [:]

    /// The document-level viewport description from the root `<svg>`, if present.
    public var rootViewBox: ViewBox?
    public var rootPreserveAspectRatio: PreserveAspectRatio = .default

    public init() {}

    // MARK: Convenience accessors (bounds-checked read helpers)

    @inline(__always)
    public func node(_ i: NodeIndex) -> SVGNode {
        nodes[Int(i)]
    }

    /// Resolve an interned id to its defining node, or `.none` if undefined.
    @inline(__always)
    public func nodeForID(_ id: StringRef) -> NodeIndex {
        idMap[id] ?? .none
    }

    /// The path command window for a `path` node, as an `Array` slice view.
    public func commands(_ window: ArenaRange) -> ArraySlice<PathCommand> {
        pathCommands[window.range]
    }

    public func points(_ window: ArenaRange) -> ArraySlice<CGPoint> {
        points[window.range]
    }

    public func stops(_ window: ArenaRange) -> ArraySlice<GradientStop> {
        gradientStops[window.range]
    }

    /// Iterate the direct children of `parent` in document order.
    public func forEachChild(of parent: NodeIndex, _ body: (NodeIndex) -> Void) {
        var c = node(parent).firstChild
        while !c.isNone {
            body(c)
            c = node(c).nextSibling
        }
    }
}

// MARK: - Arena windows

/// A (start, count) window into a side arena. Stored instead of an owned array
/// so payload-bearing nodes remain fixed-size value types.
public struct ArenaRange: Equatable {
    public var start: Int32
    public var count: Int32
    public init(start: Int32, count: Int32) {
        self.start = start
        self.count = count
    }
    public static let empty = ArenaRange(start: 0, count: 0)
    public var isEmpty: Bool { count == 0 }
    public var range: Range<Int> { Int(start) ..< Int(start + count) }
}

// MARK: - Node

/// A single IR node. Fixed-size value type; all variable data lives in side
/// arenas or the string pool and is referenced by index/window.
///
/// Tree links are an intrusive first-child / next-sibling list, so adding a
/// child never allocates and a subtree can be walked without touching any
/// container besides `nodes`.
public struct SVGNode {

    /// The element kind plus its fixed-size, kind-specific payload.
    public var kind: NodeKind

    /// Interned `id` attribute, or `.none`. Present here (not only in `idMap`)
    /// so a node can report its own id without a reverse lookup.
    public var id: StringRef = .none

    /// Tree links (see `SVGDocument` invariant 3). `.none` terminates a list.
    public var parent: NodeIndex = .none
    public var firstChild: NodeIndex = .none
    public var nextSibling: NodeIndex = .none

    /// The element's own `transform` attribute, composed left-to-right into one
    /// matrix at parse time. `.none` (identity) is the common case and free.
    public var transform: TransformRef = .none

    /// Raw, *unresolved* presentation state: the union of presentation
    /// attributes and the `style=""` declaration block for this element only.
    /// The style resolver reads this plus the inherited context to produce a
    /// `ComputedStyle`. Kept separate from computed style so the IR carries no
    /// resolution assumptions and can be re-resolved (e.g. for `use` shadow
    /// trees — see StyleResolver.swift). See `RawStyle`.
    public var style: RawStyle = RawStyle()

    public init(kind: NodeKind) {
        self.kind = kind
    }
}

// MARK: - Node kinds

/// The kind of an element plus any fixed-size geometry it carries directly.
///
/// Variable-length data (path commands, polygon points, gradient stops) is NOT
/// embedded here; it lives in a side arena referenced by `ArenaRange`. Cross
/// references (paint servers, href targets, clip/mask) are `NodeIndex`/`StringRef`.
public enum NodeKind {

    /// `<g>` and the implicit grouping done by the root. Pure container.
    case group

    /// `<svg>` used as a *nested* viewport (the root `<svg>` is also this kind;
    /// `SVGDocument.root` distinguishes it). Establishes a new viewport.
    case svg(NestedViewport)

    /// A basic shape with fixed geometry (`rect`, `circle`, `ellipse`, `line`).
    case shape(Shape)

    /// `polyline` / `polygon`: a run of points in the `points` arena. `closed`
    /// distinguishes the two.
    case poly(points: ArenaRange, closed: Bool)

    /// `<path>`: a command window into the `pathCommands` arena.
    case path(commands: ArenaRange)

    /// `<image>`: an href to raster/vector data plus the destination rect and
    /// its own aspect-ratio policy. The href is intentionally NOT decoded here;
    /// decoding is deferred to render time to avoid holding full-res bitmaps.
    case image(Image)

    /// `<text>`: positioned text. `content` is an interned string; rich
    /// tspan structure (if modeled) hangs off children. Kept minimal at this
    /// layer — text shaping is a later concern.
    case text(Text)

    /// `<use>`: references another element by id and re-instances it. The
    /// referenced element is resolved via `idMap`; the shadow subtree is NOT
    /// copied into the arena at parse time (see StyleResolver.swift TODO and
    /// MemoryModel.md — instancing stays cheap).
    case use(Use)

    /// `<symbol>`: a reusable, non-directly-rendered template that establishes a
    /// viewport when instanced by `<use>`.
    case symbol(NestedViewport)

    /// `<linearGradient>` / `<radialGradient>`: a paint server.
    case gradient(Gradient)

    /// `<pattern>`: a paint server whose tile content is its child subtree.
    case pattern(Pattern)

    /// `<clipPath>`: clip geometry is its child subtree; `clipUnits` recorded.
    case clipPath(units: Units)

    /// `<mask>`: luminance/alpha mask; content is its child subtree.
    case mask(Mask)

    /// `<defs>`: container whose descendants are definitions only and are never
    /// painted by document flow (they are painted only when referenced).
    case defs
}

// MARK: - Fixed-size kind payloads

public enum Shape {
    case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat)
    case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
    case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
}

/// A nested viewport (`<svg>` / `<symbol>`). See Transforms.swift for how the
/// viewBox + preserveAspectRatio become an alignment matrix.
public struct NestedViewport {
    public var x: CGFloat
    public var y: CGFloat
    public var width: LengthOrAuto
    public var height: LengthOrAuto
    public var viewBox: ViewBox?
    public var preserveAspectRatio: PreserveAspectRatio
    public init(x: CGFloat = 0, y: CGFloat = 0,
                width: LengthOrAuto = .auto, height: LengthOrAuto = .auto,
                viewBox: ViewBox? = nil,
                preserveAspectRatio: PreserveAspectRatio = .default) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.viewBox = viewBox; self.preserveAspectRatio = preserveAspectRatio
    }
}

public struct Image {
    public var href: StringRef
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var preserveAspectRatio: PreserveAspectRatio
}

public struct Text {
    public var x: CGFloat
    public var y: CGFloat
    public var content: StringRef
}

public struct Use {
    /// Interned id from `href`/`xlink:href` (without the leading `#`).
    public var href: StringRef
    /// Pre-resolved target if the id was defined at parse time; else `.none`.
    /// A forward reference resolvable only after the full parse is left `.none`
    /// here and resolved on demand via `idMap` (invariant 2 permits `.none`).
    public var resolved: NodeIndex
    public var x: CGFloat
    public var y: CGFloat
    /// `use` may override width/height for `svg`/`symbol` targets.
    public var width: LengthOrAuto
    public var height: LengthOrAuto
}

public struct Mask {
    public var maskUnits: Units
    public var maskContentUnits: Units
}

// MARK: - Paint

/// A resolved-or-referential paint value (used for both `fill` and `stroke`).
///
/// Critically, a paint that points at a paint server (`gradient`/`pattern`)
/// stores only a *reference* to that server — never an embedded copy — so a
/// gradient shared by 10 000 shapes exists once in the arena.
public enum Paint: Equatable {
    /// `fill="none"` — do not paint.
    case none
    /// `currentColor` — resolves against the inherited `color` property at
    /// style-resolution time, not here.
    case currentColor
    /// A solid color (already parsed; see `RGBA`).
    case color(RGBA)
    /// `url(#id)` reference to a paint server, with a fallback used if the
    /// reference is invalid/unresolved (`fill="url(#g) red"`).
    case server(PaintServer, fallback: PaintFallback)
}

/// A reference to a paint-server element, stored by id and (if known) index.
/// Never embeds the server node itself (invariant: paint servers are shared).
public struct PaintServer: Equatable {
    /// Interned id of the referenced `<linearGradient>`/`<radialGradient>`/`<pattern>`.
    public var id: StringRef
    /// Pre-resolved node index, or `.none` for a forward/unresolved reference
    /// (resolve on demand via `idMap`).
    public var node: NodeIndex
    public init(id: StringRef, node: NodeIndex = .none) {
        self.id = id; self.node = node
    }
    /// The reference could not be resolved to any element.
    public static let unresolved = PaintServer(id: .none, node: .none)
}

public enum PaintFallback: Equatable {
    case none            // no fallback token present
    case color(RGBA)     // e.g. `url(#g) red`
    case explicitNone    // e.g. `url(#g) none`
}

/// Packed 8-bit-per-channel non-premultiplied color. 4 bytes instead of four
/// `CGFloat`s. Wide-gamut / ICC color is a later concern (PROFILE-CHECK in
/// MemoryModel.md).
public struct RGBA: Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)
}

// MARK: - Gradients & patterns

public struct Gradient {
    public enum Geometry {
        case linear(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
        case radial(cx: CGFloat, cy: CGFloat, r: CGFloat, fx: CGFloat, fy: CGFloat)
    }
    public var geometry: Geometry
    public var stops: ArenaRange          // window into `gradientStops`
    public var units: Units               // userSpaceOnUse / objectBoundingBox
    public var spread: SpreadMethod
    public var gradientTransform: TransformRef
    /// `href` template gradient (`<linearGradient href="#base">`), resolved as
    /// an index into `nodes`, or `.none`. Attribute/stop inheritance from the
    /// template is a resolver concern, not stored expanded here.
    public var template: NodeIndex
}

public struct GradientStop: Equatable {
    public var offset: CGFloat   // 0...1
    public var color: RGBA       // stop-color * stop-opacity folded into alpha
}

public enum SpreadMethod { case pad, reflect, repeatSpread }

public struct Pattern {
    public var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    public var patternUnits: Units
    public var patternContentUnits: Units
    public var patternTransform: TransformRef
    public var viewBox: ViewBox?
    public var preserveAspectRatio: PreserveAspectRatio
    public var template: NodeIndex   // `href` template pattern, or `.none`
}

/// Coordinate system selector shared by gradients, patterns, clips, masks.
public enum Units { case userSpaceOnUse, objectBoundingBox }

// MARK: - Lengths & viewport primitives

/// A width/height that may be `auto` (nested viewport / image / use sizing).
public enum LengthOrAuto: Equatable {
    case auto
    case value(CGFloat)   // already resolved to user units at parse time
}

/// `viewBox="minX minY width height"`.
public struct ViewBox: Equatable {
    public var minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat
    public init(minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat) {
        self.minX = minX; self.minY = minY; self.width = width; self.height = height
    }
    public var rect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

// MARK: - Path commands

/// One path segment. Curves are stored explicitly; the elliptical arc keeps its
/// *raw endpoint parameters* exactly as authored (`A rx ry rot large sweep x y`).
/// Conversion to the center parameterization Core Graphics needs is deliberately
/// deferred to the flattening/render pass so the IR stays a faithful, compact
/// record of the source and re-flattening at different scales is possible.
public enum PathCommand: Equatable {
    case moveTo(CGPoint)
    case lineTo(CGPoint)
    case quadTo(control: CGPoint, end: CGPoint)
    case cubicTo(control1: CGPoint, control2: CGPoint, end: CGPoint)
    case arc(ArcTo)
    case close
}

/// Raw endpoint-parameterized elliptical arc, as authored.
public struct ArcTo: Equatable {
    public var rx: CGFloat
    public var ry: CGFloat
    public var xAxisRotation: CGFloat   // degrees, as authored
    public var largeArc: Bool
    public var sweep: Bool
    public var end: CGPoint
    public init(rx: CGFloat, ry: CGFloat, xAxisRotation: CGFloat,
                largeArc: Bool, sweep: Bool, end: CGPoint) {
        self.rx = rx; self.ry = ry; self.xAxisRotation = xAxisRotation
        self.largeArc = largeArc; self.sweep = sweep; self.end = end
    }
}

// MARK: - Raw (unresolved) style

/// The per-element presentation state exactly as parsed: the merge of
/// presentation *attributes* and the `style=""` declaration block, with the
/// style block taking precedence over attributes (per CSS specificity of inline
/// style over presentation attributes). Values are optional: `nil` means "not
/// specified on this element", which is what the cascade needs to distinguish
/// "inherit" from "explicitly set".
///
/// This type stores *only what this element declared*. Inheritance and initial
/// values are applied by `StyleResolver`, never here. See CascadeRules.md.
public struct RawStyle: Equatable {
    // Paint
    public var fill: Paint?
    public var stroke: Paint?
    public var strokeWidth: CGFloat?
    public var color: RGBA?            // the `color` property (for currentColor)

    // Opacity — SVG splits these; do NOT collapse into one.
    public var opacity: CGFloat?       // group/element opacity (isolates)
    public var fillOpacity: CGFloat?
    public var strokeOpacity: CGFloat?

    // Fill/stroke detail
    public var fillRule: FillRule?
    public var clipRule: FillRule?
    public var strokeLineCap: LineCap?
    public var strokeLineJoin: LineJoin?
    public var strokeMiterLimit: CGFloat?
    public var strokeDashArray: ArenaRange?   // window into a dash arena (or nil)
    public var strokeDashOffset: CGFloat?

    // Text / font (inheritable)
    public var fontFamily: StringRef?
    public var fontSize: CGFloat?
    public var fontWeight: FontWeight?
    public var fontStyle: FontStyle?
    public var textAnchor: TextAnchor?

    // Painting control
    public var visibility: Visibility?
    public var display: Display?

    // Non-inherited references (clip/mask/filter apply to the element only)
    public var clipPath: NodeIndex?   // resolved clipPath node, or nil
    public var mask: NodeIndex?       // resolved mask node, or nil

    public init() {}
}

// MARK: - Style value enums

public enum FillRule { case nonZero, evenOdd }
public enum LineCap { case butt, round, square }
public enum LineJoin { case miter, round, bevel }
public enum FontStyle { case normal, italic, oblique }
public enum TextAnchor { case start, middle, end }
public enum Visibility { case visible, hidden, collapse }
public enum Display { case inline, none }   // only `none` is load-bearing here

public struct FontWeight: Equatable {
    public var value: Int   // 100...900; normal=400, bold=700
    public init(_ value: Int) { self.value = value }
    public static let normal = FontWeight(400)
    public static let bold = FontWeight(700)
}

// MARK: - String pool

/// Deduplicating string interner. SVG documents repeat ids, class names, font
/// families and href targets heavily; interning stores each unique string once
/// and lets the IR reference them as 4-byte `StringRef`s.
public struct StringPool {
    private var storage: [String] = []
    private var lookup: [String: StringRef] = [:]

    public init() {}

    /// Intern a string, returning a stable `StringRef`. Idempotent.
    public mutating func intern(_ s: String) -> StringRef {
        if let existing = lookup[s] { return existing }
        let ref = StringRef(storage.count)
        storage.append(s)
        lookup[s] = ref
        return ref
    }

    /// Resolve a ref back to its string. `nil` for `.none`/out of range.
    public func string(_ ref: StringRef) -> String? {
        guard ref >= 0, Int(ref) < storage.count else { return nil }
        return storage[Int(ref)]
    }

    public var count: Int { storage.count }
}
