//
//  MaskRenderer.swift
//  SVGRenderer
//
//  Builds a `<mask>`'s luminance/alpha as a single-channel `CGImage`, clamped to
//  EXACTLY the masked element's clamped isolation-layer bounds (Compositing.md
//  §6 PROFILE-CHECK mask-scratch) — never the canvas. `RenderWalk.render`
//  multiplies the still-open transparency layer by this image (blend mode
//  `.destinationIn`) before compositing, per RenderPipeline.md §"Mask multiply".
//
//  Luminance coefficients: standard Rec. 601-ish sRGB luma weights
//  (0.2125/0.7154/0.0721) applied directly to PREMULTIPLIED channel bytes — for
//  premultiplied RGBA, `0.2125·R' + 0.7154·G' + 0.0721·B'` already equals
//  `luminance × alpha` (since `R' = R × alpha`), which is exactly the SVG mask
//  value, with no separate unpremultiply/multiply step.
//  ⚠️ PROFILE-CHECK (mask-color-space): pin these coefficients + sRGB (not
//  linear-light) interpolation against a reference renderer if a golden case
//  ever shows a systematic (non-edge-band) divergence.
//

import CoreGraphics
import Foundation

public enum MaskRenderer {

    /// Render `maskNode`'s children to an offscreen bitmap clamped to
    /// `deviceBounds` (device pixels, already the masked element's clamped
    /// layer bounds) and convert to a single-channel (alpha-only) luminance
    /// image. `objectBounds` is the MASKED element's own geometry bbox, used
    /// only when `maskContentUnits="objectBoundingBox"`.
    public static func buildAlphaMaskImage(maskNode: NodeIndex, context: RenderContext,
                                           deviceBounds: CGRect, objectBounds: CGRect) -> CGImage? {
        guard case .mask(let mask) = context.document.node(maskNode).kind else { return nil }

        let pixelBounds = deviceBounds.integral
        let width = max(1, Int(pixelBounds.width))
        let height = max(1, Int(pixelBounds.height))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let scratch = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Mask content is authored in the SAME user space as the masked
        // element; shift device space so `pixelBounds.origin` lands at the
        // scratch bitmap's (0,0), then reapply the masked element's own
        // device transform so content lines up pixel-for-pixel.
        scratch.translateBy(x: -pixelBounds.minX, y: -pixelBounds.minY)
        scratch.concatenate(context.current.userToDevice)

        var contentMatrix = CGAffineTransform.identity
        if mask.maskContentUnits == .objectBoundingBox, let m = ObjectBoundingBox.transform(objectBounds) {
            contentMatrix = m
        }

        let maskContext = RenderContext(
            cg: scratch, document: context.document,
            dirtyRect: CGRect(origin: .zero, size: CGSize(width: width, height: height)),
            images: context.images
        )
        maskContext.concatenate(contentMatrix)

        var walk = RenderWalk(visitor: DefaultVisitor(), context: maskContext)
        context.document.forEachChild(of: maskNode) { child in
            walk.render(child, inheriting: .initial)
        }

        guard let rgba = scratch.data else { return nil }
        let bytesPerRow = scratch.bytesPerRow
        let ptr = rgba.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        // A normal (not alpha-only) premultiplied RGBA buffer, colors zeroed —
        // `.destinationIn` only reads the source alpha channel, and pairing
        // `kCGImageAlphaOnly` with a real color space is not a valid CGImage
        // bitmap-info combination.
        var maskBytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let rowBase = y * bytesPerRow
            let outRowBase = y * width * 4
            for x in 0..<width {
                let i = rowBase + x * 4
                let lum = 0.2125 * CGFloat(ptr[i]) + 0.7154 * CGFloat(ptr[i + 1]) + 0.0721 * CGFloat(ptr[i + 2])
                maskBytes[outRowBase + x * 4 + 3] = UInt8(max(0, min(255, lum.rounded())))
            }
        }

        guard let provider = CGDataProvider(data: Data(maskBytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
