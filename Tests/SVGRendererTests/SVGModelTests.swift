import XCTest
import CoreGraphics
@testable import SVGRenderer

/// Mechanics of the flat-arena IR itself (SVGModel.swift): string interning,
/// arena-range windows, and index-based tree links. Not part of the
/// StyleResolver/Transforms test-first work — these cover the data structures
/// those two consume.
final class SVGModelTests: XCTestCase {

    func testStringPoolInterningIsStableAndDeduplicated() {
        var pool = StringPool()
        let a = pool.intern("circle")
        let b = pool.intern("circle")
        let c = pool.intern("rect")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(pool.string(a), "circle")
        XCTAssertEqual(pool.count, 2)
    }

    func testArenaRangeMapsToArraySlice() {
        var doc = SVGDocument()
        doc.pathCommands = [.moveTo(.zero), .lineTo(CGPoint(x: 1, y: 1)), .close]
        let window = ArenaRange(start: 1, count: 2)
        XCTAssertEqual(Array(doc.commands(window)), [.lineTo(CGPoint(x: 1, y: 1)), .close])
    }

    func testChildLinkTraversalInOrder() {
        var doc = SVGDocument()
        // root -> [a, b, c] via first-child/next-sibling links.
        var root = SVGNode(kind: .group)
        var a = SVGNode(kind: .group)
        var b = SVGNode(kind: .group)
        var c = SVGNode(kind: .group)
        // indices: root=0, a=1, b=2, c=3
        root.firstChild = 1
        a.parent = 0; a.nextSibling = 2
        b.parent = 0; b.nextSibling = 3
        c.parent = 0
        doc.nodes = [root, a, b, c]
        doc.root = 0
        var visited: [NodeIndex] = []
        doc.forEachChild(of: 0) { visited.append($0) }
        XCTAssertEqual(visited, [1, 2, 3])
    }

    func testNodeIndexNoneSentinel() {
        XCTAssertTrue(NodeIndex.none.isNone)
        XCTAssertFalse(NodeIndex(0).isNone)
    }

    func testPaintServerNotEmbedded() {
        // A paint server reference stores an id/index, not a node copy.
        let ref = PaintServer(id: 7, node: 42)
        let paint = Paint.server(ref, fallback: .color(.black))
        if case let .server(server, _) = paint {
            XCTAssertEqual(server.id, 7)
            XCTAssertEqual(server.node, 42)
        } else {
            XCTFail("expected server paint")
        }
    }
}
