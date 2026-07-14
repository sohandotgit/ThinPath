//
//  SVGParser.swift
//  ThinPath
//
//  Parses SVG document data into the flat-arena IR defined in SVGModel.swift.
//
//  Built on Foundation's event-driven `XMLParser` (libxml2-backed SAX) rather
//  than a retained DOM: elements are turned into arena entries as the parser
//  opens/closes tags, so the process never holds a second full object graph
//  in memory alongside the IR.
//
//  Cascade resolution (presentation attributes + `style=""` -> ComputedStyle)
//  is explicitly NOT done here — see StyleResolver.swift. This layer only
//  captures each element's *own* declarations (`RawStyle`), with the
//  `style=""` block applied after presentation attributes so it wins, per the
//  precedence documented on `RawStyle`.
//
//  id resolution timing follows the model's documented policy (SVGModel.swift
//  invariant 4 / `Use.resolved` doc comment): a reference is pre-resolved via
//  `idMap` if the target was already registered when the reference is parsed
//  (backward reference); otherwise it is left `.none` and resolved on demand
//  later via `idMap` (forward reference). There is no second fix-up pass.
//

import CoreGraphics
import Foundation

// MARK: - Entry point

public enum SVGParser {
    public static func parse(data: Data) -> (document: SVGDocument, errors: [SVGParseError]) {
        let delegate = SVGXMLDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldProcessNamespaces = false
        xmlParser.delegate = delegate
        let ok = xmlParser.parse()
        if !ok {
            let message = xmlParser.parserError?.localizedDescription ?? "XML parsing failed"
            delegate.errors.append(SVGParseError(message: message))
        }
        delegate.foldStyleSheet()
        return (delegate.doc, delegate.errors)
    }
}

// MARK: - SAX delegate

private final class SVGXMLDelegate: NSObject, XMLParserDelegate {
    var doc = SVGDocument()
    var errors: [SVGParseError] = []

    private struct Frame {
        /// Node that this element's children should attach to. Equal to
        /// `ownNode` for a real element; equal to the enclosing real node's
        /// `attachTo` for a passthrough (unknown element, or `<stop>`, which
        /// contributes to its parent gradient's stop arena rather than
        /// becoming a node of its own).
        var attachTo: NodeIndex
        /// `.none` if this element did not create an `SVGNode`.
        var ownNode: NodeIndex
        var textBuffer: String = ""
        /// True for a `<style>` element's frame: while on the stack, character
        /// data (including CDATA) accumulates in `textBuffer` for the CSS
        /// tokenizer instead of being discarded. See css-support.md §4.1.
        var isStyleElement: Bool = false
        /// Whether a `<style>` element's declared `type` (if any) is `text/css`
        /// (or absent). A non-CSS `type` still consumes the element (no stray
        /// node/text) but its buffered text is discarded, not tokenized.
        var styleTypeOK: Bool = true
    }

    private var stack: [Frame] = []
    private var lastChildOf: [NodeIndex: NodeIndex] = [:]

    /// Deferred inline `style=""` declarations, keyed by node index, split into
    /// normal/important at parse time (css-support.md §4.3). Applied during the
    /// post-parse fold at cascade layers 3 and 5, then discarded.
    var inlineDecls: [Int32: (normal: [String: String], important: [String: String])] = [:]

    // MARK: CSS transient scratch (freed with the delegate; see css-support.md §6)

    private var cssComponents: [CSSSimpleSelector] = []
    private var cssSelClasses: [StringRef] = []
    private var cssDeclBlocks: [[String: String]] = []
    private var cssRules: [CSSRule] = []
    private var cssSourceOrder: Int32 = 0

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {

        let parentAttach: NodeIndex = stack.last?.attachTo ?? .none

        if elementName == "stop" {
            handleStop(attributeDict, parentAttach: parentAttach)
            stack.append(Frame(attachTo: parentAttach, ownNode: .none))
            return
        }

        if elementName == "style" {
            let typeOK: Bool
            if let type = attributeDict["type"] {
                typeOK = type.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("text/css") == .orderedSame
            } else {
                typeOK = true
            }
            stack.append(Frame(attachTo: parentAttach, ownNode: .none,
                                isStyleElement: true, styleTypeOK: typeOK))
            return
        }

        guard let kind = makeNodeKind(elementName, attributeDict, doc: &doc) else {
            errors.append(SVGParseError(message: "unsupported element <\(elementName)>"))
            stack.append(Frame(attachTo: parentAttach, ownNode: .none))
            return
        }

        var node = SVGNode(kind: kind)

        if let idStr = attributeDict["id"] {
            node.id = doc.strings.intern(idStr)
        }

        if let cls = attributeDict["class"] {
            let start = doc.classNames.count
            for token in cls.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            where !token.isEmpty {
                doc.classNames.append(doc.strings.intern(String(token)))
            }
            node.classes = ArenaRange(start: Int32(start), count: Int32(doc.classNames.count - start))
        }

        if let t = attributeDict["transform"] {
            if let matrix = TransformParser.parse(t) {
                doc.transforms.append(matrix)
                node.transform = TransformRef(doc.transforms.count - 1)
            } else {
                errors.append(SVGParseError(message: "malformed transform on <\(elementName)>: \(t)"))
            }
        }

        applyStyleProperties(attributeDict, into: &node.style, doc: &doc)

        let newIndex = NodeIndex(doc.nodes.count)
        doc.nodes.append(node)

        if let styleStr = attributeDict["style"] {
            let (normal, important) = splitImportant(parseStyleDeclarations(styleStr))
            if !normal.isEmpty || !important.isEmpty {
                inlineDecls[newIndex] = (normal, important)
            }
        }

        if !node.id.isNone {
            doc.idMap[node.id] = newIndex
        }

        if stack.isEmpty {
            doc.root = newIndex
        } else {
            attach(child: newIndex, to: parentAttach)
        }

        if newIndex == doc.root {
            doc.rootViewBox = attributeDict["viewBox"].flatMap(parseViewBox)
            doc.rootPreserveAspectRatio = parsePreserveAspectRatio(attributeDict["preserveAspectRatio"])
        }

        stack.append(Frame(attachTo: newIndex, ownNode: newIndex))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        guard let s = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].textBuffer += s
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        if frame.isStyleElement {
            if frame.styleTypeOK {
                tokenizeStyleSheet(frame.textBuffer)
            }
            return
        }
        guard !frame.ownNode.isNone else { return }
        let idx = Int(frame.ownNode)
        guard case .text(var text) = doc.nodes[idx].kind else { return }
        let trimmed = frame.textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text.content = doc.strings.intern(trimmed)
        doc.nodes[idx].kind = .text(text)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        errors.append(SVGParseError(message: parseError.localizedDescription))
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        errors.append(SVGParseError(message: validationError.localizedDescription))
    }

    // MARK: Tree wiring

    private func attach(child: NodeIndex, to parent: NodeIndex) {
        guard !parent.isNone else { return }
        doc.nodes[Int(child)].parent = parent
        if let last = lastChildOf[parent], !last.isNone {
            doc.nodes[Int(last)].nextSibling = child
        } else {
            doc.nodes[Int(parent)].firstChild = child
        }
        lastChildOf[parent] = child
    }

    // MARK: `<stop>` (contributes to the parent gradient's stop arena, not a node)

    private func handleStop(_ attrs: [String: String], parentAttach: NodeIndex) {
        guard !parentAttach.isNone,
              case .gradient(var gradient) = doc.nodes[Int(parentAttach)].kind else { return }
        let stop = parseGradientStop(attrs)
        doc.gradientStops.append(stop)
        gradient.stops.count += 1
        doc.nodes[Int(parentAttach)].kind = .gradient(gradient)
    }

    // MARK: CSS — tokenizing `<style>` text into transient rules (css-support.md §4.4)

    private func tokenizeStyleSheet(_ rawText: String) {
        let text = stripCSSComments(rawText)
        var idx = text.startIndex
        let end = text.endIndex

        while idx < end {
            while idx < end, text[idx].isWhitespace { idx = text.index(after: idx) }
            guard idx < end else { break }

            if text[idx] == "@" {
                skipAtRule(text, &idx)
                continue
            }

            let preludeStart = idx
            var cursor = idx
            var foundBrace = false
            while cursor < end {
                let c = text[cursor]
                if c == "{" { foundBrace = true; break }
                if c == ";" { break }
                cursor = text.index(after: cursor)
            }
            guard foundBrace else { break }

            let prelude = String(text[preludeStart..<cursor])
            var depth = 1
            var bodyCursor = text.index(after: cursor)
            let bodyStart = bodyCursor
            while bodyCursor < end, depth > 0 {
                let c = text[bodyCursor]
                if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1 }
                if depth > 0 { bodyCursor = text.index(after: bodyCursor) }
            }
            let block = String(text[bodyStart..<bodyCursor])
            idx = bodyCursor < end ? text.index(after: bodyCursor) : end
            addCSSRule(prelude: prelude, block: block)
        }
    }

    private func skipAtRule(_ text: String, _ idx: inout String.Index) {
        let end = text.endIndex
        while idx < end {
            let c = text[idx]
            if c == ";" { idx = text.index(after: idx); return }
            if c == "{" {
                var depth = 1
                idx = text.index(after: idx)
                while idx < end, depth > 0 {
                    let cc = text[idx]
                    if cc == "{" { depth += 1 }
                    else if cc == "}" { depth -= 1 }
                    idx = text.index(after: idx)
                }
                return
            }
            idx = text.index(after: idx)
        }
    }

    private func addCSSRule(prelude: String, block: String) {
        let selectorStrings = prelude.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !selectorStrings.isEmpty else { return }

        let (normal, important) = splitImportant(parseStyleDeclarations(block))
        let normalIndex = Int32(cssDeclBlocks.count)
        cssDeclBlocks.append(normal)
        let importantIndex = Int32(cssDeclBlocks.count)
        cssDeclBlocks.append(important)

        let order = cssSourceOrder
        cssSourceOrder += 1

        for selStr in selectorStrings {
            guard let selector = parseCSSSelector(selStr) else { continue }
            let specificity = computeSpecificity(selector)
            cssRules.append(CSSRule(selector: selector, declNormalIndex: normalIndex,
                                     declImportantIndex: importantIndex,
                                     specificity: specificity, sourceOrder: order))
        }
    }

    /// Parses one compound-simple-selector chain (the descendant combinator,
    /// space-separated). Returns `nil` for anything containing an unsupported
    /// combinator/selector kind (child, sibling, attribute, pseudo) — the rule
    /// is then dropped, not errored (css-support.md §4.4).
    private func parseCSSSelector(_ raw: String) -> CSSSelector? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(">") || trimmed.contains("+") || trimmed.contains("~") ||
            trimmed.contains("[") || trimmed.contains(":") {
            return nil
        }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard !parts.isEmpty else { return nil }
        let start = Int32(cssComponents.count)
        for part in parts {
            guard let simple = parseSimpleSelector(String(part)) else { return nil }
            cssComponents.append(simple)
        }
        return CSSSelector(start: start, count: Int32(parts.count))
    }

    private func parseSimpleSelector(_ token: String) -> CSSSimpleSelector? {
        guard !token.isEmpty else { return nil }
        var type: CSSTypeMatch = .any
        var id: StringRef = .none
        let classStart = Int32(cssSelClasses.count)
        var classCount: Int32 = 0

        var chars = Substring(token)
        if chars.first == "*" {
            chars = chars.dropFirst()
        } else if let first = chars.first, first != "." && first != "#" {
            var typeEnd = chars.startIndex
            while typeEnd < chars.endIndex, chars[typeEnd] != "." && chars[typeEnd] != "#" {
                typeEnd = chars.index(after: typeEnd)
            }
            let typeName = String(chars[chars.startIndex..<typeEnd])
            guard !typeName.isEmpty else { return nil }
            type = .named(doc.strings.intern(typeName))
            chars = chars[typeEnd...]
        }

        while !chars.isEmpty {
            let marker = chars.removeFirst()
            var end = chars.startIndex
            while end < chars.endIndex, chars[end] != "." && chars[end] != "#" {
                end = chars.index(after: end)
            }
            let name = String(chars[chars.startIndex..<end])
            chars = chars[end...]
            guard !name.isEmpty else { return nil }
            if marker == "." {
                cssSelClasses.append(doc.strings.intern(name))
                classCount += 1
            } else if marker == "#" {
                id = doc.strings.intern(name)
            } else {
                return nil
            }
        }

        return CSSSimpleSelector(type: type, id: id, classStart: classStart, classCount: classCount)
    }

    private func computeSpecificity(_ selector: CSSSelector) -> UInt32 {
        var a = 0, b = 0, c = 0
        for i in 0..<Int(selector.count) {
            let comp = cssComponents[Int(selector.start) + i]
            if !comp.id.isNone { a += 1 }
            b += Int(comp.classCount)
            if case .named = comp.type { c += 1 }
        }
        let pa = UInt32(min(a, 1023))
        let pb = UInt32(min(b, 1023))
        let pc = UInt32(min(c, 1023))
        return (pa << 20) | (pb << 10) | pc
    }

    // MARK: CSS — the post-parse fold (css-support.md §2, §5.3, §5.5)

    /// Runs once, after the SAX parse completes and before `SVGParser.parse`
    /// returns. Matches every rule against every node in one linear pass and
    /// applies the winning declarations directly into `doc.nodes[i].style` at
    /// the cascade order presentation < normal sheet < inline normal <
    /// important sheet < inline important. All CSS scratch (`cssRules` and
    /// friends, `inlineDecls`) is local to this delegate and is released when
    /// it deallocates after this call returns — nothing is retained on `doc`.
    func foldStyleSheet() {
        guard !cssRules.isEmpty || !inlineDecls.isEmpty else { return }

        let sortedRules = cssRules.sorted { a, b in
            if a.specificity != b.specificity { return a.specificity < b.specificity }
            return a.sourceOrder < b.sourceOrder
        }

        for i in 0..<doc.nodes.count {
            var style = doc.nodes[i].style
            let matching = sortedRules.filter { selectorMatches($0.selector, nodeIndex: i) }

            for rule in matching {
                applyStyleProperties(cssDeclBlocks[Int(rule.declNormalIndex)], into: &style, doc: &doc)
            }
            if let inl = inlineDecls[Int32(i)] {
                applyStyleProperties(inl.normal, into: &style, doc: &doc)
            }
            for rule in matching {
                applyStyleProperties(cssDeclBlocks[Int(rule.declImportantIndex)], into: &style, doc: &doc)
            }
            if let inl = inlineDecls[Int32(i)] {
                applyStyleProperties(inl.important, into: &style, doc: &doc)
            }

            doc.nodes[i].style = style
        }
    }

    private func selectorMatches(_ selector: CSSSelector, nodeIndex: Int) -> Bool {
        guard selector.count > 0 else { return false }
        let rightmost = cssComponents[Int(selector.start + selector.count - 1)]
        guard simpleMatches(rightmost, nodeIndex: nodeIndex) else { return false }
        guard selector.count > 1 else { return true }

        var compIdx = Int(selector.count) - 2
        var ancestor = doc.nodes[nodeIndex].parent
        while compIdx >= 0 {
            let comp = cssComponents[Int(selector.start) + compIdx]
            var found = false
            while !ancestor.isNone {
                let current = ancestor
                ancestor = doc.nodes[Int(ancestor)].parent
                if simpleMatches(comp, nodeIndex: Int(current)) {
                    found = true
                    break
                }
            }
            guard found else { return false }
            compIdx -= 1
        }
        return true
    }

    private func simpleMatches(_ simple: CSSSimpleSelector, nodeIndex: Int) -> Bool {
        let node = doc.nodes[nodeIndex]
        switch simple.type {
        case .any: break
        case .named(let t):
            guard let typeName = doc.strings.string(t), matchesType(typeName, node.kind) else { return false }
        }
        if !simple.id.isNone, node.id != simple.id { return false }
        if simple.classCount > 0 {
            for i in 0..<Int(simple.classCount) {
                let want = cssSelClasses[Int(simple.classStart) + i]
                var has = false
                for j in 0..<Int(node.classes.count) {
                    if doc.classNames[Int(node.classes.start) + j] == want { has = true; break }
                }
                if !has { return false }
            }
        }
        return true
    }
}

// MARK: - CSS transient selector/rule model (css-support.md §5.1; never retained)

private enum CSSTypeMatch {
    case any
    case named(StringRef)
}

private struct CSSSimpleSelector {
    var type: CSSTypeMatch
    var id: StringRef = .none
    var classStart: Int32 = 0
    var classCount: Int32 = 0
}

private struct CSSSelector {
    var start: Int32
    var count: Int32
}

private struct CSSRule {
    var selector: CSSSelector
    var declNormalIndex: Int32
    var declImportantIndex: Int32
    var specificity: UInt32
    var sourceOrder: Int32
}

/// Type-selector token → `NodeKind` mapping table (css-support.md §5.2). Total:
/// anything not listed matches nothing. `tspan` and `text` both map to
/// `NodeKind.text` — the one deliberate type-selector imprecision (§1).
private func matchesType(_ str: String, _ kind: NodeKind) -> Bool {
    switch str {
    case "svg": if case .svg = kind { return true }
    case "g": if case .group = kind { return true }
    case "rect": if case .shape(.rect) = kind { return true }
    case "circle": if case .shape(.circle) = kind { return true }
    case "ellipse": if case .shape(.ellipse) = kind { return true }
    case "line": if case .shape(.line) = kind { return true }
    case "polyline": if case .poly(_, let closed) = kind { return !closed }
    case "polygon": if case .poly(_, let closed) = kind { return closed }
    case "path": if case .path = kind { return true }
    case "image": if case .image = kind { return true }
    case "text", "tspan": if case .text = kind { return true }
    case "use": if case .use = kind { return true }
    case "symbol": if case .symbol = kind { return true }
    case "linearGradient", "radialGradient": if case .gradient = kind { return true }
    case "pattern": if case .pattern = kind { return true }
    case "clipPath": if case .clipPath = kind { return true }
    case "mask": if case .mask = kind { return true }
    case "defs": if case .defs = kind { return true }
    default: return false
    }
    return false
}

private func stripCSSComments(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count)
    var remainder = Substring(s)
    while let start = remainder.range(of: "/*") {
        result += remainder[remainder.startIndex..<start.lowerBound]
        if let commentEnd = remainder.range(of: "*/", range: start.upperBound..<remainder.endIndex) {
            remainder = remainder[commentEnd.upperBound...]
        } else {
            remainder = Substring("")
            break
        }
    }
    result += remainder
    return result
}

/// Splits a raw `[property: value]` map (as produced by `parseStyleDeclarations`)
/// into normal and `!important` declarations, stripping the marker. Shared by
/// inline `style=""` and sheet rule blocks so both parse identically
/// (css-support.md §4.3/§4.4).
private func splitImportant(_ raw: [String: String]) -> (normal: [String: String], important: [String: String]) {
    var normal: [String: String] = [:]
    var important: [String: String] = [:]
    let marker = "!important"
    for (key, value) in raw {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(marker) {
            let cutIndex = trimmed.index(trimmed.endIndex, offsetBy: -marker.count)
            important[key] = trimmed[trimmed.startIndex..<cutIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normal[key] = value
        }
    }
    return (normal, important)
}

// MARK: - Node-kind construction

private func makeNodeKind(_ tag: String, _ attrs: [String: String], doc: inout SVGDocument) -> NodeKind? {
    switch tag {
    case "svg":
        return .svg(makeNestedViewport(attrs))

    case "g":
        return .group

    case "rect":
        var rx = attrs["rx"].flatMap(parseNumber)
        var ry = attrs["ry"].flatMap(parseNumber)
        if rx == nil, ry != nil { rx = ry }
        if ry == nil, rx != nil { ry = rx }
        return .shape(.rect(x: num(attrs, "x"), y: num(attrs, "y"),
                             width: num(attrs, "width"), height: num(attrs, "height"),
                             rx: rx ?? 0, ry: ry ?? 0))

    case "circle":
        return .shape(.circle(cx: num(attrs, "cx"), cy: num(attrs, "cy"), r: num(attrs, "r")))

    case "ellipse":
        return .shape(.ellipse(cx: num(attrs, "cx"), cy: num(attrs, "cy"),
                                rx: num(attrs, "rx"), ry: num(attrs, "ry")))

    case "line":
        return .shape(.line(x1: num(attrs, "x1"), y1: num(attrs, "y1"),
                             x2: num(attrs, "x2"), y2: num(attrs, "y2")))

    case "polyline", "polygon":
        let pts = parsePoints(attrs["points"] ?? "")
        let start = doc.points.count
        doc.points.append(contentsOf: pts)
        return .poly(points: ArenaRange(start: Int32(start), count: Int32(pts.count)), closed: tag == "polygon")

    case "path":
        let cmds = PathDataParser.parse(attrs["d"] ?? "")
        let start = doc.pathCommands.count
        doc.pathCommands.append(contentsOf: cmds)
        return .path(commands: ArenaRange(start: Int32(start), count: Int32(cmds.count)))

    case "image":
        let hrefStr = attrs["href"] ?? attrs["xlink:href"] ?? ""
        return .image(Image(href: doc.strings.intern(hrefStr),
                             x: num(attrs, "x"), y: num(attrs, "y"),
                             width: num(attrs, "width"), height: num(attrs, "height"),
                             preserveAspectRatio: parsePreserveAspectRatio(attrs["preserveAspectRatio"])))

    case "text", "tspan":
        return .text(Text(x: num(attrs, "x"), y: num(attrs, "y"), content: .none))

    case "use":
        let hrefRaw = attrs["href"] ?? attrs["xlink:href"] ?? ""
        let ref = doc.strings.intern(hrefID(hrefRaw))
        return .use(Use(href: ref, resolved: doc.idMap[ref] ?? .none,
                         x: num(attrs, "x"), y: num(attrs, "y"),
                         width: parseLengthOrAuto(attrs["width"]),
                         height: parseLengthOrAuto(attrs["height"])))

    case "symbol":
        return .symbol(makeNestedViewport(attrs))

    case "linearGradient":
        let geometry = Gradient.Geometry.linear(
            x1: attrs["x1"].flatMap(parseNumber) ?? 0,
            y1: attrs["y1"].flatMap(parseNumber) ?? 0,
            x2: attrs["x2"].flatMap(parseNumber) ?? 1,
            y2: attrs["y2"].flatMap(parseNumber) ?? 0)
        return .gradient(makeGradient(geometry, attrs, doc: &doc))

    case "radialGradient":
        let cx = attrs["cx"].flatMap(parseNumber) ?? 0.5
        let cy = attrs["cy"].flatMap(parseNumber) ?? 0.5
        let geometry = Gradient.Geometry.radial(
            cx: cx, cy: cy,
            r: attrs["r"].flatMap(parseNumber) ?? 0.5,
            fx: attrs["fx"].flatMap(parseNumber) ?? cx,
            fy: attrs["fy"].flatMap(parseNumber) ?? cy)
        return .gradient(makeGradient(geometry, attrs, doc: &doc))

    case "pattern":
        var transformRef: TransformRef = .none
        if let t = attrs["patternTransform"], let m = TransformParser.parse(t) {
            doc.transforms.append(m)
            transformRef = TransformRef(doc.transforms.count - 1)
        }
        var templateRef: NodeIndex = .none
        if let hrefRaw = attrs["href"] ?? attrs["xlink:href"] {
            templateRef = doc.idMap[doc.strings.intern(hrefID(hrefRaw))] ?? .none
        }
        return .pattern(Pattern(x: num(attrs, "x"), y: num(attrs, "y"),
                                 width: num(attrs, "width"), height: num(attrs, "height"),
                                 patternUnits: parseUnits(attrs["patternUnits"], default: .objectBoundingBox),
                                 patternContentUnits: parseUnits(attrs["patternContentUnits"], default: .userSpaceOnUse),
                                 patternTransform: transformRef,
                                 viewBox: attrs["viewBox"].flatMap(parseViewBox),
                                 preserveAspectRatio: parsePreserveAspectRatio(attrs["preserveAspectRatio"]),
                                 template: templateRef))

    case "clipPath":
        return .clipPath(units: parseUnits(attrs["clipPathUnits"], default: .userSpaceOnUse))

    case "mask":
        return .mask(Mask(maskUnits: parseUnits(attrs["maskUnits"], default: .objectBoundingBox),
                           maskContentUnits: parseUnits(attrs["maskContentUnits"], default: .userSpaceOnUse)))

    case "defs":
        return .defs

    default:
        return nil
    }
}

private func makeGradient(_ geometry: Gradient.Geometry, _ attrs: [String: String], doc: inout SVGDocument) -> Gradient {
    var transformRef: TransformRef = .none
    if let t = attrs["gradientTransform"], let m = TransformParser.parse(t) {
        doc.transforms.append(m)
        transformRef = TransformRef(doc.transforms.count - 1)
    }
    var templateRef: NodeIndex = .none
    if let hrefRaw = attrs["href"] ?? attrs["xlink:href"] {
        templateRef = doc.idMap[doc.strings.intern(hrefID(hrefRaw))] ?? .none
    }
    return Gradient(geometry: geometry,
                     stops: ArenaRange(start: Int32(doc.gradientStops.count), count: 0),
                     units: parseUnits(attrs["gradientUnits"], default: .objectBoundingBox),
                     spread: parseSpreadMethod(attrs["spreadMethod"]),
                     gradientTransform: transformRef,
                     template: templateRef)
}

private func makeNestedViewport(_ attrs: [String: String]) -> NestedViewport {
    NestedViewport(x: num(attrs, "x"), y: num(attrs, "y"),
                   width: parseLengthOrAuto(attrs["width"]),
                   height: parseLengthOrAuto(attrs["height"]),
                   viewBox: attrs["viewBox"].flatMap(parseViewBox),
                   preserveAspectRatio: parsePreserveAspectRatio(attrs["preserveAspectRatio"]))
}

private func parseGradientStop(_ attrs: [String: String]) -> GradientStop {
    var props = attrs
    if let styleStr = attrs["style"] {
        for (k, v) in parseStyleDeclarations(styleStr) { props[k] = v }
    }
    var offset: CGFloat = 0
    if let raw = props["offset"] {
        if raw.hasSuffix("%"), let pct = Double(raw.dropLast()) {
            offset = CGFloat(pct / 100)
        } else {
            offset = parseNumber(raw) ?? 0
        }
    }
    offset = min(max(offset, 0), 1)
    let color = props["stop-color"].flatMap(parseColor) ?? .black
    let opacity = min(max(props["stop-opacity"].flatMap(parseNumber) ?? 1, 0), 1)
    let a = UInt8(CGFloat(color.a) * opacity)
    return GradientStop(offset: offset, color: RGBA(r: color.r, g: color.g, b: color.b, a: a))
}

// MARK: - Presentation attributes / style="" declarations

/// Applies whichever of `props`' keys are recognized presentation/style
/// properties onto `style`. Unknown keys (layout attributes like `x`/`width`,
/// structural attributes like `id`/`transform`, or unmodeled CSS properties)
/// are silently ignored, which lets the caller pass the raw XML attribute
/// dictionary directly without pre-filtering it.
private func applyStyleProperties(_ props: [String: String], into style: inout RawStyle, doc: inout SVGDocument) {
    for (key, rawValue) in props {
        let v = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "fill": style.fill = parsePaint(v, doc: &doc)
        case "stroke": style.stroke = parsePaint(v, doc: &doc)
        case "stroke-width": style.strokeWidth = parseNumber(v)
        case "color": style.color = parseColor(v)
        case "opacity": style.opacity = parseNumber(v)
        case "fill-opacity": style.fillOpacity = parseNumber(v)
        case "stroke-opacity": style.strokeOpacity = parseNumber(v)
        case "fill-rule": style.fillRule = parseFillRule(v)
        case "clip-rule": style.clipRule = parseFillRule(v)
        case "stroke-linecap": style.strokeLineCap = parseLineCap(v)
        case "stroke-linejoin": style.strokeLineJoin = parseLineJoin(v)
        case "stroke-miterlimit": style.strokeMiterLimit = parseNumber(v)
        case "stroke-dashoffset": style.strokeDashOffset = parseNumber(v)
        // NOTE: `strokeDashArray` is a window into a dedicated dash arena that
        // SVGDocument does not (yet) declare — see SVGModel.swift RawStyle;
        // there is nowhere to store the parsed values without inventing
        // storage the model doesn't define, so `stroke-dasharray` is not
        // populated here. Flagging rather than guessing at a new arena.
        case "font-family": style.fontFamily = doc.strings.intern(v)
        case "font-size": style.fontSize = parseNumber(v)
        case "font-weight": style.fontWeight = parseFontWeight(v)
        case "font-style": style.fontStyle = parseFontStyle(v)
        case "text-anchor": style.textAnchor = parseTextAnchor(v)
        case "visibility": style.visibility = parseVisibility(v)
        case "display": style.display = (v == "none") ? Display.none : .inline
        case "clip-path":
            if let id = extractURLId(v) { style.clipPath = doc.idMap[doc.strings.intern(id)] ?? NodeIndex.none }
        case "mask":
            if let id = extractURLId(v) { style.mask = doc.idMap[doc.strings.intern(id)] ?? NodeIndex.none }
        case "mix-blend-mode": style.blendMode = parseBlendMode(v)
        case "isolation": style.isolation = parseIsolation(v)
        default:
            break
        }
    }
}

private func parseStyleDeclarations(_ s: String) -> [String: String] {
    var result: [String: String] = [:]
    for decl in s.split(separator: ";") {
        let parts = decl.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        result[key] = value
    }
    return result
}

// MARK: - Paint / color

private func parsePaint(_ raw: String, doc: inout SVGDocument) -> Paint {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s == "none" { return .none }
    if s == "currentColor" { return .currentColor }
    if s.hasPrefix("url(") {
        guard let id = extractURLId(s) else { return .none }
        let ref = doc.strings.intern(id)
        let node = doc.idMap[ref] ?? .none
        let afterURL: String
        if let closeParen = s.firstIndex(of: ")") {
            afterURL = String(s[s.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
        } else {
            afterURL = ""
        }
        let fallback: PaintFallback
        if afterURL.isEmpty { fallback = .none }
        else if afterURL == "none" { fallback = .explicitNone }
        else if let c = parseColor(afterURL) { fallback = .color(c) }
        else { fallback = .none }
        return .server(PaintServer(id: ref, node: node), fallback: fallback)
    }
    if let c = parseColor(s) { return .color(c) }
    return .none
}

private func extractURLId(_ s: String) -> String? {
    guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")"), open < close else { return nil }
    var inner = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    inner = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    if inner.hasPrefix("#") { inner.removeFirst() }
    return inner
}

private func parseColor(_ raw: String) -> RGBA? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") {
        let hex = s.dropFirst()
        switch hex.count {
        case 3:
            guard let r = hexNibble(hex, 0), let g = hexNibble(hex, 1), let b = hexNibble(hex, 2) else { return nil }
            return RGBA(r: r * 17, g: g * 17, b: b * 17)
        case 6:
            guard let v = UInt32(hex, radix: 16) else { return nil }
            return RGBA(r: UInt8((v >> 16) & 0xff), g: UInt8((v >> 8) & 0xff), b: UInt8(v & 0xff))
        case 8:
            guard let v = UInt32(hex, radix: 16) else { return nil }
            return RGBA(r: UInt8((v >> 24) & 0xff), g: UInt8((v >> 16) & 0xff),
                        b: UInt8((v >> 8) & 0xff), a: UInt8(v & 0xff))
        default:
            return nil
        }
    }
    if s.hasPrefix("rgb(") || s.hasPrefix("rgba(") {
        guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { return nil }
        let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        func component(_ p: String) -> UInt8 {
            if p.hasSuffix("%"), let pct = Double(p.dropLast()) {
                return UInt8(max(0, min(255, pct / 100 * 255)))
            }
            return UInt8(max(0, min(255, Double(p) ?? 0)))
        }
        let r = component(parts[0]), g = component(parts[1]), b = component(parts[2])
        var a: UInt8 = 255
        if parts.count >= 4, let av = Double(parts[3]) { a = UInt8(max(0, min(255, av * 255))) }
        return RGBA(r: r, g: g, b: b, a: a)
    }
    switch s.lowercased() {
    case "black": return .black
    case "white": return RGBA(r: 255, g: 255, b: 255)
    case "red": return RGBA(r: 255, g: 0, b: 0)
    case "green": return RGBA(r: 0, g: 128, b: 0)
    case "blue": return RGBA(r: 0, g: 0, b: 255)
    case "transparent": return .transparent
    default: return nil
    }
}

private func hexNibble(_ s: Substring, _ index: Int) -> UInt8? {
    let c = s[s.index(s.startIndex, offsetBy: index)]
    return UInt8(String(c), radix: 16)
}

// MARK: - Small value parsers

private func num(_ attrs: [String: String], _ key: String, default def: CGFloat = 0) -> CGFloat {
    attrs[key].flatMap(parseNumber) ?? def
}

/// Parses a leading numeric literal, tolerating a trailing unit/percent
/// suffix (the suffix itself is ignored; unit-aware resolution is a later
/// layer's concern per RawStyle's "raw, unresolved" contract).
private func parseNumber(_ raw: String) -> CGFloat? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let d = Double(s) { return CGFloat(d) }
    var end = s.endIndex
    while end > s.startIndex {
        let prev = s.index(before: end)
        let c = s[prev]
        if c.isNumber || c == "." || c == "-" || c == "+" || c == "e" || c == "E" { break }
        end = prev
    }
    guard end > s.startIndex, let d = Double(s[s.startIndex..<end]) else { return nil }
    return CGFloat(d)
}

private func splitNumbers(_ s: String) -> [CGFloat] {
    s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        .compactMap { parseNumber(String($0)) }
}

private func parsePoints(_ s: String) -> [CGPoint] {
    let numbers = splitNumbers(s)
    var pts: [CGPoint] = []
    var i = 0
    while i + 1 < numbers.count {
        pts.append(CGPoint(x: numbers[i], y: numbers[i + 1]))
        i += 2
    }
    return pts
}

private func parseViewBox(_ s: String) -> ViewBox? {
    let n = splitNumbers(s)
    guard n.count == 4 else { return nil }
    return ViewBox(minX: n[0], minY: n[1], width: n[2], height: n[3])
}

private func parseLengthOrAuto(_ s: String?) -> LengthOrAuto {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .auto }
    if s == "auto" { return .auto }
    guard let n = parseNumber(s) else { return .auto }
    return .value(n)
}

private func parsePreserveAspectRatio(_ s: String?) -> PreserveAspectRatio {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .default }
    var tokens = s.split(separator: " ").map(String.init)
    var defers = false
    if tokens.first == "defer" { defers = true; tokens.removeFirst() }
    guard let alignToken = tokens.first else { return .default }
    let align: PreserveAspectRatio.Align
    switch alignToken {
    case "none": align = .none
    case "xMinYMin": align = .xMinYMin
    case "xMidYMin": align = .xMidYMin
    case "xMaxYMin": align = .xMaxYMin
    case "xMinYMid": align = .xMinYMid
    case "xMidYMid": align = .xMidYMid
    case "xMaxYMid": align = .xMaxYMid
    case "xMinYMax": align = .xMinYMax
    case "xMidYMax": align = .xMidYMax
    case "xMaxYMax": align = .xMaxYMax
    default: align = .xMidYMid
    }
    let meetOrSlice: PreserveAspectRatio.MeetOrSlice = (tokens.count > 1 && tokens[1] == "slice") ? .slice : .meet
    return PreserveAspectRatio(align: align, meetOrSlice: meetOrSlice, defers: defers)
}

private func parseUnits(_ s: String?, default def: Units) -> Units {
    switch s {
    case "userSpaceOnUse": return .userSpaceOnUse
    case "objectBoundingBox": return .objectBoundingBox
    default: return def
    }
}

private func parseSpreadMethod(_ s: String?) -> SpreadMethod {
    switch s {
    case "reflect": return .reflect
    case "repeat": return .repeatSpread
    default: return .pad
    }
}

private func hrefID(_ raw: String) -> String {
    var s = raw
    if s.hasPrefix("#") { s.removeFirst() }
    return s
}

private func parseFillRule(_ s: String) -> FillRule? {
    switch s {
    case "nonzero": return .nonZero
    case "evenodd": return .evenOdd
    default: return nil
    }
}

private func parseLineCap(_ s: String) -> LineCap? {
    switch s {
    case "butt": return .butt
    case "round": return .round
    case "square": return .square
    default: return nil
    }
}

private func parseLineJoin(_ s: String) -> LineJoin? {
    switch s {
    case "miter": return .miter
    case "round": return .round
    case "bevel": return .bevel
    default: return nil
    }
}

private func parseFontStyle(_ s: String) -> FontStyle? {
    switch s {
    case "normal": return .normal
    case "italic": return .italic
    case "oblique": return .oblique
    default: return nil
    }
}

private func parseTextAnchor(_ s: String) -> TextAnchor? {
    switch s {
    case "start": return .start
    case "middle": return .middle
    case "end": return .end
    default: return nil
    }
}

private func parseVisibility(_ s: String) -> Visibility? {
    switch s {
    case "visible": return .visible
    case "hidden": return .hidden
    case "collapse": return .collapse
    default: return nil
    }
}

/// `mix-blend-mode` keyword → `BlendMode`. Unknown/malformed → `nil`, which
/// leaves `RawStyle.blendMode` unset so resolution falls back to the initial
/// value `.normal` (CSS "invalid value → initial"; Design/blend-modes.md §2.2).
private func parseBlendMode(_ s: String) -> BlendMode? {
    switch s.lowercased() {
    case "normal": return .normal
    case "multiply": return .multiply
    case "screen": return .screen
    case "overlay": return .overlay
    case "darken": return .darken
    case "lighten": return .lighten
    case "color-dodge": return .colorDodge
    case "color-burn": return .colorBurn
    case "hard-light": return .hardLight
    case "soft-light": return .softLight
    case "difference": return .difference
    case "exclusion": return .exclusion
    case "hue": return .hue
    case "saturation": return .saturation
    case "color": return .color
    case "luminosity": return .luminosity
    default: return nil
    }
}

private func parseIsolation(_ s: String) -> Isolation? {
    switch s.lowercased() {
    case "auto": return .auto
    case "isolate": return .isolate
    default: return nil
    }
}

private func parseFontWeight(_ s: String) -> FontWeight? {
    if let n = Int(s) { return FontWeight(n) }
    switch s {
    case "bold": return .bold
    case "normal": return .normal
    default: return nil
    }
}
