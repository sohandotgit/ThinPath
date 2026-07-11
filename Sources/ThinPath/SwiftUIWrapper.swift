//
//  SwiftUIWrapper.swift
//  ThinPath
//
//  Render-only SwiftUI wrapper pinned in Design/swiftui-wrapper-api.md
//  (session S3) and made to pass the frozen test spec
//  (Tests/swiftui-wrapper.spec.md, session S4). Signatures are frozen — this
//  file only supplies bodies.
//

#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics
import Dispatch

/// Where `ThinPathView` runs rasterization. See Design/swiftui-wrapper-api.md §3.1/§5.
@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
public enum ThinPathRenderingMode: Equatable {
    case asynchronous
    case synchronous
}

/// iOS-13-compatible replacement for `.onChange(of:perform:)`, which itself
/// only became available in iOS 14 — below that floor, `ThinPathView` (pinned
/// to iOS 13 per Design/swiftui-wrapper-api.md §2) can't call it directly.
/// Detects a change during `body` evaluation and defers the actual state
/// write/callback to the next run loop turn via `DispatchQueue.main.async`,
/// which avoids mutating `@State` mid-update.
@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
private struct OnChangeCompat<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void
    @State private var seenValue: Value?

    func body(content: Content) -> some View {
        if seenValue != value {
            DispatchQueue.main.async {
                guard seenValue != value else { return }
                seenValue = value
                action(value)
            }
        }
        return content
    }
}

/// Shared rasterization helpers used by both `ThinPathView` and the `Image`
/// convenience below. Not part of the public surface — see
/// Design/swiftui-wrapper-api.md §5.1 ("the queue and its identity are not
/// part of the public API").
private enum ThinPathRasterizer {
    static let queue = DispatchQueue(label: "ThinPath.SwiftUIWrapper.raster", qos: .userInitiated)

    /// Settles on `nil` (empty) for any of the degenerate cases in
    /// Design/swiftui-wrapper-api.md §3.3, never throwing/trapping.
    static func raster(_ document: SVGDocument, size: CGSize, scale: CGFloat,
                        preserveAspectRatio: PreserveAspectRatio) -> CGImage? {
        guard !document.root.isNone, document.rootViewBox != nil,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        var configured = document
        configured.rootPreserveAspectRatio = preserveAspectRatio
        return ThinPath().render(configured, size: size, scale: scale)
    }
}

/// Render-only convenience view over `ThinPath().render(_:size:scale:)`. See
/// Design/swiftui-wrapper-api.md §3 for the full contract.
@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
public struct ThinPathView<Placeholder: View>: View {
    private let document: SVGDocument
    private let preserveAspectRatio: PreserveAspectRatio?
    private let scale: CGFloat?
    private let rendering: ThinPathRenderingMode
    private let placeholder: Placeholder

    @Environment(\.displayScale) private var environmentDisplayScale: CGFloat
    @State private var cachedImage: CGImage?
    @State private var cachedKey: RasterKey?
    @State private var latestRequestedKey: RasterKey?

    public init(_ document: SVGDocument,
                preserveAspectRatio: PreserveAspectRatio? = nil,
                scale: CGFloat? = nil,
                rendering: ThinPathRenderingMode = .asynchronous,
                @ViewBuilder placeholder: () -> Placeholder) {
        self.document = document
        self.preserveAspectRatio = preserveAspectRatio
        self.scale = scale
        self.rendering = rendering
        self.placeholder = placeholder()
    }

    /// Cache/single-flight key: §5.3 keys on `(resolvedFrameSize,
    /// effectiveScale, effectivePreserveAspectRatio)` only — never on document
    /// contents (§5.5, the document is immutable for a view's identity).
    private struct RasterKey: Equatable {
        var size: CGSize
        var scale: CGFloat
        var preserveAspectRatio: PreserveAspectRatio
    }

    private var effectiveScale: CGFloat { scale ?? environmentDisplayScale }

    private var effectivePreserveAspectRatio: PreserveAspectRatio {
        preserveAspectRatio ?? document.rootPreserveAspectRatio
    }

    /// §3.2 ideal size: the document's `rootViewBox` size, or `.zero`.
    private var idealSize: CGSize {
        guard let viewBox = document.rootViewBox else { return .zero }
        return CGSize(width: viewBox.width, height: viewBox.height)
    }

    public var body: some View {
        GeometryReader { proxy in
            content(for: proxy.size)
        }
        // A flexible frame: passes through any proposed size unchanged, and
        // only substitutes `idealSize` when the incoming proposal is
        // nil/unspecified (e.g. `.fixedSize()`, a scroll view). This is what
        // gives the view both "accepts any proposed size" (§3.2 flexibility)
        // and "ideal size == rootViewBox size" (§3.2) for free.
        .frame(idealWidth: idealSize.width, idealHeight: idealSize.height)
    }

    @ViewBuilder
    private func content(for size: CGSize) -> some View {
        let key = RasterKey(size: size, scale: effectiveScale, preserveAspectRatio: effectivePreserveAspectRatio)
        switch rendering {
        case .synchronous:
            // Inline on the main thread, within this layout pass — the
            // placeholder is never shown (§5.2).
            if let image = ThinPathRasterizer.raster(document, size: key.size, scale: key.scale,
                                                       preserveAspectRatio: key.preserveAspectRatio) {
                SwiftUI.Image(decorative: image, scale: key.scale, orientation: .up)
            } else {
                Color.clear
            }
        case .asynchronous:
            Group {
                if let cachedImage {
                    SwiftUI.Image(decorative: cachedImage, scale: key.scale, orientation: .up)
                } else {
                    placeholder
                }
            }
            .onAppear { rasterAsynchronouslyIfNeeded(key: key) }
            .modifier(OnChangeCompat(value: key) { newKey in rasterAsynchronouslyIfNeeded(key: newKey) })
        }
    }

    /// §5.1: the CPU-heavy walk+raster runs on the background executor
    /// (`ThinPathRasterizer.queue`), keyed so a superseding key discards a
    /// stale in-flight result instead of publishing it. The previous
    /// `cachedImage` is left in place until the new one lands, so a key
    /// change never flashes to the placeholder.
    private func rasterAsynchronouslyIfNeeded(key: RasterKey) {
        guard key != cachedKey else { return }
        latestRequestedKey = key
        let document = self.document
        let image = ThinPathRasterizer.queue.sync {
            ThinPathRasterizer.raster(document, size: key.size, scale: key.scale,
                                       preserveAspectRatio: key.preserveAspectRatio)
        }
        guard latestRequestedKey == key else { return }
        cachedImage = image
        cachedKey = key
    }
}

@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
extension ThinPathView where Placeholder == Color {
    public init(_ document: SVGDocument,
                preserveAspectRatio: PreserveAspectRatio? = nil,
                scale: CGFloat? = nil,
                rendering: ThinPathRenderingMode = .asynchronous) {
        self.init(document,
                   preserveAspectRatio: preserveAspectRatio,
                   scale: scale,
                   rendering: rendering) { Color.clear }
    }
}

/// Fixed-size decorative `Image` convenience. See Design/swiftui-wrapper-api.md §4.
///
/// Explicitly qualified as `SwiftUI.Image` — ThinPath's own IR also declares a
/// (unrelated) `Image` struct for the `<image>` element (SVGModel.swift), and
/// an unqualified `extension Image` here would silently bind to that sibling
/// type instead of `SwiftUI.Image` (same-module lookup wins over the imported
/// module's type of the same name).
@available(iOS 13.0, macOS 11.0, watchOS 7.0, *)
extension SwiftUI.Image {
    public init?(_ document: SVGDocument, size: CGSize, scale: CGFloat = 1) {
        guard let cgImage = ThinPathRasterizer.raster(document, size: size, scale: scale,
                                                       preserveAspectRatio: document.rootPreserveAspectRatio) else {
            return nil
        }
        self.init(decorative: cgImage, scale: scale, orientation: .up)
    }

    public static func thinPath(_ document: SVGDocument,
                                 size: CGSize,
                                 scale: CGFloat = 1) async -> SwiftUI.Image? {
        let cgImage = await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            ThinPathRasterizer.queue.async {
                continuation.resume(returning: ThinPathRasterizer.raster(
                    document, size: size, scale: scale,
                    preserveAspectRatio: document.rootPreserveAspectRatio))
            }
        }
        guard let cgImage else { return nil }
        return SwiftUI.Image(decorative: cgImage, scale: scale, orientation: .up)
    }
}
#endif
