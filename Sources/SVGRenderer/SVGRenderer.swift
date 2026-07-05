//
//  SVGRenderer.swift
//  SVGRenderer
//
//  The public entry point (`APISurface.swift`'s `SVGRenderer` type) and the
//  concrete `NodeVisitor` (`DefaultVisitor`) that wires `RenderWalk`'s leaf
//  dispatch to this module's leaf renderers. `APISurface.swift` declares the
//  public method signatures as `fatalError` stubs; this file is where they are
//  actually implemented (SwiftPM/Swift does not let two files each provide a
//  body for the same declared method, so those stubs are replaced in place —
//  see `APISurface.swift`'s own edit — with one-line delegations here).
//

import CoreGraphics
import Foundation

// MARK: - DefaultVisitor

/// The one concrete `NodeVisitor` this module ships: containers are pure
/// pass-through (traversal/state already lives in `RenderWalk`/`RenderContext`);
/// each leaf kind delegates to its dedicated renderer file.
struct DefaultVisitor: NodeVisitor {
    mutating func willEnterContainer(_ node: NodeIndex, style: ComputedStyle,
                                     context: RenderContext) -> ChildWalk {
        .children
    }

    mutating func didExitContainer(_ node: NodeIndex, style: ComputedStyle, context: RenderContext) {}

    mutating func drawShape(_ node: NodeIndex, path: CGPath, style: ComputedStyle, context: RenderContext) {
        ShapeRenderer.drawShape(node, path: path, style: style, context: context)
    }

    mutating func drawImage(_ node: NodeIndex, image: Image, style: ComputedStyle, context: RenderContext) {
        ImageRenderer.drawImage(node, image: image, style: style, context: context)
    }

    mutating func drawText(_ node: NodeIndex, text: Text, style: ComputedStyle, context: RenderContext) {
        TextRenderer.drawText(node, text: text, style: style, context: context)
    }
}

// MARK: - Root rendering entry points

enum SVGRootRenderer {

    /// Default decoded-image cache budget for the `size:scale:` convenience
    /// (`ImageDecoder`/`ImageCache`'s memory contract — see CachePolicy.md).
    /// A fresh cache per standalone render keeps the convenience method
    /// self-contained; a caller doing repeated renders of the same document
    /// should prefer driving `render(_:into:rect:)` with a shared `ImageCache`
    /// (not exposed by this provisional API — see APISurface.swift).
    static let defaultImageBudgetBytes = 256 * 1024 * 1024

    static func render(_ document: SVGDocument, into cgContext: CGContext, rect: CGRect, images: ImageCache) {
        guard rect.width > 0, rect.height > 0, !document.root.isNone else { return }

        cgContext.saveGState()
        cgContext.translateBy(x: rect.origin.x, y: rect.origin.y)

        let context = RenderContext(cg: cgContext, document: document,
                                    dirtyRect: CGRect(origin: .zero, size: rect.size),
                                    images: images)
        var walk = RenderWalk(visitor: DefaultVisitor(), context: context)
        walk.run()

        cgContext.restoreGState()
    }

    static func render(_ document: SVGDocument, size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGBitmapContext's default CTM is identity: user space (0,0) is the
        // BOTTOM-left pixel, y-up. SVG user space is y-down, origin top-left
        // (CoordinateNotes.md §1 defers exactly this flip to render time).
        // Scale to device pixels, then flip: translate down by the (point-
        // space) height and mirror y, so subsequent SVG-space y-down drawing
        // lands right-side-up in the pixel buffer.
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)

        let images = ImageCache(budgetBytes: defaultImageBudgetBytes)
        render(document, into: cg, rect: CGRect(origin: .zero, size: size), images: images)

        return cg.makeImage()
    }
}
