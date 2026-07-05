//
//  PatternImageMemoryTests.swift
//  ThinPathTests
//
//  Regression tests for the pattern + image-fill memory blow-up
//  (Compositing.md §4a, ImageDecodeNotes.md §3b).
//
//  Incident: memory-stress/hotel_offer_bg_img1.svg — a 296×200 document whose
//  two `<pattern patternContentUnits="objectBoundingBox">` (patternUnits also
//  objectBoundingBox, by default) each tile a large embedded PNG (1192×800 and
//  1000×1173) through a `<use>` with a ~1/1000 scale transform. The pre-fix
//  `PatternRenderer` content matrix applied the bbox transform a second time
//  in that units combination, inflating the image's device fit rect by
//  ~bboxW × bboxH; `ImageRenderer`'s resampler then tried to materialize it
//  (~178,800 × 80,000 px ≈ 57 GB at 2× scale — observed as unbounded growth
//  to ~40 GB and a crash).
//
//  Three layers of protection, each asserted here:
//    1. `PatternRenderer.contentUnitsMatrix` maps content → pattern space
//       correctly for all four unit combinations (the root-cause fix).
//    2. `ImageRenderer.fitsVisibleDeviceBounds` refuses to materialize a
//       resample buffer beyond clip ∩ dirty (the invariant guard).
//    3. End-to-end: rendering the incident file keeps process footprint flat
//       and every decode REQUEST (cache key) device-pixel-sized — a
//       wrong-space target would surface as an absurd requested size even
//       though the decoder's native clamp bounds the actual decode.
//

import XCTest
import CoreGraphics
@testable import ThinPath

final class PatternImageMemoryTests: XCTestCase {

    // MARK: - 1. Content-units → pattern-space matrix (all four combinations)

    private let bbox = CGRect(x: 10, y: 20, width: 296, height: 200)

    func testContentUnitsMatrixIsIdentityWhenUnitsMatch() {
        // Same space on both sides — INCLUDING the bbox/bbox case that caused
        // the incident: the tile matrix already contains the bbox mapping, so
        // applying it to the content again scales everything twice.
        XCTAssertEqual(
            PatternRenderer.contentUnitsMatrix(patternUnits: .objectBoundingBox,
                                               contentUnits: .objectBoundingBox,
                                               objectBounds: bbox),
            .identity)
        XCTAssertEqual(
            PatternRenderer.contentUnitsMatrix(patternUnits: .userSpaceOnUse,
                                               contentUnits: .userSpaceOnUse,
                                               objectBounds: bbox),
            .identity)
    }

    func testContentUnitsMatrixMapsBBoxContentIntoUserSpaceTile() {
        let m = PatternRenderer.contentUnitsMatrix(patternUnits: .userSpaceOnUse,
                                                   contentUnits: .objectBoundingBox,
                                                   objectBounds: bbox)
        XCTAssertEqual(m, CGAffineTransform(a: 296, b: 0, c: 0, d: 200, tx: 10, ty: 20))
    }

    func testContentUnitsMatrixMapsUserContentIntoBBoxTile() {
        let m = PatternRenderer.contentUnitsMatrix(patternUnits: .objectBoundingBox,
                                                   contentUnits: .userSpaceOnUse,
                                                   objectBounds: bbox)
        let expected = CGAffineTransform(a: 296, b: 0, c: 0, d: 200, tx: 10, ty: 20).inverted()
        XCTAssertEqual(m.a, expected.a, accuracy: 1e-12)
        XCTAssertEqual(m.d, expected.d, accuracy: 1e-12)
        XCTAssertEqual(m.tx, expected.tx, accuracy: 1e-9)
        XCTAssertEqual(m.ty, expected.ty, accuracy: 1e-9)
    }

    func testContentUnitsMatrixDegenerateBBoxIsIdentity() {
        XCTAssertEqual(
            PatternRenderer.contentUnitsMatrix(patternUnits: .objectBoundingBox,
                                               contentUnits: .userSpaceOnUse,
                                               objectBounds: .zero),
            .identity)
    }

    // MARK: - 2. Resample-buffer bound

    func testResampleBoundAcceptsFitRectInsideVisibleRegion() {
        let visible = CGRect(x: 0, y: 0, width: 592, height: 400)
        // Fully inside, and inside-with-rounding-slack (±1 px), both allowed.
        XCTAssertTrue(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: CGRect(x: 10, y: 10, width: 500, height: 300),
            visibleDevice: visible))
        XCTAssertTrue(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: visible.insetBy(dx: -0.5, dy: -0.5),
            visibleDevice: visible))
    }

    func testResampleBoundRejectsFitRectBeyondVisibleRegion() {
        let visible = CGRect(x: 0, y: 0, width: 592, height: 400)
        // The incident's shape: a fit rect hundreds of times the render target.
        XCTAssertFalse(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: CGRect(x: 0, y: 0, width: 178_800, height: 80_000),
            visibleDevice: visible))
        // A merely partially-visible image also skips the materialized buffer.
        XCTAssertFalse(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: CGRect(x: 300, y: 0, width: 592, height: 400),
            visibleDevice: visible))
    }

    func testResampleBoundRejectsDegenerateRects() {
        let visible = CGRect(x: 0, y: 0, width: 592, height: 400)
        XCTAssertFalse(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: .null, visibleDevice: visible))
        XCTAssertFalse(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: .infinite, visibleDevice: visible))
        XCTAssertFalse(ImageRenderer.fitsVisibleDeviceBounds(
            fitRectDevice: visible, visibleDevice: .null))
    }

    // MARK: - 3. End-to-end: the incident file renders flat and device-sized

    private static func physFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    func testHotelOfferPatternImageFillStaysBounded() {
        let data = SnapshotSupport.loadSampleSVG("memory-stress/hotel_offer_bg_img1")
        let (document, errors) = parse(data: data)
        XCTAssertTrue(errors.isEmpty, "parse errors: \(errors)")

        // 2× scale — the configuration that produced the ~40 GB crash.
        let size = CGSize(width: 296, height: 200)
        let scale: CGFloat = 2
        let pixelW = Int(size.width * scale), pixelH = Int(size.height * scale)
        guard let cg = CGContext(
            data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return XCTFail("could not create bitmap context") }
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)

        // A private cache so every decode request this render made is
        // inspectable afterwards.
        let cache = ImageCache(budgetBytes: 64 * 1024 * 1024)

        let before = Self.physFootprintBytes()
        SVGRootRenderer.render(document, into: cg,
                               rect: CGRect(origin: .zero, size: size), images: cache)
        let after = Self.physFootprintBytes()

        // Peak-footprint proxy: the buggy path allocated (and progressively
        // touched) tens of GB; the fixed path needs a few MB of decoded
        // thumbnails + tile-sized buffers. 128 MB is orders of magnitude
        // above the fixed cost and orders of magnitude below the regression.
        if before >= 0, after >= 0 {
            XCTAssertLessThan(after - before, 128 * 1024 * 1024,
                              "render footprint grew by \((after - before) / 1_048_576) MB")
        }

        // Every decode REQUEST must be device-pixel-sized: bounded by the
        // output raster (plus generous slack for rounding/overlap), never
        // pattern-space or intrinsic-image derived. The pre-fix content
        // matrix produced requests of ~178,800 × 80,000 px here.
        let keys = cache.residentKeysForTesting
        XCTAssertFalse(keys.isEmpty, "expected the pattern images to be decoded")
        for key in keys {
            XCTAssertLessThanOrEqual(key.pixelWidth, pixelW * 2,
                                     "decode request width \(key.pixelWidth) exceeds device bounds")
            XCTAssertLessThanOrEqual(key.pixelHeight, pixelH * 2,
                                     "decode request height \(key.pixelHeight) exceeds device bounds")
        }

        // And the patterns must actually have painted: sample points inside
        // the second pattern's rect (x 186.76–289.3, y 80.1–200.4 user units),
        // chosen away from the document's vector overlays. If the pattern
        // fill silently vanished, all of them would be the flat #F2F2F8
        // background (memory fixed by drawing nothing = still a failure).
        guard let image = cg.makeImage() else { return XCTFail("makeImage failed") }
        let background = Pixel(0xF2, 0xF2, 0xF8)
        let userPoints = [(220, 160), (250, 170), (270, 140), (280, 185)]
        let anyPatternPixel = userPoints.contains { (ux, uy) in
            SnapshotSupport.pixel(in: image, x: ux * 2, y: uy * 2)
                .maxChannelDelta(from: background) > 8
        }
        XCTAssertTrue(anyPatternPixel,
                      "no sampled pixel differs from the background — pattern fill did not paint")
    }
}
