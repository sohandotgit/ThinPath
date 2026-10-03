//
//  UseSymbolRenderer.swift
//  ThinPath
//
//  `<use>`/`<symbol>` instancing is, by design (RenderPipeline.md §6,
//  ReferenceResolver.swift), almost entirely a matter of re-walking the
//  target's EXISTING arena nodes under an instance transform — no subtree copy,
//  no separate leaf-drawing concern, so most of it lives directly in
//  `RenderWalk.renderUse`/`renderSymbolInstance` (RenderContext.swift). This
//  file holds the one piece factored out for clarity: applying the
//  `<symbol>`/nested-`<svg>` viewport's overflow clip at the correct point in
//  the transform stack.
//

import CoreGraphics
import Foundation

public enum UseSymbolRenderer {

    /// Clip to the viewport rect a `<use>` establishes when it targets a
    /// `<symbol>`/nested `<svg>` (overflow:hidden — the only policy modeled).
    /// A no-op for a plain-shape/group target (`instanceViewportRect` returns
    /// `nil`).
    ///
    /// MUST be called BEFORE `RenderContext.concatenate(instanceTransform)`:
    /// `instanceTransform` folds the placement translate AND the viewBox
    /// alignment matrix into one matrix, but `use.x/y/width/height` (what the
    /// viewport rect is made of) are only meaningful in the use SITE's user
    /// space — i.e. the space in effect right here, before that fold.
    public static func applyViewportClip(for use: Use, context: RenderContext) {
        guard let rect = context.references.instanceViewportRect(
            for: use, currentViewport: context.current.viewport
        ) else { return }
        context.clip(toUserRect: rect)
    }
}
