import XCTest
import CoreGraphics
@testable import SVGRenderer

/// Frozen spec for the XML/attribute parsing layer (the future `parse(data:)`
/// implementation). Every assertion below is derived directly from the input
/// SVG text, not from any implementation detail — a correct parser must make
/// these pass unmodified. `parse(data:)` currently `fatalError`s (see
/// APISurface.swift), so this whole file is expected to be RED until the
/// parsing thread lands.
final class ParsingTests: XCTestCase {

    // MARK: - Helpers

    private func parseXML(_ xml: String) -> (document: SVGDocument, errors: [SVGParseError]) {
        parse(data: xml.data(using: .utf8)!)
    }

    private func firstNode(_ doc: SVGDocument, where predicate: (SVGNode) -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) -> NodeIndex {
        guard let idx = doc.nodes.firstIndex(where: predicate) else {
            XCTFail("expected a matching node", file: file, line: line)
            return .none
        }
        return NodeIndex(idx)
    }

    private func isShapeRect(_ node: SVGNode) -> Bool {
        if case .shape(.rect) = node.kind { return true }
        return false
    }

    private func isShapeCircle(_ node: SVGNode) -> Bool {
        if case .shape(.circle) = node.kind { return true }
        return false
    }

    // MARK: - Node kinds, counts, and tree shape

    func testSimpleDocumentProducesRootPlusChildrenInOrder() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <rect x="10" y="20" width="30" height="40"/>
          <circle cx="5" cy="5" r="3"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(doc.root.isNone)
        // root + rect + circle
        XCTAssertEqual(doc.nodes.count, 3)

        guard case .svg = doc.node(doc.root).kind else {
            return XCTFail("root should be kind .svg")
        }

        var children: [NodeIndex] = []
        doc.forEachChild(of: doc.root) { children.append($0) }
        XCTAssertEqual(children.count, 2)

        guard case let .shape(rectShape) = doc.node(children[0]).kind,
              case let .rect(x, y, width, height, rx, ry) = rectShape else {
            return XCTFail("first child should be a rect shape")
        }
        XCTAssertEqual(x, 10); XCTAssertEqual(y, 20)
        XCTAssertEqual(width, 30); XCTAssertEqual(height, 40)
        XCTAssertEqual(rx, 0); XCTAssertEqual(ry, 0)

        guard case let .shape(circleShape) = doc.node(children[1]).kind,
              case let .circle(cx, cy, r) = circleShape else {
            return XCTFail("second child should be a circle shape")
        }
        XCTAssertEqual(cx, 5); XCTAssertEqual(cy, 5); XCTAssertEqual(r, 3)
    }

    func testRectWithRoundedCorners() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect x="0" y="0" width="10" height="20" rx="2" ry="4"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        let idx = firstNode(doc, where: isShapeRect)
        guard case let .shape(.rect(_, _, _, _, rx, ry)) = doc.node(idx).kind else {
            return XCTFail("expected rect shape")
        }
        XCTAssertEqual(rx, 2)
        XCTAssertEqual(ry, 4)
    }

    // MARK: - id registration

    func testIdAttributeRegistersInIdMapAndOnNode() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect id="box1" x="0" y="0" width="1" height="1"/>
          <circle id="dot" cx="2" cy="2" r="1"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)

        let rectIdx = firstNode(doc, where: isShapeRect)
        let circleIdx = firstNode(doc, where: isShapeCircle)

        XCTAssertEqual(doc.strings.string(doc.node(rectIdx).id), "box1")
        XCTAssertEqual(doc.strings.string(doc.node(circleIdx).id), "dot")

        var pool = doc.strings
        XCTAssertEqual(doc.nodeForID(pool.intern("box1")), rectIdx)
        XCTAssertEqual(doc.nodeForID(pool.intern("dot")), circleIdx)
    }

    // MARK: - Presentation attributes and style="" precedence

    func testPresentationAttributesParsedIntoRawStyle() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect x="0" y="0" width="1" height="1" fill="#ff0000" stroke="#00ff00" stroke-width="2" opacity="0.5"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        let idx = firstNode(doc, where: isShapeRect)
        let style = doc.node(idx).style
        XCTAssertEqual(style.fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertEqual(style.stroke, .color(RGBA(r: 0, g: 255, b: 0)))
        XCTAssertEqual(style.strokeWidth, 2)
        XCTAssertEqual(style.opacity, 0.5)
    }

    func testInlineStyleTakesPrecedenceOverPresentationAttribute() {
        // RawStyle doc comment: "the style block taking precedence over
        // attributes (per CSS specificity of inline style over presentation
        // attributes)". fill is set two different ways; style="" must win.
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect x="0" y="0" width="1" height="1" fill="#ff0000" style="fill:#0000ff"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        let idx = firstNode(doc, where: isShapeRect)
        XCTAssertEqual(doc.node(idx).style.fill, .color(RGBA(r: 0, g: 0, b: 255)))
    }

    // MARK: - image href, captured raw (not decoded)

    func testImageHrefCapturedVerbatimIncludingDataURI() {
        let dataURI = "data:image/png;base64,AAAABBBBCCCC=="
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <image href="\(dataURI)" x="1" y="2" width="3" height="4"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let idx = doc.nodes.firstIndex(where: {
            if case .image = $0.kind { return true }; return false
        }) else { return XCTFail("expected an image node") }

        guard case let .image(image) = doc.node(NodeIndex(idx)).kind else {
            return XCTFail("expected image payload")
        }
        // Verbatim, undecoded: exact byte-for-byte string, not base64-decoded.
        XCTAssertEqual(doc.strings.string(image.href), dataURI)
        XCTAssertEqual(image.x, 1); XCTAssertEqual(image.y, 2)
        XCTAssertEqual(image.width, 3); XCTAssertEqual(image.height, 4)
    }

    func testImagePlainHrefCapturedVerbatim() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <image href="assets/icon.png" x="0" y="0" width="1" height="1"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let idx = doc.nodes.firstIndex(where: {
            if case .image = $0.kind { return true }; return false
        }) else { return XCTFail("expected an image node") }
        guard case let .image(image) = doc.node(NodeIndex(idx)).kind else {
            return XCTFail("expected image payload")
        }
        XCTAssertEqual(doc.strings.string(image.href), "assets/icon.png")
    }

    // MARK: - use / id resolution timing

    func testUseBackwardReferenceIsPreResolved() {
        // Use.resolved doc comment: "Pre-resolved target if the id was
        // defined at parse time" — the target appears before the <use>.
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect id="a" x="0" y="0" width="1" height="1"/>
          <use href="#a" x="5" y="6"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        let rectIdx = firstNode(doc, where: isShapeRect)
        guard let useIdx = doc.nodes.firstIndex(where: {
            if case .use = $0.kind { return true }; return false
        }) else { return XCTFail("expected a use node") }
        guard case let .use(use) = doc.node(NodeIndex(useIdx)).kind else {
            return XCTFail("expected use payload")
        }
        XCTAssertEqual(doc.strings.string(use.href), "a")
        XCTAssertEqual(use.resolved, rectIdx)
        XCTAssertEqual(use.x, 5); XCTAssertEqual(use.y, 6)
    }

    func testUseForwardReferenceLeftUnresolvedButIdMapStillWorks() {
        // Use.resolved doc comment: "A forward reference resolvable only
        // after the full parse is left `.none` here and resolved on demand
        // via `idMap`" — the target appears after the <use>.
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <use href="#later" x="0" y="0"/>
          <rect id="later" x="0" y="0" width="1" height="1"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let useIdx = doc.nodes.firstIndex(where: {
            if case .use = $0.kind { return true }; return false
        }) else { return XCTFail("expected a use node") }
        guard case let .use(use) = doc.node(NodeIndex(useIdx)).kind else {
            return XCTFail("expected use payload")
        }
        XCTAssertEqual(doc.strings.string(use.href), "later")
        XCTAssertTrue(use.resolved.isNone)

        let rectIdx = firstNode(doc, where: isShapeRect)
        var pool = doc.strings
        XCTAssertEqual(doc.nodeForID(pool.intern("later")), rectIdx)
    }

    // MARK: - symbol establishes a viewport, use may override size

    func testSymbolViewBoxAndUseOverridesWidthHeight() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <symbol id="s1" viewBox="0 0 10 10">
            <rect x="0" y="0" width="10" height="10"/>
          </symbol>
          <use href="#s1" x="1" y="2" width="20" height="30"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let symbolIdx = doc.nodes.firstIndex(where: {
            if case .symbol = $0.kind { return true }; return false
        }) else { return XCTFail("expected a symbol node") }
        guard case let .symbol(viewport) = doc.node(NodeIndex(symbolIdx)).kind else {
            return XCTFail("expected symbol payload")
        }
        XCTAssertEqual(viewport.viewBox, ViewBox(minX: 0, minY: 0, width: 10, height: 10))

        guard let useIdx = doc.nodes.firstIndex(where: {
            if case .use = $0.kind { return true }; return false
        }) else { return XCTFail("expected a use node") }
        guard case let .use(use) = doc.node(NodeIndex(useIdx)).kind else {
            return XCTFail("expected use payload")
        }
        XCTAssertEqual(use.width, .value(20))
        XCTAssertEqual(use.height, .value(30))
    }

    // MARK: - gradients

    func testLinearGradientRawAttributesAndStops() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <linearGradient id="g1" x1="0" y1="0" x2="1" y2="1" gradientUnits="userSpaceOnUse" spreadMethod="reflect">
            <stop offset="0" stop-color="#ff0000"/>
            <stop offset="1" stop-color="#0000ff"/>
          </linearGradient>
          <rect x="0" y="0" width="1" height="1" fill="url(#g1)"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let gIdx = doc.nodes.firstIndex(where: {
            if case .gradient = $0.kind { return true }; return false
        }) else { return XCTFail("expected a gradient node") }
        guard case let .gradient(gradient) = doc.node(NodeIndex(gIdx)).kind else {
            return XCTFail("expected gradient payload")
        }
        guard case let .linear(x1, y1, x2, y2) = gradient.geometry else {
            return XCTFail("expected linear geometry")
        }
        XCTAssertEqual(x1, 0); XCTAssertEqual(y1, 0)
        XCTAssertEqual(x2, 1); XCTAssertEqual(y2, 1)
        XCTAssertEqual(gradient.units, .userSpaceOnUse)
        XCTAssertEqual(gradient.spread, .reflect)

        let stops = Array(doc.stops(gradient.stops))
        XCTAssertEqual(stops, [
            GradientStop(offset: 0, color: RGBA(r: 255, g: 0, b: 0)),
            GradientStop(offset: 1, color: RGBA(r: 0, g: 0, b: 255)),
        ])

        // The referencing rect's fill points at the gradient's id.
        let rectIdx = firstNode(doc, where: isShapeRect)
        guard case let .server(server, _) = doc.node(rectIdx).style.fill else {
            return XCTFail("expected a server paint")
        }
        XCTAssertEqual(doc.strings.string(server.id), "g1")
    }

    func testRadialGradientGeometry() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <radialGradient id="g2" cx="5" cy="6" r="7" fx="8" fy="9">
            <stop offset="0" stop-color="#000000"/>
          </radialGradient>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let gIdx = doc.nodes.firstIndex(where: {
            if case .gradient = $0.kind { return true }; return false
        }) else { return XCTFail("expected a gradient node") }
        guard case let .gradient(gradient) = doc.node(NodeIndex(gIdx)).kind else {
            return XCTFail("expected gradient payload")
        }
        guard case let .radial(cx, cy, r, fx, fy) = gradient.geometry else {
            return XCTFail("expected radial geometry")
        }
        XCTAssertEqual(cx, 5); XCTAssertEqual(cy, 6); XCTAssertEqual(r, 7)
        XCTAssertEqual(fx, 8); XCTAssertEqual(fy, 9)
    }

    // MARK: - pattern

    func testPatternRawAttributesAndChildContent() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <pattern id="p1" x="1" y="2" width="10" height="20" patternUnits="objectBoundingBox" patternContentUnits="userSpaceOnUse" viewBox="0 0 5 5">
            <rect x="0" y="0" width="5" height="5"/>
          </pattern>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)
        guard let pIdx = doc.nodes.firstIndex(where: {
            if case .pattern = $0.kind { return true }; return false
        }) else { return XCTFail("expected a pattern node") }
        let patternIdx = NodeIndex(pIdx)
        guard case let .pattern(pattern) = doc.node(patternIdx).kind else {
            return XCTFail("expected pattern payload")
        }
        XCTAssertEqual(pattern.x, 1); XCTAssertEqual(pattern.y, 2)
        XCTAssertEqual(pattern.width, 10); XCTAssertEqual(pattern.height, 20)
        XCTAssertEqual(pattern.patternUnits, .objectBoundingBox)
        XCTAssertEqual(pattern.patternContentUnits, .userSpaceOnUse)
        XCTAssertEqual(pattern.viewBox, ViewBox(minX: 0, minY: 0, width: 5, height: 5))

        // Tile content is the pattern's child subtree.
        guard case let .shape(.rect(x, y, width, height, _, _)) = doc.node(doc.node(patternIdx).firstChild).kind else {
            return XCTFail("expected pattern's first child to be the tile rect")
        }
        XCTAssertEqual(x, 0); XCTAssertEqual(y, 0)
        XCTAssertEqual(width, 5); XCTAssertEqual(height, 5)
    }

    // MARK: - clipPath / mask

    func testClipPathAndMaskUnitsAndReferences() {
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <clipPath id="c1" clipPathUnits="objectBoundingBox">
            <rect x="0" y="0" width="1" height="1"/>
          </clipPath>
          <mask id="m1" maskUnits="userSpaceOnUse" maskContentUnits="objectBoundingBox">
            <rect x="0" y="0" width="1" height="1"/>
          </mask>
          <rect id="target" x="0" y="0" width="1" height="1" clip-path="url(#c1)" mask="url(#m1)"/>
        </svg>
        """)
        XCTAssertTrue(errors.isEmpty)

        guard let clipIdx = doc.nodes.firstIndex(where: {
            if case .clipPath = $0.kind { return true }; return false
        }) else { return XCTFail("expected a clipPath node") }
        guard case let .clipPath(units) = doc.node(NodeIndex(clipIdx)).kind else {
            return XCTFail("expected clipPath payload")
        }
        XCTAssertEqual(units, .objectBoundingBox)

        guard let maskIdx = doc.nodes.firstIndex(where: {
            if case .mask = $0.kind { return true }; return false
        }) else { return XCTFail("expected a mask node") }
        guard case let .mask(mask) = doc.node(NodeIndex(maskIdx)).kind else {
            return XCTFail("expected mask payload")
        }
        XCTAssertEqual(mask.maskUnits, .userSpaceOnUse)
        XCTAssertEqual(mask.maskContentUnits, .objectBoundingBox)

        // The referencing rect resolves clip-path/mask to the correct nodes.
        var pool = doc.strings
        let targetIdx = doc.nodeForID(pool.intern("target"))
        XCTAssertEqual(doc.node(targetIdx).style.clipPath, NodeIndex(clipIdx))
        XCTAssertEqual(doc.node(targetIdx).style.mask, NodeIndex(maskIdx))
    }

    // MARK: - malformed input: resilient, non-fatal

    func testMalformedXMLYieldsPartialTreeAndNonEmptyErrors() {
        // Unclosed <rect> tag before a sibling and the closing </svg> — not
        // well-formed XML. The parser must recover rather than crash.
        let (doc, errors) = parseXML("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <rect x="0" y="0" width="10" height="10">
          <circle cx="1" cy="1" r="1"/>
        </svg>
        """)
        XCTAssertFalse(errors.isEmpty)
        XCTAssertFalse(doc.root.isNone)
        XCTAssertFalse(doc.nodes.isEmpty)
    }

    func testCompletelyInvalidDataDoesNotCrashAndReportsErrors() {
        let (_, errors) = parseXML("this is not xml at all { } < >")
        XCTAssertFalse(errors.isEmpty)
    }
}
