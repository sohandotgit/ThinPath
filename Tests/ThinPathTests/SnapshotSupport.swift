//
//  SnapshotSupport.swift
//  ThinPathTests
//
//  Test-only utility for the two RenderTests.swift tiers:
//
//    1. Spot-pixel assertions (`assertPixel`) — read one pixel out of a
//       rendered `CGImage` and compare it exactly (within a small tolerance
//       for rounding) against a hand-computed expected color. Used for cases
//       simple enough to reason about by hand: flat fills, clip boundaries,
//       fill-rule parity, etc.
//
//    2. Golden PNG comparisons (`assertMatchesGolden`) — compare a rendered
//       `CGImage` against a reference PNG checked into
//       `SampleSVGs/references/`, loaded via `Bundle.module`, allowing a
//       per-pixel tolerance to absorb anti-aliasing differences between this
//       renderer and whatever independent oracle produced the reference (see
//       GoldenWorkflow.md).
//
//  Neither path renders anything itself — both take an already-rendered
//  `CGImage` (or produce one from a sample SVG name) and inspect pixels.
//

import CoreGraphics
import Foundation
import ImageIO
import XCTest

// MARK: - Pixel representation

/// Straightforward 8-bit-per-channel RGBA, matching `RGBA` in SVGModel but
/// kept separate since this is test-only decode/compare code, not IR.
public struct Pixel: Equatable, CustomStringConvertible {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public var description: String {
        String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    /// Per-channel max absolute difference. Used for both the spot-pixel
    /// tolerance and the golden per-pixel tolerance.
    func maxChannelDelta(from other: Pixel) -> Int {
        max(abs(Int(r) - Int(other.r)),
            abs(Int(g) - Int(other.g)),
            abs(Int(b) - Int(other.b)),
            abs(Int(a) - Int(other.a)))
    }
}

// MARK: - Decoding a CGImage to raw pixels

public enum SnapshotSupport {

    /// Decode `image` into a dense RGBA8 buffer (premultiplied-last), plus its
    /// pixel dimensions. All rendered test images in this suite are drawn over
    /// an opaque canvas (every sample SVG paints a full-bounds background
    /// rect), so premultiplied vs. straight alpha never differ in practice —
    /// tests that care about partial alpha assert on a composited-to-opaque
    /// result, never a translucent output pixel.
    public static func rgbaBuffer(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("SnapshotSupport: could not create decode context for \(width)x\(height) image")
            return (bytes, width, height)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    /// Read a single pixel at `(x, y)` in **top-left-origin, integer pixel**
    /// coordinates (matching how the SVG's own coordinate system and the
    /// sample corpus's doc comments describe sample points) — NOT Core
    /// Graphics's bottom-left device space. Callers do not need to flip `y`.
    public static func pixel(in image: CGImage, x: Int, y: Int) -> Pixel {
        let (bytes, width, height) = rgbaBuffer(image)
        precondition(x >= 0 && x < width && y >= 0 && y < height,
                     "pixel (\(x),\(y)) out of bounds for \(width)x\(height) image")
        let i = (y * width + x) * 4
        return Pixel(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    // MARK: - Spot-pixel assertion (Tier 1: EXACT)

    /// Assert the pixel at `(x, y)` equals `expected`, within `tolerance` per
    /// channel (default 0 — exact). A small nonzero tolerance is appropriate
    /// only for values derived from a rounded floating-point blend (e.g.
    /// opacity compositing landing on a `.5` boundary); pure solid-color fills
    /// sampled away from any edge should always use tolerance 0.
    public static func assertPixel(
        _ image: CGImage, x: Int, y: Int, equals expected: Pixel,
        tolerance: UInt8 = 0,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = pixel(in: image, x: x, y: y)
        let delta = actual.maxChannelDelta(from: expected)
        XCTAssertLessThanOrEqual(
            delta, Int(tolerance),
            "pixel (\(x),\(y)) was \(actual), expected \(expected) "
            + "(tolerance \(tolerance)). \(message())",
            file: file, line: line
        )
    }

    // MARK: - Sample SVG / reference PNG loading (Bundle.module)

    /// Load a sample SVG's raw bytes by its corpus-relative name, e.g.
    /// `"shapes/flat_rect"` (no `.svg` extension) for
    /// `SampleSVGs/shapes/flat_rect.svg`.
    public static func loadSampleSVG(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) -> Data {
        let (subdirectory, filename) = splitCorpusName(name)
        guard let url = Bundle.module.url(
            forResource: filename, withExtension: "svg",
            subdirectory: "SampleSVGs" + (subdirectory.map { "/\($0)" } ?? "")
        ) else {
            XCTFail("missing sample SVG '\(name).svg' in SampleSVGs/", file: file, line: line)
            return Data()
        }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// Load a reference PNG by name (no extension) from
    /// `SampleSVGs/references/`. Returns `nil` (with an `XCTFail`, not a
    /// crash) if the golden hasn't been generated yet — see
    /// GoldenWorkflow.md and `references/MANIFEST.md` for the full list of
    /// filenames this suite expects.
    public static func loadReferencePNG(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) -> CGImage? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "png", subdirectory: "SampleSVGs/references"
        ) else {
            XCTFail(
                "missing reference PNG 'references/\(name).png' — generate it per "
                + "GoldenWorkflow.md (see references/MANIFEST.md for the full list)",
                file: file, line: line
            )
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("could not decode reference PNG at \(url.path)", file: file, line: line)
            return nil
        }
        return image
    }

    private static func splitCorpusName(_ name: String) -> (subdirectory: String?, filename: String) {
        guard let slash = name.lastIndex(of: "/") else { return (nil, name) }
        return (String(name[name.startIndex..<slash]), String(name[name.index(after: slash)...]))
    }

    // MARK: - Golden comparison (Tier 2: GOLDEN)

    /// Compare `image` against the reference PNG `referenceName` (see
    /// `loadReferencePNG`). Two tolerances absorb cross-renderer
    /// anti-aliasing differences (GoldenWorkflow.md):
    ///
    ///   - `perPixelTolerance`: max per-channel delta (0...255) for a pixel to
    ///     count as "matching".
    ///   - `maxDivergentFraction`: the fraction of pixels allowed to exceed
    ///     `perPixelTolerance` before the whole comparison fails (AA edges are
    ///     a thin perimeter of a shape, not the bulk of the image).
    ///
    /// On failure, reports the divergent-pixel count/fraction and the first
    /// divergent pixel's coordinates + actual/expected colors to make triage
    /// tractable without opening an image diff tool.
    public static func assertMatchesGolden(
        _ image: CGImage, referenceName: String,
        perPixelTolerance: UInt8 = 10,
        maxDivergentFraction: Double = 0.02,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let reference = loadReferencePNG(referenceName, file: file, line: line) else {
            return // already XCTFail'd
        }
        guard image.width == reference.width, image.height == reference.height else {
            XCTFail(
                "size mismatch vs reference '\(referenceName)': rendered "
                + "\(image.width)x\(image.height), reference "
                + "\(reference.width)x\(reference.height)",
                file: file, line: line
            )
            return
        }

        let (actualBytes, width, height) = rgbaBuffer(image)
        let (expectedBytes, _, _) = rgbaBuffer(reference)

        var divergentCount = 0
        var firstDivergence: (x: Int, y: Int, actual: Pixel, expected: Pixel)?

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let actual = Pixel(actualBytes[i], actualBytes[i + 1], actualBytes[i + 2], actualBytes[i + 3])
                let expected = Pixel(expectedBytes[i], expectedBytes[i + 1], expectedBytes[i + 2], expectedBytes[i + 3])
                if actual.maxChannelDelta(from: expected) > Int(perPixelTolerance) {
                    divergentCount += 1
                    if firstDivergence == nil {
                        firstDivergence = (x, y, actual, expected)
                    }
                }
            }
        }

        let fraction = Double(divergentCount) / Double(width * height)
        if fraction > maxDivergentFraction, let first = firstDivergence {
            XCTFail(
                "golden mismatch vs '\(referenceName)': \(divergentCount)/\(width * height) "
                + "pixels (\(String(format: "%.2f%%", fraction * 100))) exceeded per-pixel "
                + "tolerance \(perPixelTolerance) (allowed \(String(format: "%.2f%%", maxDivergentFraction * 100))). "
                + "First divergence at (\(first.x),\(first.y)): actual \(first.actual), "
                + "expected \(first.expected).",
                file: file, line: line
            )
        }
    }
}
