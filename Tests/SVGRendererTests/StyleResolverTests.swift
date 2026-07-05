import XCTest
import CoreGraphics
@testable import SVGRenderer

/// Known-answer tests for `StyleResolver.swift`: inheritance of the
/// inheritable presentation properties, the non-inheriting group-opacity split,
/// and `currentColor` resolution. Written before the implementation to pin
/// down exactly which properties inherit and which fall back to their initial
/// value (see Design/CascadeRules.md § property table).
final class StyleResolverTests: XCTestCase {

    private func resolver() -> StyleResolver {
        StyleResolver(document: SVGDocument())
    }

    // MARK: - fill / stroke inheritance

    func testFillInheritsWhenUnspecified() {
        var parentRaw = RawStyle()
        parentRaw.fill = .color(RGBA(r: 200, g: 0, b: 0))
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.fill, .color(RGBA(r: 200, g: 0, b: 0)))
    }

    func testFillOnChildOverridesInheritedValue() {
        var parentRaw = RawStyle()
        parentRaw.fill = .color(RGBA(r: 200, g: 0, b: 0))
        let parent = resolver().resolve(parentRaw, inheriting: .initial)

        var childRaw = RawStyle()
        childRaw.fill = .color(RGBA(r: 0, g: 200, b: 0))
        let child = resolver().resolve(childRaw, inheriting: parent)
        XCTAssertEqual(child.fill, .color(RGBA(r: 0, g: 200, b: 0)))
    }

    func testStrokeInheritsWhenUnspecified() {
        var parentRaw = RawStyle()
        parentRaw.stroke = .color(.black)
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.stroke, .color(.black))
    }

    func testStrokeWidthInheritsWhenUnspecified() {
        var parentRaw = RawStyle()
        parentRaw.strokeWidth = 3
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.strokeWidth, 3)
    }

    func testInitialFillIsBlackAndStrokeIsNone() {
        // Root context (no parent): unspecified fill/stroke fall back to the
        // CSS/SVG initial values, not to some ad-hoc default.
        let s = resolver().resolve(RawStyle(), inheriting: .initial)
        XCTAssertEqual(s.fill, .color(.black))
        XCTAssertEqual(s.stroke, .none)
    }

    // MARK: - the opacity split

    func testGroupOpacityDoesNotInherit() {
        var parentRaw = RawStyle()
        parentRaw.opacity = 0.5
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        XCTAssertEqual(parent.groupOpacity, 0.5)
        // Child does not inherit group opacity -> resets to initial 1.
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.groupOpacity, 1)
    }

    func testFillOpacityInheritsUnlikeGroupOpacity() {
        var parentRaw = RawStyle()
        parentRaw.fillOpacity = 0.25
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.fillOpacity, 0.25) // fill-opacity DOES inherit
    }

    func testStrokeOpacityInheritsUnlikeGroupOpacity() {
        var parentRaw = RawStyle()
        parentRaw.strokeOpacity = 0.4
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.strokeOpacity, 0.4)
    }

    func testOpacityValuesAreClamped01() {
        var raw = RawStyle()
        raw.opacity = 2.0
        raw.fillOpacity = -1
        let s = resolver().resolve(raw, inheriting: .initial)
        XCTAssertEqual(s.groupOpacity, 1)
        XCTAssertEqual(s.fillOpacity, 0)
    }

    // MARK: - currentColor

    func testCurrentColorResolvesAgainstOwnColorProperty() {
        var raw = RawStyle()
        raw.color = RGBA(r: 10, g: 20, b: 30)
        raw.fill = .currentColor
        let s = resolver().resolve(raw, inheriting: .initial)
        XCTAssertEqual(s.fill, .color(RGBA(r: 10, g: 20, b: 30)))
    }

    func testCurrentColorInheritsColorFromParentWhenUnspecified() {
        var parentRaw = RawStyle()
        parentRaw.color = RGBA(r: 1, g: 2, b: 3)
        let parent = resolver().resolve(parentRaw, inheriting: .initial)

        var childRaw = RawStyle()
        childRaw.fill = .currentColor // child doesn't set its own `color`
        let child = resolver().resolve(childRaw, inheriting: parent)
        XCTAssertEqual(child.fill, .color(RGBA(r: 1, g: 2, b: 3)))
    }

    func testInheritedConcretePaintIsNotReResolvedAgainstChildsColor() {
        // Parent resolves currentColor to its own color; a child that changes
        // `color` but does NOT re-specify fill should keep the PARENT's
        // already-concretized color, not re-resolve against its own.
        var parentRaw = RawStyle()
        parentRaw.color = RGBA(r: 1, g: 2, b: 3)
        parentRaw.fill = .currentColor
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        XCTAssertEqual(parent.fill, .color(RGBA(r: 1, g: 2, b: 3)))

        var childRaw = RawStyle()
        childRaw.color = RGBA(r: 9, g: 9, b: 9) // different color, fill unspecified
        let child = resolver().resolve(childRaw, inheriting: parent)
        XCTAssertEqual(child.fill, .color(RGBA(r: 1, g: 2, b: 3))) // unchanged
    }

    // MARK: - other inheritable properties

    func testFontSizeAndFamilyInherit() {
        var parentRaw = RawStyle()
        parentRaw.fontSize = 24
        parentRaw.fontFamily = 7
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.fontSize, 24)
        XCTAssertEqual(child.fontFamily, 7)
    }

    func testFillRuleAndClipRuleInherit() {
        var parentRaw = RawStyle()
        parentRaw.fillRule = .evenOdd
        parentRaw.clipRule = .evenOdd
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.fillRule, .evenOdd)
        XCTAssertEqual(child.clipRule, .evenOdd)
    }

    // MARK: - non-inherited, element-scoped references

    func testClipPathAndMaskDoNotInherit() {
        var parentRaw = RawStyle()
        parentRaw.clipPath = 3
        parentRaw.mask = 4
        let parent = resolver().resolve(parentRaw, inheriting: .initial)
        XCTAssertEqual(parent.clipPath, 3)
        XCTAssertEqual(parent.mask, 4)

        let child = resolver().resolve(RawStyle(), inheriting: parent)
        XCTAssertEqual(child.clipPath, .none)
        XCTAssertEqual(child.mask, .none)
    }
}
