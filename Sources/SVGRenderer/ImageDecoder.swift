//
//  ImageDecoder.swift
//  SVGRenderer
//
//  The memory-critical decode path for `<image>` elements. The IR stores only an
//  href (SVGModel.swift); this file turns that href into a `CGImage` at the
//  SMALLEST resolution sufficient for the target draw size (in device pixels),
//  via ImageIO's thumbnail API — the full-resolution `CGImage` is NEVER created.
//  One accidental full-res decode of a large photo (a 12 MP JPEG is ~48 MB
//  decoded) would blow the entire project memory budget on its own.
//
//  THE RULE: the only function in this codebase that may materialize image
//  pixels is `CGImageSourceCreateThumbnailAtIndex`, and it is always called with
//  an explicit `kCGImageSourceThumbnailMaxPixelSize`. `CGImageSourceCreateImageAtIndex`
//  must never appear here or anywhere else.
//
//  Results flow through `ImageCache` (keyed by href + target pixel size) so
//  repeated draws don't re-decode; every byte of source parsing — base64
//  decode of data: URIs included — happens inside the cache-miss closure, so a
//  cache hit allocates nothing.
//
//  See Design/ImageDecodeNotes.md for the flag-by-flag rationale, the exact
//  target-size → max-pixel-size relationship, and the PROFILE-CHECK items.
//

import CoreGraphics
import Foundation
import ImageIO

// MARK: - ImageDecoder

/// Stateless decode policy: href → smallest-sufficient `CGImage`, through the
/// cache. A value type configured only with the base URL for resolving relative
/// external hrefs (typically the SVG document's own location).
public struct ImageDecoder {

    /// Base for resolving relative external hrefs (`href="assets/photo.png"`).
    /// `nil` means relative references cannot be resolved and decode to `nil`
    /// (rendered as nothing — SVG's behaviour for a broken image reference).
    public var baseURL: URL?

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    // MARK: Entry point

    /// Fetch the decoded image for `href` at `targetPixelSize` (DEVICE pixels —
    /// the caller derives this from the element rect × current CTM, which
    /// already folds in the screen scale; see `RenderContext.targetPixelSize(for:)`).
    ///
    /// Cache-hit path: one dictionary lookup, zero allocation, zero href parsing.
    /// Cache-miss path: parse the href, open a `CGImageSource`, decode a
    /// thumbnail no larger than needed, admit it to the cache (which computes
    /// cost from the ACTUAL decoded dimensions, so cost accounting is honest
    /// even where the decode was clamped to the source's native size).
    ///
    /// Returns `nil` on any failure — unparseable href, unsupported scheme,
    /// missing file, corrupt data, degenerate target size. Never traps: a broken
    /// `<image>` renders as nothing, per SVG.
    public func decodedImage(href: StringRef,
                             pool: StringPool,
                             targetPixelSize: CGSize,
                             cache: ImageCache) -> CGImage? {
        guard targetPixelSize.width.isFinite, targetPixelSize.height.isFinite,
              targetPixelSize.width >= 1, targetPixelSize.height >= 1,
              let hrefString = pool.string(href), !hrefString.isEmpty
        else { return nil }

        // Key on the ceil'd REQUESTED size, not the (possibly native-clamped)
        // decoded size: computing the clamp needs the source header, and for a
        // data: URI that would mean base64-decoding on every lookup, hit or
        // miss. Keeping the key request-derived keeps the hit path free.
        // Consequence (bounded, documented in ImageDecodeNotes.md §3): two
        // different super-native target sizes make two native-res entries.
        let pixelWidth = Int(targetPixelSize.width.rounded(.up))
        let pixelHeight = Int(targetPixelSize.height.rounded(.up))
        let key = ImageCache.Key(href: href,
                                 pixelWidth: pixelWidth,
                                 pixelHeight: pixelHeight)

        return cache.image(for: key) {
            Self.decode(hrefString: hrefString,
                        targetPixelWidth: pixelWidth,
                        targetPixelHeight: pixelHeight,
                        baseURL: baseURL)
        }
    }

    // MARK: Miss-path decode

    private static func decode(hrefString: String,
                               targetPixelWidth: Int,
                               targetPixelHeight: Int,
                               baseURL: URL?) -> CGImage? {
        guard let source = makeImageSource(hrefString: hrefString, baseURL: baseURL)
        else { return nil }
        // `source` (and, for data: URIs, the compressed bytes it retains) lives
        // only to the end of this function; the returned CGImage owns its own
        // pixel buffer and keeps nothing else alive.
        return thumbnail(from: source,
                         targetPixelWidth: targetPixelWidth,
                         targetPixelHeight: targetPixelHeight)
    }

    /// Options for CREATING a source: `kCGImageSourceShouldCache: false` tells
    /// ImageIO not to keep its own decoded-frame cache for this source. We own
    /// caching in `ImageCache`; letting ImageIO cache too would double the
    /// resident cost of every image invisibly.
    private static let sourceOptions =
        [kCGImageSourceShouldCache: false] as CFDictionary

    private static func makeImageSource(hrefString: String,
                                        baseURL: URL?) -> CGImageSource? {
        if hasDataURIPrefix(hrefString) {
            // The compressed bytes are copied out of the base64 text here; the
            // transient encoded buffers die at the end of this `guard` scope
            // (ImageDecodeNotes.md §4). Only `payload` survives, retained by
            // the source.
            guard let payload = dataURIPayload(hrefString) else { return nil }
            return CGImageSourceCreateWithData(payload as CFData, sourceOptions)
        }
        guard let url = externalURL(for: hrefString, baseURL: baseURL) else { return nil }
        // Create from URL, not from `Data(contentsOf:)`: ImageIO opens/maps the
        // file itself and reads only what the header probe + subsampled decode
        // need, instead of us slurping the whole file into a Data first.
        return CGImageSourceCreateWithURL(url as CFURL, sourceOptions)
    }

    // MARK: Thumbnail decode (the only pixel-materializing call)

    private static func thumbnail(from source: CGImageSource,
                                  targetPixelWidth: Int,
                                  targetPixelHeight: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }

        let maxPixelSize = thumbnailMaxPixelSize(source: source,
                                                 targetPixelWidth: targetPixelWidth,
                                                 targetPixelHeight: targetPixelHeight)

        // Flag rationale is spelled out in ImageDecodeNotes.md §2; the short
        // version of each:
        let options: [CFString: Any] = [
            // Always GENERATE from the image data at our size — never return an
            // embedded (EXIF/JFIF) thumbnail, whose size and quality we don't
            // control. Required for MaxPixelSize to be authoritative.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Decode NOW, on this call, into the returned image's buffer —
            // don't hand back a lazy image that decodes at first draw (which
            // would also make the cache admit a cost before the bytes exist).
            kCGImageSourceShouldCacheImmediately: true,
            // Bake EXIF orientation into the pixels so width/height match what
            // is drawn and no rotated full-dimension intermediate is needed.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // The clamp that makes this the smallest sufficient decode.
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        // Multi-frame sources (animated GIF/APNG): frame 0, per SVG static
        // rendering of animated rasters.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The exact target-size → max-pixel-size relationship (ImageDecodeNotes.md §3).
    ///
    /// `kCGImageSourceThumbnailMaxPixelSize` bounds the LONGER side of the
    /// output. The smallest decode that still covers the target on BOTH axes is
    /// found from the source's native dimensions (a header-only read — no
    /// pixels are decoded to answer this):
    ///
    ///     scale        = max(targetW / nativeW, targetH / nativeH)
    ///     maxPixelSize = ceil(max(nativeW, nativeH) × min(scale, 1))
    ///
    /// `min(scale, 1)` clamps at native resolution: when the target exceeds the
    /// source we decode native-size pixels and let Core Graphics upscale at
    /// draw time — decoding "larger than the source" buys nothing and costs
    /// real memory.
    private static func thumbnailMaxPixelSize(source: CGImageSource,
                                              targetPixelWidth: Int,
                                              targetPixelHeight: Int) -> Int {
        let header = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
            as? [CFString: Any]
        guard var nativeW = (header?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var nativeH = (header?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              nativeW > 0, nativeH > 0
        else {
            // Header unreadable: fall back to bounding the longer side by the
            // longer target side. Sufficient for matching aspect ratios and
            // still never requests more than the target's longer axis.
            return max(targetPixelWidth, targetPixelHeight)
        }

        // EXIF orientations 5–8 transpose the drawn image; since we decode with
        // CreateThumbnailWithTransform, compare the target against the
        // POST-transform dimensions.
        if let orientation = (header?[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
           orientation >= 5 {
            swap(&nativeW, &nativeH)
        }

        let scale = max(Double(targetPixelWidth) / Double(nativeW),
                        Double(targetPixelHeight) / Double(nativeH))
        let longSide = max(nativeW, nativeH)
        guard scale < 1 else { return longSide }   // never upscale past native
        return Int((Double(longSide) * scale).rounded(.up))
    }

    // MARK: data: URI handling

    private static func hasDataURIPrefix(_ href: String) -> Bool {
        // Scheme is case-insensitive per RFC 2397.
        href.count > 5 && href.prefix(5).lowercased() == "data:"
    }

    /// Extract the binary payload of a `data:` URI:
    /// `data:[<mediatype>][;base64],<payload>`. Returns the COMPRESSED image
    /// bytes (PNG/JPEG/…), not decoded pixels. The media type is ignored —
    /// ImageIO sniffs the container from the bytes, which is more reliable than
    /// authored MIME types.
    private static func dataURIPayload(_ href: String) -> Data? {
        guard let comma = href.firstIndex(of: ",") else { return nil }
        let meta = href[href.index(href.startIndex, offsetBy: 5) ..< comma]
        let payload = href[href.index(after: comma)...]

        if meta.lowercased().hasSuffix(";base64") {
            // Substring → Data avoids an intermediate String copy of the
            // (potentially large) base64 text. `.ignoreUnknownCharacters`
            // tolerates the whitespace/newlines that pretty-printed SVG wraps
            // base64 with. The encoded byte buffer is transient — released
            // when this function returns.
            let encoded = Data(payload.utf8)
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        }
        // Non-base64 data URIs are percent-encoded text (rare for rasters).
        return String(payload).removingPercentEncoding.flatMap { $0.data(using: .utf8) }
    }

    // MARK: External href resolution

    /// Resolve an external href to a LOCAL file URL, or `nil`.
    ///
    /// Network schemes (`http:`/`https:`) are refused by design: this is the
    /// synchronous render path and must never block on I/O slower than a local
    /// read. Remote images belong to a future async prefetch stage that
    /// downloads into a local cache this decoder then reads.
    private static func externalURL(for href: String, baseURL: URL?) -> URL? {
        if let url = URL(string: href), let scheme = url.scheme {
            return scheme.lowercased() == "file" ? url.absoluteURL : nil
        }
        // Scheme-less: a filesystem path (URL(string:) also fails on unencoded
        // spaces, which fileURLWithPath handles).
        if href.hasPrefix("/") {
            return URL(fileURLWithPath: href)
        }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: href, relativeTo: baseURL).absoluteURL
    }
}

// MARK: - RenderContext → target pixel size

extension RenderContext {

    /// The device-pixel size an `<image>` element's destination rect occupies
    /// under the CURRENT transform — the correct `targetPixelSize` for
    /// `ImageDecoder.decodedImage`. `userToDevice` already composes every
    /// ancestor transform with the screen scale the caller seeded the context
    /// with, so zooming in raises the target (sharper decode) and zooming out
    /// lowers it (smaller decode) with no separate scale bookkeeping.
    ///
    /// Under rotation/skew this is the transformed rect's axis-aligned bounding
    /// box — a conservative OVER-estimate, which errs on the side of sharpness,
    /// never blur (and is bounded by the source's native size at decode time).
    public func targetPixelSize(for image: Image) -> CGSize {
        let deviceRect = CGRect(x: image.x, y: image.y,
                                width: image.width, height: image.height)
            .applying(current.userToDevice)
        return deviceRect.size
    }
}
