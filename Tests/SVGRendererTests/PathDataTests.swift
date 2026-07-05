import XCTest
import CoreGraphics
@testable import SVGRenderer

/// Frozen spec for `<path d="...">` command parsing. Every expected command
/// sequence below is derived directly from the SVG path-data grammar, not
/// from any implementation detail. There is no standalone path-data entry
/// point in the public API yet, so each case round-trips through
/// `parse(data:)` on a one-path document and reads back the single path
/// node's command window. `parse(data:)` currently `fatalError`s, so this
/// whole file is expected to be RED until the parsing thread lands.
final class PathDataTests: XCTestCase {

    // MARK: - Helper

    private func commands(_ d: String, file: StaticString = #filePath, line: UInt = #line) -> [PathCommand] {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"\(d)\"/></svg>"
        let (doc, errors) = parse(data: svg.data(using: .utf8)!)
        XCTAssertTrue(errors.isEmpty, "unexpected parse errors: \(errors)", file: file, line: line)
        guard let idx = doc.nodes.firstIndex(where: {
            if case .path = $0.kind { return true }; return false
        }) else {
            XCTFail("expected a path node", file: file, line: line)
            return []
        }
        guard case let .path(range) = doc.node(NodeIndex(idx)).kind else { return [] }
        return Array(doc.commands(range))
    }

    // MARK: - Absolute vs. relative

    func testAbsoluteMoveAndLineTo() {
        XCTAssertEqual(commands("M10,10 L20,20"), [
            .moveTo(CGPoint(x: 10, y: 10)),
            .lineTo(CGPoint(x: 20, y: 20)),
        ])
    }

    func testRelativeMoveAndLineToAccumulateFromCurrentPoint() {
        // Lowercase commands are relative to the current point, so the
        // absolute end differs from the equivalent uppercase command.
        XCTAssertEqual(commands("M10,10 l20,20"), [
            .moveTo(CGPoint(x: 10, y: 10)),
            .lineTo(CGPoint(x: 30, y: 30)),
        ])
    }

    // MARK: - Implicit lineto after moveto

    func testImplicitLinetoAfterMovetoIsRelativeWhenMovetoIsRelative() {
        // "The first moveto ... is always absolute; any subsequent coordinate
        // pairs are treated as implicit linetos with the SAME relativity as
        // the moveto that introduced them."
        // m5,5 10,0 0,10 -> moveTo(5,5); implicit relative lineto (+10,+0) ->
        // (15,5); implicit relative lineto (+0,+10) -> (15,15).
        XCTAssertEqual(commands("m5,5 10,0 0,10"), [
            .moveTo(CGPoint(x: 5, y: 5)),
            .lineTo(CGPoint(x: 15, y: 5)),
            .lineTo(CGPoint(x: 15, y: 15)),
        ])
    }

    func testImplicitLinetoAfterAbsoluteMoveto() {
        XCTAssertEqual(commands("M0,0 10,0 10,10"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .lineTo(CGPoint(x: 10, y: 0)),
            .lineTo(CGPoint(x: 10, y: 10)),
        ])
    }

    // MARK: - Implicit repeated commands

    func testImplicitRepeatedLineToCommand() {
        // "L10 0 10 10 0 10" repeats L for each extra coordinate pair.
        XCTAssertEqual(commands("M0,0 L10,0 10,10 0,10 Z"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .lineTo(CGPoint(x: 10, y: 0)),
            .lineTo(CGPoint(x: 10, y: 10)),
            .lineTo(CGPoint(x: 0, y: 10)),
            .close,
        ])
    }

    func testImplicitRepeatedCubicCommand() {
        XCTAssertEqual(commands("M0,0 C1,1 2,2 3,3 4,4 5,5 6,6"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .cubicTo(control1: CGPoint(x: 1, y: 1), control2: CGPoint(x: 2, y: 2), end: CGPoint(x: 3, y: 3)),
            .cubicTo(control1: CGPoint(x: 4, y: 4), control2: CGPoint(x: 5, y: 5), end: CGPoint(x: 6, y: 6)),
        ])
    }

    // MARK: - Smooth-curve reflected control points

    func testSmoothCubicReflectsPreviousControlPoint() {
        // First cubic: control1=(0,10) control2=(10,10) end=(10,0).
        // S reflects control2 about the new current point (10,0):
        //   reflected = 2*(10,0) - (10,10) = (10,-10).
        // Then S supplies its own control2=(20,-10) and end=(20,0).
        XCTAssertEqual(commands("M0,0 C0,10 10,10 10,0 S20,-10 20,0"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .cubicTo(control1: CGPoint(x: 0, y: 10), control2: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 0)),
            .cubicTo(control1: CGPoint(x: 10, y: -10), control2: CGPoint(x: 20, y: -10), end: CGPoint(x: 20, y: 0)),
        ])
    }

    func testSmoothCubicWithoutPrecedingCurveTreatsControlAsCurrentPoint() {
        // Per spec: if S is not preceded by a C/c/S/s, the assumed reflected
        // control point is coincident with the current point.
        XCTAssertEqual(commands("M0,0 S10,10 20,0"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .cubicTo(control1: CGPoint(x: 0, y: 0), control2: CGPoint(x: 10, y: 10), end: CGPoint(x: 20, y: 0)),
        ])
    }

    func testSmoothQuadraticReflectsPreviousControlPoint() {
        // First quad: control=(5,10) end=(10,0).
        // T reflects control about the new current point (10,0):
        //   reflected = 2*(10,0) - (5,10) = (15,-10).
        // Then T supplies only its end=(20,0).
        XCTAssertEqual(commands("M0,0 Q5,10 10,0 T20,0"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .quadTo(control: CGPoint(x: 5, y: 10), end: CGPoint(x: 10, y: 0)),
            .quadTo(control: CGPoint(x: 15, y: -10), end: CGPoint(x: 20, y: 0)),
        ])
    }

    // MARK: - Arc flag packing (no separators between flags)

    func testArcFlagsPackedWithoutSeparators() {
        // "a5 5 0 015 5": rx=5 ry=5 rot=0, then the unspaced run "015 5"
        // packs large-arc-flag='0', sweep-flag='1', x=5, y=5 — each flag is
        // exactly one character wide per the path-data grammar, so no
        // separator is required before/after a flag digit.
        XCTAssertEqual(commands("M0,0 a5 5 0 015 5"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .arc(ArcTo(rx: 5, ry: 5, xAxisRotation: 0, largeArc: false, sweep: true, end: CGPoint(x: 5, y: 5))),
        ])
    }

    func testArcBothFlagsSetPackedAgainstLeadingDigitOfCoordinate() {
        // "a5 5 0 1110 0": rot=0, then "1110 0" packs large-arc-flag='1',
        // sweep-flag='1', leaving "10 0" as the coordinate pair x=10,y=0 —
        // exercises the boundary where the flag digits are followed
        // immediately by a multi-digit number starting with '1'.
        XCTAssertEqual(commands("M0,0 a5 5 0 1110 0"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .arc(ArcTo(rx: 5, ry: 5, xAxisRotation: 0, largeArc: true, sweep: true, end: CGPoint(x: 10, y: 0))),
        ])
    }

    func testAbsoluteArcCommand() {
        XCTAssertEqual(commands("M0,0 A5,5 0 1,0 10,0"), [
            .moveTo(CGPoint(x: 0, y: 0)),
            .arc(ArcTo(rx: 5, ry: 5, xAxisRotation: 0, largeArc: true, sweep: false, end: CGPoint(x: 10, y: 0))),
        ])
    }

    func testRelativeArcCommandEndIsStoredAbsolute() {
        // Lowercase 'a' is relative; the IR still tracks a running current
        // point like the other relative commands, so `end` comes out
        // absolute — consistent with how relative M/L are asserted above.
        XCTAssertEqual(commands("M10,10 a5,5 0 0,1 5,5"), [
            .moveTo(CGPoint(x: 10, y: 10)),
            .arc(ArcTo(rx: 5, ry: 5, xAxisRotation: 0, largeArc: false, sweep: true, end: CGPoint(x: 15, y: 15))),
        ])
    }
}
