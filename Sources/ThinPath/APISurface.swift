//
//  APISurface.swift
//  ThinPath
//
//  PROVISIONAL. This file declares the library's public entry points as
//  compilable stubs so downstream threads (parsing, layout, rendering) can
//  write tests against a stable public shape before those threads land. Every
//  body is `fatalError("unimplemented")` — there is no behavior here yet.
//
//  These signatures are expected to be finalized by the architecture thread
//  (overall API shape) and the rendering thread (actual `render` behavior).
//  Treat renames/signature changes here as normal churn until that lands;
//  what should stay stable in the meantime is the *shape*: one parse entry
//  point that returns a document plus non-fatal errors, and a renderer that
//  can draw into an existing `CGContext` or produce a standalone `CGImage`.
//

import CoreGraphics
import Foundation

// MARK: - Parsing entry point

/// A non-fatal problem encountered while parsing an SVG document. Parsing is
/// intended to be resilient: recoverable problems (an unknown element, a
/// malformed attribute, an unresolvable `href`) are collected here rather than
/// aborting the parse, so a document that is "mostly fine" still renders.
///
/// PROVISIONAL: fields will likely grow (e.g. a source location) once the
/// parser thread defines its diagnostics model.
public struct SVGParseError: Error, Equatable {
    public var message: String
    public init(message: String) {
        self.message = message
    }
}

/// Parse SVG document data into the in-memory IR (`SVGDocument`).
///
/// Returns the best-effort parsed document alongside any non-fatal errors
/// encountered. An empty `errors` array means a clean parse; a non-empty array
/// does not necessarily mean the document is unusable — callers may choose to
/// render anyway and surface `errors` as diagnostics.
///
/// - Note: PROVISIONAL — unimplemented. Owned by the parsing thread.
public func parse(data: Data) -> (document: SVGDocument, errors: [SVGParseError]) {
    SVGParser.parse(data: data)
}

// MARK: - Rendering entry point

/// The top-level renderer: draws a parsed `SVGDocument` using Core Graphics.
///
/// PROVISIONAL: this type intentionally has no stored configuration yet
/// (color-space handling, caching, tile/async rendering are all open
/// questions for the rendering thread). Treat it as the stable *name* and
/// *call shape* downstream test code can compile against.
public struct ThinPath {

    public init() {}

    /// Draw `document` into an existing graphics context, filling `rect` in
    /// the context's coordinate space (the document's `viewBox`/intrinsic size
    /// is fit into `rect` per its `preserveAspectRatio`).
    ///
    /// See `ThinPath.swift` for the actual implementation (`RenderContext`
    /// + `RenderWalk` + `DefaultVisitor`).
    public func render(_ document: SVGDocument, into context: CGContext, rect: CGRect) {
        SVGRootRenderer.render(document, into: context, rect: rect,
                               images: ImageCache(budgetBytes: SVGRootRenderer.defaultImageBudgetBytes))
    }

    /// Convenience: rasterize `document` into a standalone `CGImage` at the
    /// given pixel `size` and `scale` (e.g. `scale: 2` for a @2x bitmap).
    /// Returns `nil` if the image could not be created (e.g. degenerate size).
    ///
    /// See `ThinPath.swift` for the actual implementation.
    public func render(_ document: SVGDocument, size: CGSize, scale: CGFloat = 1) -> CGImage? {
        SVGRootRenderer.render(document, size: size, scale: scale)
    }
}
