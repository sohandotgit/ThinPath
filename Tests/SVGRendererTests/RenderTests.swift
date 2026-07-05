//
//  RenderTests.swift
//  SVGRendererTests
//
//  Frozen spec for the rendering thread (`SVGRenderer.render`, APISurface.swift).
//  Every case below renders a sample SVG (SampleSVGs/) at a fixed pixel size and
//  scale — chosen to match that document's own viewBox 1:1 so the hand-derived
//  spot-pixel coordinates in each .svg's header comment line up exactly with
//  device pixels — and asserts on the result.
//
//  Two tiers:
//
//    - EXACT (`assert...` helpers reading a single pixel): cases simple enough
//      to hand-compute — flat fills, clip boundaries, fill-rule parity, use/
//      symbol instancing offsets, opacity blending, currentColor resolution.
//      Sample points are chosen at least several pixels from any edge so
//      anti-aliasing policy cannot affect the result.
//
//    - GOLDEN (`assertMatchesGolden`): composited cases (gradients, patterns,
//      masks, text, images) compared against a reference PNG in
//      SampleSVGs/references/ with a per-pixel tolerance. See
//      GoldenWorkflow.md for how those PNGs are produced and why an
//      independent oracle plus tolerance — not pixel-exact equality — is the
//      right bar for these.
//
//  `SVGRenderer.render` is currently `fatalError("unimplemented")`
//  (APISurface.swift). That means running this file today does not print a
//  clean list of per-test failures — the FIRST case XCTest reaches aborts the
//  whole process. That crash *is* this file's RED signal: every test below is
//  written as if `render` worked, so once the rendering thread lands a real
//  implementation, each case starts passing/failing independently and this
//  file stops crashing. Do not add crash-catching machinery here; a fatalError
//  reaching this file is expected and correct until rendering exists.
//

import XCTest
import CoreGraphics
@testable import SVGRenderer

final class RenderTests: XCTestCase {

    // MARK: - Helper

    /// Parse and render a sample SVG (by corpus-relative name, e.g.
    /// `"shapes/flat_rect"`) at the given fixed pixel size and scale.
    private func render(
        _ sampleName: String, width: Int, height: Int, scale: CGFloat = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) -> CGImage {
        let data = SnapshotSupport.loadSampleSVG(sampleName, file: file, line: line)
        let (document, errors) = parse(data: data)
        XCTAssertTrue(errors.isEmpty, "parse errors for \(sampleName): \(errors)", file: file, line: line)
        guard let image = SVGRenderer().render(
            document, size: CGSize(width: width, height: height), scale: scale
        ) else {
            XCTFail("render(...) returned nil for \(sampleName)", file: file, line: line)
            return CGImage.zeroPixelPlaceholder
        }
        XCTAssertEqual(image.width, width * Int(scale), file: file, line: line)
        XCTAssertEqual(image.height, height * Int(scale), file: file, line: line)
        return image
    }

    private func white(_ a: UInt8 = 255) -> Pixel { Pixel(255, 255, 255, a) }

    // MARK: - Tier 1: EXACT — flat shapes

    func testFlatRectFillsExactRegion() {
        let image = render("shapes/flat_rect", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 40, y: 40, equals: Pixel(0xFF, 0x00, 0x00))
        SnapshotSupport.assertPixel(image, x: 10, y: 10, equals: white())
        SnapshotSupport.assertPixel(image, x: 90, y: 90, equals: white())
    }

    func testFlatCircleFillsExactRegion() {
        let image = render("shapes/flat_circle", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x00, 0x00, 0xFF))
        SnapshotSupport.assertPixel(image, x: 5, y: 5, equals: white())
    }

    // MARK: - Tier 1: EXACT — fill-rule parity flips a known interior pixel

    func testFillRuleNonZeroFillsInnerRegion() {
        let image = render("shapes/fill_rule_nonzero", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x00, 0x00, 0x00))
    }

    func testFillRuleEvenOddLeavesInnerRegionAsHole() {
        let image = render("shapes/fill_rule_evenodd", width: 100, height: 100)
        // Same coordinate as testFillRuleNonZeroFillsInnerRegion, opposite result.
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: white())
        SnapshotSupport.assertPixel(image, x: 20, y: 20, equals: Pixel(0x00, 0x00, 0x00))
    }

    // MARK: - Tier 1: EXACT — stroke vs. fill

    func testStrokeOnlyRectPaintsBandNotInterior() {
        let image = render("shapes/stroke_only_rect", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 40, y: 40, equals: white(), "fill=\"none\" must leave the interior untouched")
        SnapshotSupport.assertPixel(image, x: 20, y: 40, equals: Pixel(0xFF, 0x00, 0x00), "stroke band must be painted")
    }

    // MARK: - Tier 1: EXACT — opacity compositing (closed-form blend)

    func testGroupOpacityBlendsAgainstBackground() {
        let image = render("shapes/opacity_over_white", width: 100, height: 100)
        // src-over: R=255*.5+255*.5=255, G=B=0*.5+255*.5=127.5 -> allow rounding.
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(255, 127, 127, 255), tolerance: 1)
    }

    // MARK: - Tier 1: EXACT — currentColor resolution

    func testCurrentColorResolvesInheritedColorProperty() {
        let image = render("shapes/currentcolor_rect", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x00, 0xFF, 0x00))
    }

    // MARK: - Tier 1: EXACT — viewBox scaling

    func testViewBoxScalesUserSpaceToDevicePixels() {
        let image = render("shapes/viewbox_scale_rect", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 40, y: 40, equals: Pixel(0x00, 0x00, 0xFF))
        SnapshotSupport.assertPixel(image, x: 5, y: 5, equals: white())
    }

    // MARK: - Tier 1: EXACT — clip removes a known region

    func testClipPathRemovesRegionOutsideClip() {
        let image = render("clip/clip_rect_removes_region", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x00, 0x00, 0x00), "inside both rect and clip")
        SnapshotSupport.assertPixel(image, x: 15, y: 15, equals: white(), "inside rect but outside clip must not paint")
    }

    // MARK: - Tier 1: EXACT — use/symbol instancing offsets

    func testUseInstancesTemplateAtOffsetAndTemplateItselfDoesNotPaint() {
        let image = render("use-symbol/use_translate_rect", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 15, y: 15, equals: white(), "defs template must not paint directly")
        SnapshotSupport.assertPixel(image, x: 55, y: 55, equals: Pixel(0xFF, 0x00, 0xFF), "use instance at its offset")
    }

    func testNestedUseComposesOffsetsAdditively() {
        let image = render("use-symbol/nested_use_two_levels", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0xFF, 0xA5, 0x00), "composed (10+30,10+30) offset")
        SnapshotSupport.assertPixel(image, x: 5, y: 5, equals: white(), "un-instanced original must not paint")
    }

    func testSymbolViewportScalesLikeNestedViewBox() {
        let image = render("use-symbol/symbol_viewport_rect", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 40, y: 40, equals: Pixel(0x00, 0x80, 0x80))
        SnapshotSupport.assertPixel(image, x: 5, y: 5, equals: white())
    }

    // MARK: - Tier 2: GOLDEN — gradients

    func testLinearGradientBasicMatchesGolden() {
        let image = render("gradients/linear_gradient_basic", width: 120, height: 80)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "linear_gradient_basic")
    }

    func testRadialGradientBasicMatchesGolden() {
        let image = render("gradients/radial_gradient_basic", width: 100, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "radial_gradient_basic")
    }

    func testGradientObjectBoundingBoxMatchesGolden() {
        let image = render("gradients/gradient_object_bounding_box", width: 140, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "gradient_object_bounding_box")
    }

    func testGradientUserSpaceOnUseMatchesGolden() {
        let image = render("gradients/gradient_user_space_on_use", width: 140, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "gradient_user_space_on_use")
    }

    func testGradientSpreadReflectMatchesGolden() {
        let image = render("gradients/gradient_spread_reflect", width: 120, height: 60)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "gradient_spread_reflect")
    }

    // MARK: - Tier 2: GOLDEN — patterns

    func testPatternBasicTilingMatchesGolden() {
        let image = render("patterns/pattern_basic_tiling", width: 100, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "pattern_basic_tiling")
    }

    func testPatternObjectBoundingBoxMatchesGolden() {
        let image = render("patterns/pattern_object_bounding_box", width: 160, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "pattern_object_bounding_box")
    }

    // MARK: - Tier 2: GOLDEN — masks

    func testMaskLuminanceBasicMatchesGolden() {
        let image = render("mask/mask_luminance_basic", width: 100, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "mask_luminance_basic")
    }

    func testMaskNestedMatchesGolden() {
        let image = render("mask/mask_nested", width: 100, height: 100)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "mask_nested")
    }

    // MARK: - Tier 2: GOLDEN — clip (curved / AA-sensitive boundary)

    func testClipPathComplexMatchesGolden() {
        let image = render("clip/clip_path_complex", width: 120, height: 120)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "clip_path_complex")
    }

    // MARK: - Tier 2: GOLDEN — text

    func testTextBasicMatchesGolden() {
        let image = render("text/text_basic", width: 200, height: 60)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "text_basic", perPixelTolerance: 40, maxDivergentFraction: 0.05)
    }

    // MARK: - Tier 2: GOLDEN — images

    func testImageEmbeddedBasicMatchesGolden() {
        let image = render("images/image_embedded_basic", width: 80, height: 80)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "image_embedded_basic")
    }

    func testImagePreserveAspectRatioMatchesGolden() {
        let image = render("images/image_preserve_aspect_ratio", width: 80, height: 80)
        SnapshotSupport.assertMatchesGolden(image, referenceName: "image_preserve_aspect_ratio")
    }
}

private extension CGImage {
    /// A 1x1 placeholder used only so a helper can return a non-optional
    /// `CGImage` after `XCTFail` on a nil render result; the fail already
    /// marks the test red, this is never inspected.
    static var zeroPixelPlaceholder: CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
