//
//  SwiftUIWrapperTests.swift
//  ThinPathTests
//
//  FROZEN spec for the SwiftUI wrapper (Design/swiftui-wrapper-api.md, session
//  S3; frozen as Tests/swiftui-wrapper.spec.md, session S4). Do not renegotiate
//  these assertions in the implementation session (S5) — only the stub bodies
//  in Sources/ThinPath/SwiftUIWrapper.swift may change.
//
//  Two tiers, split into two XCTestCase classes:
//
//    - SwiftUIWrapperConstructionTests: construction/composition/defaults only.
//      Never invokes `body`, the failable `Image` init, or `Image.thinPath`, so
//      these PASS today against the provisional stub — they pin the API
//      *shape* independent of rendering behavior.
//
//    - SwiftUIWrapperRenderingTests: anything that requires an actual raster
//      (snapshot parity, error-handling degenerate output, scale/PAR fit,
//      caching/threading). Today, against the provisional stub, this class
//      fails in one of two ways — both are the expected RED signal until
//      session S5 lands, and neither needs crash-catching machinery:
//
//        * `ThinPathView`-based cases fail via an ordinary XCTest assertion
//          mismatch, NOT a crash. SwiftUI statically infers `body`'s opaque
//          `some View` underlying type as `EmptyView` (the stub's only
//          reachable return expression) and elides calling the getter
//          entirely for a view it knows produces nothing — so the stub's
//          `fatalError` never fires; the hosted snapshot is just empty and
//          differs from the expected pixels. Two cases (the malformed/no-root
//          "renders transparent" ones) happen to PASS today, since "empty" is
//          also the correct final answer for those — that is a real, if
//          coincidental, pass and stays green once S5 lands.
//        * `Image`-based cases (the failable initializer, `Image.thinPath`)
//          are plain function calls, not view bodies SwiftUI can elide, so
//          they DO hit the stub's `fatalError` and crash the process — same
//          convention as RenderTests.swift's stub-era crash.
//
//  Snapshot rendering hosts `ThinPathView`/`Image` in a real `NSHostingView`
//  (macOS is the native `swift test` host for this package) and rasterizes its
//  layer into a `CGContext` at an explicit pixel size — see `HostingSnapshot`
//  below. That helper is test-only glue, not part of the frozen assertions;
//  S5 may adjust it if it does not host correctly, as long as the assertions
//  in this file are not weakened.
//

#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics
import XCTest
@testable import ThinPath

#if os(macOS)
import AppKit

/// Test-only: host a SwiftUI view offscreen and rasterize it to a `CGImage`
/// at an explicit pixel size (`size` in points times `scale`), independent of
/// the actual screen's backing scale factor.
enum HostingSnapshot {
    /// Monotonic counter so each captured window gets a distinct off-screen
    /// origin — main-thread only, matching where windows are actually made.
    private static var windowOffsetCounter: CGFloat = 0
    private static func nextWindowOffset() -> CGFloat {
        windowOffsetCounter += CGFloat.random(in: 1_000...2_000)
        return windowOffsetCounter
    }

    /// `NSWindow`/`NSHostingView` must be created on the main thread; async
    /// XCTest methods otherwise run on a background executor, so this hops
    /// over to the main thread when needed before doing any AppKit work.
    static func renderPixels<V: View>(
        _ view: V, size: CGSize, scale: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) -> CGImage? {
        if Thread.isMainThread {
            return renderPixelsOnMain(view, size: size, scale: scale, file: file, line: line)
        }
        return DispatchQueue.main.sync {
            renderPixelsOnMain(view, size: size, scale: scale, file: file, line: line)
        }
    }

    private static func renderPixelsOnMain<V: View>(
        _ view: V, size: CGSize, scale: CGFloat,
        file: StaticString, line: UInt
    ) -> CGImage? {
        let hostingView = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.displayScale, scale)
        )
        hostingView.frame = CGRect(origin: .zero, size: size)

        // A real window, ordered in but positioned far off any actual
        // display, so layout/environment resolve as they would for an
        // on-screen view. `setIsVisible(false)` looked equivalent locally but
        // left SwiftUI's content never actually committed to the layer tree
        // on CI's headless runners (no window server session driving a
        // display cycle for a window that's never been ordered in), so the
        // capture below came back blank there. Ordering the window in (while
        // keeping it off-screen) gives SwiftUI a real display cycle to latch
        // onto in that environment too.
        // Each call gets its own window; give it a unique off-screen origin
        // (rather than reusing one fixed point, or explicitly closing the
        // window afterwards — both were tried and either let a still-open
        // prior window bleed into this capture, or crashed the CI runner's
        // older AppKit when torn down mid-render) so concurrent/back-to-back
        // captures within one test never spatially collide.
        let origin = CGPoint(x: -10_000, y: -10_000 - nextWindowOffset())
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()

        // A view that pins its own rasterization scale (e.g. `ThinPathView`
        // with an explicit `scale:`) must be captured at THAT scale, not the
        // injected environment one, or a test asserting override precedence
        // could never observe it: `CALayer.render(in:)` fills whatever
        // resolution the destination context is given, independent of any
        // source content's native pixel density.
        let captureScale = pinnedScale(of: view) ?? scale

        let pixelWidth = Int((size.width * captureScale).rounded())
        let pixelHeight = Int((size.height * captureScale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        hostingView.wantsLayer = true
        guard let layer = hostingView.layer else {
            XCTFail("hosting view has no backing layer", file: file, line: line)
            return nil
        }

        func capture() -> (image: CGImage, bytes: Data)? {
            guard let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                XCTFail("could not create decode context", file: file, line: line)
                return nil
            }
            // `CALayer.render(in:)` renders using the layer's own (Core
            // Animation) y-down convention; a plain CGBitmapContext is y-up,
            // so without this flip the capture comes out vertically mirrored.
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: captureScale, y: -captureScale)
            layer.render(in: context)
            guard let image = context.makeImage(), let data = context.data else { return nil }
            let bytes = Data(bytes: data, count: context.bytesPerRow * pixelHeight)
            return (image, bytes)
        }

        // Give SwiftUI's render pipeline runloop turns to flush content into
        // the hosting view's layer before trusting the snapshot. A single
        // fixed sleep-then-capture was flaky under CI load (the headless
        // runner's display cycle can take longer than on a local machine to
        // actually commit the layer tree) — instead, keep pumping the run
        // loop and re-capturing until two consecutive captures come back
        // byte-identical (the layer has settled), or a generous overall
        // budget elapses, in which case we fall back to the last capture
        // rather than fail outright.
        let deadline = Date().addingTimeInterval(2.0)
        var previous = capture()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        while Date() < deadline {
            let next = capture()
            if let previous, let next, previous.bytes == next.bytes {
                return next.image
            }
            previous = next
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return previous?.image
    }

    /// If `view` is (or wraps) a `ThinPathView` constructed with a non-nil
    /// `scale:`, returns that pinned value via reflection — mirrors the
    /// `storedProperty` trick `SwiftUIWrapperConstructionTests` already uses.
    private static func pinnedScale<V: View>(of view: V) -> CGFloat? {
        (Mirror(reflecting: view).children.first { $0.label == "scale" }?.value as? CGFloat?).flatMap { $0 }
    }

    /// Laid-out size SwiftUI resolves for `view` under `.fixedSize()` (the
    /// "ideal size" case — proposal is nil/unspecified in both dimensions).
    static func idealSize<V: View>(_ view: V) -> CGSize {
        let hostingView = NSHostingView(rootView: view)
        return hostingView.fittingSize
    }
}
#endif

// MARK: - Shared fixtures

private enum Fixture {
    /// 100x100 viewBox; red 40x40 rect at user-space [20,60)x[20,60) on a
    /// white background. Same file RenderTests.swift uses for exact
    /// spot-pixel assertions, reused here so snapshot parity has a known
    /// pixel to check.
    static func flatRect() -> SVGDocument {
        let data = SnapshotSupport.loadSampleSVG("shapes/flat_rect")
        let (document, errors) = parse(data: data)
        XCTAssertTrue(errors.isEmpty, "unexpected parse errors: \(errors)")
        return document
    }

    /// Data that is not XML at all. `parse(data:)` must not crash and must
    /// report non-empty errors; the resulting document has no root content
    /// (see ParsingTests.testCompletelyInvalidDataDoesNotCrashAndReportsErrors).
    static func completelyInvalidData() -> Data {
        Data("this is not xml at all { } < >".utf8)
    }

    /// Malformed but partially recoverable XML: an unclosed `<rect>` before a
    /// sibling. Parser recovers a partial tree with non-empty errors AND a
    /// real root/viewBox, so the wrapper should render the partial content,
    /// not go empty (see ParsingTests.testMalformedXMLYieldsPartialTreeAndNonEmptyErrors).
    static func malformedButPartiallyRecoverableData() -> Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10">
          <rect x="0" y="0" width="10" height="10" fill="#FFFFFF">
          <circle cx="1" cy="1" r="1"/>
        </svg>
        """.utf8)
    }
}

// MARK: - Tier 1: construction / composition / defaults (no rendering)

final class SwiftUIWrapperConstructionTests: XCTestCase {

    // Checklist #1 (availability): this whole file only compiles under
    // canImport(SwiftUI); its mere presence in the target pins that.

    // Checklist #2 (construction)

    func testDefaultPlaceholderInitInfersColor() {
        // Compile-time pin: if the no-placeholder init stopped inferring
        // `Placeholder == Color`, this line would fail to type-check.
        let view: ThinPathView<Color> = ThinPathView(Fixture.flatRect())
        _ = view
    }

    func testCustomPlaceholderInitCompiles() {
        let view: ThinPathView<SwiftUI.Text> = ThinPathView(Fixture.flatRect()) {
            SwiftUI.Text("loading")
        }
        _ = view
    }

    func testComposesInsideAStandardSwiftUIHierarchy() {
        // Type-checks (and is exercised as a `View`-conforming subtree) if
        // ThinPathView can be embedded in ordinary containers/modifiers
        // without any special-casing. Does not force a layout/draw pass, so
        // it does not touch the stubbed `body`.
        struct Host: View {
            let document: SVGDocument
            var body: some View {
                VStack {
                    ThinPathView(document)
                        .frame(width: 50, height: 50)
                    HStack {
                        ThinPathView(document, preserveAspectRatio: .init(align: .xMinYMin, meetOrSlice: .slice))
                        ThinPathView(document) { Color.gray }
                            .accessibility(label: SwiftUI.Text("decorative icon"))
                    }
                }
            }
        }
        _ = Host(document: Fixture.flatRect()).body
    }

    // Checklist #2/#3/#4 (defaults)

    /// Pulls a stored property's value out of `view` by label, typed as `T`.
    /// Reflects through the `Optional` wrapper transparently, so a stored
    /// `T?` that is `.none` yields `nil` here (not `.some(nil)`-as-Any).
    private func storedProperty<V, T>(_ view: V, _ label: String, as type: T.Type) -> T? {
        Mirror(reflecting: view).children.first { $0.label == label }?.value as? T
    }

    func testConstructorDefaultsAreNilNilAsynchronous() {
        let view = ThinPathView(Fixture.flatRect())
        XCTAssertNil(storedProperty(view, "preserveAspectRatio", as: PreserveAspectRatio.self),
                     "default preserveAspectRatio: must be nil (honors document default)")
        XCTAssertNil(storedProperty(view, "scale", as: CGFloat.self),
                     "default scale: must be nil (reads @Environment(\\.displayScale))")
        XCTAssertEqual(storedProperty(view, "rendering", as: ThinPathRenderingMode.self), .asynchronous,
                       "default rendering: must be .asynchronous")
    }

    func testExplicitOverridesAreStoredVerbatim() {
        let par = PreserveAspectRatio(align: .xMaxYMax, meetOrSlice: .slice)
        let view = ThinPathView(Fixture.flatRect(), preserveAspectRatio: par, scale: 3,
                                 rendering: .synchronous)
        XCTAssertEqual(storedProperty(view, "preserveAspectRatio", as: PreserveAspectRatio.self), par)
        XCTAssertEqual(storedProperty(view, "scale", as: CGFloat.self), 3)
        XCTAssertEqual(storedProperty(view, "rendering", as: ThinPathRenderingMode.self), .synchronous)
    }

    func testImageInitializerSignaturesCompile() {
        // Compile-only: constructing does not execute (fatalError is inside
        // the initializer body only reached when actually called at runtime
        // below, in the rendering tier). Here we only need the overload set
        // to resolve, which XCTest does by virtue of building this file.
        let doc = Fixture.flatRect()
        _ = { () -> SwiftUI.Image? in SwiftUI.Image(doc, size: CGSize(width: 10, height: 10)) }
        _ = { () async -> SwiftUI.Image? in await SwiftUI.Image.thinPath(doc, size: CGSize(width: 10, height: 10)) }
    }
}

// MARK: - Tier 2: rendering-dependent behavior (crashes until S5)

#if os(macOS)
final class SwiftUIWrapperRenderingTests: XCTestCase {

    // Checklist #13 (snapshot parity)

    func testSynchronousSnapshotMatchesDirectRenderPath() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)
        let scale: CGFloat = 1

        guard let direct = ThinPath().render(document, size: size, scale: scale) else {
            return XCTFail("direct render path returned nil")
        }
        guard let wrapped = HostingSnapshot.renderPixels(
            ThinPathView(document, scale: scale, rendering: .synchronous),
            size: size, scale: scale
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }

        assertPixelBuffersMatch(wrapped, direct, tolerance: 2)
    }

    func testAsynchronousSnapshotSettlesToSamePixelsAsDirectRenderPath() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)
        let scale: CGFloat = 1

        guard let direct = ThinPath().render(document, size: size, scale: scale) else {
            return XCTFail("direct render path returned nil")
        }

        // .asynchronous must be deterministic-once-settled (design doc §5.6):
        // poll until the hosted raster stabilizes, then compare. Stays on the
        // main thread (spinning the run loop between attempts) because
        // AppKit requires `NSWindow`/`NSHostingView` construction there.
        var settled: CGImage?
        let deadline = Date().addingTimeInterval(5)
        while settled == nil && Date() < deadline {
            if let image = HostingSnapshot.renderPixels(
                ThinPathView(document, scale: scale, rendering: .asynchronous),
                size: size, scale: scale
            ), image.width == direct.width {
                settled = image
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        guard let settled else { return XCTFail("async raster never settled") }
        assertPixelBuffersMatch(settled, direct, tolerance: 2)
    }

    // Checklist #11 (fixed-size Image init, sync)

    func testFixedSizeImageInitMatchesDirectRenderPath() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)

        guard let direct = ThinPath().render(document, size: size, scale: 1) else {
            return XCTFail("direct render path returned nil")
        }
        guard let image = SwiftUI.Image(document, size: size) else {
            return XCTFail("Image(_:size:scale:) returned nil for valid input")
        }
        guard let pixels = HostingSnapshot.renderPixels(image, size: size, scale: 1) else {
            return XCTFail("hosted Image produced no pixels")
        }
        assertPixelBuffersMatch(pixels, direct, tolerance: 2)
    }

    func testFixedSizeImageInitReturnsNilForDegenerateSizeOrScale() {
        let document = Fixture.flatRect()
        XCTAssertNil(SwiftUI.Image(document, size: .zero))
        XCTAssertNil(SwiftUI.Image(document, size: CGSize(width: -1, height: 10)))
        XCTAssertNil(SwiftUI.Image(document, size: CGSize(width: 10, height: 10), scale: 0))
    }

    // Checklist #12 (async Image producer)

    func testAsyncImageProducerMatchesSyncInitForSameInputs() async {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)

        guard let syncImage = SwiftUI.Image(document, size: size) else {
            return XCTFail("sync Image init returned nil")
        }
        guard let asyncImage = await SwiftUI.Image.thinPath(document, size: size) else {
            return XCTFail("Image.thinPath returned nil")
        }
        guard let syncPixels = HostingSnapshot.renderPixels(syncImage, size: size, scale: 1),
              let asyncPixels = HostingSnapshot.renderPixels(asyncImage, size: size, scale: 1) else {
            return XCTFail("hosted Image produced no pixels")
        }
        assertPixelBuffersMatch(asyncPixels, syncPixels, tolerance: 0)
    }

    // Checklist #7 (empty/degenerate — no throwing)

    func testCompletelyInvalidSVGRendersEmptyWithoutThrowingOrTrapping() {
        let (document, errors) = parse(data: Fixture.completelyInvalidData())
        XCTAssertFalse(errors.isEmpty, "caller is expected to have already seen/handled this")

        // The wrapper never sees `errors` — only the (empty) document. It
        // must settle on transparent content, not throw/trap.
        guard let pixels = HostingSnapshot.renderPixels(
            ThinPathView(document, rendering: .synchronous),
            size: CGSize(width: 20, height: 20), scale: 1
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        assertAllPixelsTransparent(pixels)
    }

    func testMalformedButPartiallyRecoverableSVGStillRendersPartialContent() {
        let (document, errors) = parse(data: Fixture.malformedButPartiallyRecoverableData())
        XCTAssertFalse(errors.isEmpty)
        XCTAssertFalse(document.root.isNone)

        // A document with a real root/viewBox renders per parse resilience —
        // it must match the direct render path exactly (same document, same
        // frame), not silently fall back to empty just because errors exist.
        let size = CGSize(width: 10, height: 10)
        guard let direct = ThinPath().render(document, size: size, scale: 1) else {
            return XCTFail("direct render path returned nil")
        }
        guard let wrapped = HostingSnapshot.renderPixels(
            ThinPathView(document, rendering: .synchronous), size: size, scale: 1
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        assertPixelBuffersMatch(wrapped, direct, tolerance: 2)
    }

    func testNoRootViewBoxRendersEmptyPlaceholder() {
        // A document with content but no declared root viewBox: still must
        // settle on empty per §3.3, not trap.
        var document = SVGDocument()
        document.root = .none
        guard let pixels = HostingSnapshot.renderPixels(
            ThinPathView(document, rendering: .synchronous),
            size: CGSize(width: 20, height: 20), scale: 1
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        assertAllPixelsTransparent(pixels)
    }

    // Checklist #3 (PAR default vs. override) and #6 (fit/content)

    func testNilPreserveAspectRatioUsesDocumentDefault() {
        let document = Fixture.flatRect() // rootPreserveAspectRatio == .default (xMidYMid meet)
        let size = CGSize(width: 200, height: 100) // non-matching aspect vs. the 100x100 viewBox
        guard let direct = ThinPath().render(document, size: size, scale: 1) else {
            return XCTFail("direct render path returned nil")
        }
        guard let wrapped = HostingSnapshot.renderPixels(
            ThinPathView(document, rendering: .synchronous), size: size, scale: 1
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        assertPixelBuffersMatch(wrapped, direct, tolerance: 2)
    }

    func testNonNilPreserveAspectRatioOverridesDocumentDefaultForThisViewOnly() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 200, height: 100)
        let override = PreserveAspectRatio(align: .xMinYMin, meetOrSlice: .slice)

        guard let wrapped = HostingSnapshot.renderPixels(
            ThinPathView(document, preserveAspectRatio: override, rendering: .synchronous),
            size: size, scale: 1
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }

        // Must match rendering the SAME document into the SAME frame with
        // the override applied via the direct path (achieved here by
        // mutating a copy's rootPreserveAspectRatio, since the direct API has
        // no override parameter — the wrapper's override is view-local, not
        // an IR mutation, so this comparison document is a throwaway copy).
        var overriddenDocument = document
        overriddenDocument.rootPreserveAspectRatio = override
        guard let expected = ThinPath().render(overriddenDocument, size: size, scale: 1) else {
            return XCTFail("direct render path returned nil")
        }
        assertPixelBuffersMatch(wrapped, expected, tolerance: 2)

        // And the ORIGINAL document's own PAR must be untouched (render-only,
        // never mutates the IR).
        XCTAssertEqual(document.rootPreserveAspectRatio, .default)
    }

    // Checklist #4 (scale default vs. override)

    func testNilScaleReadsEnvironmentDisplayScale() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)
        let environmentScale: CGFloat = 3

        guard let direct = ThinPath().render(document, size: size, scale: environmentScale) else {
            return XCTFail("direct render path returned nil")
        }
        guard let wrapped = HostingSnapshot.renderPixels(
            ThinPathView(document, rendering: .synchronous), // scale: nil (default)
            size: size, scale: environmentScale
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        XCTAssertEqual(wrapped.width, direct.width)
        XCTAssertEqual(wrapped.height, direct.height)
        assertPixelBuffersMatch(wrapped, direct, tolerance: 2)
    }

    func testNonNilScalePinsRasterIndependentOfEnvironment() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)
        let pinnedScale: CGFloat = 2

        guard let direct = ThinPath().render(document, size: size, scale: pinnedScale) else {
            return XCTFail("direct render path returned nil")
        }
        // Environment says 3x, but the explicit `scale: 2` parameter wins.
        guard let wrapped = HostingSnapshot.renderPixels(
            ThinPathView(document, scale: pinnedScale, rendering: .synchronous),
            size: size, scale: 3
        ) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        XCTAssertEqual(wrapped.width, Int(size.width * pinnedScale))
        XCTAssertEqual(wrapped.height, Int(size.height * pinnedScale))
        assertPixelBuffersMatch(wrapped, direct, tolerance: 2)
    }

    // Checklist #5 (ideal size)

    func testIdealSizeMatchesRootViewBoxWhenPresent() {
        let document = Fixture.flatRect() // rootViewBox == 100x100
        let size = HostingSnapshot.idealSize(ThinPathView(document, rendering: .synchronous))
        XCTAssertEqual(size.width, 100, accuracy: 0.5)
        XCTAssertEqual(size.height, 100, accuracy: 0.5)
    }

    func testIdealSizeIsZeroWhenNoRootViewBox() {
        let document = SVGDocument() // no rootViewBox
        let size = HostingSnapshot.idealSize(ThinPathView(document, rendering: .synchronous))
        XCTAssertEqual(size.width, 0, accuracy: 0.5)
        XCTAssertEqual(size.height, 0, accuracy: 0.5)
    }

    // Checklist #9/#10 (threading)
    //
    // NOTE ON AUTOMATION LIMITS: whether `.synchronous` truly never leaves
    // the main thread, whether `.asynchronous` truly runs on a background
    // executor, and the exact single-flight/cancellation/no-flash guarantees
    // in §5.1 are implementation-internal (no queue/executor identity is
    // public — by design, §3.1). The two cases below assert the *observable*
    // parts of the contract (settle-to-same-pixels, and that `.synchronous`
    // never shows the placeholder because it never has a "before" frame to
    // race against). The full no-flash/single-flight guarantee needs either
    // (a) an internal test hook exposed only in DEBUG builds, or (b) a timing
    // -based integration test — out of scope for this frozen spec; flag for
    // S5 to add a debug-only hook if stronger automation is wanted later.

    func testSynchronousModeNeverShowsPlaceholderEvenWithNonClearPlaceholder() {
        let document = Fixture.flatRect()
        let size = CGSize(width: 100, height: 100)
        guard let direct = ThinPath().render(document, size: size, scale: 1) else {
            return XCTFail("direct render path returned nil")
        }
        // A deliberately conspicuous placeholder (pure red) must never appear
        // in `.synchronous` output — if it did, these pixels would be solid
        // red instead of matching `direct`.
        let view = ThinPathView(document, scale: 1, rendering: .synchronous) {
            Color.red
        }
        guard let wrapped = HostingSnapshot.renderPixels(view, size: size, scale: 1) else {
            return XCTFail("hosted ThinPathView produced no pixels")
        }
        assertPixelBuffersMatch(wrapped, direct, tolerance: 2)
    }

    func testAsynchronousModeEventuallyReplacesPlaceholderWithRasterMatchingDirectPath() {
        // Same assertion as testAsynchronousSnapshotSettlesToSamePixelsAsDirectRenderPath,
        // stated separately because it targets checklist #10 (placeholder
        // lifecycle) rather than #13 (snapshot parity) — kept as two cases so
        // a regression in either contract fails under its own name.
        testAsynchronousSnapshotSettlesToSamePixelsAsDirectRenderPath()
    }

    // MARK: - Pixel comparison helpers

    private func assertPixelBuffersMatch(
        _ actual: CGImage, _ expected: CGImage, tolerance: UInt8,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard actual.width == expected.width, actual.height == expected.height else {
            return XCTFail(
                "size mismatch: actual \(actual.width)x\(actual.height), "
                + "expected \(expected.width)x\(expected.height)", file: file, line: line
            )
        }
        let (actualBytes, width, height) = SnapshotSupport.rgbaBuffer(actual)
        let (expectedBytes, _, _) = SnapshotSupport.rgbaBuffer(expected)
        var divergent = 0
        for i in stride(from: 0, to: actualBytes.count, by: 4) {
            let delta = (0..<4).map { abs(Int(actualBytes[i + $0]) - Int(expectedBytes[i + $0])) }.max() ?? 0
            if delta > Int(tolerance) { divergent += 1 }
        }
        let fraction = Double(divergent) / Double(width * height)
        XCTAssertLessThanOrEqual(
            fraction, 0.02,
            "\(divergent)/\(width * height) pixels exceeded tolerance \(tolerance)",
            file: file, line: line
        )
    }

    private func assertAllPixelsTransparent(
        _ image: CGImage, file: StaticString = #filePath, line: UInt = #line
    ) {
        let (bytes, _, _) = SnapshotSupport.rgbaBuffer(image)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertEqual(bytes[i + 3], 0, "expected fully transparent pixel", file: file, line: line)
        }
    }
}
#endif
#endif
