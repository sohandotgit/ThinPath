//
//  PathDataParser.swift
//  ThinPath
//
//  Parses a `<path d="...">` string into a stream of `PathCommand` values as
//  pure data. No `CGPath` construction and no arc-to-Bezier conversion happens
//  here — `ArcTo` keeps its raw endpoint parameters exactly as authored, and
//  the flattening/render pass owns turning that into geometry (see the
//  `PathCommand`/`ArcTo` doc comments in SVGModel.swift).
//

import CoreGraphics
import Foundation

public enum PathDataParser {

    /// Parse a full `d` attribute value into a command stream. Malformed input
    /// is handled by stopping at the first point the grammar breaks down and
    /// returning whatever commands were already produced — this never crashes,
    /// it just yields a partial (possibly empty) result.
    public static func parse(_ d: String) -> [PathCommand] {
        var scanner = PathScanner(d)
        var commands: [PathCommand] = []

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        // The command letter driving implicit repetition. `nil` means the next
        // token in the stream MUST be an explicit command letter.
        var activeCommand: Character?

        // Reflected-control-point state for S/s and T/t. Cleared by any command
        // that isn't the matching curve family, per the smooth-curve spec rule.
        var lastCubicControl2: CGPoint?
        var lastQuadControl: CGPoint?

        while true {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            let letter: Character
            if let l = scanner.peekCommandLetter() {
                scanner.advance()
                letter = l
                activeCommand = l
            } else if let a = activeCommand {
                letter = a
            } else {
                // Next token isn't a command letter and there's no active
                // command to repeat implicitly — malformed; stop here.
                break
            }

            var allowsImplicitRepeat = true

            switch letter {
            case "M", "m":
                guard let p = scanner.readCoordinatePair() else { return commands }
                let point = letter == "m" ? current + p : p
                current = point
                subpathStart = point
                commands.append(.moveTo(point))
                lastCubicControl2 = nil
                lastQuadControl = nil
                activeCommand = letter == "m" ? "l" : "L"

            case "L", "l":
                guard let p = scanner.readCoordinatePair() else { return commands }
                let point = letter == "l" ? current + p : p
                current = point
                commands.append(.lineTo(point))
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "H", "h":
                guard let x = scanner.readNumber() else { return commands }
                let point = CGPoint(x: letter == "h" ? current.x + x : x, y: current.y)
                current = point
                commands.append(.lineTo(point))
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "V", "v":
                guard let y = scanner.readNumber() else { return commands }
                let point = CGPoint(x: current.x, y: letter == "v" ? current.y + y : y)
                current = point
                commands.append(.lineTo(point))
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "C", "c":
                guard let c1 = scanner.readCoordinatePair(),
                      let c2 = scanner.readCoordinatePair(),
                      let e = scanner.readCoordinatePair() else { return commands }
                let relative = letter == "c"
                let control1 = relative ? current + c1 : c1
                let control2 = relative ? current + c2 : c2
                let end = relative ? current + e : e
                commands.append(.cubicTo(control1: control1, control2: control2, end: end))
                current = end
                lastCubicControl2 = control2
                lastQuadControl = nil

            case "S", "s":
                guard let c2 = scanner.readCoordinatePair(),
                      let e = scanner.readCoordinatePair() else { return commands }
                let relative = letter == "s"
                let control2 = relative ? current + c2 : c2
                let end = relative ? current + e : e
                let control1 = lastCubicControl2.map { current * 2 - $0 } ?? current
                commands.append(.cubicTo(control1: control1, control2: control2, end: end))
                current = end
                lastCubicControl2 = control2
                lastQuadControl = nil

            case "Q", "q":
                guard let c = scanner.readCoordinatePair(),
                      let e = scanner.readCoordinatePair() else { return commands }
                let relative = letter == "q"
                let control = relative ? current + c : c
                let end = relative ? current + e : e
                commands.append(.quadTo(control: control, end: end))
                current = end
                lastQuadControl = control
                lastCubicControl2 = nil

            case "T", "t":
                guard let e = scanner.readCoordinatePair() else { return commands }
                let relative = letter == "t"
                let end = relative ? current + e : e
                let control = lastQuadControl.map { current * 2 - $0 } ?? current
                commands.append(.quadTo(control: control, end: end))
                current = end
                lastQuadControl = control
                lastCubicControl2 = nil

            case "A", "a":
                guard let rx = scanner.readNumber(),
                      let ry = scanner.readNumber(),
                      let rot = scanner.readNumber(),
                      let largeArc = scanner.readFlag(),
                      let sweep = scanner.readFlag(),
                      let e = scanner.readCoordinatePair() else { return commands }
                let relative = letter == "a"
                let end = relative ? current + e : e
                commands.append(.arc(ArcTo(rx: abs(rx), ry: abs(ry), xAxisRotation: rot,
                                            largeArc: largeArc, sweep: sweep, end: end)))
                current = end
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "Z", "z":
                commands.append(.close)
                current = subpathStart
                lastCubicControl2 = nil
                lastQuadControl = nil
                allowsImplicitRepeat = false

            default:
                // Unknown command letter — malformed; stop here.
                return commands
            }

            if !allowsImplicitRepeat { activeCommand = nil }
        }

        return commands
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }
}

// MARK: - Scanner

/// Minimal, allocation-light scanner over path-data grammar: numbers,
/// coordinate pairs, and the packed 0/1 arc flags (which may appear with no
/// separator before/after, e.g. `"a5 5 0 015 5"`).
private struct PathScanner {
    private let chars: [Character]
    private var i: Int = 0

    private static let commandLetters: Set<Character> = [
        "M", "m", "L", "l", "H", "h", "V", "v",
        "C", "c", "S", "s", "Q", "q", "T", "t",
        "A", "a", "Z", "z",
    ]

    init(_ s: String) { chars = Array(s) }

    var isAtEnd: Bool { i >= chars.count }

    mutating func advance() { i += 1 }

    mutating func skipSeparators() {
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," {
                i += 1
            } else {
                break
            }
        }
    }

    func peekCommandLetter() -> Character? {
        guard i < chars.count, Self.commandLetters.contains(chars[i]) else { return nil }
        return chars[i]
    }

    mutating func readCoordinatePair() -> CGPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// A single-character `0`/`1` flag. May be glued directly against
    /// whatever follows (no separator required on either side).
    mutating func readFlag() -> Bool? {
        skipSeparators()
        guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
        let value = chars[i] == "1"
        i += 1
        return value
    }

    mutating func readNumber() -> CGFloat? {
        skipSeparators()
        let start = i
        if i < chars.count, (chars[i] == "+" || chars[i] == "-") { i += 1 }
        var sawDigit = false
        while i < chars.count, chars[i].isASCII, chars[i].isNumber {
            i += 1
            sawDigit = true
        }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                i += 1
                sawDigit = true
            }
        }
        guard sawDigit else { i = start; return nil }
        if i < chars.count, (chars[i] == "e" || chars[i] == "E") {
            let expStart = i
            i += 1
            if i < chars.count, (chars[i] == "+" || chars[i] == "-") { i += 1 }
            var sawExpDigit = false
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                i += 1
                sawExpDigit = true
            }
            if !sawExpDigit { i = expStart }
        }
        return CGFloat(Double(String(chars[start..<i])) ?? 0)
    }
}
