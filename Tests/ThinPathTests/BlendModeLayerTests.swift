//
//  BlendModeLayerTests.swift
//  ThinPathTests
//
//  MEMORY — deterministic layer-accounting guards for `mix-blend-mode`
//  (Tests/blend-modes.spec.md §6, T-B-M1/M3/M4/M5). These assert the wiring
//  in Design/blend-modes.md §8 — "blend adds no new surface and no retained
//  storage" — without measuring bytes: `RenderContext.layerDepth` /
//  `.peakLayerDepth` are the production accounting this pass already keeps
//  (no separate spy subclass needed — `RenderContext` is `final` and CG
//  offers no interception seam, so the context's own counters ARE the spy).
//  Peak transient *buffer* memory (bytes, not layer count) is runtime- and
//  input-dependent and is NOT certified here — that is S11's live-profiling
//  job (spec §7).
//
//  T-B-M2 (no new document-level arena / SVGNode stays fixed-size) is
//  covered by the existing CSSMemoryTests-style guards; blend adds only two
//  inline `Optional` enum fields to `RawStyle`, verified not to move
//  `MemoryLayout<SVGNode>.stride` past the frozen 320-byte bound.
//

import XCTest
import CoreGraphics
@testable import ThinPath

final class BlendModeLayerTests: XCTestCase {

    // MARK: - Helper: render a sample SVG and hand back the driving RenderContext

    /// Parses and renders `sampleName` exactly like `RenderTests.render`, but
    /// returns the `RenderContext` used for the pass so tests can inspect its
    /// layer-accounting counters afterward.
    @discardableResult
    private func renderAndInspect(
        _ sampleName: String, width: Int, height: Int, maxLayerDepth: Int? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) -> RenderContext {
        let data = SnapshotSupport.loadSampleSVG(sampleName, file: file, line: line)
        let (document, errors) = parse(data: data)
        XCTAssertTrue(errors.isEmpty, "parse errors for \(sampleName): \(errors)", file: file, line: line)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("could not create bitmap context", file: file, line: line)
            fatalError("unreachable")
        }

        let context = RenderContext(
            cg: cg, document: document,
            dirtyRect: CGRect(x: 0, y: 0, width: width, height: height),
            images: ImageCache(budgetBytes: 64 * 1024 * 1024)
        )
        if let maxLayerDepth { context.maxLayerDepth = maxLayerDepth }

        var walk = RenderWalk(visitor: DefaultVisitor(), context: context)
        walk.run()
        return context
    }

    // MARK: - T-B-M1 — a blended single-paint shape opens exactly ONE layer

    func testBlendedSinglePaintShapeOpensExactlyOneLayer() {
        let context = renderAndInspect("blend/blend_multiply_white", width: 100, height: 100)
        XCTAssertEqual(context.peakLayerDepth, 1)
        XCTAssertEqual(context.layerDepth, 0, "no layer left open after the render")
    }

    // MARK: - T-B-M3 — peak concurrent layers = nesting depth, NOT blended-element count

    func testFlatBlendedSiblingsPeakAtOneLayerRegardlessOfCount() {
        let context = renderAndInspect("blend/blend_flat_siblings_200", width: 500, height: 500)
        XCTAssertEqual(context.peakLayerDepth, 1,
                       "200 flat blended siblings must never have more than one layer open at once")
        XCTAssertEqual(context.layerDepth, 0)
    }

    func testNestedBlendedGroupsPeakAtNestingDepth() {
        let context = renderAndInspect("blend/blend_nested_8", width: 100, height: 100)
        XCTAssertEqual(context.peakLayerDepth, 8,
                       "8 nested mix-blend-mode groups must open exactly 8 concurrent layers")
        XCTAssertEqual(context.layerDepth, 0)
    }

    // MARK: - T-B-M4 — degradation at maxLayerDepth is bounded and lossy-but-safe

    func testDegradationAtMaxLayerDepthIsBoundedAndSafe() {
        let context = renderAndInspect("blend/blend_nested_8", width: 100, height: 100, maxLayerDepth: 4)
        XCTAssertLessThanOrEqual(context.peakLayerDepth, 4,
                                 "the depth guard must stop opening new layers past maxLayerDepth")
        XCTAssertEqual(context.layerDepth, 0, "render completes without a leaked layer")

        // The innermost shape still paints (degraded to `.normal` compositing,
        // blend dropped) rather than vanishing — sample the shape's own color.
        guard let image = context.cg.makeImage() else {
            XCTFail("no image produced")
            return
        }
        SnapshotSupport.assertPixel(image, x: 50, y: 50, equals: Pixel(0x33, 0x66, 0xCC))
    }

    // MARK: - T-B-M5 — every layer is balanced (no leaked open layer on any path)

    func testEveryLayerIsBalancedAcrossEarlyReturnPaths() {
        let context = renderAndInspect("blend/blend_early_return_paths", width: 100, height: 100)
        XCTAssertEqual(context.layerDepth, 0,
                       "no beginTransparencyLayer without a matching endTransparencyLayer, "
                       + "including empty-clamp / display:none / empty-bbox early returns")
    }
}
