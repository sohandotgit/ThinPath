//
//  ImageRenderer.swift
//  ThinPath
//
//  Draws `<image>` via `ImageDecoder` + `ImageCache` at the CURRENT transform's
//  target pixel size (`RenderContext.targetPixelSize(for:)`) — never a full-res
//  decode (ImageDecoder.swift's hard rule). Fits the decoded bitmap's intrinsic
//  size into the element's destination rect per `preserveAspectRatio`, reusing
//  `ViewportMath` (an image behaves like a one-shot viewport: intrinsic
//  pixel size ↔ viewBox, destination rect ↔ viewport).
//

import CoreGraphics
import Foundation

public enum ImageRenderer {

    public static func drawImage(_ node: NodeIndex, image: Image, style: ComputedStyle, context: RenderContext) {
        guard style.visibility == .visible else { return }
        guard image.width > 0, image.height > 0 else { return }

        let targetPixelSize = context.targetPixelSize(for: image)
        let decoder = ImageDecoder()
        guard let cgImage = decoder.decodedImage(
            href: image.href, pool: context.document.strings,
            targetPixelSize: targetPixelSize, cache: context.images
        ) else { return }

        let destRect = CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
        let intrinsic = ViewBox(minX: 0, minY: 0,
                               width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let fitTransform = ViewportMath.viewportTransform(viewBox: intrinsic, viewport: destRect,
                                                          par: image.preserveAspectRatio)

        // Isolation mirrors ShapeRenderer's fold rule: images always paint a
        // single contribution, so `needsIsolationLayer` isolates for ANY
        // group opacity < 1 (see RenderContext dispatch's conservative
        // `paintsFillAndStroke` for image/text). When it does (and no mask),
        // the layer itself applies `groupOpacity` — fold only when it doesn't.
        let isolate = context.needsIsolationLayer(node, style: style, paintsFillAndStroke: true)
        let opacityConsumedByLayer = isolate && style.mask.isNone
        let alpha = opacityConsumedByLayer ? 1 : style.groupOpacity
        guard alpha > 0 else { return }

        // Resample to the EXACT on-screen device pixel size ourselves with a
        // textbook (half-pixel-center, clamp-to-edge) bilinear filter, rather
        // than relying on `CGContext`'s built-in resampler: CG's own filter
        // curve is an implementation detail with no documented standard
        // definition, so cross-renderer agreement on a heavily-magnified
        // raster (a common case for small embedded icons) is otherwise
        // unpredictable. The final draw is then a lossless 1:1 copy.
        let fitRectDevice = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            .applying(fitTransform)
            .applying(context.current.userToDevice)
        let targetPixelW = max(1, Int(fitRectDevice.width.rounded()))
        let targetPixelH = max(1, Int(fitRectDevice.height.rounded()))

        // MEMORY GUARD (ImageDecodeNotes.md §3b): the resample output is an
        // offscreen buffer sized from `fitRectDevice`, and nothing upstream
        // guarantees that rect is sane — it composes every ancestor transform,
        // including pattern/use spaces. Only materialize device pixels that
        // can actually land in the region this pass produces (clip ∩ dirty,
        // padded a pixel for rounding). Past that bound — a heavily clipped
        // draw, or an upstream coordinate-space bug — skip the custom
        // resampler and let CG sample the decoded image through the clip at
        // draw time, which is bounded by the render target no matter what the
        // CTM claims.
        let visibleDevice = context.current.clipDeviceBounds.isNull
            ? context.dirtyRect
            : context.current.clipDeviceBounds.intersection(context.dirtyRect)
        let resampleIsBounded = Self.fitsVisibleDeviceBounds(fitRectDevice: fitRectDevice,
                                                             visibleDevice: visibleDevice)
        let drawImage = resampleIsBounded
            ? (bilinearResample(cgImage, toPixelWidth: targetPixelW, targetPixelHeight: targetPixelH)
               ?? cgImage)
            : cgImage

        let cg = context.cg
        cg.saveGState()
        cg.clip(to: destRect)
        cg.concatenate(fitTransform)
        cg.setAlpha(alpha)
        // Resampled: the draw is a 1:1 device-pixel copy, so interpolation is
        // off. Fallback: CG is the resampler, so it must interpolate.
        cg.interpolationQuality = resampleIsBounded ? .none : .low
        // `CGContext.draw(_:in:)` places image row 0 at the rect's MAXIMUM y in
        // the current user space — correct in a y-up space, but our CTM is
        // y-down (SVG convention) throughout, so left uncorrected the image
        // renders vertically flipped. Flip locally around the intrinsic
        // height first, exactly like TextRenderer does around the baseline.
        cg.translateBy(x: 0, y: CGFloat(cgImage.height))
        cg.scaleBy(x: 1, y: -1)
        cg.draw(drawImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        cg.restoreGState()
    }

    /// The resample-buffer bound: `fitRectDevice` must lie inside the visible
    /// device region (±1 px rounding slack) before a buffer of its size may be
    /// allocated. Degenerate inputs (null/infinite/NaN rects, from a broken
    /// CTM) fail the containment test and thus take the bounded CG-draw path —
    /// the safe direction.
    static func fitsVisibleDeviceBounds(fitRectDevice: CGRect, visibleDevice: CGRect) -> Bool {
        guard !visibleDevice.isNull, !fitRectDevice.isNull else { return false }
        return visibleDevice.insetBy(dx: -1, dy: -1).contains(fitRectDevice)
    }

    // MARK: - Bilinear resample (half-pixel-center, clamp-to-edge)

    private static func bilinearResample(_ image: CGImage, toPixelWidth targetW: Int,
                                         targetPixelHeight targetH: Int) -> CGImage? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0, targetW > 0, targetH > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let srcCtx = CGContext(
            data: nil, width: srcW, height: srcH, bitsPerComponent: 8, bytesPerRow: srcW * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        srcCtx.interpolationQuality = .none
        srcCtx.draw(image, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        guard let srcData = srcCtx.data else { return nil }
        let srcStride = srcCtx.bytesPerRow
        let srcPtr = srcData.bindMemory(to: UInt8.self, capacity: srcStride * srcH)

        @inline(__always) func sample(_ x: Int, _ y: Int, _ c: Int) -> CGFloat {
            let cx = min(max(x, 0), srcW - 1)
            let cy = min(max(y, 0), srcH - 1)
            return CGFloat(srcPtr[cy * srcStride + cx * 4 + c])
        }

        var out = [UInt8](repeating: 0, count: targetW * targetH * 4)
        let scaleX = CGFloat(srcW) / CGFloat(targetW)
        let scaleY = CGFloat(srcH) / CGFloat(targetH)

        for oy in 0..<targetH {
            let sy = (CGFloat(oy) + 0.5) * scaleY - 0.5
            let y0 = Int(sy.rounded(.down))
            let fy = sy - CGFloat(y0)
            for ox in 0..<targetW {
                let sx = (CGFloat(ox) + 0.5) * scaleX - 0.5
                let x0 = Int(sx.rounded(.down))
                let fx = sx - CGFloat(x0)
                let outIdx = (oy * targetW + ox) * 4
                for c in 0..<4 {
                    let v00 = sample(x0, y0, c), v10 = sample(x0 + 1, y0, c)
                    let v01 = sample(x0, y0 + 1, c), v11 = sample(x0 + 1, y0 + 1, c)
                    let top = v00 + (v10 - v00) * fx
                    let bottom = v01 + (v11 - v01) * fx
                    let value = top + (bottom - top) * fy
                    out[outIdx + c] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(
            width: targetW, height: targetH, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: targetW * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
