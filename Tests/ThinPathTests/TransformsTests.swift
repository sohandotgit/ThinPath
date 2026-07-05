import XCTest
import CoreGraphics
@testable import ThinPath

/// Known-answer tests for `Transforms.swift`: transform-list composition and
/// viewBox + preserveAspectRatio viewport math. Written before the
/// implementation to pin down the exact numeric behavior (composition order
/// and all nine align values are the parts most likely to be gotten backwards).
final class TransformsTests: XCTestCase {

    private func assertPoint(_ a: CGPoint, _ b: CGPoint,
                             _ accuracy: CGFloat = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Individual primitives (known-answer)

    func testTranslateTwoArgs() {
        let m = TransformParser.parse("translate(10,20)")!
        assertPoint(CGPoint(x: 1, y: 1).applying(m), CGPoint(x: 11, y: 21))
    }

    func testTranslateSingleArgDefaultsYToZero() {
        let m = TransformParser.parse("translate(5)")!
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 5, y: 0))
    }

    func testScaleUniform() {
        let m = TransformParser.parse("scale(3)")!
        assertPoint(CGPoint(x: 2, y: 4).applying(m), CGPoint(x: 6, y: 12))
    }

    func testScaleNonUniform() {
        let m = TransformParser.parse("scale(2,3)")!
        assertPoint(CGPoint(x: 1, y: 1).applying(m), CGPoint(x: 2, y: 3))
    }

    func testRotateAboutOrigin90Degrees() {
        // SVG y-down: rotate(90) sends (1,0) -> (0,1).
        let m = TransformParser.parse("rotate(90)")!
        assertPoint(CGPoint(x: 1, y: 0).applying(m), CGPoint(x: 0, y: 1))
    }

    func testRotateAboutCenterFixesCenterAndMapsPoint() {
        let m = TransformParser.parse("rotate(90 100 100)")!
        // The center is a fixed point of a rotation-about-center.
        assertPoint(CGPoint(x: 100, y: 100).applying(m), CGPoint(x: 100, y: 100))
        // (110,100) rotates 90 about center to (100,110).
        assertPoint(CGPoint(x: 110, y: 100).applying(m), CGPoint(x: 100, y: 110))
    }

    func testSkewX30Degrees() {
        let m = TransformParser.parse("skewX(45)")!
        // skewX(45): x' = x + y*tan(45) = x + y. (0,1) -> (1,1).
        assertPoint(CGPoint(x: 0, y: 1).applying(m), CGPoint(x: 1, y: 1))
    }

    func testSkewY45Degrees() {
        let m = TransformParser.parse("skewY(45)")!
        // skewY(45): y' = y + x*tan(45) = y + x. (1,0) -> (1,1).
        assertPoint(CGPoint(x: 1, y: 0).applying(m), CGPoint(x: 1, y: 1))
    }

    func testMatrixPrimitive() {
        let m = TransformParser.parse("matrix(1 0 0 1 7 8)")!
        assertPoint(CGPoint(x: 1, y: 1).applying(m), CGPoint(x: 8, y: 9))
    }

    // MARK: - Composition order (the easy-to-reverse part)

    func testCompositionOrderScaleThenTranslate() {
        // transform="translate(10,0) scale(2)": leftmost (translate) is
        // outermost -> applied LAST. Scale first: (5,0)->(10,0), then
        // translate: ->(20,0). NOT (30,0), which is what you'd get if the
        // fold direction were reversed.
        let m = TransformParser.parse("translate(10,0) scale(2)")!
        assertPoint(CGPoint(x: 5, y: 0).applying(m), CGPoint(x: 20, y: 0))
    }

    func testCompositionOrderThreeDeep() {
        // translate(1,0) scale(2) translate(3,0) applied to (0,0):
        // innermost (rightmost) first: translate(3,0) -> (3,0)
        // then scale(2)                -> (6,0)
        // then translate(1,0)          -> (7,0)
        let m = TransformParser.parse("translate(1,0) scale(2) translate(3,0)")!
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 7, y: 0))
    }

    // MARK: - Malformed / empty input

    func testMalformedReturnsNil() {
        XCTAssertNil(TransformParser.parse("translate(1,2"))
        XCTAssertNil(TransformParser.parse("bogus(1)"))
        XCTAssertNil(TransformParser.parse("rotate(1,2)")) // 2 args invalid for rotate
        XCTAssertNil(TransformParser.parse("matrix(1,2,3)")) // needs 6 args
    }

    func testEmptyIsIdentity() {
        XCTAssertEqual(TransformParser.parse("")!, .identity)
        XCTAssertEqual(TransformParser.parse("   ")!, .identity)
    }

    // MARK: - viewBox / preserveAspectRatio: meet & slice

    func testViewportMeetLetterboxesAndCenters() {
        // viewBox 100x50 into 100x100 viewport, xMidYMid meet:
        // uniform scale = min(1, 2) = 1; leftover 50 in y, centered -> ty=25.
        let vb = ViewBox(minX: 0, minY: 0, width: 100, height: 50)
        let vp = CGRect(x: 0, y: 0, width: 100, height: 100)
        let m = ViewportMath.viewportTransform(viewBox: vb, viewport: vp, par: .default)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 25))
        assertPoint(CGPoint(x: 100, y: 50).applying(m), CGPoint(x: 100, y: 75))
    }

    func testViewportSliceCoversAndOverflows() {
        // slice -> uniform scale = max(1,2) = 2; content overflows viewport.
        let vb = ViewBox(minX: 0, minY: 0, width: 100, height: 50)
        let vp = CGRect(x: 0, y: 0, width: 100, height: 100)
        let par = PreserveAspectRatio(align: .xMidYMid, meetOrSlice: .slice)
        let m = ViewportMath.viewportTransform(viewBox: vb, viewport: vp, par: par)
        // width 100*2=200, extraX = -100, centered -> tx = -50.
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: -50, y: 0))
        assertPoint(CGPoint(x: 100, y: 50).applying(m), CGPoint(x: 150, y: 100))
    }

    func testViewportNoneStretchesNonUniformly() {
        let vb = ViewBox(minX: 0, minY: 0, width: 100, height: 50)
        let vp = CGRect(x: 0, y: 0, width: 100, height: 100)
        let par = PreserveAspectRatio(align: .none)
        let m = ViewportMath.viewportTransform(viewBox: vb, viewport: vp, par: par)
        // Non-uniform: sx=1, sy=2, exact corner mapping, no letterboxing.
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 0))
        assertPoint(CGPoint(x: 100, y: 50).applying(m), CGPoint(x: 100, y: 100))
    }

    // MARK: - viewBox / preserveAspectRatio: all nine align values (meet)
    //
    // viewBox 100x50 (2:1) into a 100x100 (1:1) viewport, meet -> scale=1,
    // leftover space is 0 in x and 50 in y. Each align value places that
    // leftover according to its x/y token. Expected origin (viewBox 0,0) maps:

    func testAlignXMinYMin() {
        let m = viewportMatrix(align: .xMinYMin)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 0))
    }

    func testAlignXMidYMin() {
        let m = viewportMatrix(align: .xMidYMin)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 0)) // extraX=0
    }

    func testAlignXMaxYMin() {
        let m = viewportMatrix(align: .xMaxYMin)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 0)) // extraX=0
    }

    func testAlignXMinYMid() {
        let m = viewportMatrix(align: .xMinYMid)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 25))
    }

    func testAlignXMidYMid() {
        let m = viewportMatrix(align: .xMidYMid)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 25))
    }

    func testAlignXMaxYMid() {
        let m = viewportMatrix(align: .xMaxYMid)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 25))
    }

    func testAlignXMinYMax() {
        let m = viewportMatrix(align: .xMinYMax)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 50))
    }

    func testAlignXMidYMax() {
        let m = viewportMatrix(align: .xMidYMax)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 50))
    }

    func testAlignXMaxYMax() {
        let m = viewportMatrix(align: .xMaxYMax)
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 50))
    }

    /// A version of the alignment matrix where x has genuine leftover space
    /// too (viewBox narrower than the viewport), so xMin/xMid/xMax are
    /// actually distinguishable — the 9-case sweep above only exercises y.
    func testAlignXDistinguishableWithNarrowViewBox() {
        // viewBox 50x100 into 100x100, meet: scale=min(2,1)=1, extraX=50.
        let vb = ViewBox(minX: 0, minY: 0, width: 50, height: 100)
        let vp = CGRect(x: 0, y: 0, width: 100, height: 100)
        func m(_ align: PreserveAspectRatio.Align) -> CGAffineTransform {
            ViewportMath.viewportTransform(viewBox: vb, viewport: vp,
                                           par: PreserveAspectRatio(align: align, meetOrSlice: .meet))
        }
        assertPoint(CGPoint(x: 0, y: 0).applying(m(.xMinYMin)), CGPoint(x: 0, y: 0))
        assertPoint(CGPoint(x: 0, y: 0).applying(m(.xMidYMin)), CGPoint(x: 25, y: 0))
        assertPoint(CGPoint(x: 0, y: 0).applying(m(.xMaxYMin)), CGPoint(x: 50, y: 0))
    }

    private func viewportMatrix(align: PreserveAspectRatio.Align) -> CGAffineTransform {
        let vb = ViewBox(minX: 0, minY: 0, width: 100, height: 50)
        let vp = CGRect(x: 0, y: 0, width: 100, height: 100)
        return ViewportMath.viewportTransform(viewBox: vb, viewport: vp,
                                              par: PreserveAspectRatio(align: align, meetOrSlice: .meet))
    }

    // MARK: - Degenerate input

    func testDegenerateViewBoxIsIdentity() {
        let vb = ViewBox(minX: 0, minY: 0, width: 0, height: 50)
        let vp = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ViewportMath.viewportTransform(viewBox: vb, viewport: vp, par: .default), .identity)
    }

    func testDegenerateViewportIsIdentity() {
        let vb = ViewBox(minX: 0, minY: 0, width: 100, height: 50)
        let vp = CGRect(x: 0, y: 0, width: 0, height: 100)
        XCTAssertEqual(ViewportMath.viewportTransform(viewBox: vb, viewport: vp, par: .default), .identity)
    }
}
