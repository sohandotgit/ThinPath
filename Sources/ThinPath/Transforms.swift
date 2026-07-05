//
//  Transforms.swift
//  ThinPath
//
//  Coordinate math with no rendering:
//   1. Parse an SVG `transform`/`gradientTransform`/`patternTransform` list into
//      a single `CGAffineTransform` (matrix/translate/scale/rotate/skewX/skewY).
//   2. Compute the viewport alignment matrix from `viewBox` +
//      `preserveAspectRatio` (all align values, meet | slice).
//
//  All of this is pure value math over Core Graphics types. See
//  Design/CoordinateNotes.md for conventions and the nested-viewport open
//  question.
//

import CoreGraphics
import Foundation

// MARK: - preserveAspectRatio model

/// `preserveAspectRatio="[defer] <align> [<meetOrSlice>]"`.
public struct PreserveAspectRatio: Equatable {
    public enum Align: Equatable {
        case none                 // "none" — non-uniform scale, fill the viewport
        case xMinYMin, xMidYMin, xMaxYMin
        case xMinYMid, xMidYMid, xMaxYMid   // xMidYMid is the default
        case xMinYMax, xMidYMax, xMaxYMax
    }
    public enum MeetOrSlice: Equatable { case meet, slice }

    public var align: Align
    public var meetOrSlice: MeetOrSlice
    /// `defer` only matters on `<image>` referencing another SVG; parsed and
    /// carried for completeness, ignored by the alignment math here.
    public var defers: Bool

    public init(align: Align = .xMidYMid, meetOrSlice: MeetOrSlice = .meet, defers: Bool = false) {
        self.align = align; self.meetOrSlice = meetOrSlice; self.defers = defers
    }

    /// The SVG default: `xMidYMid meet`.
    public static let `default` = PreserveAspectRatio()
}

// MARK: - transform list parsing

public enum TransformParser {

    /// Parse a full transform list (e.g. `"translate(10,20) rotate(30) scale(2)")`
    /// into one matrix. SVG establishes nested coordinate systems left-to-right:
    /// the leftmost transform is the *outermost*, so a local point is transformed
    /// by the rightmost primitive first and the leftmost last.
    ///
    /// `CGAffineTransform` uses the row-vector convention `p' = p · M`, and
    /// `X.concatenating(Y)` yields `X · Y` = "apply X, then Y". So to make the
    /// first-listed primitive apply last, we fold with
    /// `result = primitive.concatenating(result)` while iterating the list in
    /// order: after `A B`, `result = B.concatenating(A)` applies B (rightmost)
    /// first and A (leftmost) last — exactly the SVG rule. This is verified by a
    /// unit test (translate(10,0) scale(2) on (5,0) → (20,0)). See
    /// CoordinateNotes.md § "Composition order".
    ///
    /// Returns `nil` if the string is malformed; the caller decides whether a
    /// malformed transform is dropped (treated as identity) or fails the parse.
    public static func parse(_ s: String) -> CGAffineTransform? {
        var scanner = MiniScanner(s)
        var result = CGAffineTransform.identity
        var sawAny = false

        while !scanner.isAtEnd {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }
            guard let name = scanner.scanIdentifier() else { return nil }
            scanner.skipSeparators()
            guard scanner.consume("(") else { return nil }
            let args = scanner.scanNumbers(until: ")")
            guard scanner.consume(")") else { return nil }

            guard let primitive = matrix(for: name, args: args) else { return nil }
            // First-listed applies last (outermost). Iterating the list in order,
            // pre-concatenate so earlier primitives end up leftmost in `p · M`.
            result = primitive.concatenating(result)
            sawAny = true
        }
        return sawAny ? result : .identity
    }

    /// Build the matrix for one primitive. Returns `nil` on wrong arg count.
    static func matrix(for name: String, args: [CGFloat]) -> CGAffineTransform? {
        switch name {
        case "matrix":
            guard args.count == 6 else { return nil }
            return CGAffineTransform(a: args[0], b: args[1], c: args[2],
                                     d: args[3], tx: args[4], ty: args[5])
        case "translate":
            if args.count == 1 { return CGAffineTransform(translationX: args[0], y: 0) }
            guard args.count == 2 else { return nil }
            return CGAffineTransform(translationX: args[0], y: args[1])
        case "scale":
            if args.count == 1 { return CGAffineTransform(scaleX: args[0], y: args[0]) }
            guard args.count == 2 else { return nil }
            return CGAffineTransform(scaleX: args[0], y: args[1])
        case "rotate":
            if args.count == 1 {
                return CGAffineTransform(rotationAngle: radians(args[0]))
            }
            // rotate(angle cx cy) = translate(cx,cy) rotate(angle) translate(-cx,-cy)
            guard args.count == 3 else { return nil }
            let cx = args[1], cy = args[2]
            return CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: radians(args[0]))
                .translatedBy(x: -cx, y: -cy)
        case "skewX":
            guard args.count == 1 else { return nil }
            return CGAffineTransform(a: 1, b: 0, c: tan(radians(args[0])), d: 1, tx: 0, ty: 0)
        case "skewY":
            guard args.count == 1 else { return nil }
            return CGAffineTransform(a: 1, b: tan(radians(args[0])), c: 0, d: 1, tx: 0, ty: 0)
        default:
            return nil
        }
    }

    @inline(__always)
    static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
}

// MARK: - viewBox / preserveAspectRatio → viewport matrix

public enum ViewportMath {

    /// Compute the transform that maps content in `viewBox` coordinates into the
    /// device/parent `viewport` rectangle, honoring `preserveAspectRatio`.
    ///
    /// This is the standard SVG "equations" from the spec's coordinate chapter:
    ///   sx = viewport.w / viewBox.w,  sy = viewport.h / viewBox.h
    /// For uniform (`align != .none`) scaling, meet uses min(sx,sy) (whole
    /// viewBox visible, possibly letterboxed) and slice uses max(sx,sy) (viewBox
    /// covers the viewport, overflow clipped by the caller). Then translate to
    /// honor the min/mid/max alignment and the viewBox origin.
    ///
    /// Degenerate `viewBox` (zero/negative width or height) disables rendering
    /// of that element per spec; here we return `.identity` and let the caller
    /// treat a nil-ish result appropriately (documented in CoordinateNotes.md).
    public static func viewportTransform(viewBox: ViewBox,
                                         viewport: CGRect,
                                         par: PreserveAspectRatio) -> CGAffineTransform {
        guard viewBox.width > 0, viewBox.height > 0,
              viewport.width > 0, viewport.height > 0 else {
            return .identity
        }

        var sx = viewport.width / viewBox.width
        var sy = viewport.height / viewBox.height

        if par.align != .none {
            // Uniform scale.
            let s = (par.meetOrSlice == .meet) ? min(sx, sy) : max(sx, sy)
            sx = s
            sy = s
        }

        // Base translation places viewBox origin at viewport origin after scale.
        var tx = viewport.minX - viewBox.minX * sx
        var ty = viewport.minY - viewBox.minY * sy

        // Alignment: distribute the leftover space (which is >=0 for meet,
        // <=0 for slice) per the x/y align tokens.
        if par.align != .none {
            let extraX = viewport.width - viewBox.width * sx
            let extraY = viewport.height - viewBox.height * sy
            switch par.align.xAlign {
            case .min: break
            case .mid: tx += extraX / 2
            case .max: tx += extraX
            }
            switch par.align.yAlign {
            case .min: break
            case .mid: ty += extraY / 2
            case .max: ty += extraY
            }
        }

        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }
}

// MARK: - Align decomposition

extension PreserveAspectRatio.Align {
    enum Edge { case min, mid, max }

    var xAlign: Edge {
        switch self {
        case .xMinYMin, .xMinYMid, .xMinYMax: return .min
        case .xMidYMin, .xMidYMid, .xMidYMax: return .mid
        case .xMaxYMin, .xMaxYMid, .xMaxYMax: return .max
        case .none: return .min
        }
    }
    var yAlign: Edge {
        switch self {
        case .xMinYMin, .xMidYMin, .xMaxYMin: return .min
        case .xMinYMid, .xMidYMid, .xMaxYMid: return .mid
        case .xMinYMax, .xMidYMax, .xMaxYMax: return .max
        case .none: return .min
        }
    }
}

// MARK: - Minimal numeric scanner (no Foundation Scanner dependency)
//
// Small, allocation-light scanner for transform lists. Kept private to this file;
// the real attribute parsers will have their own richer tokenizers.

struct MiniScanner {
    private let chars: [Character]
    private var i: Int = 0

    init(_ s: String) { chars = Array(s) }

    var isAtEnd: Bool { i >= chars.count }

    mutating func skipSeparators() {
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," {
                i += 1
            } else { break }
        }
    }

    mutating func consume(_ c: Character) -> Bool {
        guard i < chars.count, chars[i] == c else { return false }
        i += 1
        return true
    }

    mutating func scanIdentifier() -> String? {
        let start = i
        while i < chars.count, chars[i].isLetter { i += 1 }
        return i > start ? String(chars[start..<i]) : nil
    }

    /// Scan whitespace/comma-separated numbers up to (but not consuming) `end`.
    mutating func scanNumbers(until end: Character) -> [CGFloat] {
        var out: [CGFloat] = []
        while i < chars.count, chars[i] != end {
            skipSeparators()
            if i < chars.count, chars[i] == end { break }
            if let n = scanNumber() { out.append(n) } else { break }
        }
        return out
    }

    mutating func scanNumber() -> CGFloat? {
        let start = i
        if i < chars.count, (chars[i] == "+" || chars[i] == "-") { i += 1 }
        while i < chars.count, chars[i].isNumber { i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        // Exponent
        if i < chars.count, (chars[i] == "e" || chars[i] == "E") {
            i += 1
            if i < chars.count, (chars[i] == "+" || chars[i] == "-") { i += 1 }
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        guard i > start else { return nil }
        return CGFloat(Double(String(chars[start..<i])) ?? 0)
    }
}
