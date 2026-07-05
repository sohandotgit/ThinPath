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

        let familyName = context.document.strings.string(style.fontFamily) ?? "Helvetica"
        let font = makeFont(family: familyName, size: style.fontSize,
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

    private static func makeFont(family: String, size: CGFloat, weight: Int, italic: Bool) -> CTFont {
        let base = CTFontCreateWithName(family as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if weight >= 600 { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        guard !traits.isEmpty,
              let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits)
        else { return base }
        return styled
    }
}
