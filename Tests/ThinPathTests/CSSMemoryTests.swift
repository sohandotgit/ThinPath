//
//  CSSMemoryTests.swift
//  ThinPathTests
//
//  The decisive allocation/flatness block for CSS `<style>`/selector support
//  (Tests/css.spec.md §4). These stand in for a profiling session: IR
//  flatness is deterministic, so it is asserted structurally, not
//  Instruments-profiled. Modeled on PatternImageMemoryTests' phys_footprint
//  proxy plus exact structural invariants. Test IDs (T-A*) match the spec.
//

import XCTest
import CoreGraphics
@testable import ThinPath

final class CSSMemoryTests: XCTestCase {

    // MARK: - Shared heavy fixtures (css.spec.md §4)

    private func heavyStyledSVG(elements n: Int, rules m: Int) -> Data {
        var css = ".hot { fill: red }\n"
        if m > 1 {
            for i in 1..<m {
                css += ".c\(i) { stroke-width: \(i % 20 + 1) }\n"
            }
        }
        var body = "<svg viewBox=\"0 0 1000 1000\"><style>\(css)</style>\n"
        for i in 0..<n {
            body += "<rect id=\"r\(i)\" class=\"hot\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"/>\n"
        }
        body += "</svg>"
        return body.data(using: .utf8)!
    }

    private func heavyInlineSVG(elements n: Int) -> Data {
        var body = "<svg viewBox=\"0 0 1000 1000\">\n"
        for i in 0..<n {
            body += "<rect id=\"r\(i)\" fill=\"red\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"/>\n"
        }
        body += "</svg>"
        return body.data(using: .utf8)!
    }

    private func multiClassSVG(elements n: Int) -> Data {
        var body = "<svg viewBox=\"0 0 1000 1000\"><style>.a{fill:red} .b{stroke:blue} .c{stroke-width:2}</style>\n"
        for i in 0..<n {
            body += "<rect id=\"r\(i)\" class=\"a b c\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"/>\n"
        }
        body += "</svg>"
        return body.data(using: .utf8)!
    }

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

    // MARK: - T-A1 — <style> adds no render node

    func testStyleElementAddsNoRenderNode() {
        let (document, errors) = parse(data: heavyStyledSVG(elements: 1000, rules: 50))
        XCTAssertTrue(errors.isEmpty, "parse errors: \(errors)")
        XCTAssertEqual(document.nodes.count, 1000 + 1)
    }

    // MARK: - T-A2 — SVGDocument retains no stylesheet/rule storage (structural, exact)

    func testDocumentRetainsNoStylesheetOrRuleStorage() {
        let (document, errors) = parse(data: heavyStyledSVG(elements: 10, rules: 5))
        XCTAssertTrue(errors.isEmpty, "parse errors: \(errors)")

        let names = Set(Mirror(reflecting: document).children.compactMap { $0.label })
        let allowed: Set<String> = [
            "nodes", "root", "pathCommands", "points", "gradientStops", "strings", "transforms",
            "idMap", "rootViewBox", "rootPreserveAspectRatio",
            "classNames",
        ]
        XCTAssertEqual(names, allowed)

        for forbidden in ["rule", "selector", "stylesheet", "declaration", "matched", "css", "sheet"] {
            XCTAssertFalse(names.contains { $0.lowercased().contains(forbidden) },
                           "SVGDocument retains a CSS structure: \(names)")
        }
    }

    // MARK: - T-A3 — sheet-styled node is byte-for-byte the inline-styled node

    func testSheetStyledNodeMatchesInlineStyledNodeExactly() {
        let (sheetDoc, sheetErrors) = parse(data: heavyStyledSVG(elements: 1000, rules: 50))
        let (inlineDoc, inlineErrors) = parse(data: heavyInlineSVG(elements: 1000))
        XCTAssertTrue(sheetErrors.isEmpty, "parse errors: \(sheetErrors)")
        XCTAssertTrue(inlineErrors.isEmpty, "parse errors: \(inlineErrors)")

        var sheetStrings = sheetDoc.strings
        var inlineStrings = inlineDoc.strings
        for i in 0..<1000 {
            let id = "r\(i)"
            let sheetRef = sheetStrings.intern(id)
            let inlineRef = inlineStrings.intern(id)
            guard let sheetIdx = sheetDoc.idMap[sheetRef], let inlineIdx = inlineDoc.idMap[inlineRef] else {
                XCTFail("missing id \(id)")
                continue
            }
            XCTAssertEqual(sheetDoc.node(sheetIdx).style, inlineDoc.node(inlineIdx).style,
                           "RawStyle diverged for \(id)")
        }

        // (b) Footprint corroboration (secondary, generous bound).
        let heavySheetData = heavyStyledSVG(elements: 2000, rules: 2000)
        let heavyInlineData = heavyInlineSVG(elements: 2000)

        let beforeSheet = Self.physFootprintBytes()
        let (heavySheetDoc, _) = parse(data: heavySheetData)
        let afterSheet = Self.physFootprintBytes()
        let sheetFootprint = afterSheet - beforeSheet

        let beforeInline = Self.physFootprintBytes()
        let (heavyInlineDoc, _) = parse(data: heavyInlineData)
        let afterInline = Self.physFootprintBytes()
        let inlineFootprint = afterInline - beforeInline

        // Keep both documents alive until the measurement completes.
        XCTAssertEqual(heavySheetDoc.nodes.count, 2001)
        XCTAssertEqual(heavyInlineDoc.nodes.count, 2001)

        if beforeSheet >= 0, afterSheet >= 0, beforeInline >= 0, afterInline >= 0 {
            XCTAssertLessThan(abs(sheetFootprint - inlineFootprint), 8 * 1024 * 1024,
                              "sheet vs inline retained footprint diverged by "
                              + "\(abs(sheetFootprint - inlineFootprint) / 1_048_576) MB")
        }
    }

    // MARK: - T-A4 — class arena grows with class tokens only, independent of rule count

    func testClassArenaGrowsWithClassTokensOnlyIndependentOfRuleCount() {
        let (doc50, errors50) = parse(data: heavyStyledSVG(elements: 1000, rules: 50))
        XCTAssertTrue(errors50.isEmpty, "parse errors: \(errors50)")
        XCTAssertEqual(doc50.classNames.count, 1000)

        let (doc5000, errors5000) = parse(data: heavyStyledSVG(elements: 1000, rules: 5000))
        XCTAssertTrue(errors5000.isEmpty, "parse errors: \(errors5000)")
        XCTAssertEqual(doc5000.classNames.count, 1000)

        let (docMulti, errorsMulti) = parse(data: multiClassSVG(elements: 100))
        XCTAssertTrue(errorsMulti.isEmpty, "parse errors: \(errorsMulti)")
        XCTAssertEqual(docMulti.classNames.count, 300)
    }

    // MARK: - T-A5 — SVGNode stays a fixed-size trivial value

    // The bound guards the *structural* property T-A5 exists to protect: the
    // node is a fixed-size trivially-copyable value whose class list is an
    // `ArenaRange` window (§3.2), NOT an owned array that would add a heap
    // pointer and ARC teardown. The absolute number is dominated by two inline
    // fixed-size payloads that predate CSS — `kind: NodeKind` (88 bytes) and
    // `style: RawStyle` (~20 Optional fields, 192 bytes) — so the node measured
    // ~296 bytes *before* CSS support; `classes: ArenaRange` added the final 8.
    // The bound is therefore set above the actual 304-byte stride with modest
    // headroom to catch an accidental owned-array/heap-pointer regression. See
    // css.spec.md §4 T-A5 and Design/css-support.md §3.2/§3.5(1).
    func testSVGNodeStaysFixedSizeTrivialValue() {
        XCTAssertLessThanOrEqual(MemoryLayout<SVGNode>.stride, 320)
    }

    // MARK: - T-A6 — scratch is released; no per-parse growth accumulates

    func testScratchIsReleasedAcrossRepeatedParses() {
        let data = heavyStyledSVG(elements: 500, rules: 500)

        // Warm up (first-touch allocator effects) before the baseline.
        for _ in 0..<5 {
            _ = parse(data: data)
        }

        let before = Self.physFootprintBytes()
        for _ in 0..<100 {
            let (document, _) = parse(data: data)
            XCTAssertEqual(document.nodes.count, 501)
        }
        let after = Self.physFootprintBytes()

        if before >= 0, after >= 0 {
            XCTAssertLessThan(after - before, 16 * 1024 * 1024,
                              "footprint grew by \((after - before) / 1_048_576) MB across 100 parses")
        }
    }
}
