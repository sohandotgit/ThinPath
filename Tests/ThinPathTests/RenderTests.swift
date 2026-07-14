//
//  RenderTests.swift
//  ThinPathTests
//
//  Frozen spec for the rendering thread (`ThinPath.render`, APISurface.swift).
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
//  `ThinPath.render` is currently `fatalError("unimplemented")`
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
import CoreText
@testable import ThinPath

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
        guard let image = ThinPath().render(
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

    // MARK: - Regression — missing font family still renders text (fallback)

    /// The only `font-family` is a quoted family absent from iOS
    /// (`'Liberation Sans'`) with no fallback in the list — the exact shape that
    /// left this Inkscape/Wikimedia diagram's text invisible. After the system-
    /// font fallback, at least one dark text pixel must appear over the white
    /// canvas. Glyph placement is font/hinting dependent, so this asserts on the
    /// *presence* of drawn text, not an exact coordinate.
    func testMissingFontFamilyFallsBackAndRendersText() {
        let image = render("text/text_missing_family_fallback", width: 200, height: 60)
        let (bytes, width, height) = SnapshotSupport.rgbaBuffer(image)
        var darkPixels = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) where
            bytes[i] < 96 && bytes[i + 1] < 96 && bytes[i + 2] < 96 {
            darkPixels += 1
        }
        XCTAssertGreaterThan(
            darkPixels, 0,
            "text with a missing quoted font-family and no fallback rendered no "
            + "dark pixels — the system-font fallback did not draw the label"
        )
    }

    /// Direct check on the resolver: a quoted, absent family with no fallback
    /// resolves to a non-nil font at the requested size, and it is the iOS
    /// system fallback (its family name matches the plain system font's).
    func testResolveFontFallsBackToSystemFontForMissingFamily() {
        let size: CGFloat = 12.3472  // one of the odd sizes present in the source SVG
        let resolved = TextRenderer.resolveFont(
            familyList: "'Liberation Sans'", size: size, weight: 400, italic: false
        )
        XCTAssertEqual(CTFontGetSize(resolved), size, accuracy: 0.001)

        let systemFamily = CTFontCopyFamilyName(
            CTFontCreateUIFontForLanguage(.system, size, nil)!
        ) as String
        XCTAssertEqual(
            CTFontCopyFamilyName(resolved) as String, systemFamily,
            "missing 'Liberation Sans' should fall back to the system font"
        )
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

    // MARK: - Tier 1: EXACT — mix-blend-mode (Design/blend-modes.md, Tests/blend-modes.spec.md)

    // T-B1 — multiply is the load-bearing begin-time-capture case.
    func testBlendMultiplyOverWhiteIsIdentity() {
        let image = render("blend/blend_multiply_white", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0xFF, 0x00, 0x00))
    }

    func testBlendMultiplyRedOverGreenIsBlack() {
        let image = render("blend/blend_multiply_green", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x00, 0x00, 0x00))
    }

    // T-B2 — screen.
    func testBlendScreenOverBlackIsSource() {
        let image = render("blend/blend_screen_black", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0xFF, 0x00, 0x00))
    }

    func testBlendScreenRedOverBlueIsMagenta() {
        let image = render("blend/blend_screen_blue", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0xFF, 0x00, 0xFF))
    }

    // T-B3 — darken (per-channel min; gamma-independent).
    func testBlendDarkenTakesChannelwiseMin() {
        let image = render("blend/blend_darken", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(50, 50, 50))
    }

    // T-B4 — lighten (per-channel max; gamma-independent).
    func testBlendLightenTakesChannelwiseMax() {
        let image = render("blend/blend_lighten", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(200, 200, 200))
    }

    // T-B5 — difference.
    func testBlendDifferenceOfWhiteAndMagentaIsGreen() {
        let image = render("blend/blend_difference", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x00, 0xFF, 0x00))
    }

    // T-B6 — fill+stroke shape blends as ONE flattened unit (no single-paint fold).
    func testBlendFillStrokeOverlapBlendsAsFlattenedUnit() {
        let image = render("blend/blend_fill_stroke_overlap", width: 100, height: 100)
        // Correct: multiply(stroke=red, backdrop=white) = red, since the opaque
        // stroke fully covers the fill in the overlap and the layer flattens
        // fill+stroke before blending once. A per-paint blend (fill blended
        // against white, then stroke blended against the ALREADY-blended fill)
        // would instead land on multiply(red, green) = black.
        SnapshotSupport.assertPixel(image, x: 50, y: 28, equals: Pixel(0xFF, 0x00, 0x00))
    }

    // T-B7 — blend is orthogonal to the opacity split (fill-opacity folds
    // INSIDE the layer; the flattened layer then screens onto the backdrop).
    func testBlendOrthogonalToOpacitySplit() {
        let image = render("blend/blend_opacity_orthogonal", width: 100, height: 100)
        let pixel = SnapshotSupport.pixel(in: image, x: 50, y: 50)
        // Neither "opacity ignored" (255) nor "opacity applied after blend" (0).
        XCTAssertTrue(pixel.r > 40 && pixel.r < 200, "expected a mid-tone grey, got \(pixel)")
        XCTAssertEqual(pixel.r, pixel.g)
        XCTAssertEqual(pixel.g, pixel.b)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(128, 128, 128), tolerance: 2)
    }

    // T-B8 — a blend mode does not leak to later siblings.
    func testBlendDoesNotLeakToLaterSiblings() {
        let image = render("blend/blend_sibling_no_leak", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 75, y: 75, equals: Pixel(0x50, 0xA0, 0xF0))
    }

    // T-B9 — `isolation: isolate` confines a descendant blend to the group's backdrop.
    func testIsolationConfinesDescendantBlend() {
        let isolated = render("blend/blend_isolation_isolated", width: 100, height: 100)
        let notIsolated = render("blend/blend_isolation_not_isolated", width: 100, height: 100)
        let isolatedPixel = SnapshotSupport.pixel(in: isolated, x: 50, y: 50)
        let notIsolatedPixel = SnapshotSupport.pixel(in: notIsolated, x: 50, y: 50)
        XCTAssertGreaterThan(
            isolatedPixel.maxChannelDelta(from: notIsolatedPixel), 20,
            "isolation must change what the descendant blend composites against: "
            + "isolated=\(isolatedPixel) notIsolated=\(notIsolatedPixel)"
        )
        // Isolated: Q (white) multiplies against P-over-transparent only, ending
        // fully opaque before the group composites onto the (irrelevant) outer
        // backdrop — green channel stays high (P's green shows through).
        SnapshotSupport.assertPixel(isolated, x: 50, y: 50, equals: Pixel(128, 255, 128), tolerance: 2)
        // Not isolated: Q multiplies against P-over-red (already washed toward
        // red), so the green channel that isolation preserved is gone.
        SnapshotSupport.assertPixel(notIsolated, x: 50, y: 50, equals: Pixel(128, 128, 0), tolerance: 2)
    }

    // T-B10 — `normal` (and unspecified) never isolates / changes pixels.
    func testBlendNormalAndAbsentAreNoOps() {
        let image = render("blend/blend_normal_noop", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 35, y: 50, equals: Pixel(0x33, 0x66, 0xCC))
        SnapshotSupport.assertPixel(image, x: 65, y: 50, equals: Pixel(0x33, 0x66, 0xCC))
    }

    // T-B15 — unknown `mix-blend-mode` keyword degrades to `normal`.
    func testUnknownBlendModeKeywordDegradesToNormal() {
        let image = render("blend/blend_unknown_keyword", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x33, 0x66, 0xCC))
    }

    // MARK: - EXACT anchors — remaining modes + color-space pin (S12 amendment)
    //
    // These replace the spec's originally-planned GOLDEN tier (T-B11–B14,
    // T-B10g) per the S12/S9 amendment recorded in Tests/blend-modes.spec.md §4.
    // Expected values are computed by an independent CSS-Compositing oracle (NOT
    // Core Graphics) over flat, opaque, non-overlapping regions and sampled far
    // from every edge — hand-checkable exact answers, no reference PNGs. Because
    // ThinPath renders in device sRGB, CG evaluates each CGBlendMode on the
    // sRGB-encoded channel values, which is the CSS-correct result; every case
    // below matched the oracle to delta 0 at authoring time except soft-light
    // (see below). Tolerances follow the spec §2 rule: 0 for extreme/clean
    // operands, ≤2 for mid-tone/multi-step rounding.

    // COLOR-SPACE PIN — the load-bearing anchor for "blend-colorspace". A
    // mid-tone multiply is the one case whose answer diverges by color space:
    // sRGB-encoded multiply(128,128)=64; a silently-linearized context would
    // give ~55. This fixes the render context as sRGB and validates every
    // mid-tone/non-separable case below as a consequence.
    func testBlendMultiplyMidToneConfirmsSRGBSpace() {
        let image = render("blend/blend_colorspace_multiply_mid", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(64, 64, 64))
    }

    // Remaining separable modes over flat regions.
    func testBlendOverlayKeysOffBackdrop() {
        let image = render("blend/blend_overlay", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0, 255, 0))
    }

    func testBlendHardLightKeysOffSource() {
        let image = render("blend/blend_hardlight", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0, 255, 0))
    }

    func testBlendColorDodge() {
        let image = render("blend/blend_colordodge", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(100, 255, 100))
    }

    func testBlendColorBurn() {
        let image = render("blend/blend_colorburn", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(100, 0, 100))
    }

    func testBlendExclusionDiffersFromDifference() {
        // exclusion(0.5,·) stays mid-grey where difference would drop a channel
        // to 0 — the observable that distinguishes the two modes.
        let image = render("blend/blend_exclusion", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(127, 128, 127), tolerance: 1)
    }

    // soft-light — DOCUMENTED DIVERGENCE. Core Graphics' `.softLight` is not the
    // W3C CSS Compositing soft-light formula: for D=0.5, S=1.0 the CSS formula
    // yields (181,·,·) but CG yields (192,·,·), a ~11/255 (~4%) max-channel
    // difference. This is CG's implementation, surfaced by S12 and recorded in
    // the docs as a known limitation. Pinned here as a regression guard on CG's
    // actual value, NOT the CSS oracle value.
    func testBlendSoftLightUsesCoreGraphicsVariant() {
        let image = render("blend/blend_softlight", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(192, 64, 64), tolerance: 2)
    }

    // Non-separable modes — CG matched the CSS oracle (Lum 0.3/0.59/0.11,
    // SetSat/SetLum in sRGB) to delta 0, confirming CG uses the CSS luminance
    // model in this space. Operands chosen so the four modes are mutually
    // distinct (Cb light+desaturated, Cs dark+saturated).
    func testBlendHue() {
        let image = render("blend/blend_hue", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(159, 199, 167), tolerance: 2)
    }

    func testBlendSaturation() {
        let image = render("blend/blend_saturation", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(224, 174, 124), tolerance: 2)
    }

    func testBlendColor() {
        let image = render("blend/blend_color", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(123, 223, 143), tolerance: 2)
    }

    func testBlendLuminosity() {
        let image = render("blend/blend_luminosity", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(97, 77, 57), tolerance: 2)
    }

    // T-B10g — combined opacity + mask + mix-blend-mode on ONE element, all
    // riding a single isolation layer in the design §7 order. Full-pass mask +
    // opacity 1 reduces to multiply(red, green) = black; a broken order or a
    // second surface would not land on pure black.
    func testBlendCombinedOpacityMaskBlendSingleLayer() {
        let image = render("blend/blend_opacity_mask_multiply", width: 100, height: 100)
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0, 0, 0))
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
