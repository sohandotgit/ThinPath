//
//  CSSSelectorTests.swift
//  ThinPathTests
//
//  Correctness tests for CSS `<style>` / selector support: selector matching,
//  specificity, cascade vs. inline, `!important`, tokenizer edge cases. Known-
//  answer style, mirroring StyleResolverTests. Every case here transcribes a
//  fixture and assertion from the FROZEN Tests/css.spec.md — do not weaken or
//  edit an assertion; if a case seems wrong, that is a design question, not a
//  quiet edit here. Test IDs (T-C*) match the spec.
//

import XCTest
import CoreGraphics
@testable import ThinPath

final class CSSSelectorTests: XCTestCase {

    // MARK: - Helpers (css.spec.md §1)

    private func doc(_ svg: String) -> SVGDocument {
        let (document, errors) = parse(data: svg.data(using: .utf8)!)
        XCTAssertTrue(errors.isEmpty, "unexpected parse errors: \(errors)")
        return document
    }

    private func nodeIndex(_ document: SVGDocument, id: String) -> NodeIndex {
        var strings = document.strings
        let ref = strings.intern(id)
        return document.idMap[ref] ?? .none
    }

    private func rawStyle(_ document: SVGDocument, id: String) -> RawStyle {
        let idx = nodeIndex(document, id: id)
        guard !idx.isNone else {
            XCTFail("no node with id \(id)")
            return RawStyle()
        }
        return document.node(idx).style
    }

    private func computed(_ document: SVGDocument, id: String) -> ComputedStyle {
        let idx = nodeIndex(document, id: id)
        guard !idx.isNone else {
            XCTFail("no node with id \(id)")
            return .initial
        }
        var chain: [NodeIndex] = []
        var cursor = idx
        while !cursor.isNone {
            chain.append(cursor)
            cursor = document.node(cursor).parent
        }
        chain.reverse()
        let resolver = StyleResolver(document: document)
        var style = ComputedStyle.initial
        for node in chain {
            style = resolver.resolve(node, inheriting: style)
        }
        return style
    }

    // MARK: - T-C1 — type selector

    func testTypeSelectorMatchesOnlyItsType() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>rect { fill: red }</style>
          <rect id="r" x="0" y="0" width="10" height="10"/>
          <circle id="c" cx="5" cy="5" r="5"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "r").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertNil(rawStyle(d, id: "c").fill)
    }

    // MARK: - T-C2 — class selector, multi-class

    func testClassSelectorAndMultiClassElements() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>.hot { fill: red } .big { stroke-width: 4 }</style>
          <rect id="a" class="hot" x="0" y="0" width="10" height="10"/>
          <rect id="b" class="hot big" x="0" y="0" width="10" height="10"/>
          <rect id="c" class="cold" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "a").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertNil(rawStyle(d, id: "a").strokeWidth)

        XCTAssertEqual(rawStyle(d, id: "b").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "b").strokeWidth, 4)

        XCTAssertNil(rawStyle(d, id: "c").fill)
    }

    // MARK: - T-C3 — id beats class beats type

    func testSpecificityIdBeatsClassBeatsType() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>
          rect { fill: red }
          .k   { fill: green }
          #t   { fill: blue }
        </style>
          <rect id="t" class="k" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 0, g: 0, b: 255)))
    }

    // MARK: - T-C4 — source-order tie-break

    func testSourceOrderTieBreakAtEqualSpecificity() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>
          .k { fill: red }
          .k { fill: green }
        </style>
          <rect id="t" class="k" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 0, g: 128, b: 0)))
    }

    // MARK: - T-C5 — universal is lowest, matches everything

    func testUniversalSelectorIsLowestAndMatchesEverything() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>
          * { fill: red }
          rect { fill: green }
        </style>
          <rect id="r" x="0" y="0" width="10" height="10"/><circle id="c" cx="5" cy="5" r="5"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "c").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "r").fill, .color(RGBA(r: 0, g: 128, b: 0)))
    }

    // MARK: - T-C6 — descendant combinator (incl. deep)

    func testDescendantCombinator() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>g .hot { fill: red }</style>
          <g><rect id="inside" class="hot" x="0" y="0" width="10" height="10"/></g>
          <rect id="outside" class="hot" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "inside").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertNil(rawStyle(d, id: "outside").fill)
    }

    func testDescendantCombinatorMatchesAnyDepthAncestor() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>g .hot { fill: red }</style>
          <g><g><g><rect id="deep" class="hot" x="0" y="0" width="10" height="10"/></g></g></g>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "deep").fill, .color(RGBA(r: 255, g: 0, b: 0)))
    }

    // MARK: - T-C7 — presentation attr < normal sheet < inline

    func testCascadeOrderPresentationAttrLessThanSheetLessThanInline() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>rect { fill: green }</style>
          <rect id="pa" fill="red" x="0" y="0" width="10" height="10"/>
          <rect id="inl" fill="red" style="fill: blue" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "pa").fill, .color(RGBA(r: 0, g: 128, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "inl").fill, .color(RGBA(r: 0, g: 0, b: 255)))
    }

    // MARK: - T-C8 — !important sheet beats inline normal

    func testImportantSheetBeatsInlineNormal() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>rect { fill: green !important }</style>
          <rect id="t" style="fill: blue" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 0, g: 128, b: 0)))
    }

    // MARK: - T-C9 — inline !important beats important sheet

    func testInlineImportantBeatsImportantSheet() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>rect { fill: green !important }</style>
          <rect id="t" style="fill: blue !important" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 0, g: 0, b: 255)))
    }

    // MARK: - T-C10 — CDATA-wrapped stylesheet

    func testCDATAWrappedStylesheet() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style><![CDATA[ .k { fill: red } ]]></style>
          <rect id="t" class="k" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 255, g: 0, b: 0)))
    }

    // MARK: - T-C11 — multiple <style> blocks, forward reference

    func testMultipleStyleBlocksAndForwardReference() {
        let d = doc("""
        <svg viewBox="0 0 100 100">
          <rect id="t" class="k" x="0" y="0" width="10" height="10"/>
          <style>.k { fill: red }</style>
          <style>.k { stroke: blue }</style>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "t").stroke, .color(RGBA(r: 0, g: 0, b: 255)))
    }

    // MARK: - T-C12 — selector list shares a block

    func testSelectorListSharesABlock() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>rect, circle { fill: red }</style>
          <rect id="r" x="0" y="0" width="10" height="10"/><circle id="c" cx="5" cy="5" r="5"/>
          <line id="l" x1="0" y1="0" x2="1" y2="1"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "r").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "c").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertNil(rawStyle(d, id: "l").fill)
    }

    // MARK: - T-C13 — unsupported selectors degrade gracefully

    func testUnsupportedSelectorsDegradeGracefully() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>
          rect > text { fill: red }
          [data-x] { fill: red }
          rect:hover { fill: red }
          rect { fill: green }
        </style>
          <rect id="t" x="0" y="0" width="10" height="10"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "t").fill, .color(RGBA(r: 0, g: 128, b: 0)))
    }

    // MARK: - T-C14 — shape subtype / poly closed-ness

    func testTypeSelectorDistinguishesShapeSubtypesAndPolyClosedness() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>
          polygon { fill: red } polyline { fill: green } circle { fill: blue }
        </style>
          <polygon id="pg" points="0,0 1,0 1,1"/>
          <polyline id="pl" points="0,0 1,0 1,1"/>
          <circle id="c" cx="5" cy="5" r="5"/>
        </svg>
        """)
        XCTAssertEqual(rawStyle(d, id: "pg").fill, .color(RGBA(r: 255, g: 0, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "pl").fill, .color(RGBA(r: 0, g: 128, b: 0)))
        XCTAssertEqual(rawStyle(d, id: "c").fill, .color(RGBA(r: 0, g: 0, b: 255)))
    }

    // MARK: - T-C15 — flows through StyleResolver unchanged (inheritance)

    func testSelectorOutputFlowsThroughStyleResolverAndInherits() {
        let d = doc("""
        <svg viewBox="0 0 100 100"><style>g { fill: red }</style>
          <g id="grp"><rect id="child" x="0" y="0" width="10" height="10"/></g>
        </svg>
        """)
        XCTAssertEqual(computed(d, id: "child").fill, .color(RGBA(r: 255, g: 0, b: 0)))
    }
}
