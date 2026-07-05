//
//  TextRenderer.swift
//  SVGRenderer
//
//  Basic `<text>` via Core Text: a single positioned run at (x,y), honoring
//  font-family/size/weight/style, `text-anchor`, and a solid fill.
//
//  OUT OF SCOPE (see the module's header comment / task spec): multi-run
//  `<tspan>` layout, `dx`/`dy` per-glyph shifts, bidi, and text-on-path. The
//  IR (`SVGModel.Text`) carries only `x`/`y`/`content`, so there is nowhere to
//  hang richer layout without extending the model — flagging rather than
//  guessing at that extension.
//

import CoreGraphics
import CoreText
import Foundation

public enum TextRenderer {

    public static func drawText(_ node: NodeIndex, text: Text, style: ComputedStyle, context: RenderContext) {
        guard style.visibility == .visible else { return }
        guard let content = context.document.strings.string(text.content), !content.isEmpty else { return }

        let color: RGBA
        switch style.fill {
        case .none: return
        case .color(let rgba): color = rgba
        case .currentColor: color = style.color
        case .server: color = .black   // gradient/pattern text fill: out of scope, fall back to black
        }

        let isolate = context.needsIsolationLayer(node, style: style, paintsFillAndStroke: true)
        let opacityConsumedByLayer = isolate && style.mask.isNone
        let alpha = (opacityConsumedByLayer ? 1 : style.groupOpacity) * style.fillOpacity
        guard alpha > 0 else { return }

        // `font-family` is a comma-separated *prioritized list* of family names,
        // possibly quoted (Inkscape emits e.g. `'Liberation Sans'`). Resolution
        // walks the list and is guaranteed to end on the iOS system font, so
        // text is always drawn even when every named family is missing.
        let familyList = context.document.strings.string(style.fontFamily)
        let font = resolveFont(familyList: familyList, size: style.fontSize,
                               weight: style.fontWeight.value, italic: style.fontStyle != .normal)

        let cgColor = CGColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                              blue: CGFloat(color.b) / 255, alpha: CGFloat(color.a) / 255 * alpha)

        // `NSAttributedString.Key.font`/`.foregroundColor` are AppKit/UIKit
        // additions unavailable on a bare Foundation+CoreText build; the raw
        // CoreText attribute name constants work everywhere this package targets.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        var startX = text.x
        switch style.textAnchor {
        case .start: break
        case .middle: startX -= lineWidth / 2
        case .end: startX -= lineWidth
        }

        let cg = context.cg
        cg.saveGState()
        // Core Text draws glyphs assuming a y-up baseline convention; our CTM
        // is y-down (SVG convention) throughout, so flip locally around the
        // text origin before handing off to CTLineDraw.
        cg.translateBy(x: startX, y: text.y)
        cg.scaleBy(x: 1, y: -1)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    /// Resolve a CSS `font-family` list to a concrete, usable `CTFont`.
    ///
    /// Steps, in order:
    ///   1. Split the list on commas — it is a *prioritized* list, tried in order.
    ///   2. Normalize each entry: strip surrounding single/double quotes and
    ///      trim whitespace. A quoted name (e.g. `'Liberation Sans'`) can fail
    ///      `CTFontCreateWithName` resolution even for an installed font, so the
    ///      quotes must go before lookup.
    ///   3. Map the CSS generic keywords (`sans-serif`/`serif`/`monospace`,
    ///      plus `system-ui`) to appropriate iOS system fonts.
    ///   4. For a named family, create the font and *verify* Core Text actually
    ///      resolved to it (it silently substitutes a default for unknown
    ///      names), rejecting substitutions so the list keeps walking.
    ///   5. If nothing resolves, fall back to the iOS system font — guaranteed
    ///      non-nil — so text is ALWAYS drawn.
    ///
    /// `internal` (not `private`) so the resolver can be unit-tested directly.
    static func resolveFont(familyList: String?, size: CGFloat, weight: Int, italic: Bool) -> CTFont {
        if let familyList {
            for rawEntry in familyList.split(separator: ",") {
                let name = normalizeFamily(String(rawEntry))
                guard !name.isEmpty else { continue }

                if let generic = systemFontForGeneric(name, size: size, weight: weight, italic: italic) {
                    return generic
                }

                let candidate = CTFontCreateWithName(name as CFString, size, nil)
                if fontResolved(candidate, to: name) {
                    return applyTraits(candidate, size: size, weight: weight, italic: italic)
                }
            }
        }
        // Guaranteed final fallback: the iOS system font at the requested size
        // and weight. `CTFontCreateUIFontForLanguage(.system, …)` never returns
        // nil, so from here on text is always renderable.
        return systemFont(size: size, weight: weight, italic: italic)
    }

    /// Strip one layer of surrounding matching quotes (single or double) and
    /// trim whitespace, both before and after unquoting.
    private static func normalizeFamily(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let first = s.first, let last = s.last,
           first == last, first == "\"" || first == "'" {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map a CSS generic family keyword to an iOS system font, or `nil` if the
    /// name is not a generic keyword (and should be looked up as a real family).
    private static func systemFontForGeneric(_ name: String, size: CGFloat, weight: Int, italic: Bool) -> CTFont? {
        switch name.lowercased() {
        case "sans-serif", "system-ui", "ui-sans-serif":
            return systemFont(size: size, weight: weight, italic: italic)
        case "serif", "ui-serif":
            return applyTraits(CTFontCreateWithName("Times New Roman" as CFString, size, nil),
                               size: size, weight: weight, italic: italic)
        case "monospace", "ui-monospace":
            return applyTraits(CTFontCreateWithName("Menlo" as CFString, size, nil),
                               size: size, weight: weight, italic: italic)
        default:
            return nil
        }
    }

    /// Whether Core Text resolved `font` to the requested `name` rather than
    /// silently substituting a default. `CTFontCreateWithName` always returns a
    /// font; for an unknown name that font is a fallback whose family/full/
    /// PostScript names won't match the request. Compared case-insensitively
    /// against all three since `font-family` may name any of them.
    private static func fontResolved(_ font: CTFont, to name: String) -> Bool {
        let target = name.lowercased()
        let names = [
            CTFontCopyFamilyName(font) as String,
            CTFontCopyFullName(font) as String,
            CTFontCopyPostScriptName(font) as String,
        ]
        return names.contains { $0.lowercased() == target }
    }

    /// The iOS system font (San Francisco) at `size`, with bold/italic applied.
    private static func systemFont(size: CGFloat, weight: Int, italic: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return applyTraits(base, size: size, weight: weight, italic: italic)
    }

    /// Apply bold (weight ≥ 600) and italic symbolic traits, preserving the
    /// requested `size`. Returns `base` unchanged if no traits apply or if the
    /// styled copy can't be produced (Core Text may lack the styled variant).
    private static func applyTraits(_ base: CTFont, size: CGFloat, weight: Int, italic: Bool) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if weight >= 600 { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        guard !traits.isEmpty,
              let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits)
        else { return base }
        return styled
    }
}
