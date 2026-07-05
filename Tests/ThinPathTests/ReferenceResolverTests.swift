import XCTest
import CoreGraphics
@testable import ThinPath

/// Known-answer tests for the two unit-testable parts of the reference /
/// compositing subsystems, written BEFORE their implementations to pin the exact
/// behaviour:
///
///   1. `<use>` cycle detection (a `<use>` chain must not reference itself
///      directly or transitively) — the correctness gate for instancing.
///   2. Coordinate mapping — `objectBoundingBox` unit-square → user space
///      (`ObjectBoundingBox.transform`) and the `<use>`/`<symbol>` instance
///      transform (`ReferenceResolver.instanceTransform`).
///
/// Everything else in the four new subsystems is architecture/skeleton and is not
/// exercised here (no rasterization in unit tests). These are the pieces that are
/// pure value math and thus cheap to get exactly right and expensive to get subtly
/// wrong.
final class ReferenceResolverTests: XCTestCase {

    // MARK: - Test document builders

    /// Build a document from prepared nodes, wiring `idMap` from each node's `id`.
    /// Mirrors the hand-rolled arena construction in SVGModelTests.
    private func makeDocument(_ nodes: [SVGNode], root: NodeIndex = 0,
                              strings: StringPool = StringPool()) -> SVGDocument {
        var doc = SVGDocument()
        doc.nodes = nodes
        doc.root = root
        doc.strings = strings
        for (i, node) in nodes.enumerated() where !node.id.isNone {
            doc.idMap[node.id] = NodeIndex(i)
        }
        return doc
    }

    private func useNode(id: StringRef = .none, targetHref: StringRef,
                         resolved: NodeIndex, x: CGFloat = 0, y: CGFloat = 0,
                         width: LengthOrAuto = .auto, height: LengthOrAuto = .auto) -> SVGNode {
        var n = SVGNode(kind: .use(Use(href: targetHref, resolved: resolved,
                                       x: x, y: y, width: width, height: height)))
        n.id = id
        return n
    }

    // MARK: - Cycle detection

    func testAcyclicUseIsNotFlagged() {
        // g(0) -> child rect(1); use(2) -> g(0). No cycle.
        var g = SVGNode(kind: .group);  g.id = 10
        var rect = SVGNode(kind: .shape(.rect(x: 0, y: 0, width: 1, height: 1, rx: 0, ry: 0)))
        rect.id = 11
        g.firstChild = 1
        rect.parent = 0
        let use = useNode(targetHref: 10, resolved: 0)   // -> g

        let doc = makeDocument([g, rect, use], root: 2)
        let resolver = ReferenceResolver(document: doc)
        XCTAssertFalse(resolver.hasUseCycle(startingAt: 2))
        XCTAssertFalse(resolver.documentHasUseCycle())
    }

    func testDirectSelfReferenceIsCycle() {
        // use(0) id=#u href=#u -> itself.
        let use = useNode(id: 1, targetHref: 1, resolved: 0)
        let doc = makeDocument([use], root: 0)
        let resolver = ReferenceResolver(document: doc)
        XCTAssertTrue(resolver.hasUseCycle(startingAt: 0))
    }

    func testUseTargetingItsOwnStructuralAncestorIsCycle() {
        // g(0) id=#g contains use(1) href=#g. Expanding the use re-enters g.
        var g = SVGNode(kind: .group); g.id = 10
        g.firstChild = 1
        var use = useNode(targetHref: 10, resolved: 0)
        use.parent = 0
        let doc = makeDocument([g, use], root: 0)
        let resolver = ReferenceResolver(document: doc)
        XCTAssertTrue(resolver.hasUseCycle(startingAt: 0))
        XCTAssertTrue(resolver.documentHasUseCycle())
    }

    func testIndirectUseChainCycle() {
        // ga(0 id=#a) -> use(1 -> #b);  gb(2 id=#b) -> use(3 -> #a). Mutual.
        var ga = SVGNode(kind: .group); ga.id = 100; ga.firstChild = 1
        var ua = useNode(targetHref: 101, resolved: 2); ua.parent = 0      // -> gb
        var gb = SVGNode(kind: .group); gb.id = 101; gb.firstChild = 3
        var ub = useNode(targetHref: 100, resolved: 0); ub.parent = 2      // -> ga
        let doc = makeDocument([ga, ua, gb, ub], root: 0)
        let resolver = ReferenceResolver(document: doc)
        XCTAssertTrue(resolver.hasUseCycle(startingAt: 0))
    }

    func testDiamondReuseIsNotACycle() {
        // Shared target reached by two <use>s (a DAG) must NOT be flagged, and
        // must not blow up (3-colour memo prevents re-expansion).
        // root g(0) -> [use(1)->shared(4), use(2)->shared(4), use(3)->shared(4)]
        var root = SVGNode(kind: .group); root.firstChild = 1
        var u1 = useNode(targetHref: 40, resolved: 4); u1.parent = 0; u1.nextSibling = 2
        var u2 = useNode(targetHref: 40, resolved: 4); u2.parent = 0; u2.nextSibling = 3
        var u3 = useNode(targetHref: 40, resolved: 4); u3.parent = 0
        var shared = SVGNode(kind: .shape(.circle(cx: 0, cy: 0, r: 1))); shared.id = 40
        let doc = makeDocument([root, u1, u2, u3, shared], root: 0)
        let resolver = ReferenceResolver(document: doc)
        XCTAssertFalse(resolver.hasUseCycle(startingAt: 0))
    }

    func testUnresolvedReferenceIsNotACycle() {
        // use -> dangling id. Unresolvable, but not a cycle.
        let use = useNode(targetHref: 999, resolved: .none)
        let doc = makeDocument([use], root: 0)
        let resolver = ReferenceResolver(document: doc)
        XCTAssertFalse(resolver.hasUseCycle(startingAt: 0))
    }

    // MARK: - objectBoundingBox coordinate mapping

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, _ accuracy: CGFloat = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testObjectBoundingBoxMapsUnitSquareToBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        let m = ObjectBoundingBox.transform(bounds)!
        // Corners of the unit square map to the bbox corners.
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 10, y: 20))
        assertPoint(CGPoint(x: 1, y: 1).applying(m), CGPoint(x: 40, y: 60))
        // Fractional interior point maps proportionally.
        assertPoint(CGPoint(x: 0.5, y: 0.25).applying(m), CGPoint(x: 25, y: 30))
    }

    func testObjectBoundingBoxDegenerateBoxIsNil() {
        XCTAssertNil(ObjectBoundingBox.transform(CGRect(x: 0, y: 0, width: 0, height: 10)))
        XCTAssertNil(ObjectBoundingBox.transform(CGRect(x: 0, y: 0, width: 10, height: 0)))
    }

    func testPaintCoordinateSpaceUserSpaceIgnoresBounds() {
        // userSpaceOnUse: only the server transform applies; bounds are irrelevant.
        let serverT = CGAffineTransform(translationX: 5, y: 7)
        let space = PaintCoordinateSpace(units: .userSpaceOnUse,
                                         serverTransform: serverT,
                                         objectBounds: CGRect(x: 1, y: 2, width: 3, height: 4))
        assertPoint(CGPoint(x: 0, y: 0).applying(space.serverToUser!), CGPoint(x: 5, y: 7))
    }

    func testPaintCoordinateSpaceObjectBoundingBoxComposesTransform() {
        // objectBoundingBox with a 2× server scale, then mapped onto a 100×100 box
        // at origin (10,10): unit (0.5,0.5) → server-scaled (1,1) → bbox (110,110).
        let serverT = CGAffineTransform(scaleX: 2, y: 2)
        let bounds = CGRect(x: 10, y: 10, width: 100, height: 100)
        let space = PaintCoordinateSpace(units: .objectBoundingBox,
                                         serverTransform: serverT,
                                         objectBounds: bounds)
        assertPoint(CGPoint(x: 0.5, y: 0.5).applying(space.serverToUser!),
                    CGPoint(x: 110, y: 110))
    }

    func testPaintCoordinateSpaceDegenerateBoundsIsNil() {
        let space = PaintCoordinateSpace(units: .objectBoundingBox,
                                         serverTransform: .identity,
                                         objectBounds: CGRect(x: 0, y: 0, width: 0, height: 5))
        XCTAssertNil(space.serverToUser)
    }

    // MARK: - <use> / <symbol> instance transform

    func testUseOfPlainTargetIsTranslateOnly() {
        var rect = SVGNode(kind: .shape(.rect(x: 0, y: 0, width: 10, height: 10, rx: 0, ry: 0)))
        rect.id = 5
        let use = Use(href: 5, resolved: 0, x: 12, y: 34, width: .auto, height: .auto)
        let doc = makeDocument([rect], root: 0)
        let resolver = ReferenceResolver(document: doc)
        let m = resolver.instanceTransform(for: use, currentViewport: CGSize(width: 100, height: 100))
        assertPoint(CGPoint(x: 1, y: 1).applying(m), CGPoint(x: 13, y: 35))
    }

    func testUseOfSymbolAppliesViewportTransform() {
        // symbol viewBox 0 0 10 10; use places it at (0,0) sized 20×20 → scale 2.
        let vp = NestedViewport(x: 0, y: 0, width: .auto, height: .auto,
                                viewBox: ViewBox(minX: 0, minY: 0, width: 10, height: 10),
                                preserveAspectRatio: .default)
        var symbol = SVGNode(kind: .symbol(vp)); symbol.id = 7
        let doc = makeDocument([symbol], root: 0)
        let use = Use(href: 7, resolved: 0, x: 0, y: 0,
                      width: .value(20), height: .value(20))
        let resolver = ReferenceResolver(document: doc)
        let m = resolver.instanceTransform(for: use, currentViewport: CGSize(width: 200, height: 200))
        // uniform scale 2 (meet, square box) → (5,5) → (10,10).
        assertPoint(CGPoint(x: 5, y: 5).applying(m), CGPoint(x: 10, y: 10))
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 0, y: 0))
    }

    func testUseOfSymbolAutoSizeUsesCurrentViewport() {
        // No use width/height, no symbol width/height → auto = 100% of viewport.
        // viewBox 0 0 50 50 into a 100×100 viewport → scale 2.
        let vp = NestedViewport(x: 0, y: 0, width: .auto, height: .auto,
                                viewBox: ViewBox(minX: 0, minY: 0, width: 50, height: 50),
                                preserveAspectRatio: .default)
        var symbol = SVGNode(kind: .symbol(vp)); symbol.id = 9
        let doc = makeDocument([symbol], root: 0)
        let use = Use(href: 9, resolved: 0, x: 0, y: 0, width: .auto, height: .auto)
        let resolver = ReferenceResolver(document: doc)
        let m = resolver.instanceTransform(for: use, currentViewport: CGSize(width: 100, height: 100))
        assertPoint(CGPoint(x: 25, y: 25).applying(m), CGPoint(x: 50, y: 50))
    }

    func testUseOfSymbolPlacementTranslatesByUseXY() {
        // Non-zero use x/y with a viewBox: viewportTransform folds in the placement.
        let vp = NestedViewport(x: 0, y: 0, width: .auto, height: .auto,
                                viewBox: ViewBox(minX: 0, minY: 0, width: 10, height: 10),
                                preserveAspectRatio: .default)
        var symbol = SVGNode(kind: .symbol(vp)); symbol.id = 3
        let doc = makeDocument([symbol], root: 0)
        let use = Use(href: 3, resolved: 0, x: 100, y: 50,
                      width: .value(10), height: .value(10))   // scale 1
        let resolver = ReferenceResolver(document: doc)
        let m = resolver.instanceTransform(for: use, currentViewport: CGSize(width: 100, height: 100))
        // scale 1, translated by (100,50): (0,0) → (100,50), (10,10) → (110,60).
        assertPoint(CGPoint(x: 0, y: 0).applying(m), CGPoint(x: 100, y: 50))
        assertPoint(CGPoint(x: 10, y: 10).applying(m), CGPoint(x: 110, y: 60))
    }
}
